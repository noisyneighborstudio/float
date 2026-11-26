// Float liquid-glass transition shader:
//   effectKind 1: Diagonal wave + per-tile Fresnel bevel & specular sheen reveal
//   effectKind 2: Single continuous frosted-glass curtain wipe reveal
//   effectKind 3: Tile-origin liquid-glass lens morph -> breathing veil -> seamless wipe-open (when releaseAt >= 0)
//   effectKind 4: Directional diagonal liquid-glass curtain -> breathing veil -> seamless wipe-open (when releaseAt >= 0)
//   effectKind 5: Reverse glass sweep (web -> home) feeding into chosen revealStyle

struct Uniforms {
    resolution: vec2f,
    time: f32,
    devicePixelRatio: f32,
    effectKind: f32,
    siteCount: f32,
    gridCols: f32,
    hasResume: f32,
    resumeH: f32,
    originCx: f32,
    originCy: f32,
    originW: f32,
    originH: f32,
    originRadius: f32,
    releaseAt: f32,
    revealStyle: f32,
}

@group(0) @binding(0) var<uniform> u: Uniforms;

fn clamp01(x: f32) -> f32 {
    return clamp(x, 0.0, 1.0);
}

fn easeOutCubic(t: f32) -> f32 {
    let inv = 1.0 - t;
    return 1.0 - inv * inv * inv;
}

fn easeInOutCubic(t: f32) -> f32 {
    if (t < 0.5) {
        return 4.0 * t * t * t;
    }
    let k = -2.0 * t + 2.0;
    return 1.0 - (k * k * k) * 0.5;
}

fn continuousMorph(t: f32) -> f32 {
    if (t <= 0.0) { return 0.0; }
    if (t >= 1.0) { return 1.0; }
    let a = pow(t, 1.65);
    let b = pow(1.0 - t, 2.35);
    return a / (a + b);
}

fn sdRoundRect(p: vec2f, halfSize: vec2f, radius: f32) -> f32 {
    let q = abs(p) - (halfSize - vec2f(radius, radius));
    return length(max(q, vec2f(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

fn overPremul(top: vec4f, bot: vec4f) -> vec4f {
    return top + bot * (1.0 - top.a);
}

// Evaluates a single card's synchronized Fresnel bevel + specular glass sheen flash
fn cardBevelFlash(p: vec2f, center: vec2f, cardSize: vec2f, radius: f32, localT: f32, aa: f32) -> vec4f {
    if (localT < 0.0 || localT > 0.54) {
        return vec4f(0.0, 0.0, 0.0, 0.0);
    }

    let enterP = easeOutCubic(clamp01(localT / 0.34));
    let scale = mix(0.94, 1.0, enterP);
    let liftY = mix(8.0, 0.0, enterP);
    let lp = (p - vec2f(center.x, center.y + liftY)) / scale;
    let halfSize = cardSize * 0.5;
    let dist = sdRoundRect(lp, halfSize, radius);
    if (dist > 6.5) {
        return vec4f(0.0, 0.0, 0.0, 0.0);
    }

    let inside = 1.0 - smoothstep(-aa, aa, dist);
    let tuv = clamp((lp + halfSize) / max(cardSize, vec2f(1.0, 1.0)), vec2f(0.0), vec2f(1.0));
    let tDiag = tuv.x * 0.65 + tuv.y * 0.35;

    let sheenPos = mix(-0.35, 1.35, easeInOutCubic(clamp01(localT / 0.44)));
    let sheen = exp(-pow((tDiag - sheenPos) * 5.2, 2.0));
    let envelope = sin(clamp01(localT / 0.50) * 3.14159265);

    // Luminous cyan-turquoise Fresnel bevel rim around the rounded-rect edge
    let rim = smoothstep(-2.4 - aa, -2.4 + aa, dist) * (1.0 - smoothstep(-aa, aa, dist));
    let rimHighlight = (0.42 + 0.58 * exp(-pow((tDiag - sheenPos) * 3.2, 2.0))) * envelope;

    // Soft frosted emerald-teal glaze that crystallizes away
    let frost = (1.0 - easeOutCubic(clamp01(localT / 0.30))) * 0.30 * inside;
    var tileRgb = vec3f(0.10, 0.70, 0.72) * frost;
    var tileA = frost;

    // Specular sheen band across the glass face
    let sa = sheen * envelope * 0.40 * inside;
    tileRgb = mix(tileRgb, vec3f(0.86, 1.0, 0.99), sa / max(tileA + sa, 0.001));
    tileA = clamp01(tileA + sa);

    // Specular bevel rim highlight
    let ra = rim * rimHighlight * 0.88;
    let rimCol = mix(vec3f(0.30, 0.96, 0.96), vec3f(0.92, 1.0, 1.0), sheen);
    tileRgb = mix(tileRgb, rimCol, ra / max(tileA + ra, 0.001));
    tileA = max(tileA, ra);

    // Subtle outer cyan aura bloom around bevel
    let glow = (1.0 - smoothstep(0.0, 5.5, max(dist, 0.0))) * (1.0 - inside) * envelope * 0.20;
    tileRgb = tileRgb + vec3f(0.24, 0.92, 0.92) * glow;
    tileA = clamp01(tileA + glow);

    return vec4f(clamp(tileRgb * tileA, vec3f(0.0), vec3f(tileA)), tileA);
}

// Effect 1: O(1) per-pixel analytical grid wave + per-tile Fresnel bevel & sheen
fn renderWaveReveal(p: vec2f, size: vec2f, t: f32, aa: f32) -> vec4f {
    if (t < 0.0 || t >= 0.96) {
        return vec4f(0.0, 0.0, 0.0, 0.0);
    }

    var acc = vec4f(0.0, 0.0, 0.0, 0.0);

    // Ambient diagonal caustic light wave across the Home backdrop
    let uv = p / max(size, vec2f(1.0, 1.0));
    let diagWin = uv.x * 0.62 + uv.y * 0.38;
    let front = mix(-0.18, 1.28, easeOutCubic(clamp01(t / 0.62)));
    let waveBand = exp(-pow((diagWin - front) * 9.0, 2.0)) * (1.0 - easeInOutCubic(clamp01((t - 0.42) / 0.26)));
    if (waveBand > 0.003) {
        let wa = waveBand * 0.11;
        acc = overPremul(vec4f(vec3f(0.28, 0.92, 0.92) * wa, wa), acc);
    }

    // Resume card at top of Home scroll container (padding-top=30, padding-left/right=16)
    let hasRes = u.hasResume > 0.5;
    let resH = max(u.resumeH, 76.0);
    if (hasRes) {
        let resW = max(128.0, size.x - 32.0);
        let resCenter = vec2f(size.x * 0.5, 30.0 + resH * 0.5);
        let resCol = cardBevelFlash(p, resCenter, vec2f(resW, resH), 14.0, t, aa);
        if (resCol.a > 0.001) {
            acc = overPremul(resCol, acc);
        }
    }

    // Site mosaic grid (128x80 tiles, 12px gap -> 140x92 cell stride, left=16)
    let count = i32(max(0.0, floor(u.siteCount + 0.5)));
    let cols = i32(max(1.0, floor(u.gridCols + 0.5)));
    if (count > 0) {
        let gridTop = select(30.0, 30.0 + resH + 14.0, hasRes);
        let baseDelay = select(0.0, 0.06, hasRes);
        let gx = (p.x - 16.0) / 140.0;
        let gy = (p.y - gridTop) / 92.0;
        let baseCol = i32(floor(gx));
        let baseRow = i32(floor(gy));

        // Check nearest 2x2 neighborhood so outer bevel bloom never clips at cell boundaries
        for (var dr: i32 = -1; dr <= 1; dr = dr + 1) {
            let r = baseRow + dr;
            if (r < 0) { continue; }
            for (var dc: i32 = -1; dc <= 1; dc = dc + 1) {
                let c = baseCol + dc;
                if (c < 0 || c >= cols) { continue; }
                let idx = r * cols + c;
                if (idx < 0 || idx >= count) { continue; }

                let cx = 16.0 + f32(c) * 140.0 + 64.0;
                let cy = gridTop + f32(r) * 92.0 + 40.0;
                // Quick bounding rejection
                if (abs(p.x - cx) > 74.0 || abs(p.y - cy) > 54.0) { continue; }

                let waveIdx = min(f32(c + r), 7.0);
                let delay = baseDelay + waveIdx * 0.042;
                let tileCol = cardBevelFlash(p, vec2f(cx, cy), vec2f(128.0, 80.0), 12.0, t - delay, aa);
                if (tileCol.a > 0.001) {
                    acc = overPremul(tileCol, acc);
                }
            }
        }
    }

    return acc;
}

// Effect 2: Single continuous frosted-glass curtain wipe uncovering Home
fn renderCurtainReveal(p: vec2f, size: vec2f, t: f32) -> vec4f {
    if (t < 0.0 || t >= 0.72) {
        return vec4f(0.0, 0.0, 0.0, 0.0);
    }

    let uv = p / max(size, vec2f(1.0, 1.0));
    let diag = uv.x * 0.72 + uv.y * 0.28;
    let wipe = mix(-0.14, 1.24, easeInOutCubic(clamp01(t / 0.60)));
    let fadeOut = 1.0 - easeInOutCubic(clamp01((t - 0.48) / 0.22));

    let ahead = smoothstep(wipe - 0.06, wipe + 0.05, diag);
    let veilCol = mix(vec3f(0.04, 0.12, 0.14), vec3f(0.06, 0.24, 0.27), (1.0 - uv.y) * 0.5 + 0.3);
    let veilA = ahead * 0.76 * fadeOut;

    let distEdge = diag - wipe;
    let core = exp(-pow(distEdge * 22.0, 2.0));
    let halo = exp(-pow((distEdge + 0.025) * 9.0, 2.0));
    let rSplit = exp(-pow((distEdge - 0.012) * 18.0, 2.0));
    let bSplit = exp(-pow((distEdge + 0.014) * 18.0, 2.0));
    let prism = vec3f(
        0.55 * rSplit + 0.45 * core,
        0.96 * core + 0.35 * halo,
        0.98 * bSplit + 0.45 * halo,
    );
    let prismA = clamp01((core * 0.85 + halo * 0.35) * fadeOut);

    let rgb = mix(veilCol, prism, prismA / max(veilA + prismA, 0.001));
    let a = clamp01(max(veilA, prismA));
    return vec4f(clamp(rgb * a, vec3f(0.0), vec3f(a)), a);
}

// Shared alive liquid-glass holding surface: flows continuously with layered emerald-teal
// caustics and smooth periodic prismatic sheen sweeps while waiting for page TTI.
fn veilSurface(uv: vec2f, t: f32) -> vec3f {
    let diag = uv.x * 0.65 + uv.y * 0.35;
    let anti = uv.x * 0.38 - uv.y * 0.62;

    // Slow organic liquid-glass caustic interference (continuous, no wrap discontinuity)
    let waveA = sin(diag * 7.2 - t * 2.15 + sin(anti * 4.4 + t * 1.15) * 0.85);
    let waveB = cos(anti * 6.0 + t * 1.65 + cos(diag * 5.2 - t * 1.35) * 0.75);
    let caustic = clamp01(0.5 + 0.5 * (waveA * 0.58 + waveB * 0.42));
    let causticHighlight = pow(caustic, 3.0);

    let breathe = 0.5 + 0.5 * sin(t * 2.4);
    var rgb = mix(
        vec3f(0.025, 0.115, 0.145),
        vec3f(0.045, 0.255, 0.295),
        clamp01(diag * 0.58 + 0.14 * breathe + 0.18 * caustic)
    );
    rgb = rgb + vec3f(0.06, 0.32, 0.34) * causticHighlight * 0.42;

    // Smooth periodic diagonal specular sheen with subtle prismatic dispersion (1.75s cycle,
    // bell-enveloped offscreen so wrap-around is completely invisible)
    let cycle = fract(t / 1.75);
    let sweepEnv = sin(cycle * 3.14159265);
    let sheenPos = mix(-0.42, 1.42, easeInOutCubic(cycle));
    let dSheen = diag - sheenPos;
    let core = exp(-pow(dSheen * 6.5, 2.0));
    let rSplit = exp(-pow((dSheen - 0.024) * 7.2, 2.0));
    let bSplit = exp(-pow((dSheen + 0.026) * 7.2, 2.0));
    let sheenCol = vec3f(
        0.58 * rSplit + 0.42 * core,
        0.95 * core + 0.18 * rSplit,
        0.98 * bSplit + 0.25 * core
    );
    let sheenAmt = clamp01((core * 0.30 + (rSplit + bSplit) * 0.09) * sweepEnv);
    rgb = mix(rgb, sheenCol, sheenAmt);

    // Subtle opposing undercurrent glow so the glass stays visibly alive between primary sweeps
    let backCycle = fract(t / 2.6 + 0.5);
    let backEnv = sin(backCycle * 3.14159265);
    let backPos = mix(1.30, -0.30, easeInOutCubic(backCycle));
    let backBand = exp(-pow((diag - backPos) * 4.2, 2.0)) * backEnv * 0.14;
    rgb = mix(rgb, vec3f(0.26, 0.90, 0.92), backBand);

    return rgb;
}

// Effect 3: Tile-origin liquid-glass lens morph -> alive flowing glass cycle -> seamless wipe-open
// Stays on the same GPU surface when u.releaseAt transitions from -1 to >= 0 (zero swap blink).
fn renderLensOpen(p: vec2f, size: vec2f, t: f32, aa: f32) -> vec4f {
    let expandDur = 0.22;
    let wipeDur = 0.34;
    let releasing = u.releaseAt >= 0.0;
    let wipeStart = max(expandDur, u.releaseAt);
    if (releasing && t >= wipeStart + wipeDur + 0.04) {
        return vec4f(0.0, 0.0, 0.0, 0.0);
    }

    let winCenter = size * 0.5;
    let expU = clamp01(t / expandDur);
    let expE = continuousMorph(expU);

    let origCenter = select(winCenter, vec2f(u.originCx, u.originCy), u.originW > 1.0);
    let origSize = select(vec2f(128.0, 80.0), vec2f(u.originW, u.originH), u.originW > 1.0);
    let origR = select(12.0, u.originRadius, u.originRadius > 0.5);

    let curCenter = mix(origCenter, winCenter, expE);
    let curSize = mix(origSize, size + vec2f(4.0, 4.0), expE);
    let curHalf = curSize * 0.5;
    let curR = mix(origR, 16.0, expE);

    let dist = sdRoundRect(p - curCenter, curHalf, curR);
    let mask = 1.0 - smoothstep(-aa, aa, dist);
    if (mask <= 0.001) {
        return vec4f(0.0, 0.0, 0.0, 0.0);
    }

    let uv = clamp((p - curCenter + curHalf) / max(curSize, vec2f(1.0, 1.0)), vec2f(0.0), vec2f(1.0));
    let diag = uv.x * 0.65 + uv.y * 0.35;
    var glassRgb = veilSurface(uv, t);
    // Reach full 1.0 opacity once expanded so zero blank page flash can bleed through behind the veil
    var veilA = mix(0.72, 1.0, easeOutCubic(expU));

    // Smoothly blend from entrance bevel into a living orbiting Fresnel rim + gentle concentric ripple while waiting
    let holdIn = smoothstep(0.60, 1.0, expU);
    var holdFade = 1.0;
    if (releasing && t > wipeStart) {
        holdFade = 1.0 - smoothstep(0.0, 0.14, t - wipeStart);
    }

    // Concentric refractive liquid-glass ripple expanding gently from center during hold (1.75s cycle)
    let holdT = max(0.0, t - expandDur * 0.5);
    let pulsePhase = fract(holdT / 1.75);
    let pulseEnv = sin(pulsePhase * 3.14159265) * holdIn * holdFade;
    let normR = length((uv - vec2f(0.5, 0.5)) * vec2f(1.0, size.y / max(size.x, 1.0)));
    let ringR = mix(0.04, 0.72, easeOutCubic(pulsePhase));
    let pulseRing = exp(-pow((normR - ringR) * 16.0, 2.0)) * pulseEnv * 0.18;
    glassRgb = mix(glassRgb, vec3f(0.42, 0.98, 0.98), pulseRing);

    // Living Fresnel perimeter rim: bright on expand, then softly breathing with an orbiting cyan-white glint
    let rimW = mix(2.8, 1.8, expE);
    let rimM = smoothstep(-rimW - aa, -rimW + aa, dist) * (1.0 - smoothstep(-aa, aa, dist));
    let enterRim = 1.0 - smoothstep(0.65, 1.0, expU);
    let angle = atan2(p.y - curCenter.y, p.x - curCenter.x);
    let orbitGlint = pow(0.5 + 0.5 * cos(angle - t * 2.1), 4.0);
    let holdRim = holdIn * holdFade * (0.28 + 0.52 * orbitGlint);
    let rimStrength = clamp01(enterRim * 0.95 + holdRim);
    let rimCol = mix(vec3f(0.32, 0.94, 0.96), vec3f(0.84, 1.0, 1.0), orbitGlint * holdIn);
    glassRgb = mix(glassRgb, rimCol, rimM * rimStrength);
    veilA = max(veilA, rimM * rimStrength);

    var revealMask = 1.0;
    var edgeGlow = 0.0;
    if (releasing && t > wipeStart) {
        let wu = clamp01((t - wipeStart) / wipeDur);
        let wipeFront = mix(-0.18, 1.26, easeInOutCubic(wu));
        revealMask = smoothstep(wipeFront - 0.06, wipeFront + 0.06, diag);
        edgeGlow = exp(-pow((diag - wipeFront) * 18.0, 2.0)) * (1.0 - smoothstep(0.82, 1.0, wu));
    }

    let bodyA = veilA * revealMask;
    let rgb = mix(glassRgb, vec3f(0.70, 1.0, 0.99), edgeGlow * 0.92);
    let fa = clamp01(max(bodyA, edgeGlow * 0.88) * mask);
    return vec4f(clamp(rgb * fa, vec3f(0.0), vec3f(fa)), fa);
}

// Effect 4: Directional diagonal liquid-glass curtain -> alive flowing glass cycle -> seamless wipe-open
fn renderDiagOpen(p: vec2f, size: vec2f, t: f32) -> vec4f {
    let coverDur = 0.21;
    let clearDur = 0.34;
    let releasing = u.releaseAt >= 0.0;
    let clearStart = max(coverDur, u.releaseAt);
    if (releasing && t >= clearStart + clearDur + 0.04) {
        return vec4f(0.0, 0.0, 0.0, 0.0);
    }

    let uv = p / max(size, vec2f(1.0, 1.0));
    let diag = uv.x * 0.72 + uv.y * 0.28;

    let coverU = clamp01(t / coverDur);
    let coverFront = mix(-0.18, 1.26, easeInOutCubic(coverU));
    let covered = 1.0 - smoothstep(coverFront - 0.06, coverFront + 0.06, diag);
    let coverEdge = exp(-pow((diag - coverFront) * 18.0, 2.0)) * (1.0 - smoothstep(0.84, 1.0, coverU));

    var cleared = 0.0;
    var clearEdge = 0.0;
    if (releasing && t > clearStart) {
        let cu = clamp01((t - clearStart) / clearDur);
        let clearFront = mix(-0.18, 1.26, easeInOutCubic(cu));
        cleared = 1.0 - smoothstep(clearFront - 0.06, clearFront + 0.06, diag);
        clearEdge = exp(-pow((diag - clearFront) * 18.0, 2.0)) * (1.0 - smoothstep(0.84, 1.0, cu));
    }

    let veilMask = clamp01(covered - cleared);
    var veilCol = veilSurface(uv, t);

    // Subtle flowing diagonal caustic ribbon while holding
    let holdIn = smoothstep(0.75, 1.0, coverU);
    var holdFade = 1.0;
    if (releasing && t > clearStart) {
        holdFade = 1.0 - smoothstep(0.0, 0.14, t - clearStart);
    }
    let ribbonCycle = fract(t / 1.75);
    let ribbonPos = mix(-0.28, 1.28, easeInOutCubic(ribbonCycle));
    let ribbonBand = exp(-pow((diag - ribbonPos) * 13.0, 2.0)) * sin(ribbonCycle * 3.14159265) * holdIn * holdFade;
    veilCol = mix(veilCol, vec3f(0.56, 0.99, 0.99), ribbonBand * 0.42);

    let bodyA = veilMask;
    let edge = max(coverEdge, clearEdge);
    let rgb = mix(veilCol, vec3f(0.70, 1.0, 0.99), edge * 0.92);
    let fa = clamp01(max(bodyA, edge * 0.88));
    return vec4f(clamp(rgb * fa, vec3f(0.0), vec3f(fa)), fa);
}

// Effect 5: Brisk reverse glass sweep (Web -> Home) feeding into Home reveal
fn renderReverseHome(p: vec2f, size: vec2f, t: f32, aa: f32) -> vec4f {
    var sweep = vec4f(0.0, 0.0, 0.0, 0.0);
    if (t >= 0.0 && t < 0.42) {
        let uv = p / max(size, vec2f(1.0, 1.0));
        let diag = (1.0 - uv.x) * 0.72 + (1.0 - uv.y) * 0.28;
        let front = mix(-0.16, 1.26, easeInOutCubic(clamp01(t / 0.36)));
        let fade = 1.0 - easeInOutCubic(clamp01((t - 0.26) / 0.15));
        let band = exp(-pow((diag - front) * 16.0, 2.0));
        let halo = exp(-pow((diag - front + 0.04) * 7.5, 2.0));
        let rgb = mix(vec3f(0.14, 0.84, 0.86), vec3f(0.88, 1.0, 1.0), band);
        let a = clamp01((band * 0.82 + halo * 0.30) * fade);
        sweep = vec4f(clamp(rgb * a, vec3f(0.0), vec3f(a)), a);
    }

    var reveal = vec4f(0.0, 0.0, 0.0, 0.0);
    if (t > 0.10) {
        if (u.revealStyle > 1.5) {
            reveal = renderCurtainReveal(p, size, t - 0.10);
        } else {
            reveal = renderWaveReveal(p, size, t - 0.10, aa);
        }
    }
    return overPremul(sweep, reveal);
}

@fragment
fn main(@builtin(position) pixel: vec4f) -> @location(0) vec4f {
    let dpr = max(u.devicePixelRatio, 1.0);
    let size = u.resolution / dpr;
    let p = vec2f(pixel.x / dpr, pixel.y / dpr);
    let aa = 1.0 / dpr;
    let kind = i32(floor(u.effectKind + 0.5));

    var outCol = vec4f(0.0, 0.0, 0.0, 0.0);
    if (kind == 1) {
        outCol = renderWaveReveal(p, size, u.time, aa);
    } else if (kind == 2) {
        outCol = renderCurtainReveal(p, size, u.time);
    } else if (kind == 3) {
        outCol = renderLensOpen(p, size, u.time, aa);
    } else if (kind == 4) {
        outCol = renderDiagOpen(p, size, u.time);
    } else if (kind == 5) {
        outCol = renderReverseHome(p, size, u.time, aa);
    }

    return vec4f(clamp(outCol.rgb, vec3f(0.0), vec3f(outCol.a)), clamp01(outCol.a));
}

struct Uniforms {
    resolution: vec2f,
    time: f32,
    devicePixelRatio: f32,
    isHome: f32,
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

fn sdTriangle(p: vec2f, p0: vec2f, p1: vec2f, p2: vec2f) -> f32 {
    let e0 = p1 - p0;
    let e1 = p2 - p1;
    let e2 = p0 - p2;
    let v0 = p - p0;
    let v1 = p - p1;
    let v2 = p - p2;
    let pq0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
    let pq1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
    let pq2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
    let s = sign(e0.x * e2.y - e0.y * e2.x);
    let d0 = vec2f(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x));
    let d1 = vec2f(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x));
    let d2 = vec2f(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x));
    let d = min(min(d0, d1), d2);
    return -sqrt(d.x) * sign(d.y);
}

fn sdRoundedPlay(p: vec2f, size: f32) -> f32 {
    let r = size * 0.145;
    let inner = max(size - r * 2.1, 2.0);
    let h = inner * 0.50;
    let w = inner * 0.866;
    let leftX = -w * 0.36;
    let rightX = w * 0.64;
    let pTop = vec2f(leftX, h);
    let pBottom = vec2f(leftX, -h);
    let pRight = vec2f(rightX, 0.0);
    return sdTriangle(p, pTop, pRight, pBottom) - r;
}

fn rotMatrix(rx: f32, ry: f32, rz: f32) -> mat3x3f {
    let cx = cos(rx); let sx = sin(rx);
    let cy = cos(ry); let sy = sin(ry);
    let cz = cos(rz); let sz = sin(rz);
    let mx = mat3x3f(
        vec3f(1.0, 0.0, 0.0),
        vec3f(0.0, cx, sx),
        vec3f(0.0, -sx, cx),
    );
    let my = mat3x3f(
        vec3f(cy, 0.0, -sy),
        vec3f(0.0, 1.0, 0.0),
        vec3f(sy, 0.0, cy),
    );
    let mz = mat3x3f(
        vec3f(cz, sz, 0.0),
        vec3f(-sz, cz, 0.0),
        vec3f(0.0, 0.0, 1.0),
    );
    return mz * my * mx;
}

fn grad4(t: f32, c0: vec4f, c1: vec4f, c2: vec4f, c3: vec4f, l1: f32, l2: f32) -> vec4f {
    if (t <= l1) {
        return mix(c0, c1, clamp01(t / l1));
    }
    if (t <= l2) {
        return mix(c1, c2, clamp01((t - l1) / (l2 - l1)));
    }
    return mix(c2, c3, clamp01((t - l2) / (1.0 - l2)));
}

fn grad5(t: f32, c0: vec4f, c1: vec4f, c2: vec4f, c3: vec4f, c4: vec4f, l1: f32, l2: f32, l3: f32) -> vec4f {
    if (t <= l1) {
        return mix(c0, c1, clamp01(t / l1));
    }
    if (t <= l2) {
        return mix(c1, c2, clamp01((t - l1) / (l2 - l1)));
    }
    if (t <= l3) {
        return mix(c2, c3, clamp01((t - l2) / (l3 - l2)));
    }
    return mix(c3, c4, clamp01((t - l3) / (1.0 - l3)));
}

@fragment
fn main(@builtin(position) pixel: vec4f) -> @location(0) vec4f {
    let t = u.time;
    if (t >= 0.68) {
        return vec4f(0.0, 0.0, 0.0, 0.0);
    }

    let dpr = max(u.devicePixelRatio, 1.0);
    let size = u.resolution / dpr;
    let p = vec2f(pixel.x / dpr, size.y - pixel.y / dpr);
    let center = size * 0.5;
    let aa = 1.0 / dpr;

    // Single continuous gesture (0.00 -> 0.68s) matching Float's signature morph
    let appear = easeOutCubic(clamp01(t / 0.09));
    let liftY = mix(-10.0, 0.0, easeOutCubic(clamp01(t / 0.44)));

    let morphU = clamp01(t / 0.52);
    let morphSmooth = continuousMorph(morphU);
    let morphSize = morphSmooth + sin(morphU * 3.14159265) * pow(morphU, 3.0) * 0.012;

    // 3D logo perspective unwinds continuously from frame 0
    let pose = 1.0 - continuousMorph(clamp01(t / 0.48));
    let rotZ = pose * 0.1745329;   // 10.0 deg
    let rotY = pose * -0.3839724;  // -22.0 deg
    let rotX = pose * 0.0785398;   // 4.5 deg

    // Logo pane geometry (~1.58:1 aspect matching Float.icon)
    let maxLogoW = min(204.0, size.x * 0.64);
    let maxLogoH = min(130.0, size.y * 0.64);
    var logoW = min(max(size.x * 0.30, 116.0), maxLogoW);
    var logoH = logoW / 1.58;
    if (logoH > maxLogoH) {
        logoH = maxLogoH;
        logoW = min(maxLogoW, logoH * 1.58);
    }
    logoW = max(68.0, logoW);
    logoH = max(44.0, logoH);

    let startRadius = clamp(logoH * 0.21, 14.0, 28.0);
    let endRadius = 16.0;

    let curW = mix(logoW, size.x, morphSize);
    let curH = mix(logoH, size.y, morphSize);
    let curHalf = vec2f(curW * 0.5, curH * 0.5);
    let curCenter = vec2f(center.x, center.y + liftY);
    let curRadius = min(mix(startRadius, endRadius, morphSmooth), min(curW, curH) * 0.48);

    // Seamless cross-fade out into true native macOS Liquid Glass underneath
    let overlayFade = 1.0 - easeInOutCubic(clamp01((t - 0.44) / 0.22));
    let masterAlpha = appear * overlayFade;
    if (masterAlpha <= 0.001) {
        return vec4f(0.0, 0.0, 0.0, 0.0);
    }

    // Floating radial shadow beneath the tilted logo
    var outRgb = vec3f(0.0, 0.0, 0.0);
    var outA = 0.0;
    let shadowOpacity = appear * pose * pose;
    if (shadowOpacity > 0.002) {
        let shadowCenter = vec2f(curCenter.x, curCenter.y - curHalf.y - 20.0);
        let shadowRadii = vec2f(logoW * 0.45, 13.0);
        let sd = length((p - shadowCenter) / shadowRadii);
        if (sd < 1.0) {
            let sAlpha = mix(0.36, 0.0, smoothstep(0.0, 1.0, sd)) * shadowOpacity * overlayFade;
            outRgb = vec3f(0.0, 0.14, 0.16);
            outA = sAlpha;
        }
    }

    // Ray-plane intersection into the 3D-tilted glass pane
    let focal = 880.0;
    let rayOrig = vec3f(0.0, 0.0, focal);
    let rayDir = normalize(vec3f(p.x - curCenter.x, p.y - curCenter.y, -focal));
    let R = rotMatrix(rotX, rotY, rotZ);
    let Rt = transpose(R);
    let localOrig = Rt * rayOrig;
    let localDir = Rt * rayDir;

    if (abs(localDir.z) > 0.0001) {
        let tHit = -localOrig.z / localDir.z;
        if (tHit > 0.0) {
            let lp = localOrig.xy + localDir.xy * tHit;
            let dist = sdRoundRect(lp, curHalf, curRadius);
            let cardMask = 1.0 - smoothstep(-aa, aa, dist);

            if (cardMask > 0.001) {
                let uv = clamp((lp + curHalf) / vec2f(curW, curH), vec2f(0.0), vec2f(1.0));
                let isHome = u.isHome > 0.5;
                let tealBlend = 1.0 - morphSmooth;

                // Base refractive teal glass body fading smoothly toward clear native Liquid Glass
                var glassRgb: vec3f;
                var glassA: f32;
                if (isHome) {
                    glassRgb = mix(vec3f(0.05, 0.09, 0.11), vec3f(0.00, 0.44, 0.48), tealBlend);
                    glassA = mix(0.24, 0.80, tealBlend);
                } else {
                    glassRgb = mix(vec3f(0.02, 0.02, 0.03), vec3f(0.00, 0.44, 0.48), tealBlend);
                    glassA = mix(0.95, 0.80, tealBlend);
                }

                // 1. Rich emerald-teal glass depth gradient matching Float.icon
                let diagDepth = clamp01(uv.x * 0.65 + (1.0 - uv.y) * 0.35);
                let depthSample = grad4(
                    diagDepth,
                    vec4f(0.18, 0.90, 0.92, 0.52),
                    vec4f(0.00, 0.42, 0.47, 0.48),
                    vec4f(0.00, 0.28, 0.33, 0.54),
                    vec4f(0.10, 0.84, 0.86, 0.46),
                    0.34,
                    0.70,
                );
                let depthVis = 1.0 - easeInOutCubic(clamp01((t - 0.06) / 0.42));
                let da = depthSample.a * depthVis;
                glassRgb = mix(glassRgb, depthSample.rgb, da);
                glassA = glassA + da * (1.0 - glassA);

                // Subtle internal optical fresnel near the rounded edge
                let edgeGlow = smoothstep(-26.0, 0.0, dist) * (1.0 - smoothstep(-1.0, 1.0, dist)) * 0.26 * tealBlend;
                glassRgb = mix(glassRgb, vec3f(0.45, 0.98, 0.98), edgeGlow);
                glassA = min(1.0, glassA + edgeGlow * 0.5);

                // 2. Diagonal glossy glass light sheen sweep
                let sheenT = easeInOutCubic(clamp01(t / 0.48));
                let sheenShift = mix(-0.55, 0.78, sheenT);
                let diagCoord = uv.x * 0.65 + (1.0 - uv.y) * 0.35;
                let sPos = (diagCoord - (sheenShift - 0.35)) / 0.90;
                let sheenSample = grad5(
                    clamp01(sPos),
                    vec4f(1.0, 1.0, 1.0, 0.0),
                    vec4f(0.78, 1.0, 0.99, 0.34),
                    vec4f(1.0, 1.0, 1.0, 0.48),
                    vec4f(0.58, 0.98, 0.98, 0.16),
                    vec4f(1.0, 1.0, 1.0, 0.0),
                    0.34,
                    0.50,
                    0.66,
                );
                let sheenVis = (1.0 - easeInOutCubic(clamp01((t - 0.28) / 0.24))) * appear;
                let sa = sheenSample.a * 0.85 * sheenVis * step(0.0, sPos) * step(sPos, 1.0);
                glassRgb = mix(glassRgb, sheenSample.rgb, sa);
                glassA = min(1.0, glassA + sa * 0.45);

                // 3. Luminous cyan-turquoise specular bevel rim + inner highlight
                let rimWidth = mix(3.0, 1.35, morphSmooth);
                let rimMask = smoothstep(-rimWidth - aa, -rimWidth + aa, dist) * (1.0 - smoothstep(-aa, aa, dist));
                let rimDiag = clamp01(uv.x * 0.55 + (1.0 - uv.y) * 0.45);
                let rimColor = grad5(
                    rimDiag,
                    vec4f(0.80, 1.00, 0.99, 0.98),
                    vec4f(0.16, 0.90, 0.90, 0.95),
                    vec4f(0.04, 0.50, 0.56, 0.78),
                    vec4f(0.42, 0.98, 0.97, 0.98),
                    vec4f(0.08, 0.68, 0.72, 0.86),
                    0.25,
                    0.52,
                    0.78,
                );
                let rimFade = 1.0 - easeInOutCubic(clamp01((t - 0.36) / 0.20));
                let ra = rimMask * rimColor.a * 0.96 * rimFade;
                glassRgb = mix(glassRgb, rimColor.rgb, ra);
                glassA = max(glassA, ra);

                let innerDist = dist + rimWidth + 1.0;
                let innerMask = (1.0 - smoothstep(0.0, 1.25 + aa, abs(innerDist))) * 0.36 * (1.0 - morphSmooth);
                glassRgb = mix(glassRgb, vec3f(0.86, 1.0, 1.0), innerMask);
                glassA = max(glassA, innerMask);

                // 4. Sculpted warm-ivory rounded play triangle hovering over the glass
                let playFadeOut = 1.0 - easeInOutCubic(clamp01((t - 0.10) / 0.24));
                let playVis = appear * playFadeOut;
                if (playVis > 0.002) {
                    let playBloom = mix(0.92, 1.26, easeOutCubic(clamp01(t / 0.34)));
                    let playSize = max(8.0, min(logoH * 0.52, logoW * 0.35) * playBloom);

                    // Soft drop shadow beneath the play triangle
                    let dPlayShadow = sdRoundedPlay(lp - vec2f(0.0, -4.0), playSize);
                    let psAlpha = (1.0 - smoothstep(-1.0, 9.0, dPlayShadow)) * 0.44 * playVis;
                    glassRgb = mix(glassRgb, vec3f(0.0, 0.16, 0.20), psAlpha);

                    let dPlay = sdRoundedPlay(lp, playSize);
                    let playMask = (1.0 - smoothstep(-aa, aa, dPlay)) * 0.98 * playVis;
                    glassRgb = mix(glassRgb, vec3f(0.975, 0.97, 0.95), playMask);
                    glassA = max(glassA, playMask);
                }

                // Composite card over floor shadow (straight -> premultiplied)
                let finalCardA = clamp01(glassA * cardMask * masterAlpha);
                let outPremul = outRgb * outA * (1.0 - finalCardA) + glassRgb * finalCardA;
                let finalA = finalCardA + outA * (1.0 - finalCardA);
                return vec4f(clamp(outPremul, vec3f(0.0), vec3f(finalA)), clamp01(finalA));
            }
        }
    }

    let shadowPremul = outRgb * outA;
    return vec4f(clamp(shadowPremul, vec3f(0.0), vec3f(outA)), clamp01(outA));
}

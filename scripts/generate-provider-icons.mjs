#!/usr/bin/env bun
// Generates crisp 128x128 Retina PNG provider logos in assets/providers/*.png from vector SVGs.
// Run with: bun scripts/generate-provider-icons.mjs

import { execFileSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { resolve } from 'node:path';

const OUT_DIR = resolve(import.meta.dir, '..', 'assets', 'providers');
mkdirSync(OUT_DIR, { recursive: true });

function wrap(bg, body, defs = '') {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
  <defs>
    <clipPath id="clip"><rect width="128" height="128" rx="26"/></clipPath>
    ${defs}
  </defs>
  <g clip-path="url(#clip)">
    ${bg}
    ${body}
    <rect x="1.5" y="1.5" width="125" height="125" rx="24.5" fill="none" stroke="rgba(255,255,255,0.14)" stroke-width="2"/>
  </g>
</svg>`;
}

function grad(id, c1, c2, x2 = '100%', y2 = '100%') {
  return `<linearGradient id="${id}" x1="0%" y1="0%" x2="${x2}" y2="${y2}"><stop offset="0%" stop-color="${c1}"/><stop offset="100%" stop-color="${c2}"/></linearGradient>`;
}

const FONT = 'Helvetica Neue, Helvetica, Arial, sans-serif';

const ICONS = {
  netflix: wrap(
    `<rect width="128" height="128" fill="#141414"/>`,
    `<path d="M36 22h18v84H36z" fill="#B20710"/>
     <path d="M74 22h18v84H74z" fill="#B20710"/>
     <path d="M36 22h18l38 84H74z" fill="#E50914"/>`,
  ),

  youtube: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<rect x="18" y="34" width="92" height="60" rx="18" fill="#FFFFFF"/>
     <polygon points="56,50 82,64 56,78" fill="#FF0033"/>`,
    grad('g', '#FF0033', '#C40024'),
  ),

  appletv: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<text x="64" y="79" text-anchor="middle" font-family="${FONT}" font-weight="700" font-size="48" letter-spacing="-1.5" fill="#FFFFFF">tv+</text>`,
    grad('g', '#232328', '#09090B', '0%', '100%'),
  ),

  primevideo: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<text x="64" y="66" text-anchor="middle" font-family="${FONT}" font-weight="700" font-size="31" letter-spacing="-0.5" fill="#FFFFFF">prime</text>
     <path d="M28 80 Q64 102 98 81" fill="none" stroke="#FFFFFF" stroke-width="6.5" stroke-linecap="round"/>
     <path d="M90 77 L102 80 L96 92" fill="none" stroke="#FFFFFF" stroke-width="5.5" stroke-linecap="round" stroke-linejoin="round"/>`,
    grad('g', '#00A8E1', '#005A9E'),
  ),

  disneyplus: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<path d="M22 60 Q64 18 106 54" fill="none" stroke="url(#arc)" stroke-width="5.5" stroke-linecap="round"/>
     <text x="64" y="88" text-anchor="middle" font-family="${FONT}" font-weight="800" font-size="46" letter-spacing="-1" fill="#FFFFFF">D+</text>`,
    grad('g', '#0B1640', '#124E78') + grad('arc', 'rgba(99,230,255,0.15)', '#7CF4FF', '100%', '0%'),
  ),

  hbomax: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<text x="64" y="61" text-anchor="middle" font-family="${FONT}" font-weight="900" font-size="34" letter-spacing="1" fill="#FFFFFF">HBO</text>
     <text x="64" y="93" text-anchor="middle" font-family="${FONT}" font-weight="700" font-size="25" letter-spacing="3" fill="#B9A6FF">MAX</text>`,
    grad('g', '#1A1333', '#0B0B10'),
  ),

  hulu: wrap(
    `<rect width="128" height="128" fill="#0B0C0F"/>`,
    `<text x="64" y="79" text-anchor="middle" font-family="${FONT}" font-weight="800" font-size="44" letter-spacing="-1" fill="#1CE783">hulu</text>`,
  ),

  paramountplus: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<path d="M24 94 L64 42 L104 94 Z" fill="#FFFFFF"/>
     <path d="M44 94 L64 66 L84 94 Z" fill="#0052D4"/>
     <circle cx="64" cy="24" r="3.5" fill="#FFFFFF"/>
     <circle cx="44" cy="30" r="3.2" fill="#FFFFFF"/>
     <circle cx="84" cy="30" r="3.2" fill="#FFFFFF"/>
     <circle cx="29" cy="45" r="3" fill="#FFFFFF"/>
     <circle cx="99" cy="45" r="3" fill="#FFFFFF"/>
     <circle cx="22" cy="64" r="2.8" fill="#FFFFFF"/>
     <circle cx="106" cy="64" r="2.8" fill="#FFFFFF"/>
     <path d="M98 20v16M90 28h16" stroke="#7CE7FF" stroke-width="4.5" stroke-linecap="round"/>`,
    grad('g', '#006BFF', '#00369E'),
  ),

  peacock: wrap(
    `<rect width="128" height="128" fill="#0D0D10"/>`,
    `<text x="45" y="84" text-anchor="middle" font-family="${FONT}" font-weight="800" font-size="60" fill="#FFFFFF">P</text>
     <circle cx="88" cy="30" r="8" fill="#F7C600"/>
     <circle cx="98" cy="43" r="8" fill="#F36F21"/>
     <circle cx="101" cy="59" r="8" fill="#E21F26"/>
     <circle cx="98" cy="75" r="8" fill="#8B3FC4"/>
     <circle cx="88" cy="88" r="8" fill="#0095DA"/>
     <circle cx="74" cy="96" r="8" fill="#4DB848"/>`,
  ),

  twitch: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<path d="M34 26 L26 42 V92 H46 V104 L58 92 H74 L98 68 V26 Z" fill="#FFFFFF"/>
     <path d="M40 34 H90 V64 L76 78 H56 L46 88 V78 H34 V40 Z" fill="#9146FF"/>
     <rect x="54" y="45" width="8" height="20" rx="2" fill="#FFFFFF"/>
     <rect x="72" y="45" width="8" height="20" rx="2" fill="#FFFFFF"/>`,
    grad('g', '#9146FF', '#6441A5'),
  ),

  plex: wrap(
    `<rect width="128" height="128" fill="#1B1F23"/>`,
    `<polygon points="40,22 66,22 96,64 66,106 40,106 70,64" fill="url(#g)"/>`,
    grad('g', '#FFBE2E', '#D97B07'),
  ),

  vimeo: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<path d="M26 52 C32 42 40 35 47 36 C55 37 56 49 60 66 C63 77 65 80 68 80 C71 80 78 72 84 61 C90 50 89 45 84 45 C81 45 78 47 74 49 C78 36 86 30 95 31 C104 32 106 42 101 55 C94 74 75 97 62 97 C53 97 48 86 44 68 C41 55 39 51 35 51 C33 51 30 53 27 56 Z" fill="#FFFFFF"/>`,
    grad('g', '#1AB7EA', '#0D86B8'),
  ),

  youtubetv: wrap(
    `<rect width="128" height="128" fill="#141418"/>`,
    `<rect x="20" y="24" width="88" height="58" rx="14" fill="#FF0033"/>
     <polygon points="56,41 78,53 56,65" fill="#FFFFFF"/>
     <text x="64" y="106" text-anchor="middle" font-family="${FONT}" font-weight="800" font-size="22" letter-spacing="3" fill="#FFFFFF">TV</text>`,
  ),

  espn: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<text x="61" y="77" text-anchor="middle" font-family="${FONT}" font-weight="900" font-style="italic" font-size="33" letter-spacing="-0.5" fill="#FFFFFF">ESPN</text>
     <rect x="14" y="59" width="100" height="4.5" fill="#B80015"/>
     <path d="M103 34v18M94 43h18" stroke="#FFD23F" stroke-width="5" stroke-linecap="round"/>`,
    grad('g', '#E52521', '#A60012'),
  ),

  crunchyroll: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<circle cx="64" cy="64" r="39" fill="#FFFFFF"/>
     <circle cx="71" cy="64" r="27" fill="#F47521"/>
     <circle cx="80" cy="56" r="10" fill="#FFFFFF"/>`,
    grad('g', '#FF852E', '#DF5400'),
  ),

  tubi: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<text x="64" y="80" text-anchor="middle" font-family="${FONT}" font-weight="900" font-size="45" letter-spacing="-1" fill="#FFFF13">tubi</text>`,
    grad('g', '#5B0CE3', '#33008A'),
  ),

  plutotv: wrap(
    `<rect width="128" height="128" fill="#09090B"/>`,
    `<text x="64" y="66" text-anchor="middle" font-family="${FONT}" font-weight="800" font-size="32" letter-spacing="-0.5" fill="#FFFFFF">pluto</text>
     <circle cx="34" cy="90" r="8" fill="#FFF200"/>
     <circle cx="54" cy="90" r="8" fill="#00E5FF"/>
     <circle cx="74" cy="90" r="8" fill="#2EE56B"/>
     <circle cx="94" cy="90" r="8" fill="#FF2E93"/>`,
  ),

  fubo: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<text x="64" y="79" text-anchor="middle" font-family="${FONT}" font-weight="900" font-size="42" letter-spacing="-1" fill="#FFFFFF">fubo</text>`,
    grad('g', '#FF5522', '#CC2900'),
  ),

  sling: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<circle cx="64" cy="50" r="24" fill="none" stroke="#00B4F0" stroke-width="7"/>
     <circle cx="64" cy="50" r="11" fill="#00B4F0"/>
     <text x="64" y="102" text-anchor="middle" font-family="${FONT}" font-weight="800" font-size="28" letter-spacing="0.5" fill="#FFFFFF">sling</text>`,
    grad('g', '#0B2342', '#061224'),
  ),

  starz: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<text x="64" y="76" text-anchor="middle" font-family="${FONT}" font-weight="900" font-size="31" letter-spacing="1.5" fill="#FFFFFF">STARZ</text>
     <rect x="26" y="88" width="76" height="4" rx="2" fill="#25D4D0"/>`,
    grad('g', '#00323D', '#00151A'),
  ),

  amcplus: wrap(
    `<rect width="128" height="128" fill="#111113"/>`,
    `<rect x="18" y="34" width="92" height="60" rx="10" fill="none" stroke="#E8BE26" stroke-width="5"/>
     <text x="64" y="75" text-anchor="middle" font-family="${FONT}" font-weight="800" font-size="32" letter-spacing="-0.5" fill="#E8BE26">amc+</text>`,
  ),

  mgmplus: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<text x="64" y="76" text-anchor="middle" font-family="${FONT}" font-weight="900" font-size="31" letter-spacing="0.5" fill="url(#gold)">MGM+</text>`,
    grad('g', '#1C160C', '#0D0B07') + grad('gold', '#F5DC93', '#B8892D'),
  ),

  discoveryplus: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<circle cx="48" cy="64" r="24" fill="url(#orb)"/>
     <text x="66" y="81" text-anchor="middle" font-family="${FONT}" font-weight="800" font-size="52" fill="#FFFFFF">d+</text>`,
    grad('g', '#1E6CE0', '#0A3378') + grad('orb', '#34D399', '#38BDF8'),
  ),

  britbox: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<text x="64" y="60" text-anchor="middle" font-family="${FONT}" font-weight="800" font-size="32" fill="#FFFFFF">Brit</text>
     <text x="64" y="92" text-anchor="middle" font-family="${FONT}" font-weight="800" font-size="32" fill="#00D9B5">Box</text>
     <rect x="34" y="102" width="60" height="4" rx="2" fill="#E63946"/>`,
    grad('g', '#122B54', '#08142B'),
  ),

  kick: wrap(
    `<rect width="128" height="128" fill="#0B0E0F"/>`,
    `<path d="M32 24h22v26h14V38h12V24h22v28H88v24h14v28H80V90H68V78H54v26H32z" fill="#53FC18"/>`,
  ),

  nebula: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<path d="M64 20 L74 52 L106 64 L74 76 L64 108 L54 76 L22 64 L54 52 Z" fill="url(#star)"/>`,
    grad('g', '#16223C', '#0A101E') + grad('star', '#FFFFFF', '#38BDF8'),
  ),

  dropout: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<path d="M36 26 H68 C90 26 102 42 102 64 C102 86 90 102 68 102 H36 Z" fill="#111111"/>
     <polygon points="56,47 82,64 56,81" fill="#FFE600"/>`,
    grad('g', '#FFE900', '#F0C000'),
  ),

  dailymotion: wrap(
    `<rect width="128" height="128" fill="#121216"/>`,
    `<text x="58" y="88" text-anchor="middle" font-family="${FONT}" font-weight="900" font-size="72" fill="#FFFFFF">d</text>
     <circle cx="91" cy="83" r="8" fill="#00AAFF"/>`,
  ),

  f1tv: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<text x="64" y="68" text-anchor="middle" font-family="${FONT}" font-weight="900" font-style="italic" font-size="48" letter-spacing="-2" fill="#FFFFFF">F1</text>
     <text x="64" y="98" text-anchor="middle" font-family="${FONT}" font-weight="700" font-size="21" letter-spacing="4" fill="rgba(255,255,255,0.92)">TV</text>`,
    grad('g', '#E10600', '#9E0400'),
  ),

  mlbtv: wrap(
    `<rect width="64" height="128" fill="#041E42"/><rect x="64" width="64" height="128" fill="#BF0D3E"/>`,
    `<rect x="20" y="34" width="88" height="60" rx="12" fill="rgba(4,16,38,0.84)" stroke="#FFFFFF" stroke-width="3.5"/>
     <text x="64" y="74" text-anchor="middle" font-family="${FONT}" font-weight="900" font-size="30" letter-spacing="1" fill="#FFFFFF">MLB</text>`,
  ),

  dazn: wrap(
    `<rect width="128" height="128" fill="#0C161C"/>`,
    `<rect x="20" y="20" width="88" height="88" rx="10" fill="none" stroke="#F8F8F5" stroke-width="5"/>
     <text x="64" y="61" text-anchor="middle" font-family="${FONT}" font-weight="900" font-size="34" letter-spacing="4" fill="#FFFFFF">DA</text>
     <text x="64" y="94" text-anchor="middle" font-family="${FONT}" font-weight="900" font-size="34" letter-spacing="4" fill="#FFFFFF">ZN</text>`,
  ),

  hidive: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<text x="64" y="62" text-anchor="middle" font-family="${FONT}" font-weight="900" font-size="36" letter-spacing="2" fill="#00AEF0">HI</text>
     <text x="64" y="94" text-anchor="middle" font-family="${FONT}" font-weight="800" font-size="27" letter-spacing="2.5" fill="#FFFFFF">DIVE</text>`,
    grad('g', '#0B223C', '#05101F'),
  ),

  mubi: wrap(
    `<rect width="128" height="128" fill="#001489"/>`,
    `<circle cx="42" cy="40" r="10.5" fill="#FFFFFF"/>
     <circle cx="67" cy="40" r="10.5" fill="#FFFFFF"/>
     <circle cx="42" cy="64" r="10.5" fill="#FFFFFF"/>
     <circle cx="67" cy="64" r="10.5" fill="#FFFFFF"/>
     <circle cx="92" cy="64" r="10.5" fill="#FFFFFF"/>
     <circle cx="42" cy="88" r="10.5" fill="#FFFFFF"/>
     <circle cx="67" cy="88" r="10.5" fill="#FFFFFF"/>`,
  ),

  criterion: wrap(
    `<rect width="128" height="128" fill="#0A0A0A"/>`,
    `<path d="M90 42 A34 34 0 1 0 90 86" fill="none" stroke="#FFFFFF" stroke-width="14" stroke-linecap="butt"/>`,
  ),

  shudder: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<text x="64" y="88" text-anchor="middle" font-family="${FONT}" font-weight="900" font-size="72" fill="#FFFFFF">S</text>
     <path d="M22 80 L106 46" stroke="#E52521" stroke-width="7" stroke-linecap="round"/>`,
    grad('g', '#2A080C', '#100406'),
  ),

  viki: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<path d="M28 36 L64 96 L100 36 H80 L64 66 L48 36 Z" fill="#FFFFFF"/>`,
    grad('g', '#18A8FF', '#0068D6'),
  ),

  curiositystream: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<circle cx="64" cy="64" r="34" fill="none" stroke="url(#ring)" stroke-width="12" stroke-dasharray="165 60" stroke-linecap="round"/>
     <circle cx="64" cy="64" r="11" fill="#F59E0B"/>`,
    grad('g', '#152438', '#0A121D') + grad('ring', '#FBBF24', '#EA580C'),
  ),

  rokuchannel: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<text x="64" y="76" text-anchor="middle" font-family="${FONT}" font-weight="900" font-size="38" letter-spacing="-1" fill="#FFFFFF">Roku</text>`,
    grad('g', '#7936B0', '#4A1D70'),
  ),

  bbciplayer: wrap(
    `<rect width="128" height="128" fill="#0F0F12"/>`,
    `<rect x="34" y="28" width="14" height="72" rx="4" fill="#FF4C98"/>
     <polygon points="56,30 100,64 56,98" fill="#FF4C98"/>`,
  ),

  pbs: wrap(
    `<rect width="128" height="128" fill="url(#g)"/>`,
    `<circle cx="64" cy="64" r="42" fill="none" stroke="rgba(255,255,255,0.35)" stroke-width="4"/>
     <text x="64" y="77" text-anchor="middle" font-family="${FONT}" font-weight="900" font-size="36" letter-spacing="1" fill="#FFFFFF">PBS</text>`,
    grad('g', '#2A40D6', '#18248A'),
  ),

  kanopy: wrap(
    `<rect width="128" height="128" fill="#151518"/>`,
    `<path d="M38 24 H56 V56 L82 28 H102 L72 61 L104 104 H82 L56 69 V104 H38 Z" fill="#FF6B00"/>`,
  ),
};

let count = 0;
for (const [id, svg] of Object.entries(ICONS)) {
  const outPath = resolve(OUT_DIR, `${id}.png`);
  execFileSync('rsvg-convert', ['-w', '128', '-h', '128', '-f', 'png', '-o', outPath], {
    input: svg,
    stdio: ['pipe', 'ignore', 'inherit'],
  });
  count += 1;
}

console.log(`Generated ${count} provider icons in ${OUT_DIR}`);

#!/usr/bin/env node
// Updates site/index.html and site/latest.json with the newly published Float release metadata.
import fs from "node:fs";
import path from "node:path";

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (!k.startsWith("--")) throw new Error(`Unexpected argument: ${k}`);
    const val = argv[++i];
    if (val === undefined) throw new Error(`Missing value for ${k}`);
    out[k.slice(2)] = val;
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
const version = args.version;
const tag = args.tag || (version ? `v${version}` : "");
const url = args.url;
const sizeBytes = Number(args.size);
const build = args.build ? Number(args.build) : null;
const publishedAt = args.published || new Date().toISOString();
const edSignature = args.signature || null;
const repo = args.repo || "noisyneighborstudio/float";
const siteDir = path.resolve(args["site-dir"] || "site");

if (!version || !tag || !url || !Number.isFinite(sizeBytes) || sizeBytes <= 0) {
  console.error("Usage: update-site-version.mjs --version <x.y.z> --tag <vx.y.z> --url <zip-url> --size <bytes> [--build <n>] [--published <date>] [--signature <ed25519>] [--repo <owner/name>] [--site-dir <dir>]");
  process.exit(1);
}

const sizeLabel = `${(sizeBytes / (1024 * 1024)).toFixed(1)} MB`;
const releaseUrl = `https://github.com/${repo}/releases/tag/${tag}`;

const indexPath = path.join(siteDir, "index.html");
let html = fs.readFileSync(indexPath, "utf8");

function replaceChecked(src, re, replacement, label) {
  let count = 0;
  const next = src.replace(re, (...m) => {
    count++;
    return typeof replacement === "function" ? replacement(...m) : replacement;
  });
  if (count === 0) throw new Error(`Expected at least one match for ${label} in ${indexPath}`);
  return next;
}

html = replaceChecked(
  html,
  /https:\/\/github\.com\/[^"']+\/releases\/download\/[^"']+\/Float-[^"']+\.zip/g,
  url,
  "download zip URL"
);
html = replaceChecked(
  html,
  /<span class="js-version-short">[^<]*<\/span>/g,
  `<span class="js-version-short">${tag}</span>`,
  "short version spans"
);
html = replaceChecked(
  html,
  /<strong class="js-version"([^>]*)>[^<]*<\/strong>/g,
  (_, attrs) => `<strong class="js-version"${attrs}>${tag}</strong>`,
  "version strong tags"
);
html = replaceChecked(
  html,
  /<span class="js-size">[^<]*<\/span>/g,
  `<span class="js-size">${sizeLabel}</span>`,
  "size spans"
);
html = replaceChecked(
  html,
  /(Apple notarized,\s*)[0-9.]+ MB/g,
  (_, prefix) => `${prefix}${sizeLabel}`,
  "meta description size"
);

fs.writeFileSync(indexPath, html, "utf8");

const manifest = {
  version,
  tag,
  build,
  url,
  releaseUrl,
  sizeBytes,
  sizeLabel,
  minMacOS: "13.0",
  publishedAt,
  ...(edSignature ? { edSignature } : {}),
};

const manifestPath = path.join(siteDir, "latest.json");
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n", "utf8");

console.log(`Updated ${siteDir} → ${tag} (${sizeLabel})`);

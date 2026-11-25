// Links Float's `file:` dependencies (the @exact/* packages under .exact/checkout) into node_modules, as
// `npm ci` does (package-lock.json records each as `"link": true`), so Exact's bake resolves them on a fresh
// checkout without a network install. Exact's packages are dependency-free, so a link is a whole install.
//
//   bun scripts/link-file-dependencies.mjs [app-dir]
//
// An existing install (a link, or a copy from `npm ci` / `bun install`) is left as it is; only a missing or
// dangling entry is linked. Links are relative, so retargeting .exact/checkout retargets them too.
import { existsSync, lstatSync, mkdirSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const TARBALL = /\.(tgz|tar|tar\.gz)$/;

export function linkFileDependencies(dir) {
  const manifestPath = resolve(dir, 'package.json');
  if (!existsSync(manifestPath)) return [];
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  const linked = [];
  for (const kind of ['dependencies', 'devDependencies', 'optionalDependencies']) {
    for (const [name, spec] of Object.entries(manifest[kind] ?? {})) {
      if (typeof spec !== 'string' || !spec.startsWith('file:') || TARBALL.test(spec)) continue;
      const source = resolve(dir, spec.slice('file:'.length));
      const installed = resolve(dir, 'node_modules', name);
      if (existsSync(resolve(installed, 'package.json'))) continue;
      let dangling = false;
      try { dangling = lstatSync(installed).isSymbolicLink(); } catch { /* nothing there */ }
      if (dangling) rmSync(installed);
      else if (existsSync(installed)) continue; // a directory without package.json: not ours to replace
      mkdirSync(dirname(installed), { recursive: true });
      symlinkSync(relative(dirname(installed), source), installed, 'dir');
      linked.push(name);
    }
  }
  return linked;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  const dir = resolve(process.argv[2] ?? resolve(dirname(fileURLToPath(import.meta.url)), '..'));
  const linked = linkFileDependencies(dir);
  if (linked.length) console.error(`linked ${linked.join(', ')} into ${resolve(dir, 'node_modules')}`);
}

#!/bin/sh
':' //; if [ -n "$BUN" ]; then exec "$BUN" "$0" "$@"; elif [ -x "$HOME/.local/share/mise/installs/bun/1.4.2/bin/bun" ]; then exec "$HOME/.local/share/mise/installs/bun/1.4.2/bin/bun" "$0" "$@"; elif [ -x "$HOME/.bun/bin/bun" ]; then exec "$HOME/.bun/bin/bun" "$0" "$@"; elif [ -x "$HOME/.bun-1.4.2/bin/bun" ]; then exec "$HOME/.bun-1.4.2/bin/bun" "$0" "$@"; else exec bun "$0" "$@"; fi
// Float's Exact CLI runner: `bun exact.mjs --help` lists the verbs.
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, resolve } from 'node:path';

const candidates = [
  process.env.EXACT2,
  resolve(homedir(), 'Development/exact2-main'),
  resolve(homedir(), 'Development/expo/exact2'),
  resolve(homedir(), 'Development/exact2'),
].filter(Boolean);
const EXACT2 = candidates.find((p) => existsSync(resolve(p, 'scripts/app-cli.mjs'))) ?? resolve(homedir(), 'Development/expo/exact2');
const cli = resolve(EXACT2, 'scripts/app-cli.mjs');
if (!existsSync(cli)) {
  console.error(`no exact2 at ${EXACT2} (no scripts/app-cli.mjs): EXACT2 names the checkout`);
  process.exit(1);
}
const { ensureBun } = await import(resolve(EXACT2, 'scripts/bun.mjs'));
ensureBun('1.4.2');
const { run } = await import(cli);
process.exit(await run({ dir: import.meta.dir, name: basename(import.meta.dir), exact2: EXACT2, args: process.argv.slice(2) }));

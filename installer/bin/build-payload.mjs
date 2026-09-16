#!/usr/bin/env node
// Copies workflows/reqloop/ → installer/payload/ at npm pack time,
// so the published tarball is self-contained (no monorepo paths at install time).

import { cpSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SRC = resolve(__dirname, '../../workflows/reqloop');
const DST = resolve(__dirname, '../payload');

if (!existsSync(SRC)) {
  process.stderr.write(`build-payload: source not found: ${SRC}\n`);
  process.exit(1);
}

if (existsSync(DST)) rmSync(DST, { recursive: true, force: true });
mkdirSync(DST, { recursive: true });
cpSync(SRC, DST, { recursive: true });
process.stdout.write(`build-payload: copied ${SRC} → ${DST}\n`);

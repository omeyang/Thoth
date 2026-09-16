#!/usr/bin/env node
// reqloop installer — targets: claude-code | codex | costrict | costrict-cli | all
// Zero runtime dependencies. Node >= 18.

import { homedir } from 'node:os';
import { join, resolve, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  existsSync, mkdirSync, readdirSync, readFileSync,
  writeFileSync, statSync, rmSync
} from 'node:fs';
import { createInterface } from 'node:readline/promises';
import { stdin, stdout } from 'node:process';

const __dirname = dirname(fileURLToPath(import.meta.url));

// payload/ is created at pack time (see build-payload.mjs).
// In dev (running from repo), fall back to workflows/reqloop/.
const PAYLOAD_CANDIDATES = [
  resolve(__dirname, '../payload'),
  resolve(__dirname, '../../workflows/reqloop'),
];
const PAYLOAD = PAYLOAD_CANDIDATES.find(existsSync);
if (!PAYLOAD) fail(`payload not found. tried:\n  ${PAYLOAD_CANDIDATES.join('\n  ')}`);

// Target matrix. Pluralization and "skill vs prompt" differences are encoded here.
const TARGETS = {
  'claude-code': {
    userRoot: join(homedir(), '.claude'),
    projectRoot: '.claude',
    skill: { dir: 'skills', singular: false, entryName: 'SKILL.md' },
    command: { dir: 'commands', ext: '.md' },
  },
  'codex': {
    userRoot: join(homedir(), '.codex'),
    projectRoot: null,            // codex has no project-scope convention
    skill: null,                  // codex has no skill concept
    command: { dir: 'prompts', ext: '.md' },
  },
  'costrict': {
    userRoot: join(homedir(), '.costrict'),
    projectRoot: '.costrict',
    skill: { dir: 'skills', singular: false, entryName: 'SKILL.md' },
    command: { dir: 'commands', ext: '.md' },
  },
  'costrict-cli': {
    userRoot: process.env.XDG_CONFIG_HOME
      ? join(process.env.XDG_CONFIG_HOME, 'costrict')
      : join(homedir(), '.config', 'costrict'),
    projectRoot: '.costrict',
    skill: { dir: 'skill', singular: true, entryName: 'SKILL.md' },  // singular
    command: { dir: 'command', ext: '.md' },                          // singular
  },
};

const NAME = 'reqloop';
const SKILL_SRC = join(PAYLOAD, 'dist', 'SKILL.md');
const COMMAND_SRC = join(PAYLOAD, 'dist', 'command.md');
// Assets copied alongside SKILL.md for skill-capable targets.
const ASSETS = ['WORKFLOW.md', 'LITE.md', 'stages', 'templates', 'adapters'];

// ---------------- CLI ----------------

const argv = process.argv.slice(2);
const cmd = argv[0];
const rest = argv.slice(1);

if (cmd === '-h' || cmd === '--help') usage(0);

const flags = parseFlags(rest);
const targetArg = flags._[0];

// No subcommand, or `install` with no target, on a TTY → interactive.
const wantInteractive =
  !cmd ||
  (cmd === 'install' && !targetArg) ||
  flags.interactive;

if (wantInteractive) {
  if (!stdin.isTTY) {
    // Non-interactive shell (CI, pipe) — refuse to guess.
    fail('no target specified and stdin is not a TTY. run with a target or --help.');
  }
  await interactive(cmd === 'uninstall' ? 'uninstall' : 'install');
} else {
  switch (cmd) {
    case 'install':   run(installOne, targetArg, flags); break;
    case 'uninstall': run(uninstallOne, targetArg, flags); break;
    case 'list':      listTargets(); break;
    case 'doctor':    doctor(flags); break;
    default:          usage(1);
  }
}

// ---------------- commands ----------------

function run(fn, targetArg, flags) {
  if (!targetArg) fail(`missing <target>. valid: ${Object.keys(TARGETS).join(', ')}, all`);
  const targets = targetArg === 'all' ? Object.keys(TARGETS) : [targetArg];
  for (const t of targets) {
    if (!TARGETS[t]) fail(`unknown target: ${t}`);
    fn(t, flags);
  }
}

function installOne(target, flags) {
  const cfg = TARGETS[target];
  const scope = flags.scope || 'user';
  const root = resolveRoot(cfg, scope);
  if (!root) fail(`target ${target} does not support scope=${scope}`);

  header(`install ${NAME} → ${target} (scope=${scope}, root=${root})`);

  // 1. Skill (if supported)
  if (cfg.skill) {
    const skillDir = join(root, cfg.skill.dir, NAME);
    ensureDir(skillDir);
    copyFile(SKILL_SRC, join(skillDir, cfg.skill.entryName));
    for (const a of ASSETS) {
      const src = join(PAYLOAD, a);
      if (!existsSync(src)) continue;
      copyRecursive(src, join(skillDir, a));
    }
    log(`  skill:   ${rel(skillDir)}`);
  } else {
    log(`  skill:   (skipped — ${target} has no skill concept)`);
  }

  // 2. Command / prompt
  if (cfg.command) {
    const cmdDir = join(root, cfg.command.dir);
    ensureDir(cmdDir);
    const cmdPath = join(cmdDir, NAME + cfg.command.ext);
    // For codex (no skill), inline enough context into the prompt.
    const body = cfg.skill
      ? readFileSync(COMMAND_SRC, 'utf8')
      : buildInlinePrompt();
    writeFileSync(cmdPath, body);
    log(`  command: ${rel(cmdPath)}`);
  }

  log(`✓ installed to ${target}\n`);
}

function uninstallOne(target, flags) {
  const cfg = TARGETS[target];
  const scope = flags.scope || 'user';
  const root = resolveRoot(cfg, scope);
  if (!root) fail(`target ${target} does not support scope=${scope}`);

  header(`uninstall ${NAME} ← ${target} (scope=${scope}, root=${root})`);

  if (cfg.skill) {
    const skillDir = join(root, cfg.skill.dir, NAME);
    if (existsSync(skillDir)) { rmSync(skillDir, { recursive: true, force: true }); log(`  removed: ${rel(skillDir)}`); }
  }
  if (cfg.command) {
    const cmdPath = join(root, cfg.command.dir, NAME + cfg.command.ext);
    if (existsSync(cmdPath)) { rmSync(cmdPath, { force: true }); log(`  removed: ${rel(cmdPath)}`); }
  }
  log(`✓ uninstalled from ${target}\n`);
}

function listTargets() {
  log('supported targets:\n');
  for (const [name, cfg] of Object.entries(TARGETS)) {
    log(`  ${name.padEnd(14)} user=${cfg.userRoot}${cfg.projectRoot ? '  project=' + cfg.projectRoot : ''}`);
  }
}

function doctor(flags) {
  const scope = flags.scope || 'user';
  header(`doctor (scope=${scope})`);
  for (const [name, cfg] of Object.entries(TARGETS)) {
    const root = resolveRoot(cfg, scope);
    const hasSkill = cfg.skill && existsSync(join(root, cfg.skill.dir, NAME, cfg.skill.entryName));
    const hasCmd = cfg.command && existsSync(join(root, cfg.command.dir, NAME + cfg.command.ext));
    const state = (cfg.skill ? (hasSkill ? '✓' : '✗') : '-') + (hasCmd ? '✓' : '✗');
    log(`  ${name.padEnd(14)} [skill=${cfg.skill ? (hasSkill ? 'ok' : 'missing') : 'n/a'}] [cmd=${hasCmd ? 'ok' : 'missing'}]  ${root}`);
  }
}

// ---------------- interactive ----------------

async function interactive(action /* 'install' | 'uninstall' */) {
  const rl = createInterface({ input: stdin, output: stdout });
  const ask = async (q, def) => {
    const ans = (await rl.question(q)).trim();
    return ans === '' ? def : ans;
  };
  const c = ansi();

  stdout.write(`\n${c.bold}reqloop installer${c.reset}  ${c.dim}(zero-dep, interactive)${c.reset}\n\n`);

  // 1. Detect installed tools so we can pre-select.
  const names = Object.keys(TARGETS);
  const detected = {};
  for (const n of names) detected[n] = existsSync(TARGETS[n].userRoot);

  stdout.write(`${c.dim}Detected AI tool configs on this machine:${c.reset}\n`);
  names.forEach((n, i) => {
    const mark = detected[n] ? `${c.green}✓${c.reset}` : ` `;
    const state = detected[n] ? `${c.dim}(${TARGETS[n].userRoot} exists)${c.reset}` : `${c.dim}(not found)${c.reset}`;
    stdout.write(`  ${mark} ${i + 1}. ${n.padEnd(14)} ${state}\n`);
  });
  stdout.write('\n');

  // 2. Target selection. Default = detected tools; fallback = all.
  const defaultSelection = names.filter(n => detected[n]);
  const defaultLabel = defaultSelection.length
    ? `detected: ${defaultSelection.join(', ')}`
    : 'all';
  const rawTargets = await ask(
    `? Targets to ${action} (numbers/names comma-separated, or "all") ${c.dim}[${defaultLabel}]${c.reset}: `,
    defaultSelection.length ? defaultSelection.join(',') : 'all'
  );
  const selected = parseSelection(rawTargets, names);
  if (!selected.length) { rl.close(); fail('no targets selected.'); }

  // 3. Scope.
  const rawScope = await ask(`? Scope ${c.dim}[user]${c.reset} (user/project): `, 'user');
  const scope = rawScope === 'project' ? 'project' : 'user';

  // 4. Preview + confirm.
  stdout.write(`\n${c.bold}About to ${action}:${c.reset}\n`);
  for (const t of selected) {
    const root = resolveRoot(TARGETS[t], scope);
    if (!root) {
      stdout.write(`  ${c.yellow}!${c.reset} ${t.padEnd(14)} ${c.dim}(no ${scope}-scope support — will skip)${c.reset}\n`);
    } else {
      stdout.write(`  • ${t.padEnd(14)} ${c.dim}${root}${c.reset}\n`);
    }
  }
  stdout.write('\n');

  const confirm = (await ask(`? Proceed? ${c.dim}[Y/n]${c.reset} `, 'y')).toLowerCase();
  rl.close();
  if (confirm !== 'y' && confirm !== 'yes') { log('aborted.'); return; }

  // 5. Execute.
  stdout.write('\n');
  const fn = action === 'install' ? installOne : uninstallOne;
  for (const t of selected) {
    const root = resolveRoot(TARGETS[t], scope);
    if (!root) { log(`⊘ skipped ${t} (no ${scope}-scope)\n`); continue; }
    fn(t, { scope });
  }

  // 6. Post-install tip.
  if (action === 'install') {
    stdout.write(`${c.green}All done.${c.reset} In your AI tool, try: ${c.bold}/reqloop PR-42 --lite${c.reset}\n`);
    stdout.write(`${c.dim}Check status any time with: npx thoth-reqloop doctor${c.reset}\n`);
  }
}

function parseSelection(raw, names) {
  const low = raw.trim().toLowerCase();
  if (low === 'all' || low === '*') return [...names];
  const out = [];
  for (const tok of low.split(/[,\s]+/).filter(Boolean)) {
    if (/^\d+$/.test(tok)) {
      const idx = Number(tok) - 1;
      if (idx >= 0 && idx < names.length) out.push(names[idx]);
      else fail(`invalid number: ${tok}`);
    } else if (names.includes(tok)) {
      out.push(tok);
    } else {
      fail(`unknown target: ${tok}`);
    }
  }
  return [...new Set(out)];
}

function ansi() {
  const on = stdout.isTTY && !process.env.NO_COLOR;
  const w = (code) => on ? `\x1b[${code}m` : '';
  return {
    reset: w(0), bold: w(1), dim: w(2),
    green: w(32), yellow: w(33), red: w(31),
  };
}

// ---------------- helpers ----------------

function resolveRoot(cfg, scope) {
  if (scope === 'user') return cfg.userRoot;
  if (scope === 'project') return cfg.projectRoot ? resolve(process.cwd(), cfg.projectRoot) : null;
  fail(`invalid scope: ${scope} (expected: user | project)`);
}

function buildInlinePrompt() {
  const skill = readFileSync(SKILL_SRC, 'utf8');
  const command = readFileSync(COMMAND_SRC, 'utf8');
  const workflow = readFileSync(join(PAYLOAD, 'WORKFLOW.md'), 'utf8');
  // Strip frontmatter from sources; codex prompts don't use it.
  const stripFm = (s) => s.replace(/^---\n[\s\S]*?\n---\n+/, '');
  return [
    '# /reqloop — 需求自验收闭环\n',
    stripFm(command),
    '\n---\n\n## Skill 元信息\n\n',
    stripFm(skill),
    '\n---\n\n## 完整流程定义（WORKFLOW.md 嵌入副本）\n\n',
    workflow,
    '\n\n> 注：codex 无 skill 概念，本 prompt 已内嵌 SKILL.md + WORKFLOW.md 核心内容。阶段详细指令、模板与适配器未嵌入，请在源仓库查阅 `workflows/reqloop/stages/`、`workflows/reqloop/templates/` 与 `workflows/reqloop/adapters/`。',
  ].join('');
}

function parseFlags(args) {
  const out = { _: [] };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a.startsWith('--')) { out[a.slice(2)] = args[i + 1] && !args[i + 1].startsWith('--') ? args[++i] : true; }
    else out._.push(a);
  }
  return out;
}

function ensureDir(p) { if (!existsSync(p)) mkdirSync(p, { recursive: true }); }

function copyFile(src, dst) {
  ensureDir(dirname(dst));
  writeFileSync(dst, readFileSync(src));
}

function copyRecursive(src, dst) {
  const s = statSync(src);
  if (s.isDirectory()) {
    ensureDir(dst);
    for (const name of readdirSync(src)) copyRecursive(join(src, name), join(dst, name));
  } else {
    copyFile(src, dst);
  }
}

function rel(p) { return relative(process.cwd(), p) || p; }
function header(msg) { log(`\n→ ${msg}`); }
function log(msg) { process.stdout.write(msg + '\n'); }
function fail(msg) { process.stderr.write(`reqloop-install: ${msg}\n`); process.exit(1); }

function usage(code) {
  process.stdout.write(`
reqloop-install — install reqloop workflow into your AI coding tool

Usage:
  npx thoth-reqloop                       interactive install (default)
  npx thoth-reqloop install   <target>    [--scope user|project]
  npx thoth-reqloop uninstall <target>    [--scope user|project]
  npx thoth-reqloop list
  npx thoth-reqloop doctor                [--scope user|project]

Targets:
  claude-code     ~/.claude/             (skill + slash command)
  codex           ~/.codex/              (prompt only — skill inlined)
  costrict        ~/.costrict/           (skill + command, VS Code extension)
  costrict-cli    ~/.config/costrict/    (singular dirs: skill/, command/)
  all             install to every target above

Flags:
  --scope user     install to user config dir (default)
  --scope project  install to <cwd>/<project-root> (not supported by codex)

Examples:
  npx thoth-reqloop install claude-code
  npx thoth-reqloop install costrict-cli --scope project
  npx thoth-reqloop install all
  npx thoth-reqloop doctor
`);
  process.exit(code);
}

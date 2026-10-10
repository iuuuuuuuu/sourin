#!/usr/bin/env node
// ═══════════════════════════════════════════════════════════════════════
//  源影 · PR 规模门禁
// ═══════════════════════════════════════════════════════════════════════
//  规矩原文见 CONTRIBUTING.md 的「★★★ PR 规模」一节。本脚本是那条规矩的
//  **可执行版本** —— 规矩写在文档里会被忘掉，门禁跑在 PR 上不会。
//
//  用法：
//    node tools/pr_size.mjs --base <ref> [--head <ref>] [--warn] [--exempt]
//    node tools/pr_size.mjs --base main              # 本地开 PR 前自查
//    node tools/pr_size.mjs --base main --warn       # 只报不失败
//
//  ★ 判规模**必须**带 --ignore-all-space --ignore-blank-lines：
//    移除 forui 那次重写行尾让 lib/ui/live_page.dart 报出 2878/2876，
//    真实差异只有 +3 -1。不忽略空白会把一次性格式重排误判成巨型功能改动。
//
//  阈值（与 CONTRIBUTING.md 一致，改这里就要同步改那里）：
//    目标   ≤ 600 行 / ≤ 30 文件   —— 超了会提醒
//    硬上限 ≤1200 行 / ≤ 60 文件   —— 超了失败，除非 PR 带豁免标签
//
//  退出码：0 = 通过（可能带提醒）；1 = 超硬上限；2 = 用法/环境错误。

import { execFileSync } from 'node:child_process';

const TARGET_LINES = 600;
const TARGET_FILES = 30;
const HARD_LINES = 1200;
const HARD_FILES = 60;
const EXEMPT_LABEL = 'size/exempt';

function git(args) {
  return execFileSync('git', args, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
}

function usage(msg) {
  console.error('用法: node tools/pr_size.mjs --base <ref> [--head <ref>] [--warn] [--exempt]');
  if (msg) console.error('  ' + msg);
  process.exit(2);
}

const argv = process.argv.slice(2);
let base = null;
let head = 'HEAD';
let warnOnly = false;
let exempt = false;
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--base') base = argv[++i];
  else if (a === '--head') head = argv[++i];
  else if (a === '--warn') warnOnly = true;
  else if (a === '--exempt') exempt = true;
  else if (a === '-h' || a === '--help') usage('（这是帮助）');
  else usage('不认识的参数: ' + a);
}
if (!base) usage('必须给 --base');

// ★ --base 必须是 **merge-base 的近亲**（本地自查时就是你分支的分叉点）。
//   拿一个历史上更早的提交当 --base 会把中间所有提交都算进来，
//   读数会大得离谱（实测：--base 5fad6bb 让一个 11 行的提交报出 35110 行）。
let raw;
try {
  raw = git(['diff', '--ignore-all-space', '--ignore-blank-lines', '--numstat', base + '...' + head]);
} catch (e) {
  console.error('git diff 失败：' + String(e.stderr || e.message).trim());
  process.exit(2);
}

let files = 0, add = 0, del = 0, binary = 0;
const churn = [];
const TAB = String.fromCharCode(9);
for (const line of raw.split('\n')) {
  if (!line.trim()) continue;
  // 只按前两个 tab 切：文件名里可能含 tab
  const t1 = line.indexOf(TAB);
  const t2 = line.indexOf(TAB, t1 + 1);
  if (t1 < 0 || t2 < 0) continue;
  const a = line.slice(0, t1);
  const d = line.slice(t1 + 1, t2);
  const path = line.slice(t2 + 1);
  files++;
  if (a === '-' || d === '-') {
    // 二进制：git 只给 '-'，行数无从得知 ⇒ 不计行数，但计入文件数
    binary++;
    continue;
  }
  const ai = Number(a), di = Number(d);
  add += ai; del += di;
  churn.push({ path, n: ai + di, ai, di });
}
const lines = add + del;

let mb = '';
try { mb = git(['merge-base', base, head]).trim(); } catch (e) { /* 不阻塞 */ }
if (mb) {
  console.log('共同祖先  : ' + mb.slice(0, 7));
  const behind = (() => {
    try {
      return Number(git(['rev-list', '--count', mb + '..' + base]).trim());
    } catch (e) { return -1; }
  })();
  if (behind > 0) {
    console.log('★ ' + base + ' 已领先共同祖先 ' + behind + ' 个提交 ⇒ 读完数后 rebase 一下再看，');
    console.log('  否则算的不是「本 PR 会被评审的量」。');
  }
}

console.log('════ PR 规模（口径：--ignore-all-space --ignore-blank-lines）════');
console.log('范围      : ' + base + '...' + head);
console.log('文件数    : ' + files + '  (目标 ≤' + TARGET_FILES + ', 硬上限 ≤' + HARD_FILES + ')');
console.log('增删行    : +' + add + ' −' + del + ' = ' + lines +
            '  (目标 ≤' + TARGET_LINES + ', 硬上限 ≤' + HARD_LINES + ')');
if (binary) console.log('二进制    : ' + binary + ' 个（git 不给行数，未计入行数）');

if (churn.length) {
  churn.sort((x, y) => y.n - x.n);
  console.log('── 改动最大的 10 个文件（拆 PR 时先从这里切）──');
  for (const c of churn.slice(0, 10)) {
    console.log('  ' + String(c.n).padStart(6) + '  +' + String(c.ai).padStart(5) +
                ' −' + String(c.di).padStart(5) + '  ' + c.path);
  }
}

// ★★ 空 diff **不算通过** —— 那说明 --base 与 --head 指到了同一个东西，
//   或范围算错了。本仓铁律：一条永远为真的断言比没有断言更危险。
//   实测踩过：--base 5fad6bb --head 5fad6bb 读数是「0 文件 / 0 行 ✓ 通过」。
if (files === 0) {
  console.error('✗ 范围为空：' + base + '...' + head + ' 一个文件都没变。');
  console.error('  这不是「规模合格」—— 是范围算错了（多半 base 与 head 指到了同一处）。');
  process.exit(warnOnly ? 0 : 2);
}

const overHardLines = lines > HARD_LINES;
const overHardFiles = files > HARD_FILES;
const overTargetLines = lines > TARGET_LINES;
const overTargetFiles = files > TARGET_FILES;

const bar = (v, cap) => {
  const w = Math.min(24, Math.round((v / cap) * 100));
  return '█'.repeat(w) + '░'.repeat(Math.max(0, 24 - w)) +
         ' ' + Math.round((v / cap) * 100) + '%';
};
console.log('── 门禁 ──');
console.log('行数     : ' + bar(lines, HARD_LINES) + '(硬上限' + HARD_LINES + ')');
console.log('文件数   : ' + bar(files, HARD_FILES) + '(硬上限' + HARD_FILES + ')');

if (exempt) {
  console.log('⚠ 本次按 **已豁免** 处理（PR 带了 ' + EXEMPT_LABEL + ' 标签）——');
  console.log('  请确认豁免是有意为之：规矩见 CONTRIBUTING.md「★★★ PR 规模」。');
  process.exit(0);
}

if (overHardLines || overHardFiles) {
  const why = [];
  if (overHardLines) why.push('增删行 ' + lines + ' > 硬上限 ' + HARD_LINES);
  if (overHardFiles) why.push('文件数 ' + files + ' > 硬上限 ' + HARD_FILES);
  const mark = warnOnly ? '⚠' : '✗';
  const sink = warnOnly ? console.log : console.error;
  sink(mark + ' 超规模硬上限：' + why.join('；'));
  sink('  一条 PR = 一个功能域。请按上面的「改动最大的文件」切分；');
  sink('  确实拆不开（例如移除 forui 这种全站地基）时，改成两条：');
  sink('  「先合地基、再合功能」，并在 PR 描述里写明理由。');
  sink('  判据命令：git diff --ignore-all-space --ignore-blank-lines --shortstat ' + base + '...' + head);
  process.exit(warnOnly ? 0 : 1);
}

if (overTargetLines || overTargetFiles) {
  console.log('⚠ 超目标档（≤' + TARGET_LINES + ' 行 / ≤' + TARGET_FILES + ' 文件），');
  console.log('  还在硬上限内 ⇒ 通过。但下次试试能不能切得更小。');
  process.exit(0);
}

console.log('✓ 在目标档内（≤' + TARGET_LINES + ' 行 / ≤' + TARGET_FILES + ' 文件）。');
process.exit(0);

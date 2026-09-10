// macOS integration checks. Only touches a fresh temporary home; no launchd
// registration, user index, or user preferences are changed.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const bin = path.join(repo, 'zig-out/bin');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zest-daemon-test-'));
const home = fs.realpathSync(temporary);
const support = path.join(home, 'Library/Application Support/zest');
const env = { ...process.env, HOME: home };
fs.mkdirSync(support, { recursive: true });
const ignored = ['project/node_modules', 'project/.git', '.hidden', 'project/__pycache__',
  'Library/Caches', 'Library/Logs', 'Library/Developer'];
for (const dir of ignored) fs.mkdirSync(path.join(home, dir), { recursive: true });
fs.writeFileSync(path.join(home, 'original.txt'), 'original');
// FSEvents can assign IDs to coalesced fixture-creation events after the
// filesystem calls return. Let setup settle before starting a SinceNow stream.
await new Promise(resolve => setTimeout(resolve, 3000));
let log = '';
const child = spawn(path.join(bin, 'zest-indexer'), [home], { env });
child.stderr.on('data', data => { log += data; process.stdout.write(data); });
let exited = false;
child.on('exit', () => { exited = true; });
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const builds = () => (log.match(/Index built:/g) ?? []).length;
async function until(condition, timeout = 45000) {
  const start = Date.now();
  while (!condition()) {
    assert(!exited, 'daemon exited unexpectedly');
    assert(Date.now() - start < timeout, 'timed out waiting for daemon');
    await delay(100);
  }
}
function query(scope = home) {
  const result = spawnSync(path.join(bin, 'zest-query'), ['--index', path.join(support, 'index.zst'),
    '--scope', scope, '--depth', 'all', '--limit', '100'], { env, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout;
}
function request() {
  const temporaryRequest = path.join(support, 'request.tmp');
  fs.writeFileSync(temporaryRequest, randomBytes(16));
  fs.renameSync(temporaryRequest, path.join(support, 'reindex.request'));
}
function scan(root) {
  return new Promise((resolve, reject) => {
    const process = spawn(path.join(bin, 'zest-indexer'), ['--full-scan', root], { env });
    let output = '';
    process.stderr.on('data', data => output += data);
    process.on('error', reject);
    process.on('exit', code => code === 0 ? resolve(output) : reject(Error(output)));
  });
}
try {
  await until(() => builds() === 1);
  const progressPath = path.join(support, 'progress-daemon.json');
  const firstProgress = JSON.parse(fs.readFileSync(progressPath, 'utf8'));
  assert.equal(firstProgress.version, 1);
  assert.equal(firstProgress.phase, 'published');
  assert.equal(firstProgress.pid, child.pid);
  assert.equal(typeof firstProgress.run_id, 'string');
  assert(firstProgress.count > 0);
  assert.equal(firstProgress.written, firstProgress.total);
  assert.equal(fs.statSync(progressPath).mode & 0o777, 0o600);
  assert(query().includes('original.txt'));
  assert(!query().includes('scan-'));
  await delay(3000);
  for (const dir of ignored) fs.writeFileSync(path.join(home, dir, 'ignored.txt'), 'ignored');
  fs.writeFileSync(path.join(support, 'ignored.txt'), 'ignored');
  await delay(34000);
  assert.equal(builds(), 1, 'ignored-only events must not cause scan churn');
  console.log('PASS ignored descendants and own output do not trigger rebuilding');

  fs.renameSync(path.join(home, 'original.txt'), path.join(home, 'renamed.txt'));
  fs.writeFileSync(path.join(home, 'created.txt'), 'created');
  await until(() => builds() === 2);
  assert(query().includes('renamed.txt'));
  assert(query().includes('created.txt'));
  assert(!query().includes('original.txt'));
  assert(!query().includes('ignored.txt'));
  fs.unlinkSync(path.join(home, 'created.txt'));
  request();
  await until(() => builds() === 3, 10000);
  assert(!query().includes('created.txt'));
  console.log('PASS create, rename, delete, and immediate re-index request');

  fs.writeFileSync(path.join(home, 'afterfailure.txt'), 'after failure');
  request();
  fs.chmodSync(support, 0o555);
  await until(() => log.includes('error: rebuild failed:'), 10000);
  assert(!query().includes('afterfailure.txt'), 'failed build must retain last good index');
  fs.chmodSync(support, 0o755);
  await until(() => builds() === 4, 12000);
  const rebuiltProgress = JSON.parse(fs.readFileSync(progressPath, 'utf8'));
  assert.equal(rebuiltProgress.phase, 'published');
  assert.notEqual(firstProgress.run_id, rebuiltProgress.run_id);
  assert(rebuiltProgress.count >= firstProgress.count);
  assert(query().includes('afterfailure.txt'));
  console.log('PASS failed rebuild retries without another event and retains last good index');

  child.kill('SIGTERM');
  await until(() => exited, 5000);
  const roots = [path.join(home, 'a'), path.join(home, 'b')];
  for (const [index, root] of roots.entries()) {
    fs.mkdirSync(root);
    for (let i = 0; i < 10000 + index * 5000; i++) fs.writeFileSync(path.join(root, `file${i}.txt`), 'x');
  }
  for (let i = 0; i < 3; i++) await Promise.all(roots.map(scan));
  assert(!fs.readdirSync(support).some(name => name.startsWith('progress-manual-')), 'successful one-shot progress is cleaned up');
  assert(!fs.readdirSync(support).some(name => name.startsWith('scan-')), 'scan shards must be cleaned up');
  console.log('PASS overlapping scans, repeated three times');
} finally {
  child.kill('SIGTERM');
  if (!exited) await new Promise(resolve => child.once('exit', resolve));
  fs.chmodSync(support, 0o755);
  // The exact generated fixture is the only recursive cleanup target.
  fs.rmSync(temporary, { recursive: true, force: true });
}

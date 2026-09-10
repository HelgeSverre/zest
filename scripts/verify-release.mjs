// Read-only bundle validation plus an isolated one-shot scan. No launchd jobs.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const app = path.resolve(process.argv[2] ?? 'dist/Zest.app');
function run(command, args, env = process.env) {
  const result = spawnSync(command, args, { encoding: 'utf8', env, timeout: 60000 });
  assert.equal(result.status, 0, `${command}: signal=${result.signal ?? 'none'} ${result.error ?? result.stderr}`);
  return result.stdout;
}
run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', app]);
const plist = JSON.parse(run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(app, 'Contents/Info.plist')]));
assert.equal(plist.LSMinimumSystemVersion, '14.0');
assert.equal(plist.CFBundleExecutable, 'Zest');
for (const name of ['MacOS/Zest', 'Helpers/zest-indexer', 'Helpers/zest-query']) {
  const executable = path.join(app, 'Contents', name);
  assert.deepEqual(run('/usr/bin/lipo', ['-archs', executable]).trim().split(/\s+/).sort(), ['arm64', 'x86_64']);
  for (const arch of ['arm64', 'x86_64']) {
    assert.match(run('xcrun', ['vtool', '-arch', arch, '-show-build', executable]), /minos 14\.0\b/);
    // codesign --verify can succeed even when a new load command overlaps code.
    run('xcrun', ['llvm-objdump', '--macho', `--arch=${arch}`, '--private-headers', executable]);
  }
  const libraries = run('/usr/bin/otool', ['-arch', 'all', '-L', executable]).split('\n').filter(line => line.startsWith('\t'));
  for (const line of libraries) assert.match(line.trim(), /^\/(System\/Library|usr\/lib)\//, `Non-system dependency: ${line}`);
}
assert(fs.statSync(path.join(app, 'Contents/Resources/AppIcon.icns')).size > 0);
assert(fs.statSync(path.join(app, 'Contents/Resources/ThirdPartyNotices.txt')).size > 1000);
const agent = JSON.parse(run('/usr/bin/plutil', ['-convert', 'json', '-o', '-',
  path.join(app, 'Contents/Library/LaunchAgents/dev.zest.app.indexer.plist')]));
assert.equal(agent.Label, 'dev.zest.app.indexer');
assert.equal(agent.BundleProgram, 'Contents/Helpers/zest-indexer');
assert.deepEqual(agent.ProgramArguments, ['zest-indexer']);
assert(!('Program' in agent), 'Bundled agent must not hard-code an installed executable path');
const architectures = ['arm64', 'x86_64'].filter(architecture => {
  if (process.argv.includes('--all-architectures')) return true;
  const available = spawnSync('/usr/bin/arch', [`-${architecture}`, '/usr/bin/true']).status === 0;
  if (!available) console.log(`SKIP ${architecture} execution: host cannot run this architecture`);
  return available;
});
assert(architectures.length > 0, 'No runnable architecture on this host');
for (const architecture of architectures) {
 const fixture = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zest-bundle-test-')));
 try {
  fs.mkdirSync(path.join(fixture, 'files'));
  fs.writeFileSync(path.join(fixture, 'files/release-smoke.txt'), 'packaged helper test');
  const env = { ...process.env, HOME: fixture };
  const execute = (relative, args) => run('/usr/bin/arch', [`-${architecture}`, path.join(app, 'Contents', relative), ...args], env);
  execute('Helpers/zest-indexer', ['--full-scan', path.join(fixture, 'files')]);
  const output = execute('Helpers/zest-query', ['--scope', path.join(fixture, 'files')]);
  assert(output.includes('release-smoke.txt'));
  assert(!fs.existsSync(path.join(fixture, 'Library/LaunchAgents')), 'One-shot smoke test must not install a daemon');
  if (process.argv.includes('--render-ui')) {
    const screenshot = path.join(fixture, 'app.png');
    execute('MacOS/Zest', ['--snapshot', screenshot, '800x600']);
    assert(fs.statSync(screenshot).size > 10000, 'Packaged UI must render real content');
  }
  console.log(`PASS ${architecture} packaged executable smoke test`);
 } finally {
  fs.rmSync(fixture, { recursive: true, force: true });
 }
}
console.log('PASS bundle signatures, architecture, deployment targets, libraries, resources, and isolated indexing');

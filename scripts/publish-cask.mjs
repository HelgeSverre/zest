// Explicitly publish only Zest's cask after its GitHub release is public.
// Uses the operator's gh login (Contents: write on HelgeSverre/homebrew-tap).
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const version = process.argv[2];
assert.match(version ?? '', /^\d+\.\d+\.\d+$/);
const gh = args => execFileSync('gh', args, { encoding: 'utf8' });
const repository = 'HelgeSverre/zest';
const release = JSON.parse(gh(['release', 'view', `v${version}`, '--repo', repository, '--json', 'isDraft']));
assert.equal(release.isDraft, false, 'Publish the verified release before updating Homebrew');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zest-cask-'));
try {
  const filename = 'zest-universal-apple-darwin.pkg';
  gh(['release', 'download', `v${version}`, '--repo', repository, '--dir', directory,
    '--pattern', filename, '--pattern', `${filename}.sha256`]);
  const checksum = createHash('sha256').update(fs.readFileSync(path.join(directory, filename))).digest('hex');
  const expected = fs.readFileSync(path.join(directory, `${filename}.sha256`), 'utf8').trim();
  assert.equal(expected, `${checksum}  ${filename}`);
  const renderer = fileURLToPath(new URL('render-cask.mjs', import.meta.url));
  const content = execFileSync(process.execPath, [renderer, version, checksum]).toString('base64');
  const endpoint = 'repos/HelgeSverre/homebrew-tap/contents/Casks/zest.rb';
  // Directory listing errors must not be mistaken for an absent cask.
  const entries = JSON.parse(gh(['api', 'repos/HelgeSverre/homebrew-tap/contents/Casks']));
  const existing = entries.find(entry => entry.name === 'zest.rb');
  const current = existing ? JSON.parse(gh(['api', endpoint])) : null;
  if (current?.content.replace(/\s/g, '') === content) {
    console.log(`Zest ${version} cask is already current`);
  } else {
    const payload = { message: `zest ${version} cask`, content, ...(existing ? { sha: existing.sha } : {}) };
    execFileSync('gh', ['api', '--method', 'PUT', endpoint, '--input', '-'], {
      input: JSON.stringify(payload), stdio: ['pipe', 'pipe', 'pipe'],
    });
    console.log(`Published helgesverre/tap/zest ${version} (${checksum})`);
  }
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}

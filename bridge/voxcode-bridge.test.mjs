// node --test bridge/*.test.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { buildPrompt, codexArgs, describeWorkspace, normalizeCode, parseClaude, parseCodex, RESPONSE_SECTIONS } from './voxcode-bridge.mjs';

test('claude stream-json parsing', () => {
  assert.deepEqual(parseClaude('{"type":"system","subtype":"init","session_id":"s1"}'), [{ session: { _0: 's1' } }]);
  assert.deepEqual(parseClaude('{"type":"system","subtype":"hook_started"}'), []);
  assert.deepEqual(parseClaude('{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"a.swift"}}]}}'),
    [{ status: { _0: 'Editing' } }, { activity: { _0: 'Edit a.swift' } }]);
  assert.deepEqual(parseClaude('{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}'),
    [{ status: { _0: 'Testing' } }, { activity: { _0: '$ npm test' } }]);
  assert.deepEqual(parseClaude('{"type":"assistant","message":{"content":[{"type":"text","text":" hi \\n"}]}}'), [{ message: { _0: 'hi' } }]);
  assert.deepEqual(parseClaude('{"type":"result","is_error":false,"result":"done","session_id":"s1"}'), [{ session: { _0: 's1' } }, { completed: { _0: 'done' } }]);
  assert.deepEqual(parseClaude('{"type":"result","is_error":true,"result":"","subtype":"error_max_turns"}'), [{ failed: { _0: 'error_max_turns' } }]);
  assert.deepEqual(parseClaude('not json'), []);
});

test('codex json parsing', () => {
  assert.deepEqual(parseCodex('{"type":"thread.started","thread_id":"t1"}'), [{ session: { _0: 't1' } }]);
  assert.deepEqual(parseCodex('{"type":"item.started","item":{"type":"command_execution","command":"rg login"}}'),
    [{ status: { _0: 'Analyzing' } }, { activity: { _0: '$ rg login' } }]);
  assert.deepEqual(parseCodex('{"type":"item.completed","item":{"type":"reasoning","text":"secret"}}'), []);
  assert.deepEqual(parseCodex('{"type":"turn.completed"}'), [{ completed: { _0: '' } }]);
  assert.deepEqual(parseCodex('{"type":"turn.failed","error":{"message":"401"}}'), [{ failed: { _0: '401' } }]);
});

test('codex args keep extra -c/-m args on follow-ups', () => {
  const extra = ['-c', 'model_provider="openrouter"', '-m', 'x'];
  assert.deepEqual(codexArgs('p', null, extra, '/w'), ['exec', '--json', '--skip-git-repo-check', '-s', 'workspace-write', ...extra, '-C', '/w', 'p']);
  assert.deepEqual(codexArgs('p', 't1', extra, '/w').slice(-6), [...extra, 't1', 'p']);
});

test('prompt and workspace context', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vox-'));
  fs.mkdirSync(path.join(dir, '.git'));
  fs.mkdirSync(path.join(dir, 'src'));
  fs.writeFileSync(path.join(dir, '.git/HEAD'), 'ref: refs/heads/main\n');
  fs.writeFileSync(path.join(dir, 'package.json'), '{}');
  assert.equal(describeWorkspace(dir), 'Git branch: main\nTop-level entries: package.json, src/');

  const prompt = buildPrompt({ text: 'ช่วยดู login', workspace: dir, activeFile: null, agent: 'Codex', isFollowUp: false });
  assert.ok(prompt.includes('> ช่วยดู login'));
  assert.ok(prompt.includes('## Selected agent\nCodex'));
  for (const s of RESPONSE_SECTIONS) assert.ok(prompt.includes('## ' + s));
  fs.rmSync(dir, { recursive: true });
});

test('pairing code normalization matches the app', () => {
  assert.equal(normalizeCode(' abcd-efgh-jk23 '), 'ABCDEFGHJK23');
});

test('speech server turns Thai text into audio (macOS)', { skip: process.platform !== 'darwin', timeout: 60_000 }, async () => {
  const { SpeechServer } = await import('./voxcode-bridge.mjs');
  const speech = new SpeechServer();
  try {
    const [thai, english] = await Promise.all([speech.speak('สวัสดีครับ แก้ไฟล์เรียบร้อยแล้ว'), speech.speak('All tests pass.')]);
    assert.ok(thai.length > 5000, `thai audio too small: ${thai.length}`);
    assert.ok(english.length > 2000, `english audio too small: ${english.length}`);
    assert.equal(thai.subarray(4, 8).toString(), 'ftyp'); // MPEG-4 container
    assert.ok(speech.voices?.['th-TH'], 'reports the chosen Thai voice');
  } finally {
    speech.stop();
  }
});

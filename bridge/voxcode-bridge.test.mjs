// node --test bridge/*.test.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { buildPrompt, replyLanguageRule, claudeArgs, codexArgs, codexModels, modelsFor, sanitizeOptions, describeWorkspace, generalPrompt, interruptionNote, loadAgents, normalizeCode, parseClaude, parseCodex, RESPONSE_SECTIONS, workspacesFor } from './voxcode-bridge.mjs';

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
  assert.ok(prompt.includes('Reply in the language of the user request.')); // no language sent
  const thai = buildPrompt({ text: 'ช่วยดู login', workspace: dir, activeFile: null, agent: 'Codex', isFollowUp: false, language: 'th-TH' });
  const rule = 'Reply in Thai (ตอบเป็นภาษาไทย). Keep code, commands, file names and technical terms in English.';
  assert.ok(thai.split('\n')[1] === rule, 'rule right after the title');
  assert.ok(thai.endsWith(rule), 'and as the very last line');
  assert.equal(replyLanguageRule('en-US'), 'Reply in English.');
  fs.rmSync(dir, { recursive: true });
});

test('agents split into the project workspace and General', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vox-'));
  const file = path.join(dir, 'agents.json');
  fs.writeFileSync(file, JSON.stringify([{ name: 'Claude', cli: 'claude' }, { name: 'Codex', cli: 'codex' }]));
  const agents = loadAgents(file); // no general agent configured: the default one is added, renamed to stay unique
  assert.deepEqual(workspacesFor('/x/myapp', agents), [
    { id: 'code', name: 'myapp', agents: ['Claude', 'Codex'] },
    { id: 'general', name: 'General', agents: ['Claude (General)'] },
  ]);
  fs.writeFileSync(file, JSON.stringify([{ name: 'Codex', cli: 'codex' }, { name: 'Chat', cli: 'ollama', model: 'qwen3:8b', workspace: 'general' }]));
  assert.deepEqual(workspacesFor('/x/myapp', loadAgents(file))[1].agents, ['Chat']); // configured: kept as is
  fs.writeFileSync(file, JSON.stringify([{ name: 'Codex', cli: 'codex', workspace: 'other' }]));
  assert.throws(() => loadAgents(file), /workspace/);
  assert.ok(!generalPrompt('th-TH').includes('software engineering'));
  assert.ok(generalPrompt('th-TH').includes('ตอบเป็นภาษาไทย'));
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

test('ollama chat agent streams the answer and remembers the chat', async () => {
  const http = await import('node:http');
  const { AgentSession, chatSystemPrompt } = await import('./voxcode-bridge.mjs');
  const requests = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => (body += d)).on('end', () => {
      requests.push(JSON.parse(body));
      res.writeHead(200, { 'content-type': 'application/x-ndjson' });
      for (const piece of ['## Summary\n', 'สวัสดี', 'ครับ']) res.write(JSON.stringify({ message: { content: piece }, done: false }) + '\n');
      res.end(JSON.stringify({ message: { content: '' }, done: true }) + '\n');
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const host = `http://127.0.0.1:${server.address().port}`;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vox-'));
  const events = [];
  const session = new AgentSession(dir, [{ name: 'Local', cli: 'ollama', model: 'qwen3:8b', host }], (m) => events.push(m));
  const finished = () => new Promise((resolve) => {
    const check = () => (events.some((m) => m.finished) ? resolve(events.find((m) => m.finished).finished) : setTimeout(check, 20));
    check();
  });
  try {
    session.run({ id: 'a', text: 'ช่วยอธิบายโปรเจกต์', agent: 'Local', language: 'th-TH' });
    assert.equal((await finished()).status, 'Completed');
    const completed = events.find((m) => m.event?.event.completed)?.event.event.completed._0;
    assert.equal(completed, '## Summary\nสวัสดีครับ');
    assert.equal(requests[0].model, 'qwen3:8b');
    assert.equal(requests[0].think, false);
    assert.equal(requests[0].messages[0].role, 'system');
    assert.ok(requests[0].messages[0].content.includes('ตอบเป็นภาษาไทยเสมอ'));

    events.length = 0;
    session.run({ id: 'b', text: 'ต่อ', agent: 'Local', language: 'th-TH' });
    await finished();
    assert.deepEqual(requests[1].messages.map((m) => m.role), ['system', 'user', 'assistant', 'user']); // follow-up keeps context

    session.reset();
    events.length = 0;
    session.run({ id: 'c', text: 'ใหม่', agent: 'Local', language: 'th-TH' });
    await finished();
    assert.equal(requests[2].messages.length, 2); // new conversation forgets
  } finally {
    server.close();
    fs.rmSync(dir, { recursive: true });
  }
  assert.ok(chatSystemPrompt(os.tmpdir(), 'en-US').startsWith('You are Vox Agent'));
});

test('cancelling an ollama chat stops it cleanly', async () => {
  const http = await import('node:http');
  const { AgentSession } = await import('./voxcode-bridge.mjs');
  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'content-type': 'application/x-ndjson' });
    res.write(JSON.stringify({ message: { content: 'เริ่ม' }, done: false }) + '\n'); // then never finishes
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vox-'));
  const events = [];
  const session = new AgentSession(dir, [{ name: 'Local', cli: 'ollama', model: 'm', host: `http://127.0.0.1:${server.address().port}` }], (m) => events.push(m));
  try {
    session.run({ id: 'a', text: 'x', agent: 'Local' });
    await new Promise((r) => setTimeout(r, 200));
    session.cancel();
    await new Promise((r) => setTimeout(r, 200));
    assert.deepEqual(events.filter((m) => m.finished).map((m) => m.finished.status), ['Cancelled']);
    assert.equal(session.current, null);
  } finally {
    server.closeAllConnections();
    server.close();
    fs.rmSync(dir, { recursive: true });
  }
});

test('permission modes and effort become CLI flags (and nothing else does)', () => {
  const has = (args, ...seq) => args.join(' ').includes(seq.join(' '));
  assert.ok(has(claudeArgs('p', null, [], { mode: 'manual' }), '--permission-mode', 'acceptEdits'));
  assert.ok(has(claudeArgs('p', null, [], {}), '--permission-mode', 'auto'));
  const full = claudeArgs('p', null, [], { mode: 'full', effort: 'max' });
  assert.ok(full.includes('--dangerously-skip-permissions') && !full.includes('--permission-mode'));
  assert.ok(has(full, '--effort', 'max'));
  assert.ok(has(codexArgs('p', null, [], '/w', { mode: 'full' }), '-s', 'danger-full-access'));
  assert.ok(has(codexArgs('p', 't1', [], '/w', { mode: 'full', effort: 'max' }), '-c', 'sandbox_mode="danger-full-access"', '-c', 'model_reasoning_effort="xhigh"'));
  assert.ok(has(codexArgs('p', null, ['-c', 'model_reasoning_effort="none"'], '/w', { effort: 'high' }),
    '-c', 'model_reasoning_effort="high"', '-c', 'model_reasoning_effort="none"')); // agent's own setting comes last and wins
  assert.deepEqual(sanitizeOptions({ mode: 'root; rm -rf /', effort: '"; echo' }), { mode: 'auto', effort: undefined });
});

test('models offered per agent, and only listed ones are used', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vox-'));
  fs.writeFileSync(path.join(dir, 'models_cache.json'), JSON.stringify({ models: [
    { slug: 'b', display_name: 'B', visibility: 'list', priority: 2 },
    { slug: 'hidden', display_name: 'H', visibility: 'hide', priority: 1 },
    { slug: 'a', display_name: 'A', visibility: 'list', priority: 1 },
  ] }));
  assert.deepEqual(codexModels(dir), [{ id: 'a', name: 'A' }, { id: 'b', name: 'B' }]);
  assert.deepEqual(modelsFor({ cli: 'claude' }).map((m) => m.id), ['fable', 'opus', 'sonnet', 'haiku']);
  assert.deepEqual(modelsFor({ cli: 'codex', args: ['-m', 'qwen/qwen3-coder'] }), []); // pinned by the agent
  assert.deepEqual(modelsFor({ cli: 'ollama' }, [{ id: 'qwen3:8b', name: 'qwen3:8b' }]).map((m) => m.id), ['qwen3:8b']);
  assert.deepEqual(modelsFor({ cli: 'claude', models: ['opus'] }), [{ id: 'opus', name: 'opus' }]);
  const args = claudeArgs('p', null, ['--model', 'haiku'], { model: 'opus' });
  assert.ok(args.lastIndexOf('opus') > args.indexOf('haiku'), 'the picked model comes last and wins');
  assert.ok(codexArgs('p', null, [], '/w', { model: 'a' }).join(' ').includes('-m a'));
  fs.rmSync(dir, { recursive: true });
});

test('General answers fast: no thinking or low reasoning, streamed, read-only', () => {
  const has = (args, ...seq) => args.join('\0').includes(seq.join('\0'));
  assert.ok(has(claudeArgs('p', null, [], { fast: true }), '--settings', '{"alwaysThinkingEnabled":false}'));
  assert.ok(!claudeArgs('p', null, [], { fast: true, effort: 'high' }).includes('--settings')); // a chosen effort wins
  assert.ok(!claudeArgs('p', null, [], {}).includes('--settings'));
  assert.ok(has(codexArgs('p', null, [], '/w', { fast: true, mode: 'full' }), '-s', 'read-only', '-c', 'model_reasoning_effort="low"'));
  assert.ok(has(codexArgs('p', 't1', [], '/w', { fast: true, effort: 'high' }), 'sandbox_mode="read-only"', '-c', 'model_reasoning_effort="high"'));

  const state = {};
  const delta = (text) => JSON.stringify({ type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text } } });
  parseClaude(JSON.stringify({ type: 'stream_event', event: { type: 'message_start' } }), state);
  assert.deepEqual(parseClaude(delta('ท้องฟ้า'), state), [{ message: { _0: 'ท้องฟ้า' } }]);
  assert.deepEqual(parseClaude(delta('สีฟ้า '), state), [{ message: { _0: 'ท้องฟ้าสีฟ้า' } }]);
  parseClaude(JSON.stringify({ type: 'stream_event', event: { type: 'message_start' } }), state); // next message starts over
  assert.deepEqual(parseClaude(delta('ค่ะ'), state), [{ message: { _0: 'ค่ะ' } }]);

  assert.equal(interruptionNote(undefined), '');
  assert.match(interruptionNote(''), /before hearing any/);
  assert.match(interruptionNote('แสงอาทิตย์มีหลายสี'), /heard only up to: "…แสงอาทิตย์มีหลายสี"/);
  assert.ok(loadAgents(null).some((a) => a.cli === 'codex' && a.workspace === 'general'));
});

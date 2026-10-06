#!/usr/bin/env node
// Vox Agent bridge: lets the Vox Agent app run coding-agent CLIs in one workspace on this machine.
// Runs on macOS and Linux with Node 18+, no dependencies.
//
// Usage: node voxcode-bridge.mjs [--workspace <dir>] [--port <n>] [--host <addr>] [--agents <file>] [--new-code] [--managed]
//
// --host limits which address it listens on (default: all). --managed is for a parent app that owns the
// bridge: no Bonjour, and exit as soon as the parent closes our stdin (so it never outlives the app).
//
// Agents come from --agents, else $VOXCODE_HOME/agents.json (default ~/.voxcode), else Claude Code + Codex.
// "cli": "claude" | "codex" drive those coding-agent CLIs (Codex can also reach OpenRouter etc. via -c/-m args).
// "cli": "ollama" chats with a local model directly: no file access, but small models answer properly
// (through Codex they ignore the reply language and invent results). See agents.example.json.
// "workspace": "general" puts an agent in the General workspace: everyday questions, not the project.
// It runs in an empty folder of its own, can only search the web, and is tuned to answer fast: no extended
// thinking (Claude) or low reasoning (Codex) unless the app asks for an effort. If agents.json has no general
// agent, the default one (Claude) is added.
//
// Wire format: newline-delimited JSON over TLS 1.2 with a pre-shared key derived from the pairing code.
// It is Swift's synthesized Codable form and must match Sources/VoxCodeCore/Remote.swift:
//   app → bridge  {"run":{"id","text","agent","activeFile"?,"language"?,"mode"?,"effort"?,"model"?,"interrupted"?}} | {"cancel":{}} | {"reset":{}}
//                 mode: "manual" | "auto" | "full" (permissions); effort: "low" | "medium" | "high" | "max"
//                 interrupted: the user cut the previous answer off; what they heard of it ("" = nothing)
//                 {"speak":{"id","text"}}
//   bridge → app  {"hello":{"workspace","agents","speech","workspaces":[{"id","name","agents"}],"models":{agent:[{"id","name"}]}}}
//                 {"audio":{"id","data"?,"error"?}}   (data: base64 AAC; macOS only, see tts-server.swift)
//                 {"event":{"id","event":{"status"|"activity"|"message"|"completed":{"_0":…}}}}
//                 {"finished":{"id","status","error"?}}

import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { Readable } from 'node:stream';
import tls from 'node:tls';
import { pathToFileURL } from 'node:url';

export const DEFAULT_PORT = 47800;
const SERVICE_TYPE = '_voxcode._tcp';
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O/1/I
// ponytail: fixed 15 min agent timeout; make it a flag if long refactors hit it.
const TIMEOUT_MS = 15 * 60 * 1000;
const GENERAL = 'general';
const GENERAL_AGENT = { name: 'Claude', cli: 'claude', workspace: GENERAL };
const DEFAULT_AGENTS = [{ name: 'Claude Code', cli: 'claude' }, { name: 'Codex', cli: 'codex' }, GENERAL_AGENT,
  { name: 'GPT', cli: 'codex', workspace: GENERAL }];
// The General workspace answers questions; it has no business touching files or running commands,
// nor using the MCP servers configured for coding (company knowledge bases, docs connectors…).
// No settings sources either: the user's hooks and plugins are for their coding sessions (and slow startup).
// Partial messages: the answer streams in as it is written, so the app starts speaking after the first sentence.
export const GENERAL_CLAUDE_ARGS = ['--tools', 'WebSearch,WebFetch', '--strict-mcp-config', '--setting-sources', '',
  '--include-partial-messages'];

// MARK: Pairing

export const normalizeCode = (code) => [...code.toUpperCase()].filter((c) => ALPHABET.includes(c)).join('');

function generateCode() {
  const pick = () => ALPHABET[crypto.randomInt(ALPHABET.length)];
  return [0, 1, 2].map(() => Array.from({ length: 4 }, pick).join('')).join('-');
}

/// Same derivation as NWParameters.voxcode(pairingCode:) in Remote.swift.
export const pskFor = (code) => crypto.createHmac('sha256', normalizeCode(code)).update('VoxCode PSK').digest();

// MARK: Prompt

export const RESPONSE_SECTIONS = ['Summary', 'Changed files', 'Checks', 'Result', 'Remaining issues'];

export function describeWorkspace(workspace, maxEntries = 50) {
  let branch = 'not a git repository';
  try {
    const head = fs.readFileSync(path.join(workspace, '.git/HEAD'), 'utf8').trim();
    branch = head.startsWith('ref: refs/heads/') ? head.slice('ref: refs/heads/'.length) : `detached at ${head.slice(0, 12)}`;
  } catch {}
  const entries = fs.readdirSync(workspace, { withFileTypes: true })
    .filter((e) => !e.name.startsWith('.'))
    .map((e) => e.name + (e.isDirectory() ? '/' : ''))
    .sort();
  const listed = entries.slice(0, maxEntries).join(', ') + (entries.length > maxEntries ? ', …' : '');
  return `Git branch: ${branch}\nTop-level entries: ${listed || '(empty)'}`;
}

/// Keep in sync with PromptBuilder.swift (used when the Mac app runs agents itself).
/// The app sends its speech language: say it outright. "Reply in the user's language" isn't enough when a
/// Thai request is full of English tech words and the whole prompt is English (local models drift to English).
export function replyLanguageRule(language) {
  // Written in Thai too: small local models follow an instruction in the target language far more reliably.
  if (language?.startsWith('th')) return 'Reply in Thai (ตอบเป็นภาษาไทย). Keep code, commands, file names and technical terms in English.';
  if (language?.startsWith('en')) return 'Reply in English.';
  return 'Reply in the language of the user request.';
}

export function buildPrompt({ text, workspace, activeFile, agent, isFollowUp, language }) {
  const rule = replyLanguageRule(language);
  return `# Vox Agent request${isFollowUp ? ' (follow-up in the same conversation)' : ''}
${language ? rule + '\n' : ''}
## User request
Spoken by the user and converted with speech-to-text, so it may be informal, incomplete, or contain recognition errors. English technical words spoken inside Thai often come out as Thai words that sound alike (e.g. "มาร์คดาว" = markdown, "รีดมี" = README, "ดีพลอย" = deploy): read them by sound.
> ${text.replaceAll('\n', '\n> ')}

## Workspace
Path: ${workspace}
${describeWorkspace(workspace)}

## Active file
${activeFile || 'None'}

## Selected agent
${agent}

## How to work
You are a software engineering agent working in the workspace above. Inspect the codebase to work out what the user means instead of interpreting the transcription literally. If the request is still ambiguous, state the assumption you made.
- Before modifying code: inspect the repository, understand the relevant architecture, identify the root cause, reuse existing patterns and utilities, avoid unrelated changes.
- When implementing: make the smallest appropriate change, follow the project's conventions, do not invent APIs, schemas, business rules or requirements, add or update tests when appropriate.
- After implementing: run the relevant tests, builds or linters and review the git diff.
- Before each major step, write one short sentence in the user's language saying what you are about to do; the user may be listening instead of reading.

## Constraints
- Never expose secrets, credentials, API keys, tokens or private keys.
- Do not delete files or data unless the user explicitly asked for it.
- Do not run destructive operations (rm -rf, git reset --hard, force push, dropping data); stop and ask for confirmation instead.
- Do not commit or push unless the user explicitly asked for it.
- Report conclusions only; do not include internal reasoning.

## Response format
${rule} Use exactly these Markdown headings, in English:
${RESPONSE_SECTIONS.map((s) => '## ' + s).join('\n')}
Keep Summary to 1–3 short sentences because it is read aloud. For a plain question, answer under Summary and write "None" in the other sections.${language ? '\n\n' + rule : ''}`;
}

/// System prompt for local chat models: short, and in Thai when the app speaks Thai, which is what makes
/// small models answer in Thai and admit what they can't see instead of inventing it.
export function chatSystemPrompt(workspace, language) {
  const context = describeWorkspace(workspace);
  if (language?.startsWith('th')) {
    return `คุณคือ Vox Agent ผู้ช่วยนักพัฒนาซอฟต์แวร์ที่คุยด้วยเสียง ตอบเป็นภาษาไทยเสมอ (คำศัพท์เทคนิค ชื่อไฟล์ และโค้ดใช้ภาษาอังกฤษได้)
โปรเจกต์ที่ผู้ใช้กำลังทำ: ${path.basename(workspace)}
${context}
คุณอ่านไฟล์ แก้ไฟล์ หรือรันคำสั่งไม่ได้ ห้ามแต่งว่าได้ตรวจสอบหรือแก้ไขแล้ว ถ้าคำถามต้องดูโค้ดจริง ให้ตอบเท่าที่รู้ แล้วแนะนำให้สลับไปใช้ Claude Code
รูปแบบคำตอบ: ขึ้นต้นด้วยหัวข้อ "## Summary" ตามด้วยคำตอบสั้นๆ 1–3 ประโยค (จะถูกอ่านออกเสียง) ถ้ามีรายละเอียดเพิ่มให้ใส่ใต้หัวข้อ "## Result"`;
  }
  return `You are Vox Agent, a voice assistant for software developers. ${replyLanguageRule(language)}
The user's project: ${path.basename(workspace)}
${context}
You cannot read files, edit files or run commands. Never claim you checked or changed anything; if the question needs the actual code, answer what you can and suggest switching to Claude Code.
Format: start with "## Summary" and a 1–3 sentence answer (it is read aloud); put any details under "## Result".`;
}

/// Instructions for the General workspace: an everyday assistant, not a coding agent.
export function generalPrompt(language) {
  return `You are Vox Agent, a voice assistant. The user talks to you by voice about anything: everyday questions, ideas, writing, explanations. This is not about a codebase; there are no project files. Use web search only when the answer depends on current facts.
${replyLanguageRule(language)}
Everything you write is read aloud, so talk the way a person does in conversation: answer straight away in 1–3 short sentences, no headings, lists, tables or Markdown, and go into detail only when asked.
The user may cut you off mid-answer; then you are told how much they heard. Respond to what they say now, without repeating what they already heard.`;
}

/// Added to the prompt after the user cut the previous answer off, so the agent knows what they actually heard.
export function interruptionNote(heard) {
  if (typeof heard !== 'string') return '';
  const tail = heard.trim().slice(-400);
  return tail
    ? `\n\n(The user interrupted your previous answer. They heard only up to: "…${tail}")`
    : '\n\n(The user interrupted before hearing any of your previous answer.)';
}

/// The workspaces the app can switch between: the project folder and General, each with its own agents.
export function workspacesFor(workspace, agents) {
  const names = (general) => agents.filter((a) => (a.workspace === GENERAL) === general).map((a) => a.name);
  return [
    { id: 'code', name: path.basename(workspace), agents: names(false) },
    { id: GENERAL, name: 'General', agents: names(true) },
  ];
}

// MARK: Models

const CLAUDE_MODELS = [['fable', 'Fable'], ['opus', 'Opus'], ['sonnet', 'Sonnet'], ['haiku', 'Haiku']]
  .map(([id, name]) => ({ id, name }));

/// Models Codex offers in its own picker (its cache of the account's models), best first.
export function codexModels(home = process.env.CODEX_HOME ?? path.join(os.homedir(), '.codex')) {
  try {
    const { models } = JSON.parse(fs.readFileSync(path.join(home, 'models_cache.json'), 'utf8'));
    return models.filter((m) => m.visibility === 'list').sort((a, b) => a.priority - b.priority)
      .map((m) => ({ id: m.slug, name: m.display_name ?? m.slug }));
  } catch {
    return [];
  }
}

/// Chat models installed in Ollama (embedding models can't chat).
export async function ollamaModels(host = 'http://localhost:11434') {
  try {
    const response = await fetch(`${host}/api/tags`, { signal: AbortSignal.timeout(1500) });
    const { models } = await response.json();
    return models.map((m) => m.name).filter((n) => !n.includes('embed')).map((n) => ({ id: n, name: n }));
  } catch {
    return [];
  }
}

/// The models the app may pick for each agent. Empty when the agent's args pin one (e.g. a provider + `-m`).
export function modelsFor(agent, ollama = []) {
  if (Array.isArray(agent.models)) return agent.models.map((m) => (typeof m === 'string' ? { id: m, name: m } : m));
  if ((agent.args ?? []).some((a) => a === '-m' || a === '--model')) return [];
  if (agent.cli === 'claude') return CLAUDE_MODELS;
  if (agent.cli === 'codex') return codexModels();
  if (agent.cli === 'ollama') return ollama;
  return [];
}

// MARK: Agent CLIs

const ev = (kind, value) => ({ [kind]: { _0: value } });
const truncate = (s, max = 120) => {
  const line = s.replaceAll('\n', ' ');
  return line.length > max ? line.slice(0, max) + '…' : line;
};

function statusForCommand(command) {
  const c = command.toLowerCase();
  const checks = ['test', 'build', 'lint', 'xcodebuild', 'pytest', 'jest', 'vitest', 'tsc', 'cargo check', 'go vet'];
  return checks.some((k) => c.includes(k)) ? 'Testing' : 'Analyzing';
}

// Only these values ever reach a command line.
const MODES = ['manual', 'auto', 'full'];
const EFFORTS = ['low', 'medium', 'high', 'max'];
export const sanitizeOptions = ({ mode, effort } = {}) => ({
  mode: MODES.includes(mode) ? mode : 'auto',
  effort: EFFORTS.includes(effort) ? effort : undefined,
});

/// manual: edits allowed, shell commands need approval (none headless) · auto: Claude's safety classifier · full: no checks.
/// `options.fast`: no extended thinking unless an effort was chosen (the General workspace's quick answers).
export function claudeArgs(prompt, sessionID, extra = [], options = {}) {
  const { mode, effort } = sanitizeOptions(options);
  const fast = options.fast && !effort ? ['--settings', '{"alwaysThinkingEnabled":false}'] : [];
  const permissions = mode === 'full' ? ['--dangerously-skip-permissions']
    : ['--permission-mode', mode === 'manual' ? 'acceptEdits' : 'auto'];
  // options.model is already checked against the agent's list; last so it wins over the agent's own --model.
  return ['-p', prompt, '--output-format', 'stream-json', '--verbose', ...permissions,
    ...(effort ? ['--effort', effort] : []), ...fast, ...(sessionID ? ['--resume', sessionID] : []), ...extra,
    ...(options.model ? ['--model', options.model] : [])];
}

/// `state` (one per run) collects streamed text when Claude runs with --include-partial-messages.
export function parseClaude(line, state = {}) {
  let o;
  try { o = JSON.parse(line); } catch { return []; }
  switch (o.type) {
    case 'stream_event': {
      const e = o.event ?? {};
      if (e.type === 'message_start') state.text = '';
      if (e.type !== 'content_block_delta' || e.delta?.type !== 'text_delta') return [];
      state.text = (state.text ?? '') + (e.delta.text ?? '');
      const text = state.text.trim();
      return text ? [ev('message', text)] : [];
    }
    case 'system':
      return o.subtype === 'init' && o.session_id ? [ev('session', o.session_id)] : [];
    case 'assistant':
      return (o.message?.content ?? []).flatMap((item) => {
        if (item.type === 'text') {
          const text = (item.text ?? '').trim();
          return text ? [ev('message', text)] : [];
        }
        if (item.type === 'tool_use') {
          const name = item.name ?? 'Tool';
          const input = item.input ?? {};
          const status = ['Edit', 'MultiEdit', 'Write', 'NotebookEdit'].includes(name) ? 'Editing'
            : name === 'Bash' ? statusForCommand(input.command ?? '') : 'Analyzing';
          const detail = name === 'Bash' && input.command ? null
            : ['file_path', 'pattern', 'path', 'url', 'description'].map((k) => input[k]).find((v) => typeof v === 'string');
          const activity = name === 'Bash' && input.command ? '$ ' + truncate(input.command) : detail ? `${name} ${truncate(detail)}` : name;
          return [ev('status', status), ev('activity', activity)];
        }
        return [];
      });
    case 'result': {
      const events = o.session_id ? [ev('session', o.session_id)] : [];
      const result = o.result ?? '';
      events.push(o.is_error ? ev('failed', result || o.subtype || 'Claude Code failed') : ev('completed', result));
      return events;
    }
    default:
      return [];
  }
}

/// `exec resume` has no -s/-C flags, so extra args must be `-c`/`-m` style to work on follow-ups too.
/// The agent's own args come last so an agent can pin its reasoning (e.g. "none" for a small local model).
/// `options.fast`: read-only, and low reasoning unless an effort was chosen (the General workspace).
export function codexArgs(prompt, sessionID, extra = [], workspace, options = {}) {
  const { mode, effort } = sanitizeOptions(options);
  const sandbox = options.fast ? 'read-only' : mode === 'full' ? 'danger-full-access' : 'workspace-write';
  const level = effort ?? (options.fast ? 'low' : undefined);
  const reasoning = level ? ['-c', `model_reasoning_effort="${level === 'max' ? 'xhigh' : level}"`] : [];
  const model = options.model ? ['-m', options.model] : [];
  return sessionID
    ? ['exec', 'resume', '--json', '--skip-git-repo-check', '-c', `sandbox_mode="${sandbox}"`, ...reasoning, ...model, ...extra, sessionID, prompt]
    : ['exec', '--json', '--skip-git-repo-check', '-s', sandbox, ...reasoning, ...model, ...extra, '-C', workspace, prompt];
}

export function parseCodex(line) {
  let o;
  try { o = JSON.parse(line); } catch { return []; }
  const item = o.item ?? {};
  if (o.type === 'thread.started') return o.thread_id ? [ev('session', o.thread_id)] : [];
  if (o.type === 'turn.started') return [ev('status', 'Analyzing')];
  if (o.type === 'item.started' && item.type === 'command_execution') {
    const command = item.command ?? '';
    return [ev('status', statusForCommand(command)), ev('activity', '$ ' + truncate(command))];
  }
  if (o.type === 'item.completed' && item.type === 'agent_message') {
    const text = (item.text ?? '').trim();
    return text ? [ev('message', text)] : [];
  }
  if (o.type === 'item.completed' && item.type === 'file_change') {
    const paths = (item.changes ?? []).map((c) => c.path).filter(Boolean);
    return [ev('status', 'Editing'), ev('activity', 'Edited ' + truncate(paths.join(', ')))];
  }
  if (o.type === 'turn.completed') return [ev('completed', '')];
  if (o.type === 'turn.failed') return [ev('failed', o.error?.message ?? 'Codex turn failed')];
  // Transient (e.g. reconnect attempts); a real failure also arrives as turn.failed.
  if (o.type === 'error' && o.message) return [ev('activity', '⚠︎ ' + truncate(o.message))];
  // Reasoning items are deliberately dropped: never surface hidden chain-of-thought.
  return [];
}

// MARK: Sessions

/// Runs one agent at a time in `workspace`, remembering each agent's session for follow-ups.
export class AgentSession {
  /// `generalDir`: the empty folder General-workspace agents run in.
  constructor(workspace, agents, emit, generalDir = path.join(os.tmpdir(), 'voxagent-general')) {
    Object.assign(this, { workspace, agents, emit, generalDir, sessions: new Map(), chats: new Map(), current: null, ollama: [] });
  }

  /// The models offered for every agent (sent to the app in hello).
  models() {
    return Object.fromEntries(this.agents.map((a) => [a.name, modelsFor(a, this.ollama)]));
  }

  run({ id, text, agent: name, activeFile, language, mode, effort, model: requestedModel, interrupted }) {
    if (this.current) return this.emit({ finished: { id, status: 'Failed', error: 'The agent is already running.' } });
    const agent = this.agents.find((a) => a.name === name);
    if (!agent) return this.emit({ finished: { id, status: 'Failed', error: `Unknown agent: ${name}` } });
    // Only a model from the agent's own list ever reaches a command line.
    const model = modelsFor(agent, this.ollama).some((m) => m.id === requestedModel) ? requestedModel : undefined;
    const note = interruptionNote(interrupted);
    if (agent.cli === 'ollama') return this.chat({ id, text: text + note, agent: model ? { ...agent, model } : agent, language });

    const sessionID = this.sessions.get(name);
    const general = agent.workspace === GENERAL;
    const cwd = general ? this.generalDir : this.workspace;
    if (general) fs.mkdirSync(cwd, { recursive: true });
    const said = `The user said (speech-to-text, may contain recognition errors):\n> ${text.replaceAll('\n', '\n> ')}${note}`;
    // General Claude gets its instructions as the system prompt, replacing Claude Code's long coding one.
    const prompt = !general ? buildPrompt({ text, workspace: this.workspace, activeFile, agent: name, isFollowUp: !!sessionID, language }) + note
      : agent.cli === 'claude' ? said : `${generalPrompt(language)}\n\n${said}`;
    // General-workspace agents keep their web-only tools whatever the mode.
    const options = general ? { mode: 'auto', effort, model, fast: true } : { mode, effort, model };
    const args = agent.cli === 'claude'
      ? claudeArgs(prompt, sessionID, [...(general ? [...GENERAL_CLAUDE_ARGS, '--system-prompt', generalPrompt(language)] : []), ...(agent.args ?? [])], options)
      : codexArgs(prompt, sessionID, agent.args, cwd, options);
    const state = {};
    const parse = agent.cli === 'claude' ? (line) => parseClaude(line, state) : parseCodex;
    const command = agent.command ?? agent.cli;

    // detached: own process group, so cancelling also stops the tools the agent started.
    const child = spawn(command, args, {
      cwd,
      env: { ...process.env, ...agent.env },
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: true,
    });
    const run = { id, child, stderr: '' };
    this.current = run;

    // Ends the run exactly once, whichever of completion, failure, timeout or cancel comes first.
    run.finish = (status, error) => {
      if (this.current !== run) return;
      this.current = null;
      clearTimeout(run.timer);
      if (child.exitCode === null) { try { process.kill(-child.pid, 'SIGTERM'); } catch {} }
      this.emit({ finished: { id, status, ...(error ? { error } : {}) } });
    };
    run.timer = setTimeout(() => run.finish('Failed', `Timed out after ${TIMEOUT_MS / 60000} minutes.`), TIMEOUT_MS);

    readline.createInterface({ input: child.stdout }).on('line', (line) => {
      for (const event of parse(line)) {
        if (event.session) { this.sessions.set(name, event.session._0); continue; }
        if (event.failed) return run.finish('Failed', event.failed._0);
        this.emit({ event: { id, event } });
        if (event.completed) return run.finish('Completed');
      }
    });
    child.stderr.on('data', (data) => { run.stderr = (run.stderr + data).slice(-4000); });
    child.on('error', (err) => run.finish('Failed', err.code === 'ENOENT'
      ? `\`${command}\` CLI not found. Install it and make sure it is on the bridge's PATH.`
      : err.message));
    child.on('close', (code) => {
      const tail = run.stderr.trim().split('\n').slice(-3).join('\n');
      run.finish(code === 0 ? 'Completed' : 'Failed', code === 0 ? undefined : `Agent exited with code ${code}${tail ? ': ' + tail : '.'}`);
    });
  }

  /// Local model via Ollama's chat API, streaming the answer as it is written. Keeps the chat for follow-ups.
  chat({ id, text, agent, language }) {
    const controller = new AbortController();
    const run = { id };
    this.current = run;
    run.finish = (status, error) => {
      if (this.current !== run) return;
      this.current = null;
      clearTimeout(run.timer);
      if (status !== 'Completed') controller.abort(); // stop generating on cancel/timeout
      this.emit({ finished: { id, status, ...(error ? { error } : {}) } });
    };
    run.timer = setTimeout(() => run.finish('Failed', `Timed out after ${TIMEOUT_MS / 60000} minutes.`), TIMEOUT_MS);

    const system = agent.workspace === GENERAL ? generalPrompt(language) : chatSystemPrompt(this.workspace, language);
    const history = this.chats.get(agent.name) ?? [{ role: 'system', content: system }];
    const messages = [...history, { role: 'user', content: text }];
    this.emit({ event: { id, event: ev('status', 'Analyzing') } });

    (async () => {
      const host = agent.host ?? 'http://localhost:11434';
      const response = await fetch(`${host}/api/chat`, {
        method: 'POST',
        signal: controller.signal,
        // think: false — qwen3 & co. otherwise spend most of the time on hidden reasoning.
        body: JSON.stringify({ model: agent.model, messages, stream: true, think: false, ...(agent.options ? { options: agent.options } : {}) }),
      });
      if (!response.ok) throw new Error(`Ollama: ${response.status} ${(await response.text()).slice(0, 200)}`);
      let answer = '';
      let shown = 0;
      const body = Readable.fromWeb(response.body);
      body.on('error', () => {}); // an abort also errors the stream; the loop below reports it
      for await (const line of readline.createInterface({ input: body })) {
        if (!line.trim()) continue;
        const chunk = JSON.parse(line);
        if (chunk.error) throw new Error(`Ollama: ${chunk.error}`);
        answer += chunk.message?.content ?? '';
        // Stream to the app a few times a second rather than per token.
        if (answer.length - shown > 40 || chunk.done) {
          shown = answer.length;
          this.emit({ event: { id, event: ev('message', answer.trim()) } });
        }
        if (chunk.done) break;
      }
      this.chats.set(agent.name, [...messages, { role: 'assistant', content: answer }]);
      this.emit({ event: { id, event: ev('completed', answer.trim()) } });
      run.finish('Completed');
    })().catch((err) => {
      if (err.name === 'AbortError') return; // cancelled or timed out: already finished
      run.finish('Failed', err.cause?.code === 'ECONNREFUSED' ? 'Ollama is not running. Open the Ollama app.' : err.message);
    });
  }

  cancel() { this.current?.finish('Cancelled'); }

  reset() {
    this.cancel();
    this.sessions.clear();
    this.chats.clear();
  }
}

// MARK: Speech

/// Keeps one `swift tts-server.swift` process around (see that file for why it runs interpreted)
/// and turns text into AAC audio with the Mac's neural voices.
export class SpeechServer {
  constructor(script = path.join(path.dirname(new URL(import.meta.url).pathname), 'tts-server.swift')) {
    Object.assign(this, { script, child: null, nextID: 1, pending: new Map(), voices: null });
  }

  get available() { return process.platform === 'darwin' && fs.existsSync(this.script); }

  start() {
    if (this.child || !this.available) return;
    const child = spawn('swift', [this.script], { stdio: ['pipe', 'pipe', 'ignore'] });
    this.child = child;
    child.stdin.on('error', () => {});
    child.on('error', () => {}); // no Swift toolchain: speak() rejects and the app falls back to its own voice
    readline.createInterface({ input: child.stdout }).on('line', (line) => {
      let reply;
      try { reply = JSON.parse(line); } catch { return; }
      if (reply.ready) { this.voices = reply.voices; return; }
      const job = this.pending.get(reply.id);
      if (!job) return;
      this.pending.delete(reply.id);
      clearTimeout(job.timer);
      if (reply.error) return job.reject(new Error(reply.error));
      fs.readFile(job.out, (err, data) => {
        fs.rm(job.out, { force: true }, () => {});
        err ? job.reject(err) : job.resolve(data);
      });
    });
    child.on('exit', () => {
      if (this.child === child) this.child = null;
      for (const job of this.pending.values()) job.reject(new Error('Speech server stopped'));
      this.pending.clear();
    });
  }

  speak(text) {
    this.start();
    if (!this.child) return Promise.reject(new Error('Speech is not available on this machine'));
    const id = this.nextID++;
    const out = path.join(os.tmpdir(), `voxagent-tts-${process.pid}-${id}.m4a`);
    return new Promise((resolve, reject) => {
      // The first request also waits for the interpreter to start (~2 s).
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error('Speech timed out')); }, 20_000);
      this.pending.set(id, { resolve, reject, out, timer });
      this.child.stdin.write(JSON.stringify({ id, text, out }) + '\n');
    });
  }

  stop() { this.child?.kill(); }
}

// MARK: Server

export function loadAgents(file) {
  if (!file) return DEFAULT_AGENTS;
  const agents = JSON.parse(fs.readFileSync(file, 'utf8'));
  for (const a of agents) {
    if (!a.name || !['claude', 'codex', 'ollama'].includes(a.cli) || (a.cli === 'ollama' && !a.model)
      || ![undefined, GENERAL].includes(a.workspace)) {
      throw new Error(`Bad agent in ${file}: ${JSON.stringify(a)} (needs "name" and "cli": "claude" | "codex" | "ollama"; ollama also needs "model"; "workspace" may only be "general")`);
    }
  }
  if (!agents.some((a) => a.workspace === GENERAL)) {
    const taken = agents.some((a) => a.name === GENERAL_AGENT.name);
    agents.push(taken ? { ...GENERAL_AGENT, name: 'Claude (General)' } : GENERAL_AGENT);
  }
  return agents;
}

/// Bonjour so the app finds the bridge on the local network without typing an address.
function advertise(name, port) {
  const [cmd, args] = process.platform === 'darwin'
    ? ['dns-sd', ['-R', name, SERVICE_TYPE, 'local', String(port)]]
    : ['avahi-publish', ['-s', name, SERVICE_TYPE, String(port)]];
  const child = spawn(cmd, args, { stdio: 'ignore' });
  child.on('error', () => {}); // optional: over Tailscale etc. the app uses an explicit address
  process.on('exit', () => child.kill());
}

function main() {
  const argv = process.argv.slice(2);
  const flag = (name) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
  if (argv.includes('-h') || argv.includes('--help')) {
    console.log('Usage: node voxcode-bridge.mjs [--workspace <dir>] [--port <n>] [--host <addr>] [--agents <file>] [--new-code] [--managed]');
    return;
  }

  const workspace = path.resolve((flag('--workspace') ?? process.cwd()).replace(/^~(?=$|\/)/, os.homedir()));
  if (!fs.existsSync(workspace) || !fs.statSync(workspace).isDirectory()) {
    console.error(`Workspace not found: ${workspace}`);
    process.exit(1);
  }
  const port = Number(flag('--port') ?? DEFAULT_PORT);
  const host = flag('--host');
  const managed = argv.includes('--managed');

  // The pairing code is the shared secret; keep it private to this user and reuse it across runs.
  const home = process.env.VOXCODE_HOME ?? path.join(os.homedir(), '.voxcode');
  fs.mkdirSync(home, { recursive: true, mode: 0o700 });
  const codeFile = path.join(home, 'pairing-code');
  let code = fs.existsSync(codeFile) ? fs.readFileSync(codeFile, 'utf8').trim() : '';
  if (!code || argv.includes('--new-code')) {
    code = generateCode();
    fs.writeFileSync(codeFile, code, { mode: 0o600 });
  }

  const agentsFile = flag('--agents') ?? (fs.existsSync(path.join(home, 'agents.json')) ? path.join(home, 'agents.json') : undefined);
  const agents = loadAgents(agentsFile);

  const clients = new Set();
  const log = (msg) => console.log(`[${new Date().toLocaleTimeString()}] ${msg}`);
  const emit = (message) => {
    const line = JSON.stringify(message) + '\n';
    for (const socket of clients) socket.write(line);
    if (message.finished) log(`■ ${message.finished.status}${message.finished.error ? ': ' + message.finished.error : ''}`);
  };
  const session = new AgentSession(workspace, agents, emit, path.join(home, 'general'));
  const refreshOllama = async () => {
    const ollama = agents.find((a) => a.cli === 'ollama');
    if (ollama) session.ollama = await ollamaModels(ollama.host);
  };
  refreshOllama();
  const workspaces = workspacesFor(workspace, agents);
  const speech = new SpeechServer();
  speech.start(); // warm up so the first answer isn't delayed by the interpreter starting
  const psk = pskFor(code);

  const server = tls.createServer({
    ciphers: 'PSK-AES128-GCM-SHA256', // TLS_PSK_WITH_AES_128_GCM_SHA256, as the app offers
    minVersion: 'TLSv1.2',
    maxVersion: 'TLSv1.2',
    pskCallback: (_socket, identity) => (identity === 'VoxCode' ? psk : null),
  }, (socket) => {
    socket.setKeepAlive(true, 10_000);
    clients.add(socket);
    log(`App connected: ${socket.remoteAddress}`);
    const send = (message) => socket.write(JSON.stringify(message) + '\n');
    send({ hello: { workspace: path.basename(workspace), agents: agents.map((a) => a.name), speech: speech.available, workspaces, models: session.models() } });
    refreshOllama(); // a newly pulled model shows up on the next connection
    readline.createInterface({ input: socket }).on('line', (line) => {
      let message;
      try { message = JSON.parse(line); } catch { return; }
      if (message.run) {
        const { mode, effort } = sanitizeOptions(message.run);
        log(`▶︎ ${message.run.agent} [${mode}${effort ? ', ' + effort : ''}]: ${message.run.text}`);
        session.run(message.run);
      }
      else if (message.cancel) session.cancel();
      else if (message.reset) session.reset();
      else if (message.speak) {
        const { id, text } = message.speak;
        speech.speak(text).then(
          (data) => send({ audio: { id, data: data.toString('base64') } }),
          (err) => send({ audio: { id, error: err.message } }),
        );
      }
    });
    socket.on('close', () => { clients.delete(socket); log(`App disconnected: ${socket.remoteAddress}`); });
    socket.on('error', () => {});
  });
  // A wrong pairing code shows up here as a TLS handshake failure.
  server.on('tlsClientError', (err, socket) => log(`Rejected ${socket.remoteAddress ?? 'connection'}: ${err.code ?? err.message}`));
  server.on('error', (err) => { console.error(`Can't listen on port ${port}: ${err.message}`); process.exit(1); });

  server.listen(port, host, () => {
    const name = os.hostname().replace(/\.local$/, '');
    if (!managed) advertise(name, port);
    // Only show the secret on an interactive terminal, never in a service log file.
    const shownCode = process.stdout.isTTY ? code : `(in ${codeFile})`;
    console.log(`Vox Agent bridge
  Host:         ${name}
  Workspace:    ${workspace}
  Port:         ${port}${host ? ` on ${host}` : ''}
  Agents:       ${agents.map((a) => a.name).join(', ')}${agentsFile ? ` (${agentsFile})` : ''}
  Pairing code: ${shownCode}

Enter the pairing code in the Vox Agent app. Same Wi-Fi: found automatically; otherwise type this
machine's address (e.g. its Tailscale IP). Run with --new-code to revoke the code. Ctrl-C to stop.`);
  });

  // The user didn't cancel anything: tell the app why its run ended, then exit.
  const stop = () => { session.current?.finish('Failed', 'The bridge was stopped.'); speech.stop(); process.exit(0); };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
  if (managed) { process.stdin.on('end', stop); process.stdin.resume(); }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) main();

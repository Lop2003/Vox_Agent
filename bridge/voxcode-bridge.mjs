#!/usr/bin/env node
// Vox Agent bridge: lets the Vox Agent app run coding-agent CLIs in one workspace on this machine.
// Runs on macOS and Linux with Node 18+, no dependencies.
//
// Usage: node voxcode-bridge.mjs [--workspace <dir>] [--port <n>] [--agents <file>] [--new-code]
//
// Agents come from --agents, else $VOXCODE_HOME/agents.json (default ~/.voxcode), else Claude Code + Codex.
// Each agent drives the `claude` or `codex` CLI; Codex can also reach Ollama, OpenRouter and other
// providers through `-c`/`-m` args. See agents.example.json.
//
// Wire format: newline-delimited JSON over TLS 1.2 with a pre-shared key derived from the pairing code.
// It is Swift's synthesized Codable form and must match Sources/VoxCodeCore/Remote.swift:
//   app → bridge  {"run":{"id","text","agent","activeFile"?}} | {"cancel":{}} | {"reset":{}}
//   bridge → app  {"hello":{"workspace","agents"}}
//                 {"event":{"id","event":{"status"|"activity"|"message"|"completed":{"_0":…}}}}
//                 {"finished":{"id","status","error"?}}

import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import tls from 'node:tls';
import { pathToFileURL } from 'node:url';

export const DEFAULT_PORT = 47800;
const SERVICE_TYPE = '_voxcode._tcp';
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O/1/I
// ponytail: fixed 15 min agent timeout; make it a flag if long refactors hit it.
const TIMEOUT_MS = 15 * 60 * 1000;
const DEFAULT_AGENTS = [{ name: 'Claude Code', cli: 'claude' }, { name: 'Codex', cli: 'codex' }];

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
export function buildPrompt({ text, workspace, activeFile, agent, isFollowUp }) {
  return `# Vox Agent request${isFollowUp ? ' (follow-up in the same conversation)' : ''}

## User request
Spoken by the user and converted with speech-to-text, so it may be informal, incomplete, or contain recognition errors:
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
Reply in the language of the user request. Use exactly these Markdown headings, in English:
${RESPONSE_SECTIONS.map((s) => '## ' + s).join('\n')}
Keep Summary to 1–3 short sentences because it is read aloud. For a plain question, answer under Summary and write "None" in the other sections.`;
}

// MARK: Agent CLIs (keep in sync with ClaudeCodeAgent.swift / CodexAgent.swift)

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

export function claudeArgs(prompt, sessionID, extra = []) {
  return ['-p', prompt, '--output-format', 'stream-json', '--verbose', '--permission-mode', 'auto',
    ...(sessionID ? ['--resume', sessionID] : []), ...extra];
}

export function parseClaude(line) {
  let o;
  try { o = JSON.parse(line); } catch { return []; }
  switch (o.type) {
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
export function codexArgs(prompt, sessionID, extra = [], workspace) {
  return sessionID
    ? ['exec', 'resume', '--json', '--skip-git-repo-check', '-c', 'sandbox_mode="workspace-write"', ...extra, sessionID, prompt]
    : ['exec', '--json', '--skip-git-repo-check', '-s', 'workspace-write', ...extra, '-C', workspace, prompt];
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
  constructor(workspace, agents, emit) {
    Object.assign(this, { workspace, agents, emit, sessions: new Map(), current: null });
  }

  run({ id, text, agent: name, activeFile }) {
    if (this.current) return this.emit({ finished: { id, status: 'Failed', error: 'The agent is already running.' } });
    const agent = this.agents.find((a) => a.name === name);
    if (!agent) return this.emit({ finished: { id, status: 'Failed', error: `Unknown agent: ${name}` } });

    const sessionID = this.sessions.get(name);
    const prompt = buildPrompt({ text, workspace: this.workspace, activeFile, agent: name, isFollowUp: !!sessionID });
    const args = agent.cli === 'claude'
      ? claudeArgs(prompt, sessionID, agent.args)
      : codexArgs(prompt, sessionID, agent.args, this.workspace);
    const parse = agent.cli === 'claude' ? parseClaude : parseCodex;
    const command = agent.command ?? agent.cli;

    // detached: own process group, so cancelling also stops the tools the agent started.
    const child = spawn(command, args, {
      cwd: this.workspace,
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

  cancel() { this.current?.finish('Cancelled'); }

  reset() {
    this.cancel();
    this.sessions.clear();
  }
}

// MARK: Server

function loadAgents(file) {
  if (!file) return DEFAULT_AGENTS;
  const agents = JSON.parse(fs.readFileSync(file, 'utf8'));
  for (const a of agents) {
    if (!a.name || !['claude', 'codex'].includes(a.cli)) throw new Error(`Bad agent in ${file}: ${JSON.stringify(a)} (needs "name" and "cli": "claude" | "codex")`);
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
    console.log('Usage: node voxcode-bridge.mjs [--workspace <dir>] [--port <n>] [--agents <file>] [--new-code]');
    return;
  }

  const workspace = path.resolve((flag('--workspace') ?? process.cwd()).replace(/^~(?=$|\/)/, os.homedir()));
  if (!fs.existsSync(workspace) || !fs.statSync(workspace).isDirectory()) {
    console.error(`Workspace not found: ${workspace}`);
    process.exit(1);
  }
  const port = Number(flag('--port') ?? DEFAULT_PORT);

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
  const session = new AgentSession(workspace, agents, emit);
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
    socket.write(JSON.stringify({ hello: { workspace: path.basename(workspace), agents: agents.map((a) => a.name) } }) + '\n');
    readline.createInterface({ input: socket }).on('line', (line) => {
      let message;
      try { message = JSON.parse(line); } catch { return; }
      if (message.run) { log(`▶︎ ${message.run.agent}: ${message.run.text}`); session.run(message.run); }
      else if (message.cancel) session.cancel();
      else if (message.reset) session.reset();
    });
    socket.on('close', () => { clients.delete(socket); log(`App disconnected: ${socket.remoteAddress}`); });
    socket.on('error', () => {});
  });
  // A wrong pairing code shows up here as a TLS handshake failure.
  server.on('tlsClientError', (err, socket) => log(`Rejected ${socket.remoteAddress ?? 'connection'}: ${err.code ?? err.message}`));
  server.on('error', (err) => { console.error(`Can't listen on port ${port}: ${err.message}`); process.exit(1); });

  server.listen(port, () => {
    const name = os.hostname().replace(/\.local$/, '');
    advertise(name, port);
    console.log(`Vox Agent bridge
  Host:         ${name}
  Workspace:    ${workspace}
  Port:         ${port}
  Agents:       ${agents.map((a) => a.name).join(', ')}${agentsFile ? ` (${agentsFile})` : ''}
  Pairing code: ${code}

Enter the pairing code in the Vox Agent app. Same Wi-Fi: found automatically; otherwise type this
machine's address (e.g. its Tailscale IP). Run with --new-code to revoke the code. Ctrl-C to stop.`);
  });

  const stop = () => { session.cancel(); process.exit(0); };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) main();

# Vox Agent

Voice interface for AI coding agents (Claude Code / Codex), on iPhone and Mac.

Mic → Speech-to-Text (Thai / English) → structured prompt → agent CLI in your workspace → response → optional Text-to-Speech.

```
iPhone app (mic, STT, TTS, UI) ──TLS-PSK──▶ bridge service (Node) ──▶ claude / codex CLI in <workspace>
Mac app    (mic, STT, TTS, UI) ──localhost──▶ bridge it starts itself ──▶ claude / codex CLI in <chosen folder>
```

Both apps run agents through the same bridge ([bridge/voxcode-bridge.mjs](bridge/voxcode-bridge.mjs), Node 18+, no dependencies), so there is one implementation of prompts, CLI invocation and output parsing.

## iPhone

1. On the Mac, install the bridge as a login service (starts at login, restarts if it dies):
   ```sh
   scripts/bridge-service.sh install ~/path/to/project   # prints the pairing code
   scripts/bridge-service.sh status | code | logs | uninstall
   ```
   Or run it in a terminal: `node bridge/voxcode-bridge.mjs --workspace ~/path/to/project`.
   The code is saved in `~/.voxcode/pairing-code` (`--new-code` revokes it) and never written to the log.
2. Open `VoxCodeMobile/VoxCodeMobile.xcodeproj` in Xcode, pick your Team under Signing, and run on your iPhone.
3. Enter the pairing code. On the same Wi-Fi the bridge is found automatically; otherwise type its address (e.g. a Tailscale IP).
4. Tap the mic, speak, pause: it sends after 2 s of silence. Or tap 〰️ for a hands-free call.

The app reconnects on its own when the bridge restarts or the network drops; only a wrong pairing code needs you.

**Thai speech in the iOS Simulator:** Apple's on-device Thai model is a Cryptex the Simulator can't mount, so Thai recognition breaks once it downloads ("Failed to initialize recognizer"). Run `scripts/sim-thai-stt.sh` to remove it and keep it out (recognition then uses Apple's servers); `--undo` reverts. Real iPhones don't need this.

The link is TLS 1.2 with a pre-shared key derived from the pairing code: encrypted, and only phones with the code can connect. Anyone with the code can run agents in the workspace, so keep it private.

### Agents and models

By default the bridge offers Claude Code and Codex. Put a list in `~/.voxcode/agents.json` (or pass `--agents <file>`) to add others; see [bridge/agents.example.json](bridge/agents.example.json):
- `"cli": "claude"` with extra args, e.g. `["--model", "haiku"]` for a cheaper Claude.
- `"cli": "codex"` pointed at an OpenAI-compatible provider such as OpenRouter. Use only `-c`/`-m` args so follow-ups (`codex exec resume`) keep working.
- `"cli": "ollama", "model": "qwen3:8b"` chats with a local model directly (streams, answers in the app's language). It can't read or edit files: small models driven through Codex ignore the reply language and invent results, so this mode tells the user to switch to Claude Code for real code work.

**Workspaces.** The app switches between two workspaces, each with its own agents and chat history: the project folder (the agents above) and **General**, for everyday questions that have nothing to do with the code. Mark an agent `"workspace": "general"` to put it there. If none is marked, the bridge adds a General "Claude" that runs in an empty folder of its own (`general/` in the bridge home, `~/.voxcode` by default) with web search and fetch as its only tools (no MCP servers), so it can't touch your files or run commands.

Answers come back in the app's speech language (Thai by default); the bridge states it at the start and end of every prompt.

## Mac app

```sh
./scripts/build-app.sh   # builds "build/Vox Agent.app" (a bundle is required for mic/speech permissions)
open "build/Vox Agent.app"
```

Pick a workspace folder in the toolbar, choose the agent, press the mic (⌘M). Esc cancels.
The app starts a private bridge for that folder (localhost only, needs Node.js) and stops it when you quit;
it reuses `~/.voxcode/agents.json`. Its log is in `~/Library/Application Support/Vox Agent/bridge/`.

## Tests

```sh
swift test                               # unit, TTS, and app ⇄ bridge tests (fake agents: no API usage)
node --test bridge/*.test.mjs            # bridge unit tests
VOXCODE_INTEGRATION=claude swift test    # also real CLI round trips (or =codex)
```

Requires macOS 14+ / iOS 17+, Node.js 18+, and `claude` and/or `codex` installed and logged in on the Mac.

## Layout

- `Sources/VoxCodeCore`: `AgentRunner`, `BridgeClient` (TLS-PSK client with auto-reconnect), `LocalBridge` (Mac app's bridge process), wire format, `SpeechText`.
- `Sources/VoxUI`: shared by both apps: `AppModel` (voice → agent → speech loop), `VoiceInputManager`, `SpeechToTextService`, `TextToSpeechService`, views.
- `Sources/VoxCode`: macOS app. `bridge/`: Node bridge. `VoxCodeMobile/`: iOS app.

## Agent permissions

- Claude Code runs with `--permission-mode auto` (a classifier approves safe actions headlessly).
- Codex runs with `-s workspace-write` (edits only inside the workspace, no network).
- Both get the same constraints in the prompt: no secrets, no deletes or destructive ops without confirmation, no commit/push unless asked.

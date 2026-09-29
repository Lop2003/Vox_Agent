# Vox Agent

Voice interface for AI coding agents (Claude Code / Codex), on iPhone and Mac.

Mic → Speech-to-Text (Thai / English) → structured prompt → agent CLI in your workspace → response → optional Text-to-Speech.

```
iPhone app (mic, STT, TTS, UI) ──TLS-PSK──▶ bridge (Node, on a Mac or Linux box) ──▶ claude / codex CLI in <workspace>
Mac app    (mic, STT, TTS, UI) ───────────────────────────────────────────────────▶ claude / codex CLI in <workspace>
```

iOS can't run the agent CLIs, so the phone talks to a small bridge ([bridge/voxcode-bridge.mjs](bridge/voxcode-bridge.mjs), Node 18+, no dependencies) on a machine that has the repo and the CLIs.

## iPhone

1. On the Mac or server: `node bridge/voxcode-bridge.mjs --workspace ~/path/to/project`
   It prints a pairing code (saved in `~/.voxcode/pairing-code`; `--new-code` revokes it).
2. Open `VoxCodeMobile/VoxCodeMobile.xcodeproj` in Xcode, pick your Team under Signing, and run on your iPhone.
3. Enter the pairing code. On the same Wi-Fi the bridge is found automatically; otherwise type its address (e.g. a Tailscale IP).
4. Tap the mic, speak, pause: it sends after 2 s of silence.

**Thai speech in the iOS Simulator:** Apple's on-device Thai model is a Cryptex the Simulator can't mount, so Thai recognition breaks once it downloads ("Failed to initialize recognizer"). Run `scripts/sim-thai-stt.sh` to remove it and keep it out (recognition then uses Apple's servers); `--undo` reverts. Real iPhones don't need this.

The link is TLS 1.2 with a pre-shared key derived from the pairing code: encrypted, and only phones with the code can connect. Anyone with the code can run agents in the workspace, so keep it private.

### Agents and models

By default the bridge offers Claude Code and Codex. Put a list in `~/.voxcode/agents.json` (or pass `--agents <file>`) to add cheaper models: extra `claude` args (e.g. `--model haiku`), or Codex pointed at any OpenAI-compatible provider such as OpenRouter or Ollama. See [bridge/agents.example.json](bridge/agents.example.json). Codex agents must use only `-c`/`-m` args so follow-ups (`codex exec resume`) keep working.

## Mac app

```sh
./scripts/build-app.sh   # builds "build/Vox Agent.app" (a bundle is required for mic/speech permissions)
open "build/Vox Agent.app"
```

Pick a workspace folder in the toolbar, choose the agent, press the mic (⌘M). Esc cancels.

## Tests

```sh
swift test                               # unit tests + app ⇄ Node bridge tests (fake agents)
node --test bridge/*.test.mjs            # bridge unit tests
VOXCODE_INTEGRATION=claude swift test    # also real CLI round trips (or =codex)
```

Requires macOS 14+ / iOS 17+, and `claude` and/or `codex` installed and logged in on the Mac.

## Layout

- `Sources/VoxCodeCore`: agent abstraction (`CodingAgent`, `ClaudeCodeAgent`, `CodexAgent`, `AgentRouter`), `AgentRunner` with `AgentSession` (local) and `BridgeClient` (remote), `PromptBuilder`, `SpeechText`.
- `Sources/VoxUI`: shared by both apps: `AppModel` (voice → agent → speech loop), `VoiceInputManager`, `SpeechToTextService`, `TextToSpeechService`, views.
- `Sources/VoxCode`: macOS app. `bridge/`: Node bridge. `VoxCodeMobile/`: iOS app.

## Agent permissions

- Claude Code runs with `--permission-mode auto` (a classifier approves safe actions headlessly).
- Codex runs with `-s workspace-write` (edits only inside the workspace, no network).
- Both get the same constraints in the prompt: no secrets, no deletes or destructive ops without confirmation, no commit/push unless asked.

# Vox Agent

Voice interface for AI coding agents (Claude Code / Codex), on iPhone. (A macOS app is kept in the repo too; the iPhone app is the product.)

Mic → Speech-to-Text (Thai / English) → structured prompt → agent CLI in your workspace → response → optional Text-to-Speech.

```
iPhone app (mic, STT, TTS, UI) ──TLS-PSK──▶ bridge service (Node) ──▶ claude / codex CLI in <workspace>
Mac app    (mic, STT, TTS, UI) ──localhost──▶ bridge it starts itself ──▶ claude / codex CLI in <chosen folder>
```

Both apps run agents through the same bridge ([bridge/voxcode-bridge.mjs](bridge/voxcode-bridge.mjs), Node 18+, no dependencies), so there is one implementation of prompts, CLI invocation and output parsing.

## Setup (free Apple ID, no paid developer account)

**On the Mac (once)**
1. Install Node.js 18+ and Claude Code (`claude`, logged in) and/or Codex (`codex login`). Xcode gives the bridge the natural Thai voice.
2. Start the bridge as a login service (starts at login, restarts if it dies, keeps the Mac awake while it runs). Either:
   - **Mac app** (no Terminal): `./scripts/build-app.sh && open "build/Vox Agent.app"`, toolbar **Pair iPhone** › **Start Bridge…** › pick the project folder. It shows a QR code to scan with the iPhone Camera.
   - **Terminal**:
     ```sh
     scripts/bridge-service.sh install ~/path/to/project   # prints the pairing code
     scripts/bridge-service.sh status | code | logs | uninstall
     ```
   The code is saved in `~/.voxcode/pairing-code` (*New code* / `--new-code` revokes it) and never written to the log.

**On the iPhone (once, with a cable)**
1. iPhone: Settings › Privacy & Security › **Developer Mode** on (restarts the phone).
2. Xcode: Settings › Accounts › add your Apple ID. Open `VoxCode.xcworkspace`, target **VoxCodeMobile** › Signing & Capabilities › Team = your Personal Team, Bundle Identifier `com.voxagent.ai` (or any unique one).
3. Choose the iPhone as the run destination and press ▶︎. First time: iPhone Settings › General › VPN & Device Management › trust your Apple ID.
4. In the app, allow Microphone, Speech Recognition and Local Network, then pair: scan the Mac app's QR code with the iPhone **Camera** and tap *Open in Vox Agent* (or type the code).

**Every 7 days** a free-Apple-ID app expires: press ▶︎ in Xcode again (cable, or Window › Devices and Simulators › *Connect via network* to do it over Wi-Fi). SideStore can refresh it automatically.

**Away from home Wi-Fi:** install Tailscale (free) on the Mac and the iPhone with the same account, and put the Mac's Tailscale address (100.x.x.x) in *Mac address* when pairing. The app looks for the bridge on the local Wi-Fi first and uses that address only when it isn't there, so one setting works everywhere.

**If answers stop:** `claude` may have logged out ("OAuth session expired" in the app): run `claude` in Terminal to log in again. The Mac must be on (closing the lid sleeps it).

## Using it

Tap the mic, speak, pause: it sends when you stop talking. Or tap 〰️ for a hands-free call in the chat: a waveform bar shows listening/working/speaking, with mute, stop and hang-up buttons; say "หยุด" to cut in.

**Permissions** (⋯ › Permissions), for the project workspace:

| Mode | Asks before running | Claude Code | Codex |
|---|---|---|---|
| Manual | every request that would change files | edits files, no shell commands (`acceptEdits`) | `workspace-write` sandbox |
| Auto (default) | spoken change requests only (speech can mishear, e.g. "markdown" → "มาร์คดาว") | its safety classifier (`auto`) | `workspace-write` sandbox |
| Full access | never — shown in orange under the title | `--dangerously-skip-permissions` | `danger-full-access` |

Answer a confirmation by tapping *Run*, or in a call by saying "ใช่" / "ไม่".

**Effort** (⋯ › Effort): Default, Low, Medium, High, Max — Claude `--effort`, Codex `model_reasoning_effort` (Max = `xhigh`).

The app reconnects on its own when the bridge restarts or the network drops; only a wrong pairing code needs you.

**Thai speech in the iOS Simulator:** Apple's on-device Thai model is a Cryptex the Simulator can't mount, so Thai recognition breaks once it downloads ("Failed to initialize recognizer"). Run `scripts/sim-thai-stt.sh` to remove it and keep it out (recognition then uses Apple's servers); `--undo` reverts. Real iPhones don't need this.

The link is TLS 1.2 with a pre-shared key derived from the pairing code: encrypted, and only phones with the code can connect. Anyone with the code can run agents in the workspace, so keep it private.

### Agents and models

By default the bridge offers Claude Code and Codex (pick one from the title). Put a list in `~/.voxcode/agents.json` (or pass `--agents <file>`) to add others; see [bridge/agents.example.json](bridge/agents.example.json):
- `"cli": "claude"` with extra args, e.g. `["--model", "haiku"]` for a cheaper Claude.
- `"cli": "codex"` pointed at an OpenAI-compatible provider such as OpenRouter. Use only `-c`/`-m` args so follow-ups (`codex exec resume`) keep working.
- `"cli": "ollama", "model": "qwen3:8b"` chats with a local model directly (streams, answers in the app's language). It can't read or edit files: small models driven through Codex ignore the reply language and invent results, so this mode tells the user to switch to Claude Code for real code work.

**Workspaces.** The app switches between two workspaces, each with its own agents and chat history: the project folder (the agents above) and **General**, for everyday questions that have nothing to do with the code. Mark an agent `"workspace": "general"` to put it there. If none is marked, the bridge adds a General "Claude" that runs in an empty folder of its own (`general/` in the bridge home, `~/.voxcode` by default) with web search and fetch as its only tools (no MCP servers), so it can't touch your files or run commands.

Answers come back in the app's speech language (Thai by default); the bridge states it at the start and end of every prompt.

## Mac app (kept for experiments)

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

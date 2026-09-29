Build the entire **VoxCode** macOS application in this repository.

VoxCode is a native macOS AI coding assistant controlled by voice.

## Product Flow

Implement this complete flow:

User presses microphone
→ record microphone audio
→ Speech-to-Text with Thai language support
→ show the transcription
→ send the transcription to a coding agent
→ support both Claude Code and Codex
→ receive the agent response
→ display the response
→ optionally read the response aloud using Text-to-Speech.

## Technology

* macOS
* Swift
* SwiftUI
* AVAudioEngine for microphone/audio capture
* Apple Speech APIs or an appropriate Speech-to-Text implementation
* AVSpeechSynthesizer for Text-to-Speech
* Claude Code CLI as one agent backend
* Codex CLI as another agent backend

Prefer native Apple frameworks and a simple architecture. Avoid unnecessary third-party dependencies.

## UI

Create a clean native macOS interface named **VoxCode**.

The main screen should include:

* VoxCode title
* Microphone button
* Recording/listening state
* Transcribed user message
* Agent selector: Claude Code / Codex
* Agent execution status
* Agent response
* Stop/Cancel button
* Text-to-Speech playback button

Example flow:

User:
"ช่วยตรวจสอบ login rate limit ให้หน่อย"

UI:

Listening...
↓
Transcribing...
↓
Running Claude Code...
↓
Analyzing...
↓
Editing...
↓
Testing...
↓
Completed

Then display the agent's response.

## Agent Integration

Create a clean abstraction so Claude Code and Codex are interchangeable.

For example:

Agent
├── ClaudeCodeAgent
└── CodexAgent

The UI must not directly execute CLI commands.

Create an agent service/router responsible for launching the selected CLI and collecting its output.

The application should execute the agent inside the currently selected workspace/repository.

Do not hardcode a specific repository path.

Allow the workspace to be selected or configured.

## Agent Prompt

When sending the user's transcription to the coding agent, instruct the agent to:

* Inspect the repository before making changes.
* Understand the existing architecture.
* Identify the root cause.
* Make minimal focused changes.
* Follow existing coding conventions.
* Run relevant tests/builds.
* Review the final diff.
* Do not modify unrelated files.
* Do not expose secrets.
* Do not commit or push unless explicitly requested.

Do not request or expose chain-of-thought. Only return useful summaries, actions, test results, and errors.

## Voice Interaction

The user should be able to have a conversational workflow:

User speaks
→ STT
→ Agent
→ Agent response
→ TTS
→ User speaks again

Support multiple turns in the same session.

Handle:

* microphone permission denied
* microphone unavailable
* STT failure
* empty transcription
* agent CLI unavailable
* agent execution failure
* timeout
* user cancellation
* TTS failure

The UI must never freeze while recording, transcribing, running the agent, or speaking.

Use Swift concurrency appropriately.

## Architecture

Keep the implementation modular:

* Views
* Audio/Recording service
* Speech-to-Text service
* Text-to-Speech service
* Agent abstraction
* Claude Code adapter
* Codex adapter
* Prompt builder
* Workspace manager
* Application state
* Error handling

Use protocols where they make testing easier.

## Important Implementation Rules

Before writing code:

1. Inspect the entire repository.
2. Understand the current project structure.
3. Check the existing Swift/Xcode configuration.
4. Reuse existing code when appropriate.
5. Do not blindly overwrite existing files.

Then implement the application.

After implementation:

1. Build the macOS application.
2. Run all relevant tests.
3. Fix compilation errors.
4. Fix obvious runtime issues.
5. Review the git diff.
6. Ensure microphone permissions are configured correctly.
7. Ensure the application can launch successfully.
8. Report exactly what was implemented and what could not be tested.

Do not stop at creating a plan. **Actually implement the application in the repository.**

Do not commit or push changes.

Start now by inspecting the repository and then implement VoxCode end-to-end.

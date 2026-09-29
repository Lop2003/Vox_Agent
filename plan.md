Build a macOS voice-controlled AI coding agent application called **VoxCode** using **SwiftUI**.

## Goal

VoxCode allows the user to speak naturally to a coding agent from a macOS application. The complete flow is:

Microphone → Speech-to-Text → User Text → AI Coding Agent → Agent Response → Text-to-Speech

The application should support both **Claude Code** and **Codex** as coding-agent backends.

## Core Flow

1. Build the application UI with SwiftUI.
2. Request and manage macOS microphone permission.
3. Capture microphone audio using Apple's AVAudioEngine.
4. Record the user's speech.
5. Convert speech to text, with Thai language support.
6. Display the transcribed text in the UI.
7. Build a structured prompt from the transcription and current workspace context.
8. Send the prompt to the selected coding agent:

   * Claude Code
   * Codex
9. Capture the agent's response and execution status.
10. Display the agent response in the UI.
11. Provide Text-to-Speech so the agent can optionally speak its response back to the user.
12. Allow the user to continue the conversation naturally.

## Agent Behavior

The agent is a software engineering agent.

Before modifying code:

* Inspect the existing repository.
* Understand the relevant architecture and implementation.
* Identify the root cause of the requested issue.
* Reuse existing patterns and utilities.
* Avoid unrelated changes.

When implementing:

* Make the smallest appropriate change.
* Follow the project's existing coding conventions.
* Do not invent APIs, schemas, business rules, or requirements.
* Add or update relevant tests when appropriate.

After implementing:

* Run relevant tests, builds, or linters.
* Review the git diff.
* Report what was changed.
* Report verification results.
* Report remaining issues if any.

Safety:

* Never expose secrets, credentials, API keys, tokens, or private keys.
* Do not delete files or data unless explicitly requested.
* Do not perform destructive operations without explicit confirmation.
* Do not commit or push changes unless explicitly requested.

## Voice Input

Voice input may be informal, incomplete, or contain speech-recognition errors.

Example:

User says:

"ช่วยดู login rate limit แล้วแก้ให้หน่อย"

The application should convert this into a structured agent request containing:

* User request
* Current workspace
* Relevant project context
* Active file if available
* Selected agent
* Execution constraints

The agent should inspect the codebase rather than blindly interpreting the voice transcription.

## Agent Abstraction

Do not tightly couple the application to Claude Code.

Create an abstraction such as:

Agent
├── ClaudeCodeAgent
└── CodexAgent

The UI should be able to select:

Claude Code / Codex

without changing the voice or prompt-processing layer.

## Suggested Architecture

SwiftUI
↓
VoiceInputManager
↓
SpeechToTextService
↓
PromptBuilder
↓
AgentRouter
├── ClaudeCodeAdapter
└── CodexAdapter
↓
AgentResponse
↓
TextToSpeechService
↓
SwiftUI

Keep components separated and testable.

## UI

Create a clean native macOS interface.

The main screen should contain:

* Application name: VoxCode
* Microphone / recording button
* Recording state
* Transcribed user message
* Selected agent
* Agent response
* Agent execution status
* Stop / cancel action
* Text-to-Speech playback control

Example:

VoxCode

[ 🎙 Start Speaking ]

User:
"ช่วยตรวจสอบ login rate limit ให้หน่อย"

Agent:
"กำลังตรวจสอบ login flow..."

Status:
Analyzing → Editing → Testing → Completed

[ 🔊 Play Response ]

## Response Format

The agent response should provide structured information:

* Summary
* Changed files
* Tests/checks performed
* Result
* Remaining issues

Do not expose internal chain-of-thought or hidden reasoning.

## Implementation Strategy

First inspect the existing project and determine its current structure.

Then implement the application incrementally:

1. SwiftUI application shell
2. Microphone permission
3. Audio recording
4. Speech-to-text integration
5. Prompt builder
6. Agent abstraction
7. Claude Code integration
8. Codex integration
9. Agent response handling
10. Text-to-speech
11. Conversation loop
12. Error handling
13. Tests
14. Final UI polish

Do not rewrite the entire project unnecessarily.

At every stage, preserve working functionality.

## Important

The final product should feel like a native macOS **voice interface for AI coding agents**, not merely a speech-to-text demo.

The primary user experience is:

Press microphone → Speak Thai → Stop speaking → Text appears → Agent works → Agent response appears → Agent optionally speaks the response.

Start by inspecting the repository and implementing the first appropriate step. Do not ask unnecessary questions if the repository already provides enough context.

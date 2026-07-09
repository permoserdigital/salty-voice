# SALTY Voice

macOS menu bar dictation app (Swift/SwiftUI, macOS 14+). Fork of
[blitztext-app](https://github.com/cmagnussen/blitztext-app) with team features.

## Build

Requires full Xcode 16+ and XcodeGen (`brew install xcodegen`).

```bash
./build.sh --install   # generates the Xcode project, builds, installs to /Applications
rm -rf "SALTY Voice.app"   # always delete the build copy in the repo (duplicate instances)
```

The app is ad-hoc signed: after every rebuild macOS invalidates the Accessibility
(and sometimes Microphone) permission. Reset with
`tccutil reset Accessibility com.saltybrands.saltyvoice`, relaunch, re-grant.
Symptom of a lost microphone permission: every transcription returns just "you"
(Whisper's response to silent audio).

## Architecture map

- `BlitztextMac/App/` — AppState (workflow lifecycle, `workflowGeneration` guard against
  stale-callback races), AppDelegate, menu bar icon renderer, floating indicators
  (bubble / cursor follower) in StatusBubbleController.swift
- `BlitztextMac/Features/Workflows/` — one workflow per mode; settings models in
  WorkflowProtocol.swift
- `BlitztextMac/Services/` — hotkeys (flagsChanged monitors + Carbon Escape hotkey),
  recording, transcription (team proxy > personal key > local WhisperKit),
  hallucination filters + canonical term enforcement (TranscriptionQualityService),
  correction learning, history, sounds, update check, team vocabulary client

## Conventions

- User-facing strings are German; code and comments are English.
- Internal identifiers stay on the original names (Application Support folder
  "Blitztext", keychain service "app.blitztext.preview.credentials") so user data
  survives rebrands. Do not rename them.
- Global NSEvent keyDown monitors do NOT work here (they require the separate Input
  Monitoring permission). Use flagsChanged monitors or Carbon hotkeys
  (see EscapeCancelHotkey.swift).
- Never commit secrets: team codes, API keys, or internal server details.
- Pure logic changes (TranscriptionQualityService, hotkey state machine,
  CorrectionLearningService, version compare) should be verified with a standalone
  Swift script test before building.

## Debug logging

```bash
log stream --predicate 'subsystem == "app.blitztext.preview"' --level debug
```

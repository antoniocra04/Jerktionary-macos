<div align="center">

# Jerktionary for macOS

**A native SwiftUI meeting copilot: live transcription, on-demand answers, and an always-on-top card that stays out of screen shares.**

[![CI](https://github.com/antoniocra04/Jerktionary-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/antoniocra04/Jerktionary-macos/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/antoniocra04/Jerktionary-macos)](https://github.com/antoniocra04/Jerktionary-macos/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6.2%2B-orange)](https://swift.org)

</div>

Jerktionary listens to a call, transcribes it live, highlights the terms that come
up, and — **only when you ask for it** — streams an answer you can read while the
other side is still talking.

This is the native SwiftUI port of the Electron front end. The headline
difference: **system audio is captured with ScreenCaptureKit**, so there is no
BlackHole, no Multi-Output Device, and no fragile virtual audio routing to set up.

---

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [Install](#install)
- [First run](#first-run)
- [Usage](#usage)
  - [Keyboard shortcuts](#keyboard-shortcuts)
  - [The three tabs](#the-three-tabs)
  - [Compact overlay](#compact-overlay)
  - [Stealth mode](#stealth-mode)
- [Backend](#backend)
- [Settings reference](#settings-reference)
- [Where your data lives](#where-your-data-lives)
- [Building from source](#building-from-source)
- [Project layout](#project-layout)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Features

**Live transcription**
Audio is resampled to 16 kHz mono little-endian int16 and streamed over a
WebSocket to your backend in 4096-frame chunks. The connection reconnects on its
own with exponential backoff (500 ms → 5 s). Two sources, switchable at any time:

| Source | How it is captured | macOS permission |
| --- | --- | --- |
| **Microphone** — you | `AVAudioEngine`, with a device picker | Microphone |
| **System** — the other side | `ScreenCaptureKit`, no virtual devices | Screen & System Audio Recording |

**Answers on your command, never automatically**
The transcript never triggers a request by itself. You press a key, the app
freezes the last utterance, and exactly one streaming answer is generated.
"More detail" is a separate, deliberate second request.

**Term highlighting**
Terms detected in the transcript are highlighted inline. Click one for a
streamed explanation (title, short definition, example, why it matters), with
background prefetching so the common case feels instant.

**Chat with images and math**
A full chat tab over your backend's `/api/chat`, with streaming responses, model
and reasoning-depth pickers driven by what the backend reports for that model,
and image attachments from file, drag-and-drop, paste, or the screenshot hotkey.
Block formulas (`$$…$$`, `\[…\]`) render with real fractions, roots, and
matrices; inline `$…$` is converted to Unicode.

**Compact overlay**
A small translucent card that floats above every window — including another
app's full-screen space — on all desktops, with **Live** and **Chat** panes and
an opacity slider. Clicking it never activates the app, so macOS does not yank
you back to the desktop your main window lives on.

**Stealth**
The window is excluded from screen capture and sharing (`sharingType`), the Dock
icon is hidden while stealth is on, and the window title is maskable — set it to
anything you like in Settings.

**Notes and meeting archive**
Free-form notes with Apple Notes-style ordering, plus a meeting history that
shares `meetings.json` with the Electron build — the archive is the same file,
so your history carries over. Meetings export to Markdown.

**Guided first run**
A five-step wizard walks through profile → audio source → permissions → backend
address → readiness check, and refuses to finish until the permission and the
backend both actually check out.

---

## Requirements

- **macOS 14 (Sonoma) or newer** — Apple silicon builds are published; the source
  builds for whatever your toolchain targets
- **A running Jerktionary backend** — default `http://127.0.0.1:8000`, changeable
  in Settings (see [Backend](#backend))
- **Permissions**, depending on your audio source:
  - *Microphone* for the microphone source
  - *Screen & System Audio Recording* for the system source (and for the
    screenshot hotkey)
- **To build from source:** Swift 6.2+ and the macOS 26 SDK (Xcode 26 or the
  matching Command Line Tools). The project deliberately refuses to compile on
  an older SDK — see [Troubleshooting](#troubleshooting).

---

## Install

### Download a release (recommended)

Grab the latest `.dmg` or `.zip` from the
[releases page](https://github.com/antoniocra04/Jerktionary-macos/releases/latest)
and drag `Jerktionary.app` to `/Applications`.

Builds are **ad-hoc signed and not notarized**, so Gatekeeper will complain the
first time. Right-click the app → **Open** → **Open**, or clear the quarantine
flag:

```bash
xattr -dr com.apple.quarantine /Applications/Jerktionary.app
```

### Build it yourself

```bash
git clone https://github.com/antoniocra04/Jerktionary-macos.git
cd Jerktionary-macos
./scripts/make-app.sh
open dist/Jerktionary.app
```

See [Building from source](#building-from-source) for the full toolchain notes.

---

## First run

1. **Start your backend** and note its address.
2. **Launch Jerktionary.** The setup wizard opens automatically.
3. **Profile** — pick the window title (this is what a screen share would show if
   stealth were ever off) and write a short "about me": role, stack, years of
   experience. It is prepended to answer requests so replies land in your voice.
4. **Audio source** — microphone (you) or system (the call). Pick the input
   device if you have several.
5. **Permissions** — the wizard requests exactly the one your source needs and
   links straight to the right System Settings pane if you have to grant it by
   hand.
6. **Backend** — enter the address and press **Check connection**. The wizard
   will not let you finish until the check passes for that exact URL.
7. **Done.** Press <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Space</kbd> during a
   call to get your first answer.

You can re-run the wizard any time from Settings → **Run setup again**.

> Permissions are granted per bundle identity. Replacing a dev build with the
> packaged app (or vice versa) can require re-granting them.

---

## Usage

### Keyboard shortcuts

Global shortcuts work while any other app is focused, and need no Accessibility
permission (they use Carbon hotkeys).

| Shortcut | Action |
| --- | --- |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Space</kbd> | **Answer now** — freeze the latest utterance, stream one answer |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Enter</kbd> | **Answer with full context** — same, but with the whole transcript |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>O</kbd> | Toggle the compact overlay card |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>S</kbd> | Silent screenshot of the main display into the chat |
| <kbd>⌘</kbd>+<kbd>1</kbd> / <kbd>2</kbd> / <kbd>3</kbd> | Session / Notes / Chat tab |
| <kbd>⌘</kbd>+<kbd>,</kbd> | Settings |

The screenshot hotkey is deliberately invisible: no crosshair, no cursor in the
image, no shutter sound, no thumbnail, and the app never comes forward. macOS may
still light its own screen-recording indicator — that part is not ours to
suppress.

If another copy of the app already owns a shortcut (typically while you are
swapping a dev build for the installed one), registration retries every two
seconds until the other process exits.

### The three tabs

- **Session** — the live transcript with highlighted terms, the answer
  stream, and the meeting sidebar. Transcription and answers keep running while
  you are on another tab; switching is purely a view change.
- **Notes** — free-form notes, autosaved on a debounce and flushed on
  quit. The most recently edited note floats to the top.
- **Chat** — conversations with your model, including images and math.
  Conversations persist across launches.

### Compact overlay

<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>O</kbd> (or the header button) swaps the
main window for a small floating card:

- Sits above every window on every desktop, including other apps' full-screen
  spaces
- Two panes: **Live** (transcript + answers) and **Chat**
- Background opacity is adjustable from 70 % to 100 % — the slider shades the
  material only, never the text
- Position and size are remembered, and the card is pulled back on screen if you
  disconnect the monitor it was left on

### Stealth mode

On by default. The window is excluded from screen capture and sharing APIs, so
it does not appear in Zoom/Meet/Teams shares or in recordings, and the Dock icon
is hidden while it is active. Toggle it from the **Session** menu. The window
title is whatever you set as the display name.

---

## Backend

Jerktionary is the client half. It expects a Jerktionary-compatible backend at
the configured address, speaking these endpoints:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Liveness |
| `GET` | `/ready` | Per-component readiness, polled every 30 s |
| `WS` | `/ws/audio` | Binary PCM in (16 kHz mono int16 LE), JSON transcript events out |
| `POST` | `/api/answer/stream` | SSE — streaming answer snapshots |
| `POST` | `/api/terms/explain` | Term explanation, non-streaming |
| `POST` | `/api/terms/explain/stream` | SSE — streaming term explanation |
| `GET` | `/api/chat/capabilities` | Provider, models, reasoning levels, image support |
| `POST` | `/api/chat/stream` | SSE — chat deltas |
| `GET` | `/docs` | Opened by Settings → **Open web diagnostics** |

**WebSocket events** the app understands: `transcript_update`
(`text`, `is_final`, `terms`), `terms_update`, and `error`. Malformed terms are
dropped rather than failing the event.

**Request shaping.** The transcript tail is what matters, so "answer now" sends
the last 2000 characters of context (full-context mode sends everything), your
profile capped at 1000 characters, and the meeting context capped at 2000. Term
explanations get a 2000-character window centered on the term's last mention.

**Chat images** are sent as base64 `data:` URIs, capped at 8 per message and
~7 MB of base64 each, downscaled to 1568 px on the longest edge — matching the
backend's own limits so oversized images are rejected before the round trip.

---

## Settings reference

Open with <kbd>⌘</kbd>+<kbd>,</kbd>.

| Setting | What it does |
| --- | --- |
| **Service address** | Backend base URL. A schemeless `192.168.0.17:8000` is fixed up to `http://` automatically. |
| **Source / Microphone** | Audio source and, for microphone, the specific input device. |
| **Window name** | The masked window title. |
| **About me** | Persistent profile prepended to answer requests. |
| **Theme** | System / light / dark. |
| **Models** | Chat models offered in the picker, one per line. Empty means "whatever the backend was started with". |
| **System prompt** | Prepended to every chat conversation. |
| **Question asked about a screenshot** | Asked automatically about a <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>S</kbd> screenshot. Leave empty to drop the shot in the composer and type your own question. |
| **Diagnostics** | Resolved address, provider, default model, per-component readiness, link to the backend's own docs. |

The model list is hand-maintained on purpose: providers disagree about whether
`/v1/models` exists and what it returns, so a fetched list would be empty for
some backends and unusable for others.

---

## Where your data lives

Everything is local, in `~/Library/Application Support/Jerktionary/`:

| File | Contents |
| --- | --- |
| `meetings.json` | Meeting archive — **shared with the Electron build** |
| `notes.json` | Notes |
| `chats.json` | Chat conversations, including attached images |

Preferences live in `UserDefaults` under the `local.jerktionary.mac` domain.
Writes are debounced off the main thread and force-flushed on quit.

---

## Building from source

The project is a plain SwiftPM package — `open Package.swift` opens it in Xcode.

```bash
swift build              # debug binary
swift test               # unit tests for the ported logic
swift run Jerktionary    # run without packaging
./scripts/make-app.sh    # dist/Jerktionary.app (release + ad-hoc signature)
```

`make-app.sh` accepts a configuration argument (`./scripts/make-app.sh debug`)
and ad-hoc signs the bundle, which is enough for local use — TCC permission
grants stick to the bundle id.

**Toolchain.** Swift 6.2+ and the macOS 26 SDK are required, and the build stops
with an explicit `#error` otherwise. This is intentional: an older SDK silently
changes SwiftUI's linked-on-or-after appearance and omits macOS 26 components
such as Liquid Glass, so a build against it would look nothing like the shipped
app while claiming to be a preview of it. In Xcode, make sure the destination is
**My Mac** — SwiftPM's `platforms:` only sets a minimum version, and Xcode will
happily offer you an iPhone destination that has no AppKit, Carbon, or
ScreenCaptureKit.

**Tests** cover the parts worth locking down: transcript excerpting, term
merging and overlap resolution, UTF-16 offset handling with emoji, PCM
conversion and resampling, chunk accumulation, RMS levels, SSE payload parsing,
chat wire encoding, and image limits.

CI (GitHub Actions, `macos-26`) runs `swift build` and `swift test` on every push
to `main` and every pull request.

---

## Project layout

```
Sources/Jerktionary/
  App/            @main entry point, AppDelegate (global hotkeys, stealth)
  Core/           Central store, stream managers, settings, persistence
    Audio/        Microphone (AVAudioEngine), system (ScreenCaptureKit), PCM
    Logic/        Latest-utterance extraction, term merging
    Network/      WebSocket transport, SSE, REST
  UI/             SwiftUI views
    Math/         LaTeX rendering for chat and answers
Tests/            Unit tests for the ported logic
Resources/        Info.plist, app icon
scripts/          make-app.sh
```

---

## Troubleshooting

**"No connection to the answer service"**
The backend is unreachable. Check the address in Settings and press **Check
connection**; the diagnostics section shows exactly which component is not ready.

**System audio produces no transcript**
Screen & System Audio Recording permission is missing or was granted to a
different copy of the app. Grant it in System Settings → Privacy & Security, then
restart Jerktionary.

**Global shortcuts do nothing**
Another copy of the app (often a `swift run` build) still holds them. Quit it —
registration retries automatically every two seconds and takes over as soon as
the other process exits.

**Build fails with "requires Swift 6.2+ and the macOS 26 SDK"**
Install Xcode 26 or the matching Command Line Tools, and point at them:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

**Build fails with "macOS-only app"**
The Xcode destination is not **My Mac**. Change it in the toolbar next to the
scheme selector.

**"Jerktionary is damaged and can't be opened"**
Gatekeeper quarantine on an un-notarized build. See [Install](#install).

**Typing does not work in a `swift run` build**
Already handled — the app sets `.regular` activation policy at launch. If you
see it anyway, launch the packaged `.app` instead.

---

## License

No license file is present in this repository yet, so default copyright applies
and no usage rights are granted. If you need one, please open an issue.

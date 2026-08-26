# ReadBack

A native macOS menu-bar service that turns streamed text into local speech with Kokoro and MLX.

## TL;DR

ReadBack runs text-to-speech on an Apple Silicon Mac. Start the menu-bar app, download the pinned Kokoro model, then pipe text into `voicepipe` or call the local HTTP API. After setup, text, inference, audio, and playback stay on the Mac.

## Executive summary

ReadBack provides three parts:

- A native Swift menu-bar app that owns the local service and model backend.
- A loopback HTTP and WebSocket API for speech generation and playback.
- A `voicepipe` command that reads live text from standard input and speaks complete chunks as they arrive.

The app runs a pinned MLX-Audio server as a child process, uses the pinned Kokoro 82M model, and plays WAV data from memory with AVFoundation. Both services bind to `127.0.0.1`. Settings live in a JSON file; there is no database.

This project targets macOS 14 or later on Apple Silicon. It is a source build, not a signed or notarized release.

## Quick start

### 1. Install the prerequisites

You need:

- macOS 14 or later
- An Apple Silicon Mac
- A Swift toolchain that can build a Swift 6.2 package
- [`uv`](https://docs.astral.sh/uv/)

Install `uv` with Homebrew if needed:

```sh
brew install uv
```

### 2. Build the app

From the repository root:

```sh
Scripts/build-app
```

This creates an ad hoc signed development app at `dist/ReadBack.app`. Open it with:

```sh
open "dist/ReadBack.app"
```

The waveform icon will appear in the macOS menu bar.

To read copied text, copy up to 2,000 characters from any app and press
`Option-Command-R` (`⌥⌘R`). With the same text still on the clipboard, press
the shortcut again to pause at the current audio position and press it once
more to resume. If the clipboard text changes, the shortcut stops the current
read-back and starts the new text from the beginning. You can use the same
dynamic action from the menu-bar app.

Use the **Playback Speed** slider to change the current or next read-back from
`0.5×` through `2×` in `0.25×` steps. Changes take effect at the current
audio position without generating the speech again, including while paused.
The default is `1×`, and the app saves the selected rate for later launches.

Choose **Voice** to select a short curated list for each supported language.
Each item shows only the voice name. Choosing any voice selects it and
immediately says “test, hello world” as a preview.

Use the **Paragraph Pause** slider to add a saved gap from `0 ms` through
`2,000 ms` in `50 ms` steps. The default is `150 ms`. Pause and resume preserve
the unused part of a paragraph gap.

Before synthesis, ReadBack removes common Markdown formatting such as headings,
emphasis, list markers, quotes, links, tables, and code delimiters. It speaks the
readable content and keeps paragraph breaks.

| Current state | Clipboard | `⌥⌘R` action |
| --- | --- | --- |
| Idle | Valid text | Start from the beginning |
| Starting | Same text | Cancel the pending read-back |
| Playing | Same text | Pause at the current audio position |
| Paused | Same text | Resume at the same audio position |
| Starting, playing, or paused | Changed text | Stop the old request and start the new text |
| Any active state | Empty, non-text, or too long | Keep the current read-back unchanged |

### 3. Download and load Kokoro

Open the menu-bar item and choose **Download Kokoro**.

The app downloads this exact model revision:

```text
Repository: mlx-community/Kokoro-82M-bf16
Revision:   a71e4d38b236d968966a2002c4c895dbd12b1c3c
```

The first start may also download Python 3.12 and the pinned Python packages used by the backend.

### 4. Read text aloud

In another terminal:

```sh
printf 'Hello from ReadBack.' |
  "dist/ReadBack.app/Contents/MacOS/voicepipe"
```

`voicepipe` exits after the service has played all submitted text.

## Use `voicepipe`

`voicepipe` reads UTF-8 text from standard input and sends it to the local WebSocket service.

Build the command without creating the app bundle:

```sh
Scripts/swiftw build
```

Speak fixed text:

```sh
printf 'This text is generated and played on this Mac.' |
  .build/debug/voicepipe
```

Pipe a live command:

```sh
your-command | .build/debug/voicepipe
```

The client sends text as it arrives and commits buffered input after 300 milliseconds of inactivity. The service also splits input at sentence and paragraph boundaries and caps each speech segment at 250 Unicode characters.

Override the WebSocket URL when needed:

```sh
printf 'Hello.' |
  .build/debug/voicepipe \
  --url ws://127.0.0.1:51280/v1/readback/stream
```

## Menu-bar controls

The menu-bar app provides:

- Current service status and public API address
- Start and stop controls
- Read Clipboard with the global `⌥⌘R` shortcut
- Curated voice choices grouped by language, plus voice preview
- Paragraph-pause slider from `0 ms` through `2,000 ms` in `50 ms` steps
- Live playback-speed slider from `0.5×` through `2×` in `0.25×` steps
- Kokoro download and reload
- Launch at login when running from the app bundle
- Quit with managed backend shutdown

When an installed model loads, the app runs a short warm-up request so later speech requests avoid the full cold-start cost.

## How it works

```text
stdin or API client
        |
        v
voicepipe or HTTP request
        |
        v
ReadBack on 127.0.0.1:51280
        |
        +-- text chunking and playback queue
        |
        v
MLX-Audio on 127.0.0.1:51281
        |
        v
Kokoro on MLX
        |
        v
WAV bytes in memory -> AVFoundation playback
```

| Process | Address | Purpose |
| --- | --- | --- |
| ReadBack | `127.0.0.1:51280` | Public HTTP and WebSocket API |
| MLX-Audio | `127.0.0.1:51281` | App-managed model server |

The Swift app owns both the public service and the MLX-Audio child process. The public service uses Hummingbird. The backend runs:

```text
Python 3.12
mlx-audio[server]==0.5.0
misaki[en]==0.9.4
```

The app supports one active playback session at a time. Streamed input has a 2,000-character pending-input limit and applies backpressure while playback catches up.

## HTTP API

The public API listens at `http://127.0.0.1:51280`.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Report service, backend, and model state |
| `GET` | `/v1/models` | List the supported model and its install state |
| `POST` | `/v1/models/kokoro/download` | Download the pinned Kokoro revision |
| `POST` | `/v1/models/kokoro/load` | Load the installed Kokoro model |
| `DELETE` | `/v1/models/kokoro` | Delete the local Kokoro model |
| `POST` | `/v1/audio/speech` | Return generated audio bytes |
| `POST` | `/play` | Generate and play speech on the Mac |
| `GET` upgrade | `/v1/readback/stream` | Open the read-back WebSocket |

Check health:

```sh
curl http://127.0.0.1:51280/health
```

Generate a WAV file:

```sh
curl \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{
    "model": "kokoro",
    "input": "Save this speech to a WAV file.",
    "voice": "af_heart",
    "lang_code": "a",
    "speed": 1.0,
    "response_format": "wav"
  }' \
  --output speech.wav \
  http://127.0.0.1:51280/v1/audio/speech
```

The speech endpoint supports `wav` and `pcm` responses.

Generate and play speech on the Mac:

```sh
curl \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{
    "model": "kokoro",
    "input": "Play this on the Mac.",
    "voice": "af_heart",
    "speed": 1.0
  }' \
  http://127.0.0.1:51280/play
```

The `/play` request completes after playback finishes.

Manage the model:

```sh
curl --request POST http://127.0.0.1:51280/v1/models/kokoro/download
curl --request POST http://127.0.0.1:51280/v1/models/kokoro/load
curl --request DELETE http://127.0.0.1:51280/v1/models/kokoro
```

## WebSocket protocol

Connect to `ws://127.0.0.1:51280/v1/readback/stream`.

Client events:

```json
{"type":"text.append","text":"A complete sentence."}
{"type":"input.commit"}
{"type":"input.done"}
{"type":"playback.pause"}
{"type":"playback.resume"}
{"type":"playback.cancel"}
```

The service may send:

- `session.ready`
- `speech.queued`
- `speech.started`
- `speech.finished`
- `playback.paused`
- `playback.resumed`
- `queue.paused`
- `queue.resumed`
- `session.finished`
- `error`

Server events contain a `session_id`. Speech events may contain a `sequence`; errors may contain a `message`.

```json
{
  "type": "speech.started",
  "session_id": "A4E55B8E-19C4-4D57-9B7E-D3391DAF6682",
  "sequence": 0
}
```

## Model and local files

ReadBack currently supports one model:

| ID | Repository | Revision | Default voice |
| --- | --- | --- | --- |
| `kokoro` | `mlx-community/Kokoro-82M-bf16` | `a71e4d38b236d968966a2002c4c895dbd12b1c3c` | `af_heart` |

Model weights are not tracked by Git. The repository ignores `models/**`.

When you run the package from the repository root, the default model directory is `models/Kokoro-82M-bf16`. Download the pinned revision there directly with:

```sh
uvx --from huggingface-hub hf download \
  mlx-community/Kokoro-82M-bf16 \
  --revision a71e4d38b236d968966a2002c4c895dbd12b1c3c \
  --local-dir models/Kokoro-82M-bf16
```

When you run the built app outside the repository, it uses:

```text
~/Library/Application Support/ReadBack/models
```

Other local files live under `~/Library/Application Support/ReadBack/`:

| File | Purpose |
| --- | --- |
| `config.json` | Hosts, ports, model path, voice, synthesis speed, paragraph pause, and playback rate |
| `backend.log` | MLX-Audio standard output and errors |

ReadBack stores configuration in JSON. It does not use SQLAlchemy or any other database.

Set a custom model root before the app creates its first config file:

```sh
READBACK_MODELS_DIR=/absolute/path/to/models \
  Scripts/swiftw run readback
```

## Privacy and network access

Both services bind only to `127.0.0.1` by default.

After setup:

- Text input stays on the Mac.
- Kokoro inference runs on the Mac through MLX.
- Generated audio stays in memory unless an API client saves it.
- Playback uses AVFoundation.
- This project has no database, account system, or telemetry code.

Network access is required when the app first resolves Python packages or downloads model files from package and model hosts.

The local API has no authentication. Do not expose it on a public or shared network.

## Requirements

- macOS 14 or later
- Apple Silicon
- Swift package tools version 6.2
- `uv`
- Network access for initial dependency and model downloads
- About 400 MB for the current Kokoro checkout, plus package caches and build output

## Build and test

Use the repository wrapper for Swift package commands:

```sh
Scripts/swiftw build
```

The wrapper sets isolated SwiftPM caches and the SDK compatibility flags used by the current development toolchain.

Run the custom test harness:

```sh
Scripts/swiftw run readback-tests
```

Build the menu-bar app and bundled command:

```sh
Scripts/build-app
```

The build script creates an ad hoc signed development bundle. It does not produce a notarized release.

## Current limits

- Only the pinned Kokoro model is exposed through the public model API.
- Only one playback session can run at a time.
- In-memory playback accepts WAV data.
- The app has no release installer or automatic updater.
- The HTTP and WebSocket APIs have no authentication.
- Model download, backend startup, and model warm-up can take time on the first run.

## Upstream projects

ReadBack builds on:

- [MLX-Audio](https://github.com/Blaizzy/mlx-audio) for Apple Silicon audio inference and the model server
- [Kokoro](https://huggingface.co/mlx-community/Kokoro-82M-bf16) for text-to-speech
- [Misaki](https://github.com/hexgrad/misaki) for English text processing
- [Hummingbird](https://github.com/hummingbird-project/hummingbird) for the Swift HTTP service
- [Hummingbird WebSocket](https://github.com/hummingbird-project/hummingbird-websocket) for streamed input
- Apple AVFoundation for in-memory playback

The README structure follows patterns from [MLX-Audio](https://github.com/Blaizzy/mlx-audio#readme), [Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI#readme), [Ollama](https://github.com/ollama/ollama#readme), [Ice](https://github.com/jordanbaird/Ice#readme), and [SwiftBar](https://github.com/swiftbar/SwiftBar#readme).

## License

ReadBack is available under the [MIT License](LICENSE).

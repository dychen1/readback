# ReadBack

![ReadBack — a blue origami bird on layered blue and coral paper](Assets/readback-banner.png)


## Overview

ReadBack is a native macOS menu-bar app for reading back copied or streamed text into audio locally on your Mac. The app includes Kokoro 82M BF16, English, and French out the box and fast install options for select Qwen3 and Chatterbox models from HuggingFace. This project also includes support for loading local MLX models. ReadBack keeps one model actively loaded at a time.

## Listen

Compare three full-precision models reading the same opening of Herman Melville's [*Moby-Dick*](https://www.gutenberg.org/files/2701/2701-h/2701-h.htm) at 1×:

> Call me Ishmael. Some years ago—never mind how long precisely—having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world.

<table>
<tr>
<th width="33%">Kokoro 82M BF16<br>Michael</th>
<th width="33%">Qwen3 CustomVoice 0.6B BF16<br>Aiden</th>
<th width="33%">Chatterbox Turbo FP16<br>Default</th>
</tr>
<tr>
<td width="33%">

https://github.com/user-attachments/assets/23bbd1f6-e801-416d-bdfd-c9cb3fa3af7f

</td>
<td width="33%">

https://github.com/user-attachments/assets/62b0afc6-c96a-4b68-ad47-717604e015d4

</td>
<td width="33%">

https://github.com/user-attachments/assets/5a13293b-b407-41b0-801b-a250a5aa451a

</td>
</tr>
</table>

These demo takes use Michael for Kokoro, a restrained narration prompt for Qwen, and lower sampling temperature for Chatterbox. They use the native inference runtime with demo-specific settings, not the app's default settings.

The [source recordings and generation notes](Assets/Demo/) are included in the repository.


## Install

Pre-requisites:
- Apple Silicon Mac — M1 or newer.
- macOS 14 Sonoma or later.
- Apple developer tools with Swift 6.3+ and `make`
  - Install the tools with `xcode-select --install`.
  - Check Swift with `swift --version`; update the tools if it’s older than 6.3.

On an Apple Silicon Mac running macOS 14 or later, clone the repository and run:

```sh
git clone https://github.com/dychen1/readback.git
cd readback
make install
```

`make install` downloads the required models, builds and locally signs the app, installs it in `~/Applications`, and opens it. No `sudo` or Apple Developer account is needed. ReadBack appears in the menu bar; copy text and press `Option-Command-R` to hear it.

## Read copied text

Copy up to 2,000 characters, then press `Option-Command-R` (`⌥⌘R`). Press the same shortcut again to pause and once more to resume from the same audio position. After copying different text, press the shortcut to stop the old speech and start the new text from the beginning.

| Current state | Clipboard | Shortcut action |
| --- | --- | --- |
| Idle | Valid text | Start from the beginning |
| Starting | Same text | Cancel |
| Playing | Same text | Pause |
| Paused | Same text | Resume |
| Any active state | Changed text | Replace the current read-back |

The menu-bar popover has the same Read Clipboard action.

ReadBack plays one reading at a time. A new reading from any source — the shortcut, a voice preview, `voicepipe`, the HTTP API, or an agent — stops the current one and starts from the beginning. The popover's **Stop** button ends the current reading, whatever started it.

## Agent read-back

ReadBack serves an [MCP](https://modelcontextprotocol.io) server at `http://127.0.0.1:51280/mcp` with two tools:

- `play(text)` reads the text aloud. It returns as soon as playback starts and replaces any current reading.
- `stop()` ends the current reading.

**Settings → Agent Read-Back** shows how to connect each host with the port ReadBack actually uses, and when each host last connected. ReadBack never edits another app's configuration; you run or confirm the step yourself:

| Host | Connect |
| --- | --- |
| Cursor | Click **Add to Cursor**, then confirm in Cursor. Without Cursor installed, Settings shows the entry for `~/.cursor/mcp.json`. |
| Claude Code | `claude mcp add --transport http --scope user readback http://127.0.0.1:51280/mcp` |
| Codex | `codex mcp add readback --url http://127.0.0.1:51280/mcp` |

The same section installs the `readback` skill for ChatGPT and Codex, Claude Code, and Cursor. The skill turns the latest agent answer into a spoken brief and plays it with the MCP `play` tool when the host has it. ReadBack keeps the skill in `~/Library/Application Support/ReadBack/Skills/readback` and links each host's skills folder to it. At launch, ReadBack updates that copy to the version bundled with the app if ReadBack installed it; it never changes a skill folder it does not own.

## Models and languages

Kokoro is bundled, active by default. English and French work without another download. The Settings window offers these optional model installs:

| Model | Approximate download |
| --- | ---: |
| Qwen3 CustomVoice 0.6B 8-bit | 1.65 GB |
| Qwen3 CustomVoice 0.6B BF16 | 2.50 GB |
| Chatterbox Turbo 8-bit | 708 MB |
| Chatterbox Turbo FP16 | 2.99 GB |

ReadBack stores settings per model. Switching back to a model restores its last voice and language. It keeps only one model loaded, then clears the old MLX cache during a switch.



## What it includes

- A Swift menu-bar app for model choice, voices, playback, and service state
- Native MLX-Audio Swift inference in the app process
- AVFoundation playback from memory
- A loopback HTTP and WebSocket service on `127.0.0.1:51280`
- `voicepipe`, a small command that speaks streamed standard input
- Bundled Kokoro 82M BF16 with six English voices and one French voice
- One-click Qwen3 CustomVoice 0.6B and Chatterbox Turbo installs in 8-bit and 16-bit forms
- One-click installs for Japanese, Mandarin Chinese, Spanish, Hindi, Italian, and Brazilian Portuguese
- One local MLX model slot for technical users

It targets macOS 14 or later on Apple Silicon.


## App controls

The popover provides:

- An installed-model selector
- Voice choices grouped by installed language
- Automatic voice preview with `test, hello world`
- A paragraph-pause slider from `0 ms` to `250 ms` in `25 ms` steps; the default is `50 ms`
- A playback-speed slider from `0.5×` to `2×` in `0.25×` steps; the default is `1×`
- A **Stop** button that ends the current reading, whatever started it
- Start, stop, launch-at-login, and clipboard controls
- A Settings window for agent read-back setup, model installs, removal, and local model registration

ReadBack removes common Markdown markers while it keeps readable text and paragraph breaks.


### Add a local model

Choose **Settings → Choose Local MLX Model…** and select a model directory. ReadBack uses the folder in place and never copies or deletes its weights. The current release accepts local Kokoro-compatible MLX folders with `config.json` and SafeTensors weights. It performs a real load and preview before it makes the model active.

Registering a new local folder replaces the old registration. You must switch away from the local model first.

## Stream text with `voicepipe`

The bundled command reads UTF-8 text from standard input. It lives inside the app bundle rather than on `$PATH` (installing the cask does not add it automatically):

```sh
printf 'Hello from ReadBack.' |
  /Applications/ReadBack.app/Contents/MacOS/voicepipe
```

For a build from source, the path is `dist/ReadBack.app/Contents/MacOS/voicepipe` instead. Symlink it onto your own `$PATH` if you want it available as a plain command.

For a debug build:

```sh
make build                              # Build without installing
make install OPEN=0                     # Install without opening
make install INSTALL_DIR=/Applications  # Use a different writable folder
```

These commands create a local build. Developer ID signing and notarization for distributed releases remain available through `Scripts/build-dmg`.

```sh
Scripts/swiftw build
your-command | .build/debug/voicepipe
```

`voicepipe` sends text as it arrives, commits buffered input after 300 milliseconds without input, and exits after playback finishes. If a newer reading replaces it or it is stopped, it says so and exits with status 1. It does not accept a model option; it always uses the model active in the app.

## HTTP API

The public service listens only on `http://127.0.0.1:51280` by default.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Report the active model and runtime state |
| `POST` | `/v1/audio/speech` | Return WAV or PCM audio |
| `POST` | `/play` | Generate and play speech on this Mac |
| `POST` | `/mcp` | MCP server for agents (see [Agent read-back](#agent-read-back)) |
| WebSocket | `/v1/readback/stream` | Stream text and playback controls |

Generate a WAV file with the app's active model:

```sh
curl \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{
    "input": "Save this speech to a WAV file.",
    "response_format": "wav"
  }' \
  --output speech.wav \
  http://127.0.0.1:51280/v1/audio/speech
```

Play speech:

```sh
curl \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{"input":"Play this on the Mac."}' \
  http://127.0.0.1:51280/play
```

`/play` replaces any current reading, reads long text in sentence-sized chunks with the paragraph pause between paragraphs, and responds when the reading ends. Closing the connection early stops the reading. Errors use a JSON body such as `{"error":{"code":"empty_input","message":"The text to read is empty."}}`:

| Status | Codes | Meaning |
| --- | --- | --- |
| `200` | — | The whole text was read: `{"ok":true}` |
| `400` | `invalid_json`, `invalid_request`, `empty_input`, `invalid_speed`, `invalid_voice`, `model_selection_not_allowed` | The request cannot be read; nothing was interrupted |
| `409` | `interrupted`, `stopped` | A newer reading replaced this one, or it was stopped |
| `413` | `request_too_large` | The body is too large |
| `500` | `speech_failed` | Synthesis or playback failed |
| `503` | `model_not_ready` | The model is loading, switching, or installing; nothing was interrupted |

`speed` must be between `0.5` and `2`.

Clients cannot list, install, remove, load, or select models. A speech request that contains a `model` key returns HTTP 400 with `model_selection_not_allowed`. Change the active model in the ReadBack app.

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

Server event types include `session.ready`, `speech.queued`, `speech.started`, `speech.finished`, `playback.paused`, `playback.resumed`, `queue.paused`, `queue.resumed`, `session.finished`, and `error`.

A new connection replaces the current reading. `session.finished` carries a `reason`: `completed`, `interrupted` (a newer reading replaced it), `stopped`, or `failed`. After that, the connection's events no longer affect playback.


## Local files

ReadBack stores app data under:

```text
~/Library/Application Support/ReadBack/
```

| Path | Purpose |
| --- | --- |
| `config.json` | Active model, per-model choices, playback speed, paragraph pause, host, and port |
| `Models/` | Verified model and optional language downloads |
| `RuntimeModels/` | Runtime links for the bundled Kokoro model |
| `local-model.json` | One security-scoped local folder registration |
| `Skills/readback/` | The managed `readback` skill that host skill folders link to |
| `mcp-clients.json` | Name, version, and last connection time of up to 20 MCP clients |

Model weights and generated app bundles are not tracked by Git.


## Privacy and limits

- Text, inference, generated audio, and playback stay on the Mac.
- The local service, including the MCP server, has no authentication. Do not expose it beyond loopback. It refuses browser origins, and the MCP server also refuses requests whose `Host` is not a loopback address.
- ReadBack plays one reading and keeps one model loaded at a time.
- The local model slot supports known runtime profiles, not arbitrary code or repositories.
- The app has no automatic updater yet.

## License

ReadBack is available under the [MIT License](LICENSE).

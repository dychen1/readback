![ReadBack — a blue origami bird on layered blue and coral paper](Assets/readback-banner.png)

# ReadBack

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


## Install

Release builds can ship as a self-contained DMG or Homebrew Cask. The app bundle contains the native runtime, MLX Metal library, Kokoro weights, and its included language files.

To build from source:

```sh
Scripts/build-app
open dist/ReadBack.app
```

The build needs a Swift 6.2 toolchain and network access the first time it resolves packages and release assets. The built app does not need those tools.

## Read copied text

Copy up to 2,000 characters, then press `Option-Command-R` (`⌥⌘R`). Press the same shortcut again to pause and once more to resume from the same audio position. If the clipboard changes, ReadBack stops the old speech and starts the new text from the beginning.

| Current state | Clipboard | Shortcut action |
| --- | --- | --- |
| Idle | Valid text | Start from the beginning |
| Starting | Same text | Cancel |
| Playing | Same text | Pause |
| Paused | Same text | Resume |
| Any active state | Changed text | Replace the current read-back |

The menu-bar popover has the same Read Clipboard action.

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
- Start, stop, launch-at-login, and clipboard controls
- A Settings window for model installs, removal, and local model registration

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
Scripts/swiftw build
your-command | .build/debug/voicepipe
```

`voicepipe` sends text as it arrives, commits buffered input after 300 milliseconds without input, and exits after playback finishes. It does not accept a model option; it always uses the model active in the app.

## HTTP API

The public service listens only on `http://127.0.0.1:51280` by default.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Report the active model and runtime state |
| `POST` | `/v1/audio/speech` | Return WAV or PCM audio |
| `POST` | `/play` | Generate and play speech on this Mac |
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

Model weights and generated app bundles are not tracked by Git.


## Privacy and limits

- Text, inference, generated audio, and playback stay on the Mac.
- The local service has no authentication. Do not expose it beyond loopback.
- ReadBack supports one playback session and one loaded model at a time.
- The local model slot supports known runtime profiles, not arbitrary code or repositories.
- The app has no automatic updater yet.

## License

ReadBack is available under the [MIT License](LICENSE).

# Demo generation

## Overview

- Purpose: compare three full-precision models on one passage.
- Scope: the README's three embedded clips and their source WAV files.
- Approach: generate through the native Swift inference runtime, then wrap the audio in compact video cards for GitHub.
- Boundary: these settings apply to the demos, not the app defaults. Voice quality still needs a listening check.
- Outcome: playback inside the README without separate download links.

## Shared text

Call me Ishmael. Some years ago—never mind how long precisely—having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world.

## Settings

All clips play at 1× with no time stretching or voice processing. The source WAVs use mono, 24 kHz, 16-bit PCM. The embedded MP4s contain AAC audio and a static 320 × 200 H.264 card. GitHub adds its own controls, initial mute state, and 200-pixel minimum player height.

| File | Model / voice | Generation settings |
| --- | --- | --- |
| `kokoro-michael.wav` | Kokoro 82M BF16 / `am_michael` | `KokoroSpeechSynthesizer`, English, speed 1 |
| `qwen3-bf16-aiden.wav` | Qwen3 CustomVoice 0.6B BF16 / Aiden | Temperature 0.65, top-p 0.9, MLX seed 42, instruction below |
| `chatterbox-turbo-fp16.wav` | Chatterbox Turbo FP16 / default conditioning | Temperature 0.55, top-p 0.9, MLX seed 42, no reference audio |

Qwen receives this instruction after `Aiden,` in the runtime's voice argument:

> Read this as restrained first-person literary narration. Use a calm matter-of-fact tone, an even pace, and light natural pauses. Keep the aside understated. Avoid excitement, a cheerful sales tone, whispering, or dramatic emphasis.

Qwen uses model revision `6415d95f88be018ff9e46813119dc3bc12261328`; Chatterbox uses `b2d0a13aa7cfff0a06d9acb247ae91c8f19a6d75`. Other generation settings use the model defaults from the runtime pinned in `Package.resolved`. Kokoro uses the bundled model and English language files.

Kokoro has fixed voices rather than a style prompt. Qwen's CustomVoice parser accepts a speaker followed by a comma and an instruction. Chatterbox Turbo does not use the regular Chatterbox model's emotion or guidance overrides; lower temperature changes sampling but does not guarantee a neutral delivery.

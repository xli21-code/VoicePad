# VoicePad

Offline voice-to-text for macOS. Hold a key, speak, release — text appears at your cursor.

## Features

- **Offline ASR** — SenseVoice model via sherpa-onnx. No audio leaves your Mac.
- **Push-to-talk** — Hold Control to record, release to transcribe and paste.
- **Pre-roll buffer** — Captures 1.5s before key press so no speech is lost.
- **Smart Polish** — Optional LLM post-processing via Claude API to clean up transcription.
- **History** — Searchable transcript history with full-text search.
- **Lightweight** — Native Swift, menu bar only, no Electron.

## How It Works

1. Hold **Right Control**.
2. Speak naturally. A floating overlay shows recording status.
3. Release the key. Text is transcribed and pasted into the active app.

Audio is processed locally using SenseVoice (zh/en/ja/ko/yue). Optionally, raw transcription can be polished by Claude API to fix grammar and remove filler words.

## Requirements

- macOS 14.0+ (Apple Silicon)
- Microphone permission
- Accessibility permission (global hotkey + paste simulation)

## Build from Source

```bash
# 1. Build sherpa-onnx native libraries (first time only)
./scripts/build_sherpa.sh

# 2. Build and package the app
./scripts/build_app.sh

# 3. Run
open dist/VoicePad.app
```

The ASR model (~200MB) downloads automatically on first launch.

## Configuration

### Smart Polish (optional)

Enable LLM-powered transcript cleanup:

1. Click the VoicePad menu bar icon.
2. Select **Set API Key...** and enter your API key.
3. Toggle **Smart Polish (LLM)** on.

Supports Anthropic API and any compatible endpoint. Config stored at `~/.voicepad/config.json`:

```json
{
  "anthropic_api_key": "sk-...",
  "api_base_url": "https://api.anthropic.com",
  "model": "claude-sonnet-4-20250514"
}
```

## Permissions

| Permission    | Purpose                                   |
|---------------|-------------------------------------------|
| Microphone    | Record voice for transcription            |
| Accessibility | Global hotkey capture + paste simulation  |

Grant in **System Settings > Privacy & Security**.

## Tech Stack

| Layer     | Technology                              |
|-----------|-----------------------------------------|
| Language  | Swift 5.9                               |
| UI        | AppKit (NSPanel overlay, NSStatusBar)   |
| ASR       | SenseVoice via sherpa-onnx (C bridge)   |
| LLM       | Claude API (optional polish)            |
| Storage   | GRDB / SQLite (history with FTS5)       |
| Audio     | AVAudioEngine (16kHz mono Float32)      |

## License

MIT

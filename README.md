<div align="center">
  <img src="assets/icon/app_icon.png" width="128" height="128" alt="MiniChat logo">
</div>

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="textlogowhite.svg">
    <source media="(prefers-color-scheme: light)" srcset="textlogoblack.svg">
    <img src="assets/logo-dark-theme.svg" alt="MiniChat Logo" width="256">
  </picture>
</div>

---

<p align="center">
  A Flutter chat client for LLMs with OpenAI-compatible APIs, featuring local speech recognition via Whisper.
</p>

## Features

- **Chat with any OpenAI-compatible LLM** — configure your own endpoint, API key, and model
- **SSE streaming responses** — real-time token-by-token replies
- **Offline speech-to-text** — on-device Whisper model via sherpa_onnx (no data sent to external servers)
- **Markdown rendering** — including LaTeX math (`$...$`) via gpt_markdown and flutter_math_fork
- **Dark/light theme** — persistent across sessions
- **Settings persistence** — via SharedPreferences

## Platform Support

| Platform  | Status |
|-----------|--------|
| Android   | Working |
| Linux     | Working |
| iOS       | Not tested |
| Windows   | Not tested |
| macOS     | Not tested |
| Web       | Not supported |

## Getting Started

### Prerequisites

- Flutter SDK ^3.12.2
- A valid API endpoint compatible with OpenAI's chat completions API

### Configuration

1. Open the app and navigate to **Settings**
2. Enter your API endpoint URL (e.g. `api.openai.com/v1/chat/completions`)
3. Enter your API key
4. Specify the model name (e.g. `gpt-4o-mini`)
5. Save settings

### Offline Speech Recognition

The app can download a Whisper model (~200MB) for offline speech-to-text. Go to **Settings** and tap **Download Offline Whisper Model**. Once downloaded, the mic button in the chat screen will let you dictate messages.

## Dependencies

| Package | Purpose |
|---------|---------|
| `gpt_markdown` | Markdown rendering |
| `flutter_math_fork` | LaTeX math display |
| `shared_preferences` | Persistent settings |
| `simple_sse_http` | SSE streaming |
| `sherpa_onnx` | On-device Whisper inference |
| `record` | Audio recording |
| `archive` | Tarball extraction for Whisper model |
| `path_provider` | File system paths |
| `http` | HTTP client |

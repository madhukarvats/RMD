# RMD — Record My Day

A macOS menu bar app that, while switched on, listens to your **microphone** ("Me") and your **computer audio** ("Others") and keeps a **timestamped text transcript** of your day. Audio is transcribed on-device and never written to disk. Summaries (time blocks, meetings, daily) are generated locally, and an **MCP server** lets Claude or any MCP client query everything.

## Build & run

Requires macOS 26, Xcode 26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
make run     # generate project, build, launch (menu bar icon: waveform circle)
make build   # build only
make clean
```

`RMD.xcodeproj` is generated from `project.yml`; edit the YAML, not the project.

Speech models live in `~/Library/Application Support/RMD/models` (see *Speech-to-text engine*); everything runs offline.
Transcripts live in `~/Library/Application Support/RMD/rmd.sqlite`.

### Testing without talking

```bash
# Run an audio file through the same pipeline as the mic and print timestamped lines (nothing saved)
build/Build/Products/Debug/RMD.app/Contents/MacOS/RMD --transcribe some-clip.m4a

# Compare candidate speech models side by side on your own voice clips (put them in samples/, which git ignores)
uv run tools/model-test/compare.py samples/*.m4a
```

Debug knobs for `--transcribe`: `RMD_DEBUG=1` prints each Whisper segment with its confidence scores;
`RMD_LANGUAGE=hi|en` forces a language instead of auto-detecting (`en` on Hindi speech translates to English).

## Connect to Claude (MCP)

RMD ships an MCP server inside the app: `RMD.app/Contents/MacOS/rmd-mcp`. It only reads the transcript;
recording stays in the app. MCP clients launch it themselves, so the RMD app doesn't need to be running to read.

**Claude Code** (available in every project):

```bash
claude mcp add --scope user rmd -- /Users/madhukarsharma/Desktop/workspace/ThinkingLab/RMD/build/Build/Products/Debug/RMD.app/Contents/MacOS/rmd-mcp
```

**Claude Desktop**: Settings → Developer → Edit Config, add this to `claude_desktop_config.json`, then restart Claude:

```json
{
  "mcpServers": {
    "rmd": {
      "command": "/Users/madhukarsharma/Desktop/workspace/ThinkingLab/RMD/build/Build/Products/Debug/RMD.app/Contents/MacOS/rmd-mcp"
    }
  }
}
```

The path points at the build folder, so run `make build` again after a `make clean`.

| Tool | What it returns |
|---|---|
| `list_days` | Days with a transcript, line counts, first/last time |
| `get_transcript` | One day (`date`: YYYY-MM-DD / today / yesterday), optionally `from`–`to` (HH:mm) |
| `search_transcript` | Lines matching words, with date and time |
| `get_recent` | The last N minutes |

Prompts (slash commands in clients that support them): `summarize_day`, `summarize_time_range`, `summarize_meeting`.

## Architecture

```
mic ──────────► "Me"     ┐
                         ├─► voice activity detection ─► local speech-to-text ─► SQLite (timestamped segments)
system audio ─► "Others" ┘        (skip silence)          (audio held in memory only)      │
  (Core Audio process tap)                                                                  ├─► summarizer (Apple on-device LLM)
                                                                                            │     30-min blocks · meetings · daily
                                                                                            └─► rmd-mcp (stdio MCP server, read-only)
```

Each segment stores: start/end time, source (Me/Others), app (Zoom, Chrome…), text, language.

### Speech-to-text engine

You speak Hinglish, Hindi and English, so Apple's built-in `SpeechTranscriber` is out (it has English, incl. `en_IN`, but no Hindi). Wispr Flow was considered but is cloud-only (its docs say transcription needs an internet connection), so its model can't run locally.

Hindi must be written in Roman letters ("kya tum hindi bol sakte ho"), so RMD runs
**Oriserve Whisper-Hindi2Hinglish-Apex** (a Whisper large-v3-turbo fine-tune for Indian-accented
Hindi/Hinglish, Apache 2.0) on the Neural Engine via WhisperKit, decoding with language `en`
as its model card says. English stays English. About 1 s per line; loads in ~2 s.

Stock Whisper turbo (Hindi in Devanagari) is the fallback if the converted model is missing.
Apple's on-device LLM can't romanize afterwards: it rejects Hindi input.

**Re-creating the converted model** (1.5 GB, ~15 min on an M4, then ~4 min one-time Neural Engine setup on first load):

1. Copy the Hugging Face snapshot of `Oriserve/Whisper-Hindi2Hinglish-Apex` into a folder whose path has
   no spaces, and add `"alignment_heads": [[2,4],[2,11],[3,3],[3,6],[3,11],[3,14]]` (from
   `openai/whisper-large-v3-turbo`) to its `generation_config.json`. The converter's checks expect them.
2. Convert with Argmax's [whisperkittools](https://github.com/argmaxinc/whisperkittools), output dir also without spaces
   (its compile step doesn't quote paths). Don't pass `--disable-default-tests` (that skips building the encoder and
   decoder) or `--generate-decoder-context-prefill-data` (its consistency check fails for this model):
   ```bash
   uv tool run --python 3.11 --from git+https://github.com/argmaxinc/whisperkittools \
     whisperkit-generate-model --model-version <copied-folder> --output-dir <out-dir>
   ```
3. Move the result to `~/Library/Application Support/RMD/models/converted/Oriserve_Whisper-Hindi2Hinglish-Apex`
   and copy `config.json` + `generation_config.json` next to it. RMD picks it up on next switch-on.

## Roadmap

- [x] 1. Setup — menu bar app shell, mic permission, signing, project
- [x] 2. Mic → live transcript with timestamps, Hindi in Roman letters (Oriserve Apex on the Neural Engine)
- [ ] 3. Computer audio via process tap, app exclude list, echo handling
- [x] 4. MCP server (`rmd-mcp`): transcript tools + summary prompts
- [ ] 5. Meeting detection and summaries (30-min, meeting, daily), Markdown export
- [ ] 6. Polish — live transcript window, timeline, pause hotkey, launch at login

## Defaults

- Music apps (Spotify, Apple Music) excluded from computer audio
- Pauses when the Mac locks or sleeps
- Transcripts kept forever, stored only on this Mac
- Echo cancellation on the mic when using speakers

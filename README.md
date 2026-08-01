# QwikVidCompressor

Dead-simple macOS app for trimming and compressing videos to fit Twitter and Discord's free upload limits.

Drop a video, pick a platform, compress. Output lands right next to the original file.

## Features

- **Twitter mode** — 512 MB / 2m20s free limit, including the 40 fps and web resolution constraints
- **Discord mode** — 10 MB free limit, with an adaptive bitrate, frame rate, and resolution
- Drag & drop, Cmd+V paste, or click to browse
- Shows thumbnail, duration, resolution, and file size
- Expandable native trim tools for removing the beginning, end, or multiple middle sections
- Timing-versus-clarity control for especially difficult size targets
- Fast, lossless remuxing when a video already fits the selected platform
- Isolated two-pass encoding, useful FFmpeg diagnostics, output validation, and cancel support
- Output saved next to original as `filename_twitter.mp4` or `filename_discord.mp4`

## Requirements

- macOS 13.0+
- FFmpeg — install with `brew install ffmpeg`

## Install

**Option A:** Download `QwikVidCompressor.zip` from [Releases](https://github.com/machi47/QwikVidCompressor/releases), unzip, and move to Applications.

**Option B:** Build from source:
```bash
git clone https://github.com/machi47/QwikVidCompressor.git
cd QwikVidCompressor
open QwikVidCompressor.xcodeproj
```
Then hit Build & Run in Xcode.

## How it works

Uses FFmpeg under the hood for compression:
- Calculates a safe bitrate budget from the edited output duration and exact platform limit
- Uses two-pass H.264 encoding for predictable file sizes, with a unique writable pass log per job
- Adapts frame rate, resolution, and audio bitrate to preserve as much visible detail as the budget permits
- Validates the finished file and automatically tightens the bitrate if MP4 overhead pushes it over the limit
- Uses H.264 Main profile, AAC audio, and `yuv420p` for broad compatibility

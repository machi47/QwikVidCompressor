# QwikVidCompressor

Dead-simple macOS app for compressing screen recordings to fit Twitter and Discord limits.

Drop a video, pick a platform, compress. Output lands right next to the original file.

## Features

- **Twitter mode** — 512 MB / 2m20s limit. Automatically speeds up videos that are too long, then compresses with two-pass encoding
- **Discord mode** — 50 MB limit. Smart resolution scaling and CRF-based compression
- Drag & drop, Cmd+V paste, or click to browse
- Shows thumbnail, duration, resolution, and file size
- Progress bar with cancel support
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
- Calculates target bitrate based on platform file size limit and video duration
- Two-pass encoding for tight bitrate targets
- Smart CRF defaults based on video length (higher quality for short clips)
- Scales resolution down to 1080p/720p when needed
- H.264 Main profile with `yuv420p` for max compatibility

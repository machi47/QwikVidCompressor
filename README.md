# QwikVidCompressor

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://github.com/machi47/QwikVidCompressor/releases/latest)
[![Swift 5](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Latest release](https://img.shields.io/github/v/release/machi47/QwikVidCompressor)](https://github.com/machi47/QwikVidCompressor/releases/latest)

A small native macOS utility for trimming and compressing videos to fit Discord and Twitter/X upload limits. Drop in a video, choose a platform, and get a post-ready MP4 beside the original.

**[Download the latest version](https://github.com/machi47/QwikVidCompressor/releases/latest/download/QwikVidCompressor.zip)**

## Highlights

- **Discord** — targets the current 10 MB free-account attachment limit
- **Twitter/X** — targets the 512 MB and 2:20 free-account limits, plus web resolution and frame-rate constraints
- Drag and drop, click to browse, or paste a file with <kbd>⌘</kbd><kbd>V</kbd>
- Trim the beginning or end and remove multiple sections from the middle
- Scrubbable native video preview with precise one-second navigation
- Choose between preserving the original timing and shortening difficult videos for sharper frames
- Lossless fast path when the selected video already fits
- Adaptive bitrate, resolution, frame rate, and audio quality when compression is required
- Predictable two-pass encoding with finished-file validation and automatic retry
- Useful FFmpeg diagnostics instead of unexplained numeric exit codes
- Everything runs locally; the app does not upload or collect your videos

## Install

1. Install FFmpeg if it is not already available:

   ```bash
   brew install ffmpeg
   ```

2. [Download `QwikVidCompressor.zip`](https://github.com/machi47/QwikVidCompressor/releases/latest/download/QwikVidCompressor.zip).
3. Unzip it and move `QwikVidCompressor.app` to `/Applications`.
4. Because this personal build is not Apple-notarized, right-click the app and choose **Open** the first time.

QwikVidCompressor requires macOS 13 Ventura or newer. Homebrew installations on both Apple silicon and Intel Macs are detected automatically.

## Use

1. Drop, paste, or select a video.
2. Optionally expand **More Options**:
   - Choose **Edit…** beside **Trim & Cuts** to set the beginning/end or mark middle cuts.
   - Leave the balance at **Keep timing** to preserve playback speed.
   - Move toward **Sharper frames** to permit shortening when an unusually restrictive size target would otherwise require severe quality loss.
3. Choose **Twitter** or **Discord** as the final output target. The app explains whether the edited result already fits, only needs its edits applied, needs compatibility conversion, or requires size reduction.
4. Press **Compress for Twitter** or **Compress for Discord**.

The result is saved beside the source as `filename_twitter.mp4` or `filename_discord.mp4`. Existing source files are never modified.

## Platform targets

| Mode | Free-account target | Other compatibility work |
| --- | --- | --- |
| Discord | Under 10 MB | H.264/AAC MP4 output |
| Twitter/X | Up to 512 MB and 140 seconds | Up to 40 fps, supported web resolution/aspect ratio, H.264/AAC MP4 |

Limits can change. The values above follow the official [Discord attachment documentation](https://support.discord.com/hc/en-us/articles/25444343291031-File-Attachments-FAQ) and [Twitter/X video documentation](https://help.x.com/en/using-x/x-videos).

## How compression works

QwikVidCompressor first checks the edited duration and estimated edited size against the selected platform's constraints. Compatible untouched files take a fast stream-copy path, avoiding needless quality loss. If trimming makes a video fit, the app applies those edits at source-quality settings instead of forcing size reduction.

When conversion is needed, the app:

1. Applies the requested trims and joins the remaining sections.
2. Calculates a safe video/audio bit budget from the edited duration and platform limit.
3. Chooses an appropriate frame rate and resolution for that budget.
4. Performs a two-pass H.264 encode using an isolated temporary stats file.
5. Validates the completed MP4 and retries at a tighter bitrate if container overhead puts it over the limit.

The output uses H.264 Main profile, AAC audio, `yuv420p`, and fast-start MP4 metadata for broad compatibility.

## Troubleshooting

**FFmpeg Required**

Run `brew install ffmpeg`, then reopen the app.

**macOS says the developer cannot be verified**

Right-click `QwikVidCompressor.app`, choose **Open**, and confirm once. Subsequent launches work normally.

**The result is much smaller or shorter than the original**

Discord's free 10 MB limit can be extremely restrictive for long videos. Keep the balance slider to the left to preserve timing, or move it right to trade duration for clearer frames.

**Compression fails**

Expand **Technical details** beneath the error. The app preserves the relevant FFmpeg output so the actual codec, permission, disk-space, or input-file problem is visible.

## Build from source

```bash
git clone https://github.com/machi47/QwikVidCompressor.git
cd QwikVidCompressor
open QwikVidCompressor.xcodeproj
```

Build the `QwikVidCompressor` scheme in Xcode. The project targets macOS 13+ and expects FFmpeg at a standard Homebrew path or bundled in the app resources.

See [CHANGELOG.md](CHANGELOG.md) for release history.

QwikVidCompressor is an independent utility and is not affiliated with Discord or X Corp.

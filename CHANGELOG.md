# Changelog

## 2.0.2 — 2026-08-01

### Fixed

- Made the complete Trim & Cuts row—including its label, summary, empty space, and chevron—the button that opens and closes the editor.
- Removed the undersized Edit button that made the row's apparent click target misleading.
- Added enough finished-state window height to keep both result buttons fully visible after editing and compression.

## 2.0.1 — 2026-08-01

### Fixed

- Replaced SwiftUI's crashing `VideoPlayer` bridge with the native macOS `AVPlayerView` on macOS 15.
- Made the entire More Options and Technical Details rows clickable.
- Prevented short edited videos from being assigned absurdly high bitrates from the 512 MB X allowance.
- Capped X output at its documented 25 Mbps maximum bitrate.

### Improved

- Added direct draggable handles for start/end trims and middle-cut selections.
- Moved platform selection to the final step and preserved every edit when switching platforms.
- Added a preflight message explaining whether the video needs no work, edits only, compatibility conversion, or size reduction.
- Added a source-quality edit path when trimming makes a video fit without compression.
- Refined the options hierarchy around compact native macOS controls.

## 2.0.0 — 2026-08-01

### Added

- Native video preview and timeline controls for trimming the beginning and end.
- Multiple removable middle sections with automatic splicing.
- Timing-versus-clarity control for difficult compression targets.
- Adaptive resolution, frame rate, audio bitrate, and playback-speed planning.
- Lossless stream-copy path for files that already satisfy platform constraints.
- Output validation, automatic bitrate tightening, compatibility fallback, and detailed FFmpeg diagnostics.

### Fixed

- Fixed FFmpeg exit code 187 when the installed app launched with `/` as its working directory. Two-pass statistics now use a unique writable temporary path.
- Corrected Discord's free-account target from the outdated 50 MB Nitro Basic limit to 10 MB.
- Enforced Twitter/X's free-account duration, frame-rate, resolution, and file-size constraints together.
- Prevented shared two-pass statistics from colliding between jobs.

### Changed

- Updated the app version to 2.0 (build 2).
- Refined progress, completion, cancellation, error, and platform-limit messaging.

## 1.0.0 — 2026-02-14

- Initial public release with drag-and-drop Twitter/X and Discord video compression.

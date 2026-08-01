# Changelog

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

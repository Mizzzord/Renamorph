<div align="center">

![Renamorph — rename it, transform it](docs/assets/banner.svg)

[Русский](README.md) · **English** · [Español](README.es.md)

**Rename it. Transform it. Keep the original.**

[![Stars](https://img.shields.io/github/stars/Mizzzord/Renamorph?style=for-the-badge&color=51d6b4)](https://github.com/Mizzzord/Renamorph/stargazers)
[![Release](https://img.shields.io/github/v/release/Mizzzord/Renamorph?include_prereleases&style=for-the-badge&color=139c97)](https://github.com/Mizzzord/Renamorph/releases)
[![Downloads](https://img.shields.io/github/downloads/Mizzzord/Renamorph/total?style=for-the-badge&color=139c97)](https://github.com/Mizzzord/Renamorph/releases)
[![License](https://img.shields.io/badge/license-GPL--2.0--or--later-405b6a?style=for-the-badge)](LICENSE)

[**Download for macOS ↗**](https://github.com/Mizzzord/Renamorph/releases) · [Formats](docs/FORMATS.md) · [Validation](docs/VALIDATION.md)

</div>

---

## A rename that actually converts the file

Renamorph is a macOS menu bar utility for local file conversion. Its name combines *rename* and *morph*.

Renaming `photo.heic` to `photo.jpg` normally leaves HEIC data inside. Renamorph detects the change in a selected folder, identifies the actual content and produces a real JPEG. It saves the original and validates the result before publishing it.

```text
photo.heic → photo.jpg     HEIC → actual JPEG
song.flac  → song.mp3      FLAC → MP3
clip.mov   → clip.mp4      remux or transcode according to settings
```

## What it does

| Feature | Behavior |
| --- | --- |
| Watching | Selected folders, exclusions, event coalescing and safe reconciliation after restart |
| Detection | Signatures, container structure, full decoding and parsing |
| Control | Confirmation or automatic mode, format-pair rules, queue, diagnostics and cancellation |
| Preservation | Stable source, backup, input version checks, publication journal and recovery |
| Undo | Restores saved bytes; stops if the result has been changed or replaced |
| Privacy | Conversion runs on your Mac; files are not uploaded to services |

A compatible extension or a basename-only rename does not re-encode the file. Handling newly created files with mismatched extensions is a separate opt-in setting. A backup quota does not automatically delete old originals.

## 29 formats · 264 routes

| Family | Input | Output |
| --- | --- | --- |
| Images | JPEG, PNG, TIFF, HEIC, BMP, WebP, GIF, AVIF | JPEG, PNG, TIFF, HEIC, BMP, WebP, AVIF |
| Audio | MP3, WAV, FLAC, AIFF, M4A, AAC, Ogg, Opus, WMA, CAF, WavPack | All listed except WMA; AAC or ALAC for M4A |
| Video | MP4, MOV, MKV, WebM, AVI, MPEG, WMV, TS | MP4, MOV, MKV, WebM, AVI; audio extraction |
| Subtitles | SRT, WebVTT | SRT ↔ WebVTT |

Routes have codec, stream and property restrictions. Images are currently static; GIF is a single-frame input only. WMV → AVI is disabled. Remuxing preserves compressed streams but drops tags and chapters; transcoding may reduce quality. [Detailed matrix and losses](docs/FORMATS.md) (Russian).

`file.png,webp` prepares independent outputs from one captured original. Choose the group policy explicitly in settings. Multiple files are published sequentially with a recovery journal.

## Install

**Current binary: macOS 27.0+, Apple Silicon, local APFS.** This is the tested configuration. Intel and earlier macOS versions are not claimed.

1. Download `Renamorph-0.4.2-macOS-arm64.zip` from [Releases](https://github.com/Mizzzord/Renamorph/releases/tag/v0.4.2). `SHA256SUMS` accompanies the assets.
2. Extract it, move `Renamorph.app` to Applications and open it.
3. Add a folder and start with a disposable copy in confirmation mode.
4. Rename its extension, review the job settings and approve. Use History / Undo to restore the original.

The release is **ad-hoc signed, not notarized**. macOS may block the first launch; if you trust the verified file, use the standard Open Anyway option in System Settings → Privacy & Security. [Apple instructions](https://support.apple.com/en-us/102445). No Homebrew installation is needed to run the packaged app. The current app interface is in Russian; these README translations do not imply a localized UI.

Existing ConsulMAC profiles retain their settings, history and original backups in the legacy directory. New installations use `~/Library/Application Support/Renamorph`.

## Smaller, with measured improvements

The bundle uses about **31 MiB**, down from 94 MiB in an earlier build, while preserving and expanding the route matrix. Unused FFmpeg dependencies and debug symbols were removed. Full media validation now streams frame descriptions in one decoding pass.

Measured on synthetic fixtures: WAV → MP3 including validation **2.8×**, MOV → MKV **6.4×**, H.264 transcoding **3.4×** faster than the earlier build. These are medians of three local runs, excluding confirmation, backup and publication time. [Method and raw measurements](docs/VALIDATION-0.3.md) (Russian).

## Build and test

Requires Apple Command Line Tools with Swift 6 / Swift Testing, Python 3 and Homebrew. Verified with Swift 6.4 / SDK 27.0.

```bash
git clone https://github.com/Mizzzord/Renamorph.git
cd Renamorph
brew install pkgconf x264 lame opus libvorbis libvpx webp dav1d
bash scripts/build-app.sh
open dist/Renamorph.app
bash scripts/test.sh
```

The initial build compiles FFmpeg 9.0.2 from a SHA-256-pinned archive. Minimum macOS is computed from every bundled library; another build host may produce another minimum. The Swift package's macOS 14 deployment target is not a compatibility claim for the complete media bundle.

Tests use prepared copies and real engines for declared routes, stale approvals, conflicts, cancellation, damaged input, Undo and crash recovery. [Validation report](docs/VALIDATION.md) (Russian).

## Current boundaries

Local APFS files are supported. Symlinks, hard links, cloud placeholders, external and network volumes are rejected. Full ACL, xattr and Finder tag restoration is not promised. Hardware power loss, true whole-disk ENOSPC and every VFR/HDR/multichannel profile have not been tested. Full rescans of very large folder trees remain costly.

PDF/Office, archives, JPEG XL and more audio codecs are candidates, not current supported routes. No app licensing service, trial or automatic updater is included. [Origins](docs/ORIGINS.md) · [Contributing](CONTRIBUTING.md).

## License

**GPL-2.0-or-later.** © 2026 [Mizzzord](https://github.com/Mizzzord). Provided without warranty.

The release uses FFmpeg and x264 under GPL-2.0-or-later; other libraries retain their licenses. Matching third-party source archives and build recipes accompany binary releases. [Third-party notices and source](docs/THIRD_PARTY.md).

<div align="center">

If Renamorph helps you, a ⭐ helps others discover it.

</div>

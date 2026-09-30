# Renamorph 0.4.1 — release validation

30 September 2026. macOS 27.0 (26A428), Apple Silicon arm64, internal APFS, Swift 6.4 / Apple CLT / SDK 27.0. This binary requires macOS 27.0 according to its bundled Mach-O libraries. Intel and earlier systems were not tested.

## Rebrand and state compatibility

The app, executable, worker, Swift modules, menus and window now use Renamorph. Bundle identifier: `local.consulmac.app` (stable across the rebrand). Version: 0.4.1. The existing icon is retained, with all ten macOS .icns representations.

A new data-directory policy keeps an existing ConsulMAC profile when no Renamorph profile exists. It leaves originals and history in place. A new regression test checks fresh installation, legacy profile reuse, preservation of saved bytes and precedence of an existing Renamorph profile. The existing exclusive state lock continues to prevent two coordinators from using one profile.

In the actual UI, the old app had no queued/running jobs before it was closed. Renamorph opened the existing profile, displayed the saved successful operation, the renamed window/sidebar and the packaged FFmpeg 9.0.2 engine with the expanded route list. User codec/rule settings and original files were not changed. The 0.4.0 identifier change caused the legacy-profile startup to remain at FSEventStreamCreate/open. This was confirmed by a process sample; it was not an observed full scan. Version 0.4.1 retains the application's original identifier to preserve update identity. System permission settings are not changed. The screen became locked during this final compatibility check, so the 0.4.1 UI check could not be performed. The final worker/FFmpeg/ffprobe bytes match the tested 0.4.0 assets; the main executable also matches after removing only code signatures from comparison copies. These comparisons do not confirm runtime folder access.

## Tests

```bash
RENAMORPH_WORKER="$PWD/dist/Renamorph.app/Contents/Helpers/RenamorphWorker" \
RENAMORPH_MEDIA_BIN="$PWD/dist/Renamorph.app/Contents/Helpers/Media" \
bash scripts/test.sh
```

**47 tests passed, 0 issues, 34.659 seconds.** [Sanitized full log](validation/tests-0.4-release.log).

The real 0.4.0 packaged worker and media engine were used for all 264 routes. Version 0.4.1 changes only release metadata and documentation; its Swift/engine implementation is unchanged. Tests cover content recognition despite misleading extensions, preserved transparency, decoded PCM equivalence for CAF/WavPack/ALAC, subtitle semantics, input changes, conflicts, permissions/quota, cancellation of process groups, timeout, damaged input, journaled publication, SIGKILL recovery and exact-byte Undo. The new profile compatibility test is in addition to the previous 46 tests. Synthetic/disposable files are used for destructive scenarios.

Python compilation, shell syntax, plist validation and ad-hoc signature verification passed. There is no claim that signing alone proves runtime or UI correctness.

## Release packaging and corresponding source

Assets: ZIP containing `Renamorph.app`, compressed DMG containing the same app and an Applications link, separate third-party source archive, and SHA256SUMS.

The source kit has ten exact components: FFmpeg 9.0.2 plus the nine installed library formulas. Archive SHA-256 values are checked; x264 is fetched from its official repository at the pinned 40-character revision. Installed formulas, inline patches, receipts, FFmpeg configuration, licenses and the packaging/build scripts accompany the source archives. The kit and binaries are offered on the same GitHub release page.

ZIP and DMG contents are verified separately after extraction/mounting; the relocated packaged engine is checked without Homebrew library paths. Source-kit checksums are verified after extraction. Raw local build logs and test fixtures are not uploaded to the code repository; retained evidence logs have local home/workspace paths sanitized. The supplied Consul research document is excluded from publication.

## Scope and limitations

The conversion implementation and 29-format / 264-route matrix are unchanged from the validated 0.3 engine. [Full matrix](FORMATS.md), [previous safety report and measured performance](VALIDATION-0.3.md). Earlier speed measurements are retained as earlier measurements, not a new benchmark of this renamed release.

This is a public preview with ad-hoc signing, without Developer ID notarization. Downloaded Gatekeeper behavior on a separate Mac is not tested. The installer has one verified architecture; an Intel asset is not fabricated.

Only supported local APFS scenarios are claimed. External/network/non-APFS volumes, symlinks, hard links and placeholders are rejected. Real whole-disk ENOSPC, hardware power loss, every VFR/HDR/multichannel variant, TCC revocation, kernel dropped events and all window scales were not tested. Multiple output publication is sequential with recovery evidence, not atomic. Original bytes are recoverable in supported scenarios; full metadata preservation is not claimed. Licensing/trial/update services are absent.

The app UI is currently Russian. The repository README and profile project entries are available in Russian, English and Spanish.

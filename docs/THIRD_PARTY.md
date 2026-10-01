# Third-party software and corresponding source

Renamorph source and artwork: **GPL-2.0-or-later**, copyright 2026 Mizzzord. Apple frameworks are supplied by macOS and are not redistributed in this project.

The downloadable application includes a separate FFmpeg/ffprobe toolchain built with `--enable-gpl`, without `--enable-nonfree`. This FFmpeg build and x264 are **GPL-2.0-or-later**. The Swift application communicates with these tools through worker processes; this is not a sandbox claim.

Every binary release is accompanied on the same GitHub release by `Renamorph-<version>-third-party-sources.tar.gz`. It includes the exact upstream versions/revisions, source archives, SHA-256 manifest, installed Homebrew formulas (including inline patches), installation receipts, FFmpeg configure data and project packaging/build scripts. Source is provided directly, rather than only offered by a third-party URL.

| Component in 0.4.2 | Version / revision | License |
| --- | --- | --- |
| FFmpeg / ffprobe | 9.0.2 | GPL-2.0-or-later for this configured build |
| x264 | r3222 / b35605ace3ddf7c1a5d67a2eb553f034aef41d55 | GPL-2.0-or-later |
| LAME | 4.0 | LGPL-2.0-or-later |
| mpg123 | 1.33.7 | LGPL-2.1-only |
| Ogg | 1.3.6 | BSD-3-Clause |
| Vorbis | 1.3.7 | BSD-3-Clause |
| Opus | 1.6.1 | BSD-3-Clause |
| libvpx | 1.17.0, Homebrew macOS target patch | BSD-3-Clause |
| WebP / SharpYUV | 1.6.0 | BSD-3-Clause |
| dav1d | 1.5.4 | BSD-2-Clause |

The application contains preserved notices under `Contents/Resources/ThirdParty`. Runtime file hashes and versions are recorded in its `manifest.json`; the media capability registry is verified against the packaged executable hashes.

Source kit generation: `python3 scripts/package-sources.py dist/Renamorph.app 0.4.2`. Native tools and system zlib/bzip2 are part of the macOS toolchain; no Apple SDK files are included. The source kit explains the build environment and library relocation/stripping. Rebuilding on another host may produce different bytes and can raise the resulting minimum macOS version.

References: [FFmpeg licensing](https://ffmpeg.org/legal.html), [x264](https://www.videolan.org/developers/x264.html), and the upstream license texts included in each source archive. Multimedia codec patent rules vary by jurisdiction; the project does not claim patent clearance.

# Origins

Renamorph is an independent macOS application built around a simple interaction: changing a known file’s extension requests a local conversion. File contents determine the source format; the extension describes the desired output.

The initial functional brief referred to Consul. Renamorph does not contain Consul source code, is not affiliated with its authors and does not claim to reproduce its internal implementation or complete format matrix. The supplied research document remains local and is not redistributed in this repository.

Swift, AppKit/SwiftUI, FSEvents, ImageIO, the worker protocol and journaled APFS publication are implementation choices made for this project. Source requirements and unverified reconstruction hypotheses are not treated as equivalent evidence.

The project was previously called ConsulMAC during development. Renamorph keeps existing state and original backups in the legacy `~/Library/Application Support/ConsulMAC` directory when that profile exists and no Renamorph profile exists. New installations use `~/Library/Application Support/Renamorph`. No originals are moved or deleted during this transition; an exclusive profile lock prevents concurrent coordinators.

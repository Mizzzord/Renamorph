#!/usr/bin/env python3
"""Package the exact source versions and recipes of the bundled media engine."""
import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import tarfile
import urllib.parse

parser = argparse.ArgumentParser()
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('version')
args = parser.parse_args()
if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
    parser.error('version must be a numeric release version')
root = pathlib.Path(__file__).resolve().parent.parent
notices = args.app.resolve() / 'Contents/Resources/ThirdParty'
manifest = json.loads((notices / 'manifest.json').read_text())
kit = root / '.build/source-kit' / ('Renamorph-' + args.version + '-third-party-sources')
archives = kit / 'upstream'
archives.mkdir(parents=True, exist_ok=True)
shutil.copytree(notices, kit / 'notices-and-recipes', dirs_exist_ok=True)
for name in ('LICENSE', 'NOTICE'):
    shutil.copy2(root / name, kit / name)
recipes = kit / 'renamorph-build-scripts'
recipes.mkdir(exist_ok=True)
for name in ('build-media.sh', 'bundle-media.py', 'package-sources.py'):
    shutil.copy2(root / 'scripts' / name, recipes / name)
entries = []

def download(name, version, url, digest):
    filename = pathlib.Path(urllib.parse.urlparse(url).path).name
    if not filename or filename == 'download':
        raise RuntimeError('Source URL does not contain an archive name: ' + url)
    destination = archives / (name + '-' + filename)
    if not destination.exists() or hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
        temporary = destination.with_suffix(destination.suffix + '.download')
        subprocess.run(['curl', '--fail', '--location', '--retry', '2', '--connect-timeout', '20', '--max-time', '300', '--proto', '=https', '--tlsv1.2', '--silent', '--show-error', url, '-o', str(temporary)], check=True)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != digest:
            raise RuntimeError('Source checksum mismatch: ' + name)
        temporary.replace(destination)
    print('Verified source:', name, version, flush=True)
    return {'name': name, 'version': version, 'upstream': url, 'sha256': digest, 'archive': str(destination.relative_to(kit))}

jobs = []
ffmpeg = manifest['sourceBuild']
jobs.append(('ffmpeg', ffmpeg['version'], ffmpeg['source'], ffmpeg['archiveSHA256']))
git_sources = []
for formula in manifest['formulas']:
    recipe = notices / formula['name'] / '.brew' / (formula['name'] + '.rb')
    text = recipe.read_text()
    url = re.search(r'^  url "([^"]+)"', text, re.M).group(1)
    if url.endswith('.git'):
        revision = re.search(r'revision: "([a-f0-9]{40})"', text).group(1)
        git_sources.append((formula, url, revision))
    else:
        digest = re.search(r'^  sha256 "([a-f0-9]{64})"', text, re.M).group(1)
        jobs.append((formula['name'], formula['version'], url, digest))
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    for result in pool.map(lambda job: download(*job), jobs):
        entries.append(result)
for formula, url, revision in git_sources:
    checkout = root / '.build/source-checkouts' / formula['name']
    if not (checkout / '.git').exists():
        checkout.mkdir(parents=True, exist_ok=True)
        subprocess.run(['git', 'init', str(checkout)], check=True, stdout=subprocess.DEVNULL)
    cached = subprocess.run(['git', '-C', str(checkout), 'cat-file', '-e', revision + '^{commit}'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if cached.returncode != 0:
        subprocess.run(['git', '-C', str(checkout), 'fetch', '--depth=1', url, revision], check=True, timeout=120)
    actual = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', revision + '^{commit}'], text=True).strip()
    if actual != revision:
        raise RuntimeError('Source git revision mismatch: ' + formula['name'])
    destination = archives / (formula['name'] + '-' + revision + '.tar.gz')
    subprocess.run(['git', '-C', str(checkout), 'archive', '--format=tar.gz', '--prefix=' + formula['name'] + '-' + revision + '/', '--output=' + str(destination), revision], check=True)
    entries.append({'name': formula['name'], 'version': formula['version'], 'upstream': url, 'revision': revision, 'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(), 'archive': str(destination.relative_to(kit))})
    print('Verified source revision:', formula['name'], revision, flush=True)
entries.sort(key=lambda item: item['name'])
(kit / 'sources.json').write_text(json.dumps(entries, indent=2) + '\n')
(kit / 'SHA256SUMS').write_text(''.join(item['sha256'] + '  ' + item['archive'] + '\n' for item in entries))
(kit / 'README.md').write_text('''# Renamorph corresponding third-party source

This kit accompanies the Renamorph binary release. `upstream/` contains the
exact upstream archive or git revision for each bundled component. Verify with
`shasum -a 256 -c SHA256SUMS`. `sources.json` records versions and origin URLs.
Upstream copyrights and license texts are inside the source archives and the
preserved application notices. FFmpeg and x264 in this build are GPL v2 or later.

`notices-and-recipes/` contains installed Homebrew formulas, inline patches and
installation receipts. These are the recipes used for the linked library
bottles. Apply each formula's inline patches and `inreplace` steps before its
install commands. The x264 git archive is the pinned formula revision; its
revision is explicitly recorded even when rebuilding without `.git` metadata.

Environment: macOS 27.0, Apple Silicon arm64, Apple CLT Swift 6.4 / SDK 27.0.
Homebrew build dependencies include pkgconf, meson/ninja where indicated by
the formulas, and the ordinary Apple C/C++ toolchain. System zlib and bzip2 are
macOS dependencies, not copies supplied by Renamorph.

`renamorph-build-scripts/build-media.sh` records the FFmpeg configure invocation.
The actual generated config is in `notices-and-recipes/ffmpeg-source/config.mak`.
FFmpeg sources were not patched. The libraries use the preserved Homebrew
recipes, including libvpx's macOS target patch and libvorbis/LAME build fixes.
No additional source changes were applied by Renamorph. `bundle-media.py`
records the post-build loader-path relocation, symbol stripping and ad-hoc
signing. These operations change binary metadata, not source code. Build paths
in generated configuration are descriptive and may be adapted to your machine.

Application source is separately published at https://github.com/Mizzzord/Renamorph
under GPL-2.0-or-later. Source kit and binary assets share the same release page.
''')
output = root / 'dist' / (kit.name + '.tar.gz')
with tarfile.open(output, 'w:gz') as archive:
    archive.add(kit, arcname=kit.name)
print(output, output.stat().st_size, 'bytes', flush=True)

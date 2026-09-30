#!/usr/bin/env python3
"""Copy the installed local FFmpeg toolchain with relocatable library references."""
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
candidates = [os.environ['RENAMORPH_MEDIA_BIN']] if 'RENAMORPH_MEDIA_BIN' in os.environ else [str(pathlib.Path(__file__).resolve().parent.parent / '.build/media/bin'), '/opt/homebrew/opt/ffmpeg-full/bin', '/usr/local/opt/ffmpeg-full/bin']
binary_dir = next((pathlib.Path(p) for p in candidates if all((pathlib.Path(p) / n).is_file() for n in ('ffmpeg', 'ffprobe'))), None)
if not binary_dir:
    sys.exit('FFmpeg full is required. Install it with: brew install ffmpeg-full')
media = app / 'Contents/Helpers/Media'
libs = media / 'lib'
notices = app / 'Contents/Resources/ThirdParty'
libs.mkdir(parents=True)
notices.mkdir(parents=True)
files = {}
references = {}
formulas = {}
minimum = (14, 0)

def output(*args):
    return subprocess.check_output(args, text=True)

def copy(source, destination):
    global minimum
    source = source.resolve()
    if source in files:
        return files[source]
    if destination.exists():
        raise RuntimeError(f'Library name collision: {destination}')
    shutil.copy2(source, destination)
    os.chmod(destination, 0o755)
    files[source] = destination
    load_commands = output('otool', '-l', str(source))
    versions = re.findall(r'\bminos (\d+(?:\.\d+)+)', load_commands)
    for version in versions:
        minimum = max(minimum, tuple(map(int, version.split('.'))))
    if '/Cellar/' in str(source):
        head, tail = str(source).split('/Cellar/', 1)
        formula, version = tail.split('/')[:2]
        formulas[formula] = pathlib.Path(head) / 'Cellar' / formula / version
    dependencies = []
    for line in output('otool', '-L', str(source)).splitlines()[1:]:
        name = line.strip().split(' (compatibility')[0]
        if name.startswith(('/System/', '/usr/lib/')):
            continue
        if name.startswith('@loader_path/'):
            dependency = source.parent / name.removeprefix('@loader_path/')
        elif name.startswith('@rpath/'):
            rpaths = re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset', load_commands)
            choices = [pathlib.Path(p.replace('@loader_path', str(source.parent))) / name.removeprefix('@rpath/') for p in rpaths]
            dependency = next((p for p in choices if p.exists()), None)
            if dependency is None:
                raise RuntimeError(f'Unresolved dependency {name} in {source}')
        else:
            dependency = pathlib.Path(name)
        dependency = dependency.resolve()
        if dependency == source:
            continue
        target = copy(dependency, libs / dependency.name)
        dependencies.append((name, target))
    references[destination] = dependencies
    return destination

for name in ('ffmpeg', 'ffprobe'):
    copy(binary_dir / name, media / name)
for destination, dependencies in references.items():
    subprocess.run(['codesign', '--remove-signature', str(destination)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    changes = []
    if destination.parent == libs:
        changes += ['-id', '@loader_path/' + destination.name]
    for original, target in dependencies:
        relative = os.path.relpath(target, destination.parent)
        changes += ['-change', original, '@loader_path/' + relative]
    if changes:
        subprocess.run(['install_name_tool', *changes, str(destination)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['strip', '-S', '-x', str(destination)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(destination)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

manifest = {'ffmpeg': output(str(media / 'ffmpeg'), '-version').splitlines()[0], 'minimumOS': '.'.join(map(str, minimum)), 'architecture': output('uname', '-m').strip(), 'files': [], 'formulas': []}
vendor = binary_dir.parent / 'share/renamorph'
if not vendor.exists():
    vendor = binary_dir.parent / 'share/consul'
if vendor.exists():
    shutil.copytree(vendor, notices / 'ffmpeg-source')
    manifest['sourceBuild'] = json.loads((vendor / 'source.json').read_text())
listing = output(str(media / 'ffmpeg'), '-hide_banner', '-encoders')
encoders = [fields[1] for line in listing.splitlines() if len(fields := line.split()) >= 2 and len(fields[0]) == 6]
listing = output(str(media / 'ffmpeg'), '-hide_banner', '-decoders')
decoders = [fields[1] for line in listing.splitlines() if len(fields := line.split()) >= 2 and len(fields[0]) == 6]
capabilities = {'version': manifest['ffmpeg'], 'encoders': encoders, 'decoders': decoders, 'binaries': {name: hashlib.sha256((media / name).read_bytes()).hexdigest() for name in ('ffmpeg', 'ffprobe')}}
(app / 'Contents/Resources/MediaCapabilities.json').write_text(json.dumps(capabilities, indent=2))
for original, destination in files.items():
    manifest['files'].append({'path': str(destination.relative_to(app)), 'sha256': hashlib.sha256(destination.read_bytes()).hexdigest()})
for formula, prefix in sorted(formulas.items()):
    destination = notices / formula
    destination.mkdir()
    receipt = prefix / 'INSTALL_RECEIPT.json'
    if receipt.exists():
        shutil.copy2(receipt, destination)
    for file in prefix.rglob('*'):
        if file.is_file() and (file.name.upper().startswith(('COPYING', 'LICENSE', 'LICENCE', 'NOTICE')) or file.parent.name == '.brew'):
            target = destination / file.relative_to(prefix)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, target)
    manifest['formulas'].append({'name': formula, 'version': prefix.name, 'source': f'https://formulae.brew.sh/formula/{formula}'})
(notices / 'manifest.json').write_text(json.dumps(manifest, indent=2))
(notices / 'README.txt').write_text('Renamorph contains FFmpeg and x264 under GPL-2.0-or-later, plus linked libraries under their preserved licenses. FFmpeg configuration and license: run Contents/Helpers/Media/ffmpeg -L and -version. Exact corresponding third-party sources and build recipes accompany the binary release at https://github.com/Mizzzord/Renamorph/releases. See manifest.json, vendor notices and installed Homebrew recipes in this directory.\n')
plist = app / 'Contents/Info.plist'
with plist.open('rb') as f:
    info = plistlib.load(f)
info['LSMinimumSystemVersion'] = manifest['minimumOS']
with plist.open('wb') as f:
    plistlib.dump(info, f)
for tool in ('ffmpeg', 'ffprobe'):
    subprocess.run([str(media / tool), '-version'], check=True, stdout=subprocess.DEVNULL)
print(f'Bundled {len(files)} Mach-O files; macOS {manifest["minimumOS"]}+; {manifest["ffmpeg"]}')

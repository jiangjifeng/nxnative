#!/usr/bin/env python3
"""Package prepared game files and a Mac host into a self-contained .app."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'dm/games'))
import game


def clone(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['cp', '-cR', str(source), str(destination)], check=True)


def icon(source, destination, work):
    if not source.is_file():
        return False
    with tempfile.TemporaryDirectory(prefix='mac-icon-', dir=work / 'build') as temporary:
        iconset = Path(temporary) / 'Game.iconset'
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
                subprocess.run(['sips', '-s', 'format', 'png', '-z', str(size * scale), str(size * scale), str(source), '--out', str(iconset / name)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(destination)], check=True)
    return True


def package(args):
    work, output = args.work.expanduser().resolve(), args.output.expanduser().resolve()
    if work.is_relative_to(REPO) or output.is_relative_to(REPO):
        raise ValueError('Keep game files and app bundles outside the source repository.')
    if output.suffix != '.app':
        raise ValueError('The output path must end in .app.')
    if output.exists() and not args.replace:
        raise ValueError('The app already exists; use --replace to keep a backup and replace it.')
    manifest_path = work / 'build/macos_build.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    previous_info = plistlib.loads((output / 'Contents/Info.plist').read_bytes()) if output.exists() else {}
    selected = args.profile
    if not selected and manifest.get('title_id'):
        local = work / 'profile' / manifest['title_id']
        selected = local if local.is_dir() else REPO / 'dm/games' / manifest['title_id']
    profile = game.load(str(selected) if selected else None)
    title = profile.id
    if not re.fullmatch(r'[0-9A-Fa-f]{16}', title):
        raise ValueError('The profile directory must be a base game title ID.')
    if manifest.get('title_id', title) != title:
        raise ValueError('The game profile and build manifest name different title IDs.')
    language = args.language or previous_info.get('DMGameDefaultLanguage') or manifest.get('language') or 'en'
    name = args.name or previous_info.get('CFBundleDisplayName') or profile.get('name')
    version = args.package or manifest.get('package') or profile.get('package')
    if version not in profile.builds():
        raise ValueError(f'No known module builds for package {version}.')
    header = re.search(r'#define DMSH_CHAIN "([0-9a-f]+)"', profile.table('dmsh_chain.h').read_text())
    if not header:
        raise ValueError('The profile has no generated translation chain header.')
    if manifest.get('chain', header.group(1)) != header.group(1):
        raise ValueError('The build manifest and profile have different translation chains.')
    manifest.update(title_id=title, package=version, chain=header.group(1), display_version=profile.builds()[version]['display'])
    source = work / 'data' / version
    patched = work / 'build' / ('patched_' + version)
    host = args.host or (work / 'build/dmhost' if (work / 'build/dmhost').exists() else REPO / 'dm/host/dmhost')
    cache = (args.cache or work / 'build/cache/metal_shader_cache') / ('b-' + manifest['chain'])
    if manifest['chain'].encode() + b'\0' not in host.read_bytes():
        raise ValueError('Rebuild the Mac host for this profile and translation chain before packaging.')
    for module in profile.words('modules'):
        for suffix in ('.patched.bin', '.fixups.tsv'):
            if not (patched / (module + suffix)).is_file():
                raise ValueError(f'Missing rewritten module: {module}{suffix}')
    report = json.loads((cache / '_b_build.json').read_text())
    expected = {line.split('\t')[3] for line in profile.table('shader_map.tsv').read_text().splitlines() if line and not line.startswith(('#', 'package'))}
    if {row['key'] for row in report} != expected or any(row['st'] != 'ok' for row in report):
        raise ValueError('The shader build is incomplete.')
    manifest.update(shader_total=len(expected), shaders={'ok': len(expected)})
    # Refuse a live replacement; the native host retains this lock for its lifetime.
    lock = None
    lock_path = Path.home() / 'Library/Application Support/nxnative' / title / 'run/game.lock'
    if output.exists() and lock_path.exists():
        lock = lock_path.open('r+')
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            lock.close()
            raise ValueError('Close the running game before replacing its app.')
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = output.with_name(f'.{output.stem}.build-{os.getpid()}.app')
    if stage.exists():
        raise ValueError(f'A previous packaging directory remains: {stage}')
    mac = stage / 'Contents/MacOS'
    resources = stage / 'Contents/Resources'
    assets = resources / 'game'
    mac.mkdir(parents=True)
    assets.mkdir(parents=True)
    try:
        for src, dst in ((source / 'RomFS', assets / 'romfs'), (patched, assets / 'patched'),
                         (profile.dir, assets / 'profile'), (work / 'build/font', assets / 'font'),
                         (cache, assets / 'metal_shader_cache' / cache.name)):
            print('Bundling', src, flush=True)
            clone(src, dst)
        if (work / 'data/aoc').is_dir():
            clone(work / 'data/aoc', assets / 'aoc')
        standard = Path('/System/Library/Fonts/Supplemental/Arial Unicode.ttf')
        if not (assets / 'font/standard.ttf').exists():
            clone(standard, assets / 'font/standard.ttf')
        for path in (assets / 'metal_shader_cache' / cache.name).iterdir():
            if '.tmp-' in path.name:
                path.unlink()
        shutil.copy2(host, mac / 'dmhost')
        build = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(host)], text=True)
        minimum = re.search(r'\bminos\s+([0-9.]+)', build)
        info = dict(CFBundleExecutable='dmhost', CFBundleIdentifier=f'org.nxnative.{title.lower()}.macos',
                    CFBundleName=name, CFBundleDisplayName=name,
                    CFBundlePackageType='APPL', CFBundleShortVersionString=manifest['display_version'],
                    CFBundleVersion=version.removeprefix('v'), LSMinimumSystemVersion=minimum.group(1) if minimum else '26.0',
                    LSApplicationCategoryType=profile.get('app_category', 'public.app-category.games'),
                    NSHighResolutionCapable=True, NSPrincipalClass='NSApplication',
                    DMGameTitleID=title, DMGameRomfsMarker=profile.get('romfs_marker'), DMGameDefaultLanguage=language)
        if icon(source / 'icon.jpg', resources / 'Game.icns', work):
            info['CFBundleIconFile'] = 'Game.icns'
        with (stage / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump(info, stream)
        (stage / 'Contents/PkgInfo').write_bytes(b'APPL????')
        manifest.update(host_sha256=hashlib.sha256(host.read_bytes()).hexdigest(), language=language)
        (resources / 'macos_build.json').write_text(json.dumps(manifest, indent=2) + '\n')
        licenses = resources / 'licenses'
        licenses.mkdir()
        shutil.copy2(REPO / 'LICENSE', licenses / 'nxnative-LICENSE.txt')
        third_party = REPO / 'dm/third_party'
        for path in third_party.rglob('*'):
            if path.is_file() and any(word in path.name.upper() for word in ('LICENSE', 'COPYING', 'COPYRIGHT')):
                destination = licenses / path.relative_to(third_party)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, destination)
        if any(path.is_symlink() for path in stage.rglob('*')):
            raise ValueError('The app must contain its assets without external symlinks.')
        backup = None
        if output.exists():
            stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
            backup = work / 'build/app_backups' / stamp / output.name
            backup.parent.mkdir(parents=True)
            output.rename(backup)
        try:
            stage.rename(output)
        except Exception:
            if backup is not None:
                backup.rename(output)
            raise
        print('App:', output)
        print('Saves:', Path.home() / 'Library/Application Support/nxnative' / title / 'save')
    finally:
        if lock is not None:
            lock.close()
        if stage.exists():
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('work', type=Path, help='Prepared game work directory; build/macos_build.json is optional')
    parser.add_argument('output', type=Path, help='Destination .app; all game resources are bundled')
    parser.add_argument('--profile', type=Path, help='Override the local or repository game profile')
    parser.add_argument('--package', help='Version directory, such as v1114112; defaults to the build manifest or profile')
    parser.add_argument('--host', type=Path, help='Mac host built for the selected profile')
    parser.add_argument('--cache', type=Path, help='Shader cache root; defaults to <work>/build/cache/metal_shader_cache')
    parser.add_argument('--name', help='App display name')
    parser.add_argument('--language', help='Default game language, such as zh-Hans; preserves an existing app setting')
    parser.add_argument('--replace', action='store_true', help='Move the previous app into the work directory before replacing it')
    try:
        package(parser.parse_args())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Packaging failed: {error}\n')


if __name__ == '__main__':
    main()

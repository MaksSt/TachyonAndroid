"""Prepare unmodified official native artifacts for a private local Android build."""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

from native_elf import inspect_android_elf

root = Path(__file__).resolve().parents[1]
local = root / '.local'
local.mkdir(exist_ok=True)

def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path]))

def asset_file(repo, release, name, destination):
    matches = [asset for asset in release['assets'] if asset['name'] == name]
    if len(matches) != 1:
        raise RuntimeError('No unique official asset: ' + name)
    asset = matches[0]
    digest = asset.get('digest', '')
    if not digest.startswith('sha256:') or len(digest) != 71:
        raise RuntimeError('Missing official SHA-256: ' + name)
    destination.parent.mkdir(parents=True, exist_ok=True)
    expected = digest.removeprefix('sha256:')
    def verified():
        return destination.exists() and destination.stat().st_size == asset['size'] and hashlib.sha256(destination.read_bytes()).hexdigest() == expected
    if not verified():
        url = asset['browser_download_url']
        if not url.startswith('https://github.com/' + repo + '/releases/download/'):
            raise RuntimeError('Unexpected official release URL')
        subprocess.run(['curl.exe', '--fail', '--location', '--silent', '--show-error', '--connect-timeout', '15', '--max-time', '180', '--output', str(destination), url], check=True)
    if not verified():
        raise RuntimeError('Official asset verification failed: ' + name)
    return expected

release = api('repos/Dushnilin/tachyon-core/releases/latest')
version = release['tag_name']
proof = {'version': version, 'source': release['html_url'], 'artifacts': []}
prepared_binaries = []
for abi, arch, machine in [('arm64-v8a', 'aarch64', 183), ('x86_64', 'x86_64', 62)]:
    target_triple = f'{arch}-linux-android'
    name = f'tachyon-core-{target_triple}-{version}.tar.gz'
    archive = local / 'core' / name
    checksum = asset_file('Dushnilin/tachyon-core', release, name, archive)
    with tarfile.open(archive) as bundle:
        matches = [entry for entry in bundle if entry.isfile() and Path(entry.name).name in {'tachyon-core', f'tachyon-core-{target_triple}-{version}'}]
        if len(matches) != 1 or matches[0].size > 128 * 1024 * 1024:
            raise RuntimeError('Unexpected native archive contents')
        binary = bundle.extractfile(matches[0]).read()
    elf = inspect_android_elf(binary, machine)
    target = root / 'android/app/src/main/jniLibs' / abi / 'libtachyon.so'
    prepared_binaries.append((target, binary))
    proof['artifacts'].append({'abi': abi, 'target': target_triple, 'asset': name,
                              'archive_sha256': checksum, 'binary_sha256': hashlib.sha256(binary).hexdigest(), **elf})

bridge = api('repos/heiher/hev-socks5-tunnel/releases/tags/2.19.3')
proof['packet_bridge_sha256'] = asset_file('heiher/hev-socks5-tunnel', bridge, 'hev-socks5-tunnel.aar', local / 'hev-socks5-tunnel.aar')
for target, binary in prepared_binaries:
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(binary)
assets = root / 'android/app/src/main/assets'
assets.mkdir(parents=True, exist_ok=True)
(assets / 'core-manifest.json').write_text(json.dumps(proof, indent=2) + '\n', encoding='utf-8')
(local / 'native-verification.json').write_text(json.dumps(proof, indent=2) + '\n', encoding='utf-8')
print(json.dumps(proof, indent=2))

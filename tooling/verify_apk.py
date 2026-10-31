"""Verify that an APK contains the prepared core and packet bridge unchanged."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

from native_elf import inspect_android_elf

parser = argparse.ArgumentParser()
parser.add_argument('apk', type=Path)
parser.add_argument('--abi', action='append', choices=['arm64-v8a', 'x86_64'])
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
prepared = json.loads((root / '.local/native-verification.json').read_text(encoding='utf-8'))
verified = []
with zipfile.ZipFile(args.apk) as package, zipfile.ZipFile(root / '.local/hev-socks5-tunnel.aar') as bridge:
    available_abis = {artifact['abi'] for artifact in prepared['artifacts']}
    expected_abis = set(args.abi) if args.abi else available_abis
    if not expected_abis <= available_abis:
        raise RuntimeError('Requested ABI was not prepared')
    packaged_abis = {name.split('/')[1] for name in package.namelist() if name.startswith('lib/') and name.endswith('.so')}
    if packaged_abis != expected_abis:
        raise RuntimeError(f'Unexpected APK ABIs: {packaged_abis}, expected {expected_abis}')
    for artifact in prepared['artifacts']:
        abi = artifact['abi']
        if abi not in expected_abis:
            continue
        path = f'lib/{abi}/libtachyon.so'
        package.getinfo(f'lib/{abi}/libflutter.so')
        binary = package.read(path)
        elf = inspect_android_elf(binary, {'arm64-v8a': 183, 'x86_64': 62}[abi])
        digest = hashlib.sha256(binary).hexdigest()
        if digest != artifact['binary_sha256']:
            raise RuntimeError('Core bytes changed: ' + abi)
        libraries = [name for name in bridge.namelist() if name.startswith(f'jni/{abi}/') and name.endswith('.so')]
        if not libraries:
            raise RuntimeError('Packet bridge is missing ABI: ' + abi)
        for name in libraries:
            installed = package.read('lib/' + name.removeprefix('jni/'))
            if installed != bridge.read(name):
                raise RuntimeError('Packet bridge bytes changed: ' + name)
        verified.append({'abi': abi, 'core_sha256': digest, 'bridge_libraries': len(libraries), **elf})
    bundled = json.loads(package.read('assets/core-manifest.json'))
    if bundled != prepared:
        raise RuntimeError('Packaged core manifest differs from prepared artifacts')

with args.apk.open('rb') as artifact:
    apk_digest = hashlib.file_digest(artifact, 'sha256').hexdigest()
proof = {
    'apk': str(args.apk.resolve()),
    'apk_sha256': apk_digest,
    'apk_size': args.apk.stat().st_size,
    'core_version': prepared['version'],
    'verified': verified,
    'artifact_verified': True,
    'vpn_verified': False,
}
(root / '.local/apk-verification.json').write_text(json.dumps(proof, indent=2) + '\n', encoding='utf-8')
print(json.dumps(proof, indent=2))

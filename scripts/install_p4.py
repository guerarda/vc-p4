#!/usr/bin/env python3
"""Install checksum-pinned test binaries into .tools (macOS ARM64 only).

Hashes from Perforce's r24.2 SHA256SUMS, retrieved 2026-10-20. Downloads are
never installed globally. Other platforms can supply their own p4/p4d paths.
"""
import hashlib
from pathlib import Path
import platform
import subprocess
import urllib.request

BASE = 'https://ftp.perforce.com/perforce/r24.2/bin.macosx12arm64/'
HASHES = {
    'p4': '6b6d901da39d9d59544072f88842b6567da87619748558617fe4aef43a735cfc',
    'p4d': 'bcb9b1eda49b6069a11f19b573d582daf770dfe64347013b73922c174190ae9e',
}


def main():
    if (platform.system(), platform.machine()) != ('Darwin', 'arm64'):
        raise SystemExit('Supply native p4/p4d binaries; this installer targets macOS ARM64.')
    target = Path(__file__).resolve().parent.parent / '.tools'
    target.mkdir(exist_ok=True)
    for name, expected in HASHES.items():
        path = target / name
        data = path.read_bytes() if path.exists() else b''
        if hashlib.sha256(data).hexdigest() != expected:
            with urllib.request.urlopen(BASE + name, timeout=60) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != expected:
                raise SystemExit(f'{name}: checksum mismatch; review upstream release before updating pins')
            staged = target / (name + '.download')
            staged.write_bytes(data)
            staged.chmod(0o755)
            staged.replace(path)
        subprocess.run([str(path), '-V'], check=True)


if __name__ == '__main__':
    main()

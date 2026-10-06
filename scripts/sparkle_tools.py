"""Fetch a pinned official Sparkle distribution; signing keys stay in Keychain."""
import hashlib
from pathlib import Path
import tarfile
import urllib.request

VERSION = '2.10.0'
DIGEST = 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c'
ACCOUNT = 'circuitstudio-release'

def tools_directory():
    cache = Path.home() / 'Library/Caches/CircuitStudio/Sparkle' / VERSION
    if (cache / 'bin/sign_update').exists():
        return cache / 'bin'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / 'distribution.tar.xz'
    urllib.request.urlretrieve(f'https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/Sparkle-{VERSION}.tar.xz', archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != DIGEST:
        raise RuntimeError('The Sparkle tool archive checksum did not match the pinned release')
    with tarfile.open(archive) as bundle:
        bundle.extractall(cache, filter='tar')
    archive.unlink()
    return cache / 'bin'

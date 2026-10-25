#!/usr/bin/env python3
"""Pull reviewed static site files. Never execute downloaded repository code."""
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import urllib.request

SOURCE = 'https://raw.githubusercontent.com/ln71v/kombain/site-vaska-de-gamma'
TARGET = Path('/usr/local/share/kombain-site/www')
STATE = Path('/var/lib/vaska-site-sync')
MAX_FILE = 12 * 1024 * 1024


def download(url, limit=MAX_FILE):
    request = urllib.request.Request(url, headers={'User-Agent': 'VaskaSiteSync/1'})
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.geturl().split('/')[2] != 'raw.githubusercontent.com':
            raise ValueError('Unexpected download origin')
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError('Download is too large')
    return data


def digest(data):
    return hashlib.sha256(data).hexdigest()


def validate_manifest(data):
    manifest = json.loads(data)
    if not isinstance(manifest, dict) or manifest.get('version') != 1:
        raise ValueError('Unsupported manifest')
    files = manifest.get('files')
    if not isinstance(files, dict) or not 2 <= len(files) <= 32:
        raise ValueError('Invalid file list')
    if not {'index.html', 'favicon.svg'} <= files.keys():
        raise ValueError('Page and favicon are required')
    for name, checksum in files.items():
        if not isinstance(name, str) or not isinstance(checksum, str):
            raise ValueError('Invalid file entry')
        if not re.fullmatch(r'[0-9a-f]{64}', checksum):
            raise ValueError('Invalid checksum')
        if name not in ('index.html', 'favicon.svg', 'robots.txt'):
            match = re.fullmatch(r'assets/[a-z0-9-]+-([0-9a-f]{12})\.(png|jpg|webp|svg|css|js|woff2)', name)
            if not match or match[1] != checksum[:12]:
                raise ValueError('Only static assets with content hashes are allowed')
    return files


def check_destination(root, name):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unexpected site root')
    path = root / name
    for part in (path, *path.parents):
        if part == root.parent:
            break
        if part.is_symlink():
            raise ValueError('Symlinks in deployment paths are not supported')
    return path


def atomic_write(path, data, mode=0o644):
    if not path.parent.exists():
        path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        path.parent.chmod(0o755)
    fd, temporary = tempfile.mkstemp(prefix='.vaska-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
            os.fchmod(handle.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def synchronize(root=TARGET, state=STATE, fetch=download):
    files = validate_manifest(fetch(SOURCE + '/manifest.json', 65536))
    pending = {}
    for name, checksum in files.items():
        destination = check_destination(root, name)
        if destination.is_file() and digest(destination.read_bytes()) == checksum:
            continue
        data = fetch(SOURCE + '/site/' + name)
        if digest(data) != checksum:
            raise ValueError('Content checksum mismatch; current site retained')
        if name == 'index.html' and b'<!doctype html>' not in data[:100].lower():
            raise ValueError('Invalid HTML page')
        pending[name] = data
    if not pending:
        print('Site is up to date.')
        return False

    # All downloads are verified before changing any live files.
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    backups = state / 'backups'
    backups.mkdir(mode=0o700, exist_ok=True)
    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ-')
    backup = Path(tempfile.mkdtemp(prefix=timestamp, dir=backups))
    shutil.copytree(root, backup / 'www', symlinks=True)
    originals = {}
    written = []
    try:
        # Content-hashed assets first, entry HTML last. Old assets remain available.
        for name in sorted(pending, key=lambda name: (name == 'index.html', name)):
            destination = check_destination(root, name)
            originals[name] = (destination.read_bytes(), destination.stat().st_mode & 0o777) if destination.is_file() else None
            atomic_write(destination, pending[name])
            written.append(name)
    except Exception:
        for name in reversed(written):
            destination = root / name
            if originals[name] is None:
                destination.unlink(missing_ok=True)
            else:
                data, mode = originals[name]
                atomic_write(destination, data, mode)
        raise
    atomic_write(state / 'state.json', json.dumps({'files': files, 'backup': str(backup)}).encode(), 0o600)
    print('Site updated. Backup:', backup / 'www')
    return True


def main():
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (STATE / 'sync.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        try:
            synchronize()
        except Exception as error:
            print('Site sync failed:', error, file=sys.stderr)
            raise SystemExit(1)


if __name__ == '__main__':
    main()

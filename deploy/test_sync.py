import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('site_sync', Path(__file__).with_name('sync.py'))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'www'
        self.state = Path(self.tmp.name) / 'state'
        self.root.mkdir()
        (self.root / 'index.html').write_bytes(b'old page')
        (self.root / 'favicon.svg').write_bytes(b'old icon')
        self.asset = b'new photo'
        self.asset_name = 'assets/studio-' + sync.digest(self.asset)[:12] + '.png'
        self.content = {'index.html': b'<!doctype html><title>New</title>', 'favicon.svg': b'<svg/>', self.asset_name: self.asset}
        self.manifest = {'version': 1, 'files': {name: sync.digest(data) for name, data in self.content.items()}}

    def fetch(self, url, limit=None):
        if url.endswith('/manifest.json'):
            return json.dumps(self.manifest).encode()
        return self.content[url.split('/site/')[1]]

    def run_sync(self, fetch=None):
        return sync.synchronize(self.root, self.state, fetch or self.fetch)

    def assert_old_page(self):
        self.assertEqual((self.root / 'index.html').read_bytes(), b'old page')
        self.assertEqual((self.root / 'favicon.svg').read_bytes(), b'old icon')

    def test_publish_and_idempotence(self):
        self.assertTrue(self.run_sync())
        self.assertEqual((self.root / 'index.html').read_bytes(), self.content['index.html'])
        backups = list((self.state / 'backups').iterdir())
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'www/index.html').read_bytes(), b'old page')
        self.assertFalse(self.run_sync())
        self.assertEqual(len(list((self.state / 'backups').iterdir())), 1)

    def test_download_failure_keeps_site(self):
        def fail_after_manifest(url, limit=None):
            if url.endswith('/manifest.json'):
                return self.fetch(url, limit)
            raise OSError('offline')
        with self.assertRaises(OSError):
            self.run_sync(fail_after_manifest)
        self.assert_old_page()

    def test_checksum_failure_keeps_site(self):
        self.content[self.asset_name] = b'corrupt image'
        with self.assertRaises(ValueError):
            self.run_sync()
        self.assert_old_page()

    def test_reject_paths_and_nonstatic_files(self):
        for name in ('../Caddyfile', '/etc/passwd', 'assets/../../Caddyfile', 'Caddyfile', 'deploy/sync.py', 'assets/arbitrary.png'):
            with self.subTest(name=name):
                manifest = {'version': 1, 'files': {'index.html': '0' * 64, 'favicon.svg': '0' * 64, name: '0' * 64}}
                with self.assertRaises(ValueError):
                    sync.validate_manifest(json.dumps(manifest).encode())

    def test_reject_symlink(self):
        outside = Path(self.tmp.name) / 'outside'
        outside.mkdir()
        (self.root / 'assets').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.run_sync()
        self.assert_old_page()
        self.assertEqual(list(outside.iterdir()), [])

    def test_caddy_can_read_files_with_restrictive_umask(self):
        previous = os.umask(0o077)
        try:
            self.run_sync()
        finally:
            os.umask(previous)
        self.assertEqual((self.root / 'assets').stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.root / self.asset_name).stat().st_mode & 0o777, 0o644)
        self.assertEqual((self.root / 'index.html').stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)

    def test_failed_write_rolls_back(self):
        real_write = sync.atomic_write
        def fail_index(path, data, mode=0o644):
            if path == self.root / 'index.html':
                raise OSError('write failed')
            real_write(path, data, mode)
        with patch.object(sync, 'atomic_write', side_effect=fail_index):
            with self.assertRaises(OSError):
                self.run_sync()
        self.assert_old_page()
        self.assertFalse((self.root / self.asset_name).exists())

    def test_modified_live_file_is_restored(self):
        self.run_sync()
        (self.root / 'index.html').write_bytes(b'manual drift')
        self.assertTrue(self.run_sync())
        self.assertEqual((self.root / 'index.html').read_bytes(), self.content['index.html'])


if __name__ == '__main__':
    unittest.main()

import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "preview-cache.sh"


class PreviewCacheTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cache = self.root / "cache with spaces"
        self.cache.mkdir()
        self.dest = self.cache / "wallhaven-test.jpg"
        self.calls = self.root / "calls"
        binary = self.root / "dms"
        binary.write_text(
            '#!/bin/sh\n'
            'echo called >> "$TEST_CALLS"\n'
            'while [ "$#" -gt 0 ]; do\n'
            '  if [ "$1" = -o ]; then shift; output=$1; fi\n'
            '  shift\n'
            'done\n'
            'printf "%s" "${TEST_BODY-original}" > "$output"\n'
            'exit "${TEST_EXIT-0}"\n'
        )
        binary.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.root}:{os.environ['PATH']}", TEST_CALLS=str(self.calls))

    def run_cache(self, **env):
        return subprocess.run(
            ["sh", str(SCRIPT), str(self.dest), "https://w.wallhaven.cc/full/test.jpg", "test-agent", "30"],
            env=dict(self.env, **env), capture_output=True, text=True,
        )

    def old_file(self, path, body="old"):
        path.write_text(body)
        old = time.time() - 3600
        os.utime(path, (old, old))
        return path

    def test_download_is_complete_and_reused_without_network(self):
        self.assertEqual(self.run_cache().returncode, 0)
        self.assertEqual(self.dest.read_text(), "original")
        self.assertFalse(Path(f"{self.dest}.part").exists())
        self.assertEqual(self.run_cache().returncode, 0)
        self.assertEqual(self.calls.read_text().splitlines(), ["called"])

    def test_reuse_renews_disk_expiration_and_pruning_stays_in_cache(self):
        self.old_file(self.dest)
        stale = self.old_file(self.cache / "wallhaven-stale.png")
        unrelated = self.old_file(self.cache / "notes.txt")
        part = self.old_file(self.cache / "wallhaven-active.jpg.part")
        nested = self.cache / "nested"
        nested.mkdir()
        nested_file = self.old_file(nested / "wallhaven-nested.jpg")
        outside = self.old_file(self.root / "wallhaven-outside.jpg")
        before = time.time()
        self.assertEqual(self.run_cache().returncode, 0)
        self.assertGreaterEqual(self.dest.stat().st_mtime, before - 1)
        self.assertFalse(stale.exists())
        for preserved in [unrelated, part, nested_file, outside]:
            self.assertTrue(preserved.exists(), preserved)
        self.assertFalse(self.calls.exists())

    def test_failure_and_empty_download_leave_no_original_or_partial(self):
        for env in [dict(TEST_EXIT="1"), dict(TEST_BODY="")]:
            with self.subTest(env=env):
                self.assertEqual(self.run_cache(**env).returncode, 1)
                self.assertFalse(self.dest.exists())
                self.assertFalse(Path(f"{self.dest}.part").exists())

    def test_unsplash_previews_are_cached_and_both_providers_are_pruned(self):
        self.dest = self.cache / "unsplash-current.jpg"
        stale = [self.old_file(self.cache / name) for name in ["wallhaven-stale.jpg", "unsplash-stale.jpg"]]
        self.assertEqual(self.run_cache().returncode, 0)
        self.assertEqual(self.dest.read_text(), "original")
        self.assertEqual(self.run_cache().returncode, 0)
        self.assertEqual(self.calls.read_text().splitlines(), ["called"])
        for path in stale:
            self.assertFalse(path.exists())

    def test_arguments_are_not_executed_as_shell_code(self):
        self.dest = self.cache / "wallhaven-$(touch injected);quote'file.jpg"
        self.assertEqual(self.run_cache().returncode, 0)
        self.assertEqual(self.dest.read_text(), "original")
        self.assertFalse((Path.cwd() / "injected").exists())

    def test_invalid_arguments_fail_before_touching_cache(self):
        for args in [[], [str(self.dest), "url", "agent", "-1"], [str(self.dest), "url", "agent", "0"]]:
            with self.subTest(args=args):
                result = subprocess.run(["sh", str(SCRIPT), *args], capture_output=True)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(list(self.cache.iterdir()), [])


if __name__ == "__main__":
    unittest.main()

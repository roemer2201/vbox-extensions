"""Unprivileged checks for the RAM helper's capture and replay logic."""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from contextlib import nullcontext

path = Path(__file__).resolve().parents[1] / "libexec/vbox-relocate-helper"
loader = importlib.machinery.SourceFileLoader("ram_helper", str(path))
spec = importlib.util.spec_from_loader(loader.name, loader)
helper = importlib.util.module_from_spec(spec)
loader.exec_module(helper)


class CaptureTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        self.snap = root / "Snapshots"
        self.snap.mkdir()
        self.ram = root / "ram"
        self.upper = self.ram / "private/upper"
        self.upper.mkdir(parents=True)
        (self.ram / "state").mkdir()
        self.data = dict(snap=str(self.snap), parent=root.stat().st_ino,
                         device=root.stat().st_dev, lower=self.snap.stat().st_ino)

    def capture(self, name):
        with patch.object(helper, "caller", return_value=nullcontext()):
            helper.release_overlay(os.getuid(), self.data, self.ram, "test", name)

    def test_replay_after_unmount_or_move(self):
        (self.upper / "guest.sav").write_bytes(b"state")
        self.capture("guest.sav")
        self.capture("guest.sav")
        self.assertEqual((self.ram / "state/guest.sav").read_bytes(), b"state")

    def test_keep_unexpected_upper_entries(self):
        (self.upper / "disk.vdi").touch()
        with self.assertRaises(ValueError):
            self.capture(None)
        self.assertTrue((self.upper / "disk.vdi").exists())

    def test_refuse_symlink(self):
        (self.upper / "guest.sav").symlink_to("/dev/null")
        with self.assertRaises(ValueError):
            self.capture("guest.sav")


if __name__ == "__main__":
    unittest.main()

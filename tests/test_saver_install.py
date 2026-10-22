"""Filesystem/rollback tests; macOS codesign and the system host are not simulated as successes."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("install_saver", ROOT / "scripts/install_saver.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class SaverInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="MotionWall тест '")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.template = self.root / "template/MotionWall.saver"
        (self.template / "Contents/MacOS").mkdir(parents=True)
        (self.template / "Contents/Resources").mkdir()
        (self.template / "Contents/Info.plist").write_bytes((ROOT / "ScreenSaver/Info.plist").read_bytes())
        (self.template / "Contents/MacOS/MotionWallSaver").write_bytes(b"test executable fixture")
        self.movie = self.root / "Видео с пробелами ' $().mp4"
        self.movie.write_bytes(b"new movie data")
        self.target = self.root / "Library/Screen Savers/MotionWall.saver"

    def install(self, signer=lambda bundle: None, **kwargs):
        return installer.install(self.template, self.movie, self.target, signer=signer, **kwargs)

    def test_installed_saver_is_self_contained_and_signs_final_resources(self):
        observed = []
        def signer(bundle):
            observed.append((bundle / "Contents/Resources/wallpaper.mp4").read_bytes())
            self.assertFalse(self.target.exists())
        self.install(signer=signer, fill=False, respect_low_power=False)
        self.movie.unlink()
        self.assertEqual(observed, [b"new movie data"])
        self.assertEqual((self.target / "Contents/Resources/wallpaper.mp4").read_bytes(), b"new movie data")
        self.assertEqual(json.loads((self.target / "Contents/Resources/settings.json").read_text()),
                         {"fill": False, "respectLowPower": False})
        self.assertFalse((self.template / "Contents/Resources/wallpaper.mp4").exists())
        self.assertFalse(list(self.target.parent.glob(".MotionWall-install-*")))

    def test_signing_failure_keeps_old_video_and_unrelated_savers(self):
        self.install()
        unrelated = self.target.parent / "Other.saver"
        unrelated.mkdir()
        self.movie.write_bytes(b"replacement")
        def reject(bundle):
            raise RuntimeError("Signature verification failed")
        with self.assertRaisesRegex(RuntimeError, "Signature verification failed"):
            self.install(signer=reject)
        self.assertEqual((self.target / "Contents/Resources/wallpaper.mp4").read_bytes(), b"new movie data")
        self.assertTrue(unrelated.is_dir())

    def test_successful_replacement_updates_video(self):
        self.install()
        self.movie.write_bytes(b"replacement")
        self.install()
        self.assertEqual((self.target / "Contents/Resources/wallpaper.mp4").read_bytes(), b"replacement")
        self.assertFalse(list(self.target.parent.glob(".MotionWall-install-*")))

    def test_failed_final_move_rolls_back_old_saver(self):
        self.install()
        self.movie.write_bytes(b"replacement")
        real_replace = installer.os.replace
        def fail_install(source, dest):
            if Path(source).name == "MotionWall.saver" and Path(source) != self.target:
                raise OSError("Disk error during final move")
            return real_replace(source, dest)
        with patch.object(installer.os, "replace", side_effect=fail_install):
            with self.assertRaisesRegex(OSError, "Disk error"):
                self.install()
        self.assertEqual((self.target / "Contents/Resources/wallpaper.mp4").read_bytes(), b"new movie data")

    def test_rollback_failure_preserves_backup(self):
        self.install()
        real_replace = installer.os.replace
        def fail_after_backup(source, dest):
            if Path(source) != self.target:
                raise OSError("Disk unavailable")
            return real_replace(source, dest)
        with patch.object(installer.os, "replace", side_effect=fail_after_backup):
            with self.assertRaisesRegex(RuntimeError, "Предыдущая заставка сохранена"):
                self.install()
        backups = list(self.target.parent.glob(".MotionWall-install-*/Previous.saver/Contents/Resources/wallpaper.mp4"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), b"new movie data")

    def test_foreign_saver_is_not_replaced(self):
        self.install()
        info_path = self.target / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleIdentifier"] = "other.application"
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(RuntimeError, "другая заставка"):
            self.install()
        self.assertEqual(plistlib.loads(info_path.read_bytes())["CFBundleIdentifier"], "other.application")

    def test_missing_video_keeps_existing_install(self):
        self.install()
        self.movie.unlink()
        with self.assertRaisesRegex(RuntimeError, "видео недоступно"):
            self.install()
        self.assertEqual((self.target / "Contents/Resources/wallpaper.mp4").read_bytes(), b"new movie data")

    def test_symlink_target_is_not_followed(self):
        self.target.parent.mkdir(parents=True)
        self.target.symlink_to(self.template, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "является ссылкой"):
            self.install()
        self.assertTrue(self.target.is_symlink())


if __name__ == "__main__":
    unittest.main(verbosity=2)

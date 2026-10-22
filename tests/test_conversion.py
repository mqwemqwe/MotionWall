#!/usr/bin/env python3
"""Exercise the exact conversion recipe used by the app. Requires ffmpeg and ffprobe."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RECIPE = json.loads((ROOT / "Resources/conversion.json").read_text())

def run(args):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90)

class ConversionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
            raise unittest.SkipTest("ffmpeg + ffprobe are required")
        cls.temp = tempfile.TemporaryDirectory(prefix="motionwall-tests-")
        cls.root = Path(cls.temp.name)
        cls.base = cls.root / "original.mp4"
        p = run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
                 "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "1.2",
                 "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", str(cls.base)])
        if p.returncode: raise RuntimeError(p.stderr.decode())

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def convert(self, source):
        target = self.root / (source.name + ".converted.mp4")
        result = run(["ffmpeg"] + RECIPE["beforeInput"] + ["-i", str(source)] + RECIPE["afterInput"] + [str(target)])
        return result, target

    def verify(self, target):
        p = run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(target)])
        self.assertEqual(p.returncode, 0, p.stderr.decode())
        info = json.loads(p.stdout)
        self.assertEqual(len(info["streams"]), 1, "Audio/subtitles must be stripped")
        video = info["streams"][0]
        self.assertEqual(video["codec_name"], "h264")
        self.assertEqual(video["pix_fmt"], "yuv420p")
        self.assertEqual(video["r_frame_rate"], "30/1")
        self.assertEqual(video["sample_aspect_ratio"], "1:1")
        self.assertLessEqual(video["width"], 2560)
        self.assertLessEqual(video["height"], 1440)
        self.assertEqual(video["width"] % 2, 0)
        self.assertEqual(video["height"] % 2, 0)
        self.assertGreater(float(info["format"]["duration"]), 0)
        decoded = run(["ffmpeg", "-v", "error", "-i", str(target), "-f", "null", "-"])
        self.assertEqual(decoded.returncode, 0, decoded.stderr.decode())
        return video

    def test_common_containers(self):
        formats = {"mp4": ["-c", "copy"], "mov": ["-c", "copy"], "mkv": ["-c", "copy"],
                   "avi": ["-c:v", "mpeg4", "-c:a", "mp3"],
                   "webm": ["-c:v", "libvpx-vp9", "-c:a", "libopus"],
                   "flv": ["-c", "copy"], "gif": ["-an"]}
        for ext, codec in formats.items():
            with self.subTest(format=ext):
                source = self.root / ("Тест с пробелом ' $(never-execute)." + ext)
                fixture = run(["ffmpeg", "-v", "error", "-i", str(self.base)] + codec + [str(source)])
                self.assertEqual(fixture.returncode, 0, fixture.stderr.decode())
                result, target = self.convert(source)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertIn(b"progress=end", result.stdout)
                self.verify(target)

    def test_anamorphic_video(self):
        source = self.root / "anamorphic.mkv"
        fixture = run(["ffmpeg", "-v", "error", "-i", str(self.base), "-vf", "setsar=2", "-an", str(source)])
        self.assertEqual(fixture.returncode, 0, fixture.stderr.decode())
        result, target = self.convert(source)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        video = self.verify(target)
        self.assertEqual((video["width"], video["height"]), (640, 180))

    def test_rotation_metadata(self):
        source = self.root / "rotated.mov"
        fixture = run(["ffmpeg", "-v", "error", "-display_rotation", "90", "-i", str(self.base), "-c", "copy", str(source)])
        self.assertEqual(fixture.returncode, 0, fixture.stderr.decode())
        probe = run(["ffprobe", "-v", "error", "-show_entries", "stream_side_data", "-of", "json", str(source)])
        self.assertIn('"rotation": 90', probe.stdout.decode(), "Fixture must contain a real display rotation matrix")
        result, target = self.convert(source)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        video = self.verify(target)
        self.assertEqual((video["width"], video["height"]), (180, 320))

    def test_invalid_and_audio_only(self):
        invalid = self.root / "broken.mp4"
        invalid.write_bytes(b"this is not a movie")
        audio = self.root / "audio.m4a"
        fixture = run(["ffmpeg", "-v", "error", "-i", str(self.base), "-vn", "-c:a", "copy", str(audio)])
        self.assertEqual(fixture.returncode, 0, fixture.stderr.decode())
        for source in (invalid, audio):
            with self.subTest(source=source.name):
                result, _ = self.convert(source)
                self.assertNotEqual(result.returncode, 0)

if __name__ == "__main__":
    unittest.main(verbosity=2)

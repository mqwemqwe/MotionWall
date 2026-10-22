#!/usr/bin/env python3
"""Fetch an exact upstream wheel; extract only its FFmpeg executable, without installing Python packages."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import zipfile

WHEELS = {
    "arm64": (
        "https://files.pythonhosted.org/packages/40/5c/f3d8a657d362cc93b81aab8feda487317da5b5d31c0e1fdfd5e986e55d17/imageio_ffmpeg-0.6.0-py3-none-macosx_11_0_arm64.whl",
        "b1ae3173414b5fc5f538a726c4e48ea97edc0d2cdc11f103afee655c463fa742",
    ),
    "x86_64": (
        "https://files.pythonhosted.org/packages/da/58/87ef68ac83f4c7690961bce288fd8e382bc5f1513860fc7f90a9c1c1c6bf/imageio_ffmpeg-0.6.0-py3-none-macosx_10_9_intel.macosx_10_9_x86_64.whl",
        "9d2baaf867088508d4a3458e61eeb30e945c4ad8016025545f66c4b5aaef0a61",
    ),
}

def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def fetch(arch, destination, cache):
    url, expected = WHEELS[arch]
    cache.mkdir(parents=True, exist_ok=True)
    wheel = cache / ("imageio-ffmpeg-0.6.0-" + arch + ".whl")
    if not wheel.exists() or digest(wheel) != expected:
        temporary = wheel.with_suffix(".download")
        try:
            subprocess.run(["/usr/bin/curl", "--fail", "--location", "--retry", "2",
                            "--connect-timeout", "20", "--max-time", "600", "--output", str(temporary), url], check=True)
            if digest(temporary) != expected:
                raise RuntimeError("Контрольная сумма видеоконвертера не совпала. Установка остановлена.")
            os.replace(temporary, wheel)
        finally:
            temporary.unlink(missing_ok=True)
    with zipfile.ZipFile(wheel) as archive:
        candidates = [n for n in archive.namelist()
                      if n.startswith("imageio_ffmpeg/binaries/ffmpeg-") and not n.endswith("/")]
        if len(candidates) != 1:
            raise RuntimeError("В архиве не найден однозначный исполняемый файл FFmpeg.")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(archive.read(candidates[0]))
        destination.chmod(0o755)

if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in WHEELS:
        raise SystemExit("Usage: fetch_ffmpeg.py arm64|x86_64 DESTINATION CACHE_DIRECTORY")
    fetch(sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]))

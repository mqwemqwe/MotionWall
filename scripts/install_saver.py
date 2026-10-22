#!/usr/bin/env python3
"""Install a self-contained saver; sign and verify before replacing the old copy."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

BUNDLE_ID = "app.motionwall.screensaver"


def check_bundle(bundle):
    if bundle.is_symlink():
        raise RuntimeError("Папка заставки является ссылкой. Установка остановлена.")
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise RuntimeError("В этой папке находится другая заставка. Она не будет заменена.")
    if not (bundle / "Contents/MacOS/MotionWallSaver").is_file():
        raise RuntimeError("Не найден модуль заставки. Повторно запусти Install.command.")


def sign_and_verify(bundle):
    for arguments in (
        ["--force", "--sign", "-", "--timestamp=none", str(bundle)],
        ["--verify", "--deep", "--strict", str(bundle)],
    ):
        result = subprocess.run(["/usr/bin/codesign"] + arguments, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError("Не удалось проверить заставку: " + (result.stderr or result.stdout).strip())


def install(template, movie, destination, fill=True, respect_low_power=True, signer=sign_and_verify):
    template, movie, destination = map(Path, (template, movie, destination))
    check_bundle(template)
    if not movie.is_file() or movie.stat().st_size == 0:
        raise RuntimeError("Подготовленное видео недоступно. Выбери его заново.")
    if destination.name != "MotionWall.saver":
        raise ValueError("Unexpected saver destination")
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Refuse unknown bundles and links; never replace another app's screen saver.
    if os.path.lexists(destination):
        check_bundle(destination)
    work = Path(tempfile.mkdtemp(prefix=".MotionWall-install-", dir=destination.parent))
    staged = work / "MotionWall.saver"
    backup = work / "Previous.saver"
    preserve_backup = False
    try:
        shutil.copytree(template, staged)
        resources = staged / "Contents/Resources"
        resources.mkdir(exist_ok=True)
        shutil.copy2(movie, resources / "wallpaper.mp4")
        (resources / "settings.json").write_text(json.dumps({
            "fill": bool(fill), "respectLowPower": bool(respect_low_power)
        }), encoding="utf-8")
        signer(staged)  # Includes the copied movie in the signature's resource seal.
        if os.path.lexists(destination):
            check_bundle(destination)
            os.replace(destination, backup)
        try:
            os.replace(staged, destination)
        except BaseException:
            if backup.exists():
                try:
                    os.replace(backup, destination)
                except OSError as rollback_error:
                    preserve_backup = True
                    raise RuntimeError(f"Предыдущая заставка сохранена в {backup}: {rollback_error}") from rollback_error
            raise
        return destination
    finally:
        if not preserve_backup:
            shutil.rmtree(work, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("template", type=Path)
    parser.add_argument("movie", type=Path)
    parser.add_argument("--fill", choices=("true", "false"), default="true")
    parser.add_argument("--respect-low-power", choices=("true", "false"), default="true")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise RuntimeError("Установка заставки доступна только на macOS.")
    destination = Path.home() / "Library/Screen Savers/MotionWall.saver"
    install(args.template, args.movie, destination, args.fill == "true", args.respect_low_power == "true")
    print("Видеозаставка MotionWall установлена.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

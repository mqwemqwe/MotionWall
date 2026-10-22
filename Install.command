#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
PROJECT_DIR="$PWD"
BUILD_DIR=""
cleanup() {
  local result=$?
  if [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then /bin/rm -rf "$BUILD_DIR"; fi
  if [[ $result -ne 0 ]]; then
    echo
    echo "Установка остановлена. Сообщение об ошибке находится выше."
    echo "Пришли скриншот этого окна, если нужна помощь."
  fi
  if [[ -t 0 ]]; then read -r -p "Нажми Enter, чтобы закрыть установщик… " || true; fi
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "MotionWall устанавливается только на macOS 13 или новее."
  exit 1
fi
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( OS_MAJOR < 13 )); then
  echo "Нужна macOS Ventura 13 или новее. Текущая версия: $(sw_vers -productVersion)."
  exit 1
fi
if ! /usr/bin/xcode-select -p >/dev/null 2>&1 || ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  echo "Для первой сборки нужны бесплатные Apple Command Line Tools. Полный Xcode не требуется."
  /usr/bin/xcode-select --install || true
  echo "Нажми «Установить» в окне Apple, дождись окончания и снова открой Install.command."
  exit 1
fi
if /usr/bin/pgrep -x MotionWall >/dev/null; then
  echo "Сначала заверши MotionWall через его значок в строке меню, затем запусти установщик снова."
  exit 1
fi
ARCH="$(uname -m)"
if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == "1" ]]; then ARCH="arm64"; fi
if [[ "${ARCH}" != arm64 && "${ARCH}" != x86_64 ]]; then echo "Неизвестная архитектура: ${ARCH}"; exit 1; fi
APPLICATIONS_DIR="$HOME/Applications"
/bin/mkdir -p "$APPLICATIONS_DIR"
BUILD_DIR="$(/usr/bin/mktemp -d "$APPLICATIONS_DIR/.motionwall-build.XXXXXX")"
APP="$BUILD_DIR/MotionWall.app"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp "$PROJECT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$PROJECT_DIR/Resources/conversion.json" "$APP/Contents/Resources/"
/bin/cp "$PROJECT_DIR/THIRD_PARTY.txt" "$APP/Contents/Resources/"

echo "1/4. Получаю видеоконвертер (примерно 25 МБ, только при первой установке)…"
/usr/bin/python3 "$PROJECT_DIR/scripts/fetch_ffmpeg.py" "${ARCH}" \
  "$APP/Contents/Resources/ffmpeg" "$HOME/Library/Caches/MotionWallInstaller"
echo "2/4. Собираю приложение для ${ARCH}…"
/usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -O -parse-as-library \
  -target "${ARCH}-apple-macosx13.0" \
  "$PROJECT_DIR"/Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework AVKit -framework AVFoundation \
  -framework QuartzCore -framework ServiceManagement \
  -o "$APP/Contents/MacOS/MotionWall"
echo "3/4. Проверяю и подписываю локальную сборку…"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$APP/Contents/Resources/ffmpeg"
"$APP/Contents/Resources/ffmpeg" -version >/dev/null
/usr/bin/codesign --force --sign - --timestamp=none "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

TARGET="$APPLICATIONS_DIR/MotionWall.app"
BACKUP=""
if [[ -e "$TARGET" ]]; then
  BACKUP="$APPLICATIONS_DIR/MotionWall-backup-$(date +%Y%m%d-%H%M%S).app"
  /bin/mv "$TARGET" "$BACKUP"
fi
if ! /bin/mv "$APP" "$TARGET"; then
  if [[ -n "$BACKUP" ]]; then /bin/mv "$BACKUP" "$TARGET"; fi
  exit 1
fi
echo "4/4. Готово! Открываю MotionWall…"
echo "Приложение: $TARGET"
if [[ -n "$BACKUP" ]]; then echo "Предыдущая версия сохранена: $BACKUP"; fi
/usr/bin/open "$TARGET" --args --show

#!/bin/zsh
# Packages Editroom.app into a verified macOS DMG, computes SHA-256, and emits Sparkle appcast.xml.
# Works locally on Apple Silicon and in GitHub Actions macos-15 without requiring Developer ID keys.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/editroom/Editroom.xcodeproj"
APP_NAME="Editroom"
APP_PATH=""
OUT_DIR="$ROOT_DIR/dist"
REPO="${GITHUB_REPOSITORY:-nguyenducvuongg/hybrid_editor}"
VERSION=""
BUILD_NUM=""
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_PATH="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD_NUM="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

settings="$(xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -configuration Release -showBuildSettings 2>/dev/null || true)"
if [[ -z "$VERSION" ]]; then
  VERSION="$(print -r -- "$settings" | awk -F' = ' '/ MARKETING_VERSION = /{print $2; exit}' | tr -d ' ')"
  VERSION="${VERSION:-2.0.0}"
fi
if [[ -z "$BUILD_NUM" ]]; then
  BUILD_NUM="$(print -r -- "$settings" | awk -F' = ' '/ CURRENT_PROJECT_VERSION = /{print $2; exit}' | tr -d ' ')"
  BUILD_NUM="${BUILD_NUM:-20}"
fi

WORK="$(mktemp -d /tmp/editroom_dmg_XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

if [[ -z "$APP_PATH" ]]; then
  if [[ "$SKIP_BUILD" -eq 1 ]]; then
    echo "--skip-build requires --app <path/to/Editroom.app>" >&2
    exit 1
  fi
  DD="$WORK/DerivedData"
  echo "==> Building Release $APP_NAME ($VERSION build $BUILD_NUM)..."
  xcodebuild -project "$PROJECT" -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath "$DD" CODE_SIGN_IDENTITY="${CODESIGN_IDENTITY:--}" CODE_SIGNING_REQUIRED=NO build
  APP_PATH="$DD/Build/Products/Release/$APP_NAME.app"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

DMG_NAME="Hybrid-Editor-$VERSION.dmg"
VOL_NAME="Hybrid Editor"
DMG_PATH="$OUT_DIR/$DMG_NAME"
rm -f "$DMG_PATH" "$DMG_PATH.sha256"

echo "==> Creating DMG $DMG_PATH..."
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
hdiutil verify "$DMG_PATH" >/dev/null

SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
BYTES="$(stat -f%z "$DMG_PATH")"
printf "%s  %s\n" "$SHA256" "$DMG_NAME" > "$DMG_PATH.sha256"

ENC_SIG=""
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  SIGN_BIN="$(find /tmp/hybrid_edit_editroom_dd "$WORK" "$HOME/Library/Developer/Xcode/DerivedData" -name sign_update -type f 2>/dev/null | head -n 1 || true)"
  if [[ -n "$SIGN_BIN" && -x "$SIGN_BIN" ]]; then
    ENC_SIG="$(print -r -- "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_BIN" --ed-key-file - "$DMG_PATH" 2>/dev/null || true)"
  fi
fi

TAG="v$VERSION"
PUB_DATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"
APPCAST_PATH="$OUT_DIR/appcast.xml"
cat > "$APPCAST_PATH" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Hybrid Editor</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUM</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>https://github.com/$REPO/releases/tag/$TAG</link>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$DMG_NAME" ${ENC_SIG:+$ENC_SIG }length="$BYTES" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

echo "==> Packaged $DMG_PATH ($BYTES bytes, sha256=$SHA256)"
echo "==> Wrote $APPCAST_PATH"

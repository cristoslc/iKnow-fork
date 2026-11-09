#!/usr/bin/env bash
#
# Build, sign, and install iKnowViewer.app.
#
# The app is a single window that starts `uv run python server.py` from this
# repo. It exists so macOS Full Disk Access can be granted to one program: the
# live stores are behind TCC, which grants per program and cannot be narrowed
# to a folder, and granting a terminal would hand that reach to everything run
# from it.
#
# The repo path and the uv path are baked into the app's Info.plist here, at
# build time, because a Finder-launched app has no useful working directory.
#
# Usage: scripts/build-app.sh
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)

APP_SRC="$REPO_ROOT/app"
BUILD_DIR="$APP_SRC/build"
APP_BUNDLE="$BUILD_DIR/iKnowViewer.app"
CONTENTS="$APP_BUNDLE/Contents"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/iKnowViewer.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "build-app.sh: swiftc not found." >&2
  echo "  Install Xcode or the Command Line Tools: xcode-select --install" >&2
  exit 1
fi

if ! UV_PATH=$(command -v uv); then
  echo "build-app.sh: uv not found on PATH." >&2
  echo "  Install uv (https://docs.astral.sh/uv/) and run this again." >&2
  exit 1
fi

echo "==> repo: $REPO_ROOT"
echo "==> uv:   $UV_PATH"
echo "==> compiling app/main.swift"

rm -rf "$BUILD_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

swiftc -swift-version 5 -O \
  -o "$BUILD_DIR/iKnowViewer" \
  "$APP_SRC/main.swift" \
  -framework AppKit

echo "==> assembling $APP_BUNDLE"

cp "$BUILD_DIR/iKnowViewer" "$CONTENTS/MacOS/iKnowViewer"
chmod +x "$CONTENTS/MacOS/iKnowViewer"

cp "$APP_SRC/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :IKRepoPath $REPO_ROOT" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :IKUVPath $UV_PATH" "$CONTENTS/Info.plist"

printf 'APPL????' > "$CONTENTS/PkgInfo"

plutil -lint "$CONTENTS/Info.plist" >/dev/null

echo "==> signing (ad hoc)"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> installing to $INSTALLED_APP"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
cp -R "$APP_BUNDLE" "$INSTALLED_APP"

cat <<EOF

Built and installed: $INSTALLED_APP

Launch it:
    open ~/Applications/iKnowViewer.app

Full Disk Access (once per build):
    1. System Settings -> Privacy & Security -> Full Disk Access
    2. Click + and choose ~/Applications/iKnowViewer.app
    3. Switch it on, then relaunch the app

Warning: macOS ties a Full Disk Access grant to the app's signature. Every
rebuild changes that signature, so after rebuilding you must re-add the app
(or switch it off and on again) before it can read the stores.

EOF

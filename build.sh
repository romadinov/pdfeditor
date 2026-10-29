#!/bin/bash
# Builds "PDF Text Editor.app" into ./build and sets up the text engine.
set -euo pipefail
cd "$(dirname "$0")"

# Universal binary: runs on Apple Silicon and Intel Macs.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
APP="build/PDF Text Editor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release "${ARCHS[@]}" --show-bin-path)/PDFTextEditor" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Engine/pdftext_engine.py "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null

# The app creates this on first launch too; doing it here makes launch instant.
SUPPORT="$HOME/Library/Application Support/PDFTextEditor"
if ! "$SUPPORT/venv/bin/python3" -c "import pymupdf, fontTools" 2>/dev/null; then
    echo "Setting up the text engine (PyMuPDF + fontTools)…"
    mkdir -p "$SUPPORT"
    python3 -m venv "$SUPPORT/venv"
    "$SUPPORT/venv/bin/pip" install --disable-pip-version-check -q pymupdf fonttools
fi

echo "Built: $APP"

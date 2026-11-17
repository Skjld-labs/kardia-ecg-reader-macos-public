#!/bin/zsh
set -eu
# Resolve paths from this script, so invoking it from another directory also works.
ROOT=${0:A:h}
# Full Xcode is required; the Command Line Tools-only SDK layout is not used here.
TOOLCHAIN=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
APP="$ROOT/build/Kardia Reader.app"
mkdir -p "$APP/Contents/MacOS"
"$TOOLCHAIN/swiftc" -parse-as-library -O -sdk "$SDK" -target arm64-apple-macosx14.0 \
  "$ROOT/Sources/Protocol.swift" "$ROOT/Sources/App.swift" -o "$APP/Contents/MacOS/KardiaReader"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
# Local ad-hoc signature only: this does not notarize or install the application.
/usr/bin/codesign --force --sign - --identifier local.jon.kardia-reader "$APP"
print -r -- "$APP"

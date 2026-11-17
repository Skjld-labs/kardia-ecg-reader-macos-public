#!/bin/zsh
set -eu
# Compile the pure protocol/export layer without SwiftUI, Bluetooth access or hardware.
# Do not add -Ounchecked: precondition checks below are the test assertions.
ROOT=${0:A:h}
TOOLCHAIN=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
mkdir -p "$ROOT/build"
"$TOOLCHAIN/swiftc" -parse-as-library -sdk "$SDK" -target arm64-apple-macosx14.0 \
  "$ROOT/Sources/Protocol.swift" "$ROOT/Sources/ProtocolTests.swift" -o "$ROOT/build/protocol-tests"
"$ROOT/build/protocol-tests"

#!/usr/bin/env bash
#
# Run the Swift Testing suite under CommandLineTools.
#
# CLT ships swift-testing under Library/Developer but not on the default search
# path, so both compilation (`import Testing`) and the test runner need to be
# pointed at Testing.framework and its interop dylib. These flags are passed
# build-wide (not via Package.swift) so SwiftPM's synthesized runner target sees
# them too — otherwise test discovery silently finds nothing.
#
# Under a full Xcode toolchain these paths simply won't exist and swift-testing is
# already on the default path; use plain `swift test` there.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

if [[ ! -d "$FW/Testing.framework" ]]; then
  echo "Testing.framework not found under CLT; on a full Xcode toolchain run: swift test" >&2
  exit 0
fi

exec swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB"

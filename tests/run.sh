#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/tcc-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -swift-version 5 -framework AppKit \
  "$ROOT/Sources/TCCCore.swift" "$ROOT/Sources/TCCAuto.swift" \
  "$ROOT/Sources/ComputerUse.swift" "$ROOT/tests/main.swift" -o "$BUILD/tests"
"$BUILD/tests"

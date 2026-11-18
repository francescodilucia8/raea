#!/bin/bash
# The native host of the binaries being packaged or promoted.
set -eu
platform="$(uname -s)/$(uname -m)"
case "$platform" in
  Darwin/arm64) echo macos-arm64 ;;
  Darwin/x86_64)
    if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
      echo "release: run packaging from a native Apple Silicon shell" >&2
      exit 1
    fi
    echo macos-x86_64 ;;
  Linux/x86_64) echo linux-x86_64 ;;
  MINGW*64/x86_64|MSYS*/x86_64|CYGWIN*/x86_64) echo windows-x86_64 ;;
  *) echo "release: unsupported build host $platform" >&2; exit 1 ;;
esac

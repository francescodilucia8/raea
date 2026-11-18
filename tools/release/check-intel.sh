#!/bin/bash
# Inspect the unpacked Intel CLI package on macOS. The Air runs intel-smoke.sh.
set -euo pipefail
stage=${1:?usage: check-intel.sh PACKAGE_ROOT}
fail() { echo "Intel package: $*" >&2; exit 1; }

for path in bin/raea bin/libraea_bundle.dylib share/raea/VERSION share/raea/LICENSE share/raea/NOTICE; do
  [ -s "$stage/$path" ] || fail "missing $path"
done
[ -d "$stage/share/raea/LICENSES" ] || fail "missing third-party licenses"

while IFS= read -r binary; do
  [ "$(lipo -archs "$binary")" = x86_64 ] || fail "expected only x86_64 in $binary"
  vtool -show-build "$binary" | awk '
    $1 == "platform" && $2 == "MACOS" { mac = 1 }
    $1 == "minos" && ($2 + 0 <= 14.0) { compatible = 1 }
    END { exit !(mac && compatible) }
  ' || fail "expected macOS deployment target 14.0 or earlier in $binary"
  codesign --verify --strict "$binary"
  while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/Frameworks/*|/usr/lib/*) ;;
      @rpath/libraea_bundle.dylib)
        [ "$binary" = "$stage/bin/libraea_bundle.dylib" ] || fail "unexpected rpath link in $binary" ;;
      *) fail "unexpected dependency $dependency in $binary" ;;
    esac
  done < <(otool -L "$binary" | awk 'NR > 1 {print $1}')
done < <(find "$stage" -type f -exec file -F '|' {} + | awk -F '|' '$2 ~ /Mach-O/ { print $1 }')

for path in bin/raea bin/libraea_bundle.dylib; do
  file -b "$stage/$path" | grep -q 'Mach-O' || fail "expected a Mach-O file at $path"
done
codesign -d --entitlements :- "$stage/bin/raea" 2>/dev/null | plutil -p - | grep -Eq '"com.apple.security.cs.allow-jit" => (true|1)' ||
  fail "missing JIT entitlement"
RAEA_NO_TREE=1 "$stage/bin/raea" --version
echo "Intel package: checked architecture, deployment target, load paths, signatures and licenses"

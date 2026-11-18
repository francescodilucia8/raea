#!/bin/sh
# Adapted from Raea's Unix installer at https://raea.io/install (Shane Murphy).
# Distributed under the fork's LICENSE and NOTICE.
#
# Puts the raea engine (the `raea` CLI that renders, plays and checks compositions written in React and
# TypeScript) under ~/.raea, links it into ~/.local/bin, and adds raea's agent skills to ~/.claude/skills so a coding
# agent (Claude Code, or anything that reads that folder) knows how to write and render with it. Run it again to
# update. macOS on Apple Silicon or Intel, and Linux on x86_64.
#
# RAEA_VERSION=0.1.0-canary.1 picks a release (by default the newest with a build for this machine); RAEA_PREFIX
# moves ~/.raea; RAEA_NO_SKILLS=1 leaves the skills out; RAEA_DOWNLOAD serves the releases from somewhere else (a
# mirror, or a local folder to test).
set -eu

repo="francescodilucia8/raea"
prefix="${RAEA_PREFIX:-$HOME/.raea}"
bindir="$HOME/.local/bin"
say() { printf '%s\n' "raea: $*"; }
fail() { printf '%s\n' "raea: $*" >&2; exit 1; }

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) platform=macos-arm64 ;;
  Darwin/x86_64)
    if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
      platform=macos-arm64
    else
      platform=macos-x86_64
    fi ;;
  Darwin/*) fail "no Raea build for this Mac architecture ($(uname -m))." ;;
  Linux/x86_64) platform=linux-x86_64 ;;
  Linux/*) fail "raea runs on x86_64 Linux for now (this is $(uname -m))." ;;
  MINGW*|MSYS*|CYGWIN*) fail "on Windows, install raea from PowerShell:  irm https://raea.io/install.ps1 | iex" ;;
  *) fail "raea runs on macOS, Linux and Windows for now (this is $(uname -s))." ;;
esac
command -v curl >/dev/null || fail "curl is needed."

if [ -n "${RAEA_VERSION:-}" ]; then
  tag="v$RAEA_VERSION"
else
  # the newest release with a build for this platform (a web-SHA pre-release has none, and a build can follow its release)
  tag=$(curl -fsSL "https://api.github.com/repos/$repo/releases?per_page=30" \
    | sed -n "s|.*\"browser_download_url\": *\"[^\"]*/download/\(v[^/]*\)/raea-[^/]*-$platform\.tar\.gz\".*|\1|p" | head -n 1)
  [ -n "$tag" ] || fail "couldn't find a release of $repo."
fi
version="${tag#v}"
case "$version" in
  ""|[!0-9]*|*[!a-zA-Z0-9._-]*) fail "invalid release version: $version" ;;
esac
asset="raea-$version-$platform.tar.gz"
url="${RAEA_DOWNLOAD:-https://github.com/$repo/releases/download}/$tag/$asset"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
say "downloading raea $version"
curl -fL --progress-bar "$url" -o "$tmp/$asset" || fail "couldn't download $url"
curl -fsSL "$url.sha256" -o "$tmp/$asset.sha256" || fail "couldn't download the checksum"
expected=$(awk -v asset="$asset" '
  NR == 1 && NF == 2 && length($1) == 64 && $1 !~ /[^[:xdigit:]]/ &&
    ($2 == asset || $2 == "*" asset) { digest = tolower($1) }
  END { if (NR != 1 || digest == "") exit 1; print digest }
' "$tmp/$asset.sha256") || fail "invalid checksum for $asset"
if command -v sha256sum >/dev/null; then
  actual=$(sha256sum < "$tmp/$asset")
else
  actual=$(shasum -a 256 < "$tmp/$asset")
fi
[ "${actual%% *}" = "$expected" ] || fail "the download's checksum doesn't match."
tar -xzf "$tmp/$asset" -C "$tmp"
[ -d "$tmp/raea/share/raea" ] || fail "archive has no runtime files"
[ -x "$tmp/raea/bin/raea" ] || [ -x "$tmp/raea/bin/raea-motion" ] || fail "archive has no Raea executable"

# replace the old install whole (a release's files go together)
mkdir -p "$prefix"
rm -rf "$prefix/bin" "$prefix/share"
mv "$tmp/raea/bin" "$tmp/raea/share" "$prefix/"
mkdir -p "$bindir"
# raea is the command (releases before 10-24 named it raea-motion: their `raea` links to that); an earlier install's
# raea-motion link goes
if [ -e "$prefix/bin/raea" ]; then ln -sf "$prefix/bin/raea" "$bindir/raea"; else ln -sf "$prefix/bin/raea-motion" "$bindir/raea"; fi
if [ -L "$bindir/raea-motion" ] && [ -e "$prefix/bin/raea" ]; then rm -f "$bindir/raea-motion"; fi
say "installed raea $version in $prefix (linked from $bindir)"
# Linux: raea links ALSA and fontconfig, which a bare system (a server, a container) may not have: say what's missing
# rather than let the first `raea` fail with a loader error (0.1.1-rc2 on ubuntu:24.04, 11-10)
if [ "$platform" = linux-x86_64 ] && command -v ldd >/dev/null; then
  missing=$(ldd "$prefix/bin/raea" 2>/dev/null | awk '/not found/ {print $1}' | tr '\n' ' ')
  if [ -n "$missing" ]; then
    say "raea needs $missing- install them, e.g.:  sudo apt install libasound2t64 libfontconfig1  (libasound2 before Ubuntu 24.04)"
  fi
fi
# Linux: kanji and kana come from a system CJK font (the bundled faces are Latin), as on a Mac; without one raea warns
# and draws those characters as boxes
if [ "$platform" = linux-x86_64 ] && ! { command -v fc-list >/dev/null && [ -n "$(fc-list :lang=ja 2>/dev/null)" ]; }; then
  say "no CJK font found: Japanese, Chinese and Korean text will draw as boxes. Install one, e.g.:  sudo apt install fonts-noto-cjk"
fi

if [ -z "${RAEA_NO_SKILLS:-}" ]; then
  skills="$HOME/.claude/skills"
  mkdir -p "$skills"
  for s in "$prefix/share/raea/skills/"*; do
    n=$(basename "$s")
    rm -rf "$skills/$n"
    cp -R "$s" "$skills/$n"
  done
  # an older raea's raea-bevy (stamped `version:`): it's the raea skill's 3D guide now, 3d.md
  grep -qs "^version: " "$skills/raea-bevy/SKILL.md" && rm -rf "$skills/raea-bevy"
  say "added the raea skill to $skills"
fi

case ":$PATH:" in
  *":$bindir:"*) ;;
  *) say "add $bindir to your PATH, e.g.:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.$(basename "${SHELL:-sh}")rc" ;;
esac
say "try it:  raea render your-composition.tsx -o out.mp4"
say "agents: ask your coding agent to make something with raea; the skill tells it how."

#!/bin/bash
# From the extracted GitHub Actions artifact: bash intel-smoke.sh /path/to/raea-...-macos-x86_64.tar.gz
set -euo pipefail
fail() { echo "Intel smoke: $*" >&2; exit 1; }
archive=${1:?usage: intel-smoke.sh ARCHIVE}
asset=$(basename "$archive")
case "$asset" in
  raea-[0-9]*-macos-x86_64.tar.gz) ;;
  *) fail "expected an Intel macOS candidate archive" ;;
esac
version=${asset#raea-}
version=${version%-macos-x86_64.tar.gz}
installer="$(cd "$(dirname "$0")" && pwd)/install.sh"
[ -f "$installer" ] || installer="$(cd "$(dirname "$0")/.." && pwd)/install.sh"
[ -f "$installer" ] || fail "keep the installer from the same workflow artifact beside this script"
for cmd in ffmpeg ffprobe; do command -v "$cmd" >/dev/null || fail "$cmd is required to verify the MP4"; done
[ "$(uname -s)/$(uname -m)" = Darwin/x86_64 ] || fail "run on the Intel Mac"
[ "$(sysctl -n hw.model)" = MacBookAir8,2 ] || fail "expected MacBook Air 8,2"
[ "$(sw_vers -productVersion)" = 14.8.2 ] || fail "expected macOS 14.8.2"

work=$(mktemp -d)
mkdir -p "$work/home" "$work/mirror/v$version" "$work/project"
echo "Smoke test output: $work"
exec > >(tee "$work/report.log") 2>&1
sw_vers
sysctl hw.model hw.memsize machdep.cpu.brand_string
cp "$archive" "$archive.sha256" "$work/mirror/v$version/"
HOME="$work/home" RAEA_VERSION="$version" RAEA_NO_SKILLS=1 RAEA_DOWNLOAD="file://$work/mirror" sh "$installer"
cat "$archive.sha256"
du -sh "$work/home/.raea"
raea="$work/home/.local/bin/raea"

cat > "$work/project/hello.tsx" <<'TSX'
import { AbsoluteFill, Composition, registerRoot, useCurrentFrame } from "raea";

function Hello() {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ backgroundColor: frame < 24 ? "#d01a16" : "#194bdf", color: "#fff", justifyContent: "center", alignItems: "center", fontSize: 60 }}>
      Raea {frame}
    </AbsoluteFill>
  );
}

registerRoot(() => (
  <Composition id="intel-smoke" component={Hello} width={640} height={360} fps={24} durationInFrames={48} />
));
TSX

cd "$work/project"
export HOME="$work/home" RAEA_NO_TREE=1 RAEA_OFFLINE=1
"$raea" --version
if "$raea" index status > index.log 2>&1 || ! grep -q 'unavailable in the Intel macOS CLI' index.log; then
  fail "expected the Intel ONNX limitation diagnostic"
fi
cat index.log
"$raea" guide music > guide.log
grep -qi music guide.log || fail "installed craft guide is missing"
WGPU_BACKEND=metal RAEA_WGPU_ADAPTER_LOG=1 /usr/bin/time -l "$raea" render hello.tsx -o hello.mp4 2>&1 | tee render.log
grep -Ei 'raea GPU adapter: .*Intel.*(UHD|617).*\(Metal,' render.log || fail "the render did not report the Intel Metal adapter"

ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate,duration \
  -of default=noprint_wrappers=1 hello.mp4 | tee video-info.txt
for field in codec_name=h264 width=640 height=360 r_frame_rate=24/1; do
  grep -Fxq "$field" video-info.txt || fail "missing $field"
done
awk -F= '$1 == "duration" && $2 >= 1.99 && $2 <= 2.01 { ok = 1 } END { exit !ok }' video-info.txt ||
  fail "expected two seconds of video"

# Decode all frames and sample a 2x2 corner clear of text. Red must become blue.
ffmpeg -nostdin -v error -xerror -i hello.mp4 -map 0:v:0 -vf 'crop=2:2:0:0,format=rgb24' -f rawvideo frames.rgb
[ "$(wc -c < frames.rgb | tr -d ' ')" -eq $((48 * 12)) ] || fail "expected 48 decoded frames"
read -r r0 g0 b0 <<< "$(od -An -tu1 -N 3 frames.rgb)"
read -r r1 g1 b1 <<< "$(od -An -tu1 -j $((47 * 12)) -N 3 frames.rgb)"
(( r0 > b0 + 80 && b1 > r1 + 80 )) || fail "the expected red-to-blue transition is missing"
echo "Decoded 48 frames. First corner RGB: $r0 $g0 $b0. Last corner RGB: $r1 $g1 $b1."
echo "Play $work/project/hello.mp4 in QuickTime, then share confirmation and $work/report.log."
open -a 'QuickTime Player' "$work/project/hello.mp4"

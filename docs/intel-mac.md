# Intel macOS CLI candidate

The validation target is a 2019 MacBook Air 8,2 with Intel UHD Graphics 617, 8 GB RAM and macOS 14.8.2.
Intel support is pending the native render and playback check below.

## Test the packaged CLI

Sign in to GitHub and download the artifact named `raea-macos-x86_64-<commit>` from the successful
[Intel macOS CLI workflow](https://github.com/francescodilucia8/raea/actions/workflows/intel-macos.yml).
Extract the outer workflow ZIP. Keep the archive, its SHA-256 file and the scripts together in their extracted
layout. The script verifies the archive and installs into a temporary home. For video verification, have FFmpeg
and FFprobe on your PATH.

```sh
bash tools/release/intel-smoke.sh dist/raea-*-macos-x86_64.tar.gz
```

Run that command from the extracted workflow artifact on the Air. It renders a two-second H.264 MP4, reports
the Metal adapter, wall time and maximum resident memory, then decodes all 48 frames and verifies the color
transition. Play the video through in QuickTime Player and report playback plus the printed `report.log` path
and contents. The report includes the artifact digest and installed size.

## Availability

- The scoped candidate contains the Raea CLI and its TSX bundler. It uses JavaScriptCore, Bevy/wgpu Metal and
  the system AVFoundation/VideoToolbox codec path. GPU and codec behavior on the UHD 617 still requires testing.
- The pinned ONNX Runtime ships no Intel macOS library. `raea index`, `raea fingerprint`, `raea song`, the
  `raea/ml` APIs and Pocket TTS (`raea/speech` and composition speech synthesis) are unavailable. The
  `raea-perceive` helper and its model are absent, so automatic face tracking and face framing that needs a
  fresh track require a compatible helper. Explicit video framing works without it.
- `raea motion`, `raea setup motion`, and the MLX-DLSS neural command require Apple Silicon on macOS.
  MetalFX temporal denoising requires macOS 26 and suitable hardware. Advanced features such as ray tracing
  and hardware codec acceleration depend on the adapter and codec capabilities and have no validation here.
- The candidate omits the optional third-party Bevy plugin catalog, separate Rune and page app hosts, and the
  desktop app. App commands that launch or package those hosts require separately built host binaries.
- Render time and practical composition sizes on the two-core Air are unmeasured. Begin with the 640×360
  smoke sample. The workflow records CI build disk use separately from the installed size measured by the smoke test.

## Build the CLI on Intel

Install Xcode Command Line Tools, Rust via rustup, Bun 1.4.2, CMake, Ninja and NASM.
Run from a native Intel shell with free disk space for Cargo, its artifacts and swap. The checkout pins Rust
1.99.1. On the two-core, 8 GB Air, start with one Cargo and CMake job. Try two only if memory pressure stays
low. There is no measured source-build RAM or disk minimum for this machine yet. Prefer the CI artifact if
local storage is tight.

```sh
git clone --branch intel-macos-cli https://github.com/francescodilucia8/raea.git
cd raea
git submodule update --init skills
for dir in sdk/react/js sdk/react/tw; do (cd "$dir" && bun install --frozen-lockfile) || exit 1; done
export MACOSX_DEPLOYMENT_TARGET=14.0 CARGO_INCREMENTAL=0 CARGO_PROFILE_RELEASE_DEBUG=0
export CARGO_BUILD_JOBS=1 CMAKE_BUILD_PARALLEL_LEVEL=1
cargo build --locked --release --target x86_64-apple-darwin -p raea-cli --bin raea --no-default-features
version="0.1.0-intel.$(git rev-parse --short=12 HEAD)"
RAEA_INTEL_CANDIDATE=1 bash tools/release.sh "$version" target/x86_64-apple-darwin/release HEAD
```

The packager writes the archive and its `.sha256` beside each other under `dist/`. It checks Mach-O
architectures, deployment targets, load paths and code signatures. The Air smoke test provides the Sonoma
runtime and playback evidence.

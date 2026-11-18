"""Exercise the Unix installer against local release fixtures."""

import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[2]
GITHUB_API = "https://api.github.com/repos/francescodilucia8/raea/releases?per_page=30"
RELEASES = "https://github.com/francescodilucia8/raea/releases/download"


def write_executable(path, source):
    path.write_text(source, encoding="utf-8", newline="\n")
    path.chmod(0o755)


def fixture(mirror, version, platform, checksum="good"):
    release = mirror / f"v{version}"
    release.mkdir(exist_ok=True)
    archive = release / f"raea-{version}-{platform}.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        for name, content in (
            ("bin/raea", f"#!/bin/sh\necho {version}-{platform}\n"),
            ("share/raea/VERSION", version),
        ):
            data = content.encode()
            entry = tarfile.TarInfo(f"raea/{name}")
            entry.mode = 0o755 if name == "bin/raea" else 0o644
            entry.size = len(data)
            tar.addfile(entry, io.BytesIO(data))
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if checksum != "missing":
        digest = "0" * 64 if checksum == "corrupt" else digest
        name = "another.tar.gz" if checksum == "wrong-name" else archive.name
        Path(f"{archive}.sha256").write_text(f"{digest}  {name}\n", encoding="ascii", newline="\n")
    return {"browser_download_url": f"{RELEASES}/v{version}/{archive.name}"}


def main():
    shell = os.environ.get("RAEA_TEST_BASH", "bash")
    with tempfile.TemporaryDirectory(prefix="raea-installer-") as directory:
        tmp = Path(directory)
        # Git Bash accepts drive-letter paths with forward slashes. Its PATH requires POSIX paths.
        def shell_path(path):
            return path.as_posix().replace(path.drive, f"/{path.drive[0].lower()}", 1) if path.drive else path.as_posix()

        mock = tmp / "mock"
        mock.mkdir()
        mirror = tmp / "mirror"
        mirror.mkdir()
        home = tmp / "home"
        home.mkdir()
        for name, source in {
            "uname": 'case "$1" in -s) echo "$TEST_OS";; -m) echo "$TEST_ARCH";; esac',
            "sysctl": 'echo "$TEST_ROSETTA"',
            "ldd": "exit 0",
            "curl": f'''case "$*" in *'{GITHUB_API}'*) cat "$TEST_MIRROR/releases.json"; exit;; esac
url= output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    *://*) url=$1 ;;
    -o) shift; output=$1 ;;
  esac
  shift
done
case "$url" in
  {RELEASES}/*) cp "$TEST_MIRROR/${{url#{RELEASES}/}}" "$output" ;;
  file://*) cp "${{url#file://}}" "$output" ;;
  *) echo "unexpected URL: $url" >&2; exit 1 ;;
esac''',
        }.items():
            write_executable(mock / name, f"#!/bin/sh\n{source}\n")

        platforms = {"macos-x86_64", "macos-arm64", "linux-x86_64"}
        releases = [fixture(mirror, "1.0.0", p) for p in sorted(platforms)]
        releases.insert(0, fixture(mirror, "1.1.0", "macos-arm64"))
        (mirror / "releases.json").write_text(json.dumps([{"assets": releases}], indent=2), encoding="utf-8")
        fixture(mirror, "1.2.0", "macos-x86_64")
        for suffix, checksum in enumerate(("missing", "corrupt", "wrong-name")):
            fixture(mirror, f"1.3.{suffix}", "macos-x86_64", checksum)

        def install(system, arch, *, rosetta="0", version="", use_mirror=False, error=None):
            env = os.environ | {
                "HOME": shell_path(home),
                "RAEA_PREFIX": shell_path(home / "test-prefix"),
                "RAEA_NO_SKILLS": "1",
                "RAEA_VERSION": version,
                "RAEA_DOWNLOAD": f"file://{shell_path(mirror)}" if use_mirror else "",
                "TEST_MIRROR": shell_path(mirror),
                "TEST_OS": system,
                "TEST_ARCH": arch,
                "TEST_ROSETTA": rosetta,
            }
            installer = shlex.quote(shell_path(ROOT / "tools/install.sh"))
            path = shlex.quote(shell_path(mock))
            result = subprocess.run(
                [shell, "-c", f'PATH={path}:"$PATH" sh {installer}'],
                env=env, capture_output=True, text=True,
            )
            if error:
                assert result.returncode != 0 and error in result.stderr, result
            else:
                assert result.returncode == 0, result
            return (home / "test-prefix/bin/raea").read_text(encoding="utf-8").splitlines()[1]

        assert install("Darwin", "x86_64") == "echo 1.0.0-macos-x86_64"
        assert install("Darwin", "arm64") == "echo 1.1.0-macos-arm64"
        assert install("Darwin", "x86_64", rosetta="1") == "echo 1.1.0-macos-arm64"
        assert install("Linux", "x86_64") == "echo 1.0.0-linux-x86_64"
        latest = "echo 1.2.0-macos-x86_64"
        assert install("Darwin", "x86_64", version="1.2.0", use_mirror=True) == latest
        for suffix, error in enumerate(("couldn't download the checksum", "checksum doesn't match", "invalid checksum")):
            assert install("Darwin", "x86_64", version=f"1.3.{suffix}", error=error) == latest
        assert install("Darwin", "i386", error="no Raea build for this Mac architecture") == latest
        print("Installer fixtures passed for Intel, Apple Silicon, Rosetta, Linux, updates and rejected checksums")


if __name__ == "__main__":
    main()

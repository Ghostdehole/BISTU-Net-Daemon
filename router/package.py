"""Build the offline router installer and Windows bundle from this directory."""
import argparse
import hashlib
from pathlib import Path
import zipfile

SOURCE = Path(__file__).resolve().parent
VERSION = "1.8.0"
SHELL_NAME = f"bistu-auth-router-{VERSION}.sh"
ZIP_NAME = f"bistu-auth-windows-{VERSION}.zip"
FILES = ("install.sh", "bistu_auth.sh", "bistu-auth", "bistu_auth.conf")


def shell_installer():
    parts = ['''#!/bin/sh
# BISTU router installer. Run with sh in an interactive root terminal.
set -eu
umask 077
case ${1:-} in ''|--check) ;; *) echo 'Usage: sh installer.sh [--check]' >&2; exit 2;; esac
[ "$#" -le 1 ] || exit 2
stage=$(mktemp -d "${TMPDIR:-/tmp}/bistu-pkg.XXXXXX")
clean() {
    rm -f "$stage/install.sh" "$stage/bistu_auth.sh" "$stage/bistu-auth" "$stage/bistu_auth.conf"
    rmdir "$stage"
}
trap clean EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
''']
    for idx, name in enumerate(FILES):
        body = (SOURCE / name).read_text(encoding="utf-8").rstrip("\n") + "\n"
        sentinel = f"BISTU_AUTH_FILE_END_{idx}"
        if sentinel in body.splitlines():
            raise ValueError(f"package delimiter in {name}")
        parts.extend([f'cat >"$stage/{name}" <<\'{sentinel}\'\n', body, sentinel + "\n"])
    parts.append('''if [ "${1:-}" = --check ]; then
    for name in install.sh bistu_auth.sh bistu-auth bistu_auth.conf; do sh -n "$stage/$name"; done
    echo 'Installer payload syntax OK.'
    exit 0
fi
sh "$stage/install.sh"
''')
    return "".join(parts).encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    target = parser.parse_args().output
    target.mkdir(exist_ok=True, parents=True)
    shell = shell_installer()
    (target / SHELL_NAME).write_bytes(shell)
    readme = (SOURCE / "README.md").read_text(encoding="utf-8").encode()
    files = [(SHELL_NAME, shell), ("README.md", readme)]
    for filename in ("install-from-windows.cmd", "install-from-windows.ps1"):
        path = SOURCE / filename
        encoding = "utf-8-sig" if path.suffix.lower() == ".ps1" else "utf-8"
        data = path.read_text(encoding="utf-8-sig").replace("\n", "\r\n").encode(encoding)
        files.append((path.name, data))
    with zipfile.ZipFile(target / ZIP_NAME, "w") as archive:
        for name, contents in files:
            entry = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, contents, compress_type=zipfile.ZIP_DEFLATED)
    with zipfile.ZipFile(target / ZIP_NAME) as archive:
        assert archive.testzip() is None
        assert archive.read(SHELL_NAME) == shell
    checks = []
    for name in (SHELL_NAME, ZIP_NAME):
        digest = hashlib.sha256((target / name).read_bytes()).hexdigest()
        checks.append(f"{digest}  {name}\n")
    (target / "SHA256SUMS").write_bytes("".join(checks).encode())
    print("".join(checks), end="")


if __name__ == "__main__":
    main()

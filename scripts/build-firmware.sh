#!/usr/bin/env bash
# Builds Windows-OS (a Windows 11 style desktop for the NumWorks n0120) on YOUR
# machine, from NumWorks' official sources.
#
#   1. downloads Epsilon from github.com/numworks/epsilon at the pinned commit
#   2. applies patches/windows-os-epsilon.patch (desktop, windows, apps, and
#      the fix for the Home / On-Off crash)
#   3. compiles the userland for slot B (n0120, third-party apps allowed)
#   4. fills installer/ with what the one-click installer needs:
#        installer/firmware/  windows-os.B.dfu + windows-os.B.elf (symbols)
#        installer/numworks/  NumWorks' dfu.py, and the EADK runtime to link
#                             .nwa games at their address in slot B
#   5. if games/ holds .nwa games, copies them to installer/games/ and
#      pre-links them (installer/firmware/games.bin + games.json), so that
#      installing them needs no ARM toolchain (Windows PCs)
#
# Nothing from NumWorks is stored in this repository: their code is fetched
# from their own repository and only ever lives on your machine.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMMIT="$(cat "$ROOT/EPSILON_COMMIT")"
SRC="$ROOT/firmware"
VENV="$ROOT/.venv"
OUT="$ROOT/installer"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
MODEL=n0120

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Epsilon needs GNU Make >= 4.3 (macOS ships 3.81: brew install make -> gmake)
MAKE_BIN=make
if command -v gmake >/dev/null; then MAKE_BIN=gmake; fi

for tool in git "$MAKE_BIN" python3; do
  command -v "$tool" >/dev/null || { echo "Il manque « $tool »."; exit 1; }
done
if ! command -v arm-none-eabi-gcc >/dev/null; then
  echo "Le compilateur ARM est absent (macOS : brew install --cask gcc-arm-embedded)."
  exit 1
fi

say "1/5  Sources officielles d'Epsilon ($COMMIT)"
if [ ! -d "$SRC/.git" ]; then
  # Without blobs first: only the files of the pinned commit get downloaded.
  git clone --filter=blob:none --no-checkout https://github.com/numworks/epsilon.git "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$COMMIT" 2>/dev/null || true
git -C "$SRC" checkout --quiet --force "$COMMIT"
git -C "$SRC" clean -fdq -e output -e .venv

say "2/5  Application du patch Windows-OS"
git -C "$SRC" apply --whitespace=nowarn "$ROOT/patches/windows-os-epsilon.patch"

say "3/5  Environnement Python de compilation"
[ -x "$VENV/bin/python3" ] || python3 -m venv "$VENV"
"$VENV/bin/pip" -q install setuptools lz4 pypng pyelftools stringcase parse rich black
ln -sfn "$VENV" "$SRC/.venv"
ln -sfn ../.venv "$SRC/epsilon/.venv"

say "4/5  Compilation de Windows-OS ($MODEL, slot B) : quelques minutes"
PATH="$VENV/bin:$PATH" "$MAKE_BIN" -C "$SRC/epsilon" PLATFORM="$MODEL" \
  PYTHON="$VENV/bin/python3" -j"$JOBS" userland.allow3rdparty.B.dfu >"$ROOT/.build.log" 2>&1 \
  || { tail -30 "$ROOT/.build.log"; echo "Échec, voir .build.log"; exit 1; }

BUILD="$SRC/epsilon/output/release/$MODEL"
mkdir -p "$OUT/firmware" "$OUT/numworks/eadk" "$OUT/games"
cp "$BUILD/userland.allow3rdparty.B.dfu" "$OUT/firmware/windows-os.B.dfu"
arm-none-eabi-strip --strip-debug -o "$OUT/firmware/windows-os.B.elf" "$BUILD/userland.allow3rdparty.B.elf"

# NumWorks' DFU tool and the pyusb copy it ships with
cp "$SRC/epsilon/tools/device/dfu.py" "$OUT/numworks/dfu.py"
rm -rf "$OUT/numworks/usb"
cp -R "$SRC/epsilon/tools/device/usb" "$OUT/numworks/usb"

# EADK runtime for the games, as one relocatable object + its linker script
EADK="$SRC/epsilon/eadk"
TMP="$(mktemp -d)"
CPU="-mcpu=cortex-m7 -mthumb -mfloat-abi=hard -mfpu=fpv5-d16 -Os -fno-tree-loop-distribute-patterns -DPLATFORM_DEVICE=1 -ffunction-sections -fdata-sections"
INC="-I$EADK/include -I$SRC/shared -I$SRC/shared/ion/src/device"
# shellcheck disable=SC2086
arm-none-eabi-gcc $CPU $INC -c "$EADK/src/platform.c" -o "$TMP/platform.o"
# shellcheck disable=SC2086
arm-none-eabi-gcc $CPU $INC -std=c++20 -fno-exceptions -fno-rtti -c "$EADK/src/svc.cpp" -o "$TMP/svc.o"
# shellcheck disable=SC2086
arm-none-eabi-gcc $CPU $INC -std=c++20 -fno-exceptions -fno-rtti -c "$EADK/src/trampoline.cpp" -o "$TMP/trampoline.o"
arm-none-eabi-ld -r "$TMP/platform.o" "$TMP/svc.o" "$TMP/trampoline.o" -o "$OUT/numworks/eadk/eadk.o"
cp "$EADK/src/linker.ld" "$OUT/numworks/eadk/linker.ld"
rm -rf "$TMP"

say "5/5  Jeux"
rm -f "$OUT/firmware/games.bin" "$OUT/firmware/games.json"
shopt -s nullglob
GAMES=("$ROOT"/games/*.nwa)
if [ ${#GAMES[@]} -gt 0 ]; then
  cp "${GAMES[@]}" "$OUT/games/"
fi
INSTALLED=("$OUT"/games/*.nwa)
if [ ${#INSTALLED[@]} -gt 0 ]; then
  "$VENV/bin/python3" "$OUT/link_games.py" "$OUT/firmware/windows-os.B.elf" \
    "$OUT/games" "$OUT/firmware/games.bin"
  "$VENV/bin/python3" - "$OUT" <<'PY'
import hashlib, json, sys
from pathlib import Path
out = Path(sys.argv[1])
games = [{"name": p.name, "sha1": hashlib.sha1(p.read_bytes()).hexdigest()}
         for p in sorted((out / "games").glob("*.nwa"))]
(out / "firmware" / "games.json").write_text(json.dumps({"games": games}, indent=1))
PY
  echo "${#INSTALLED[@]} jeu(x) préparé(s)."
else
  echo "Aucun jeu (mets des .nwa dans games/ pour les inclure)."
fi

say "Windows-OS est prêt dans installer/."
echo "Mac : double-clique sur « installer/Installer Windows-OS.command » (ou : python3 installer/server.py)."
echo "Windows : l'installateur .exe se fait sur un PC Windows avec scripts/build-windows-installer.py,"
echo "          ou dans ta copie privée sur GitHub (Actions > Build Windows-OS)."

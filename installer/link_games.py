#!/usr/bin/env python3
"""Pre-install NWA games into the Windows-OS external apps area (slot B).

Does what NumWorks' nwlink does when installing an app from the website: link
each relocatable .nwa together with the EADK runtime at its final flash
address inside the slot's external apps area, and concatenate the results
(each app aligned on the external apps sector unit) into one binary image to
flash at the start of the area.

The EADK runtime (eadk.o) and its linker script template are produced by
scripts/build-firmware.sh from NumWorks' sources, in numworks/eadk/.

Usage: link_games.py <userland.elf> <games_dir> <out.bin> [--eadk DIR]
Needs arm-none-eabi-gcc only when there is at least one game.
"""

import argparse
import glob
import os
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

import sys

# Next to the .exe in the Windows installer (PyInstaller), else next to this file
HERE = (Path(sys.executable).resolve().parent if getattr(sys, "frozen", False)
        else Path(__file__).resolve().parent)
SECTOR = 0x10000  # Config::ExternalAppsSectorUnit on n0120
TRAMPOLINE = 0x0807FC00  # TrampolineOrigin (bootloader, internal flash)
CPU = ["-mcpu=cortex-m7", "-mthumb", "-mfloat-abi=hard", "-mfpu=fpv5-d16"]


def tool(name):
    path = shutil.which(name)
    if path is not None:
        return path
    exe = name + (".exe" if os.name == "nt" else "")
    patterns = ["/opt/homebrew/bin", "/usr/local/bin",
                "/Applications/ArmGNUToolchain/*/arm-none-eabi/bin",
                "/Applications/ArmGNUToolchain/bin"]
    if os.name == "nt":
        for root in (os.environ.get("ProgramFiles", r"C:\Program Files"),
                     os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")):
            patterns.append(os.path.join(root, "Arm GNU Toolchain arm-none-eabi", "*", "bin"))
            patterns.append(os.path.join(root, "GNU Arm Embedded Toolchain", "*", "bin"))
    for pattern in patterns:
        for directory in sorted(glob.glob(pattern), reverse=True):
            candidate = os.path.join(directory, exe)
            if os.path.exists(candidate):
                return candidate
    raise SystemExit(f"{name} introuvable : installe la chaîne ARM "
                     "(Arm GNU Toolchain : brew install --cask gcc-arm-embedded "
                     "sur Mac, ou l'installateur Windows sur developer.arm.com).")


def symbols(elf):
    """Symbol table of an ELF32 little-endian file, read in Python (no nm
    needed, so this also works on Windows without the ARM toolchain)."""
    data = Path(elf).read_bytes()
    shoff, = struct.unpack_from("<I", data, 0x20)
    shentsize, shnum = struct.unpack_from("<HH", data, 0x2E)
    sections = [struct.unpack_from("<IIIIIIIIII", data, shoff + i * shentsize)
                for i in range(shnum)]
    table = {}
    for sh in sections:
        if sh[1] != 2:  # SHT_SYMTAB
            continue
        strtab = sections[sh[6]]
        for off in range(sh[4], sh[4] + sh[5], 16):
            name_off, value = struct.unpack_from("<II", data, off)
            if name_off == 0:
                continue
            start = strtab[4] + name_off
            name = data[start:data.index(b"\0", start)].decode("ascii", "replace")
            table[name] = value
    return table


def linker_script(template, flash_start, flash_length, ram_start, ram_length):
    ld = (template.replace("{{ flashStart }}", hex(flash_start))
                  .replace("{{ flashLength }}", hex(flash_length))
                  .replace("{{ ramStart }}", hex(ram_start))
                  .replace("{{ ramLength }}", hex(ram_length))
                  .replace("{{ trampolineStart }}", hex(TRAMPOLINE)))
    # The app size in the header must cover the .data initial values stored
    # in flash after .rodata, otherwise the next app could overlap them.
    ld = ld.replace("    _eadk_app_end = .;\n", "")
    ld += ("\n_eadk_app_end = LOADADDR(.data) + SIZEOF(.data);\n"
           "_eadk_external_data_start = _eadk_app_end;\n"
           "_eadk_external_data_size = 0;\n")
    return ld


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("userland_elf")
    parser.add_argument("games_dir")
    parser.add_argument("out_bin")
    parser.add_argument("--eadk", default=str(HERE / "numworks" / "eadk"))
    args = parser.parse_args(argv)

    games = sorted(Path(args.games_dir).glob("*.nwa"), key=lambda p: p.name.lower())
    image = bytearray()
    if games:
        sym = symbols(args.userland_elf)
        area_start = sym["_external_apps_flash_start"]
        area_end = sym["_external_apps_flash_end"]
        ram_start = (sym["_external_apps_RAM_start"] + 7) & ~7
        ram_end = sym["_external_apps_RAM_end"]
        eadk_obj = os.path.join(args.eadk, "eadk.o")
        template = Path(args.eadk, "linker.ld").read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as tmp:
            for game in games:
                address = area_start + len(image)
                ld_path = os.path.join(tmp, "app.ld")
                Path(ld_path).write_text(linker_script(
                    template, address, area_end - address, ram_start,
                    ram_end - ram_start), encoding="utf-8")
                elf = os.path.join(tmp, "app.elf")
                binary = os.path.join(tmp, "app.bin")
                subprocess.run([tool("arm-none-eabi-gcc"), *CPU, "-nostartfiles",
                                "-nostdlib", "-T", ld_path, "-Wl,--gc-sections",
                                "-Wl,-e,_start", "-Wl,--no-warn-rwx-segments",
                                str(game), eadk_obj, "-lgcc", "-lc", "-lgcc", "-o", elf],
                               check=True)
                subprocess.run([tool("arm-none-eabi-objcopy"), "-O", "binary",
                                elf, binary], check=True)
                data = Path(binary).read_bytes()
                assert int.from_bytes(data[0:4], "little") == 0xDEC0BEBA
                size_field = int.from_bytes(data[24:28], "little")
                assert size_field >= len(data), (game, size_field, len(data))
                padded = (len(data) + SECTOR - 1) // SECTOR * SECTOR
                image += data + b"\xff" * (padded - len(data))
                print(f"{game.name:28s} @ {address:#x}  {len(data):7d} octets")
        assert area_start + len(image) + SECTOR <= area_end, "Trop de jeux"
    # One erased sector after the last app ends the app list
    image += b"\xff" * SECTOR
    Path(args.out_bin).write_bytes(image)
    print(f"Image des jeux : {len(image)} octets, {len(games)} jeu(x)")


if __name__ == "__main__":
    main()

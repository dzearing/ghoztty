#!/usr/bin/env python3
"""build-symbols-zip.py -- package the debug symbols of one Windows release
(T1936).

The MSI and the portable ZIP ship no .pdb on purpose (D64: ghoztty.pdb is
~100 MB beside a ~50 MB exe). Before this script nothing kept the PDBs of a
shipped build at all -- they lived only in the build machine's zig-out -- so a
stack taken from a user's hot or hung ghoztty.exe was a column of bare
`ghoztty+0x...` offsets that nobody could ever resolve. This builds the third
release asset, Ghoztty-symbols-<semver>-x64.zip, which is published beside the
other two and kept as long as the release is.

The zip is a SYMBOL STORE, not a folder of loose files: every entry sits at
the path a debugger asks a `srv*` symbol path for,

    ghoztty.pdb/<GUID><age>/ghoztty.pdb          the symbols
    ghoztty.exe/<TimeDateStamp><SizeOfImage>/ghoztty.exe   the image

so after unzipping it into a directory, `srv*<dir>` is the whole symbol path
-- cdb, WinDbg and WPA all resolve from it with no copying or renaming. The
images are in the store too because a minidump does not carry module memory
and x64 stack unwinding reads the image's .pdata.

What this script will NOT do is publish symbols that do not belong to the
exe. Every pair is checked before anything is written: the CodeView record
in the exe names a GUID and an age, the PDB's info stream carries a GUID and
its DBI stream an age, and a debugger silently refuses a PDB whose identity
differs. A mismatched pair (a rebuild between packaging and symbol capture, a
stale zig-out) fails the run instead of shipping symbols that look right and
resolve nothing.

Usage:
  build-symbols-zip.py --out <zip> --semver <X.Y.Z> --pair <image> <pdb> [--pair ...]
  build-symbols-zip.py --ids <image> [<pdb>]     print the store keys, check the pair

Requires only the Python standard library, so it runs on the Linux release
runner and on the Windows box alike.
"""

import argparse
import json
import os
import struct
import sys
import uuid
import zipfile

PDB_MAGIC = b"Microsoft C/C++ MSF 7.00\r\n\x1aDS\x00\x00\x00"
IMAGE_DEBUG_TYPE_CODEVIEW = 2


class SymbolError(Exception):
    pass


# -- PE side ----------------------------------------------------------------


def read_pe_identity(path):
    """Return the image's symbol-store identity: the image key, and the
    CodeView record's PDB name, GUID and age."""
    data = open(path, "rb").read()
    if data[:2] != b"MZ":
        raise SymbolError(f"{path}: not a PE image (no MZ header)")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe : pe + 4] != b"PE\x00\x00":
        raise SymbolError(f"{path}: not a PE image (no PE signature)")
    coff = pe + 4
    n_sections = struct.unpack_from("<H", data, coff + 2)[0]
    timestamp = struct.unpack_from("<I", data, coff + 4)[0]
    opt_size = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    magic = struct.unpack_from("<H", data, opt)[0]
    if magic == 0x20B:  # PE32+
        dirs = opt + 112
    elif magic == 0x10B:  # PE32
        dirs = opt + 96
    else:
        raise SymbolError(f"{path}: unknown optional-header magic {magic:#x}")
    size_of_image = struct.unpack_from("<I", data, opt + 56)[0]
    debug_rva, debug_size = struct.unpack_from("<II", data, dirs + 6 * 8)

    sections = []
    sec = opt + opt_size
    for i in range(n_sections):
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, sec + i * 40 + 8)
        sections.append((vaddr, max(vsize, rawsize), rawptr))

    def rva_to_offset(rva):
        for vaddr, size, rawptr in sections:
            if vaddr <= rva < vaddr + size:
                return rva - vaddr + rawptr
        raise SymbolError(f"{path}: RVA {rva:#x} is in no section")

    cv = None
    if debug_rva and debug_size:
        base = rva_to_offset(debug_rva)
        for i in range(debug_size // 28):
            ent = base + i * 28
            dtype = struct.unpack_from("<I", data, ent + 12)[0]
            dsize, _, dptr = struct.unpack_from("<III", data, ent + 16)
            if dtype == IMAGE_DEBUG_TYPE_CODEVIEW and data[dptr : dptr + 4] == b"RSDS":
                guid = uuid.UUID(bytes_le=bytes(data[dptr + 4 : dptr + 20]))
                age = struct.unpack_from("<I", data, dptr + 20)[0]
                raw = data[dptr + 24 : dptr + dsize]
                name = raw.split(b"\x00", 1)[0].decode("utf-8", "replace")
                cv = (guid, age, name)
                break
    if cv is None:
        raise SymbolError(
            f"{path}: no CodeView (RSDS) debug record -- the image was linked "
            "without debug info (-Dstrip=true?), so no PDB can ever match it"
        )
    guid, age, pdb_path = cv
    return {
        "image": os.path.basename(path),
        "image_key": f"{timestamp:08X}{size_of_image:x}",
        "pdb_name": pdb_path.replace("\\", "/").rsplit("/", 1)[-1],
        "guid": guid,
        "age": age,
    }


# -- PDB side ---------------------------------------------------------------


def read_pdb_identity(path):
    """Return (guid, info_age, dbi_age) from the PDB's MSF streams 1 and 3."""
    with open(path, "rb") as f:
        head = f.read(56)
        if head[:32] != PDB_MAGIC:
            raise SymbolError(f"{path}: not an MSF 7.00 PDB")
        block_size, _, _, dir_bytes, _, block_map = struct.unpack_from("<IIIIII", head, 32)

        def read_blocks(blocks, length):
            out = bytearray()
            for b in blocks:
                f.seek(b * block_size)
                out += f.read(block_size)
            return bytes(out[:length])

        n_dir_blocks = -(-dir_bytes // block_size)
        f.seek(block_map * block_size)
        dir_block_list = struct.unpack(f"<{n_dir_blocks}I", f.read(4 * n_dir_blocks))
        directory = read_blocks(dir_block_list, dir_bytes)

        n_streams = struct.unpack_from("<I", directory, 0)[0]
        sizes = struct.unpack_from(f"<{n_streams}I", directory, 4)
        pos = 4 + 4 * n_streams
        streams = []
        for size in sizes:
            if size == 0xFFFFFFFF:
                streams.append((0, ()))
                continue
            n = -(-size // block_size)
            streams.append((size, struct.unpack_from(f"<{n}I", directory, pos)))
            pos += 4 * n

        def stream(i):
            if i >= len(streams):
                raise SymbolError(f"{path}: no stream {i}")
            size, blocks = streams[i]
            return read_blocks(blocks, size)

        info = stream(1)
        _, _, info_age = struct.unpack_from("<III", info, 0)
        guid = uuid.UUID(bytes_le=bytes(info[12:28]))
        dbi = stream(3)
        dbi_age = struct.unpack_from("<I", dbi, 8)[0] if len(dbi) >= 12 else info_age
    return guid, info_age, dbi_age


def pdb_key(guid, age):
    return guid.hex.upper() + f"{age:x}"


def check_pair(image, pdb):
    """The identity check a debugger applies, done before publishing."""
    pe = read_pe_identity(image)
    guid, info_age, dbi_age = read_pdb_identity(pdb)
    if os.path.basename(pdb).lower() != pe["pdb_name"].lower():
        raise SymbolError(
            f"{image} names its PDB '{pe['pdb_name']}', not '{os.path.basename(pdb)}'"
        )
    if guid != pe["guid"]:
        raise SymbolError(
            f"{pdb} does not belong to {image}: PDB GUID {guid} != image GUID "
            f"{pe['guid']} (a rebuild between the image and the symbols?)"
        )
    if dbi_age != pe["age"]:
        raise SymbolError(
            f"{pdb} does not belong to {image}: PDB age {dbi_age} != image age {pe['age']}"
        )
    pe["pdb_key"] = pdb_key(guid, pe["age"])
    pe["info_age"] = info_age
    return pe


# -- the zip ----------------------------------------------------------------

README = """Ghoztty {semver} for Windows -- debug symbols

This zip is a symbol store for the ghoztty.exe, ghoztty.com and
ghoztty-agent.exe of the {semver} release (commit {commit}). Unzip it into a
directory and point a debugger or profiler at it:

    set _NT_SYMBOL_PATH=srv*C:\\path\\to\\unzipped;srv*%LOCALAPPDATA%\\ghoztty\\symcache*https://msdl.microsoft.com/download/symbols

Then cdb/WinDbg (`.reload /f`), or WPA on a WPR trace, names Ghoztty frames
instead of printing ghoztty+0x... offsets. symbols.json lists every file in
the store with the identity (GUID/age, timestamp/size) it was verified against
before it was published. The full triage recipe is in HACKING.md.
"""


def build(out, semver, pairs, commit):
    # Every pair is checked before the first byte is written, so a bad pair
    # leaves no partial zip behind.
    store = []
    files = {}  # archive path -> source; ghoztty.exe and .com share one PDB
    for image, pdb in pairs:
        ident = check_pair(image, pdb)
        pdb_name = os.path.basename(pdb)
        img_arc = f"{ident['image']}/{ident['image_key']}/{ident['image']}"
        pdb_arc = f"{pdb_name}/{ident['pdb_key']}/{pdb_name}"
        files[img_arc] = image
        files[pdb_arc] = pdb
        store.append(
            {
                "image": ident["image"],
                "image_key": ident["image_key"],
                "pdb": pdb_name,
                "pdb_key": ident["pdb_key"],
                "guid": str(ident["guid"]),
                "age": ident["age"],
                "files": [img_arc, pdb_arc],
            }
        )
        print(f"    {ident['image']}: {ident['image_key']}  {pdb_name}: {ident['pdb_key']}  (match)")

    tmp = out + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for arc, src in files.items():
            z.write(src, arc)
        manifest = {"semver": semver, "commit": commit, "store": store}
        z.writestr("symbols.json", json.dumps(manifest, indent=2) + "\n")
        z.writestr("README.txt", README.format(semver=semver, commit=commit))
    os.replace(tmp, out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    ap.add_argument("--out")
    ap.add_argument("--semver")
    ap.add_argument("--commit", default="")
    ap.add_argument("--pair", nargs=2, action="append", metavar=("IMAGE", "PDB"))
    ap.add_argument("--ids", nargs="+", metavar="FILE")
    a = ap.parse_args()
    try:
        if a.ids:
            if len(a.ids) == 2:
                ident = check_pair(a.ids[0], a.ids[1])
                print(f"MATCH image={ident['image_key']} pdb={ident['pdb_key']}")
            else:
                ident = read_pe_identity(a.ids[0])
                print(
                    f"image={ident['image_key']} pdb={ident['pdb_name']} "
                    f"key={pdb_key(ident['guid'], ident['age'])}"
                )
            return 0
        if not (a.out and a.semver and a.pair):
            ap.error("--out, --semver and at least one --pair are required")
        build(a.out, a.semver, a.pair, a.commit)
        print(f"==> symbols: {a.out} ({os.path.getsize(a.out) // (1024 * 1024)} MB)")
        return 0
    except (SymbolError, OSError, struct.error) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

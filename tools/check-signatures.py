"""Validate the UE4SS AOB signatures against an actual game executable.

Run this after a game update, before launching. It reads the patterns out of
Signatures/*.lua, scans the exe, and reports whether UE4SS would accept each
one. No dependencies beyond the standard library.

    python tools/check-signatures.py
    python tools/check-signatures.py --exe "D:/path/to/SWGR-Win64-Shipping.exe"

UE4SS dedupes candidates by RESOLVED value, not by match count, so a pattern
matching several sites is fine as long as they all resolve to the same address.
A pattern resolving to two different addresses is rejected, and a pattern
matching nothing fails the scan.

Exit codes: 0 all good, 1 something would be rejected, 2 could not run.
"""
import argparse
import os
import re
import struct
import sys

DEFAULT_EXE = (r"C:\Program Files (x86)\Steam\steamapps\common"
               r"\STAR WARS Galactic Racer\Griffin\Binaries\Win64"
               r"\SWGR-Win64-Shipping.exe")

# How each signature turns a match into an address. Mirrors the OnMatchFound in
# the corresponding .lua file.
#   ("direct", 0)            -> the match address is the answer
#   ("riprel", instr, disp)  -> match + instr + int32_at(match + disp)
RESOLVERS = {
    "GMalloc": ("riprel", 7, 3),
    "FName_ToString": ("direct", None, None),
    "FName_Constructor": ("direct", None, None),
    "GUObjectArray": ("riprel", 7, 3),
}


def read_sections(data):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("not a PE file")
    count = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    out = []
    table = pe + 24 + opt_size
    for i in range(count):
        entry = table + i * 40
        name = data[entry:entry + 8].rstrip(b"\0").decode("latin1")
        vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", data, entry + 8)
        out.append((name, vaddr, vsize, raddr, rsize))
    return out


def offset_to_rva(sections, offset):
    for _name, vaddr, _vsize, raddr, rsize in sections:
        if raddr <= offset < raddr + rsize:
            return vaddr + (offset - raddr)
    return None


def pattern_from_lua(path):
    """Pull the byte pattern out of a signature file's Register()."""
    text = open(path, encoding="utf-8", errors="replace").read()
    # Ignore anything inside a --[[ ]] comment block, so documented examples of
    # old patterns are not mistaken for the live one.
    text = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
    match = re.search(r'return\s*"([0-9A-Fa-f?\s]+)"', text)
    return match.group(1).strip() if match else None


def scan(data, pattern):
    tokens = pattern.split()
    regex = b"".join(b"." if t == "?" else re.escape(bytes([int(t, 16)]))
                     for t in tokens)
    return [m.start() for m in re.finditer(regex, data, re.S)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", default=DEFAULT_EXE)
    ap.add_argument("--signatures", default=None)
    args = ap.parse_args()

    sig_dir = args.signatures or os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Signatures")

    if not os.path.isfile(args.exe):
        print("cannot find exe: %s" % args.exe)
        return 2
    if not os.path.isdir(sig_dir):
        print("cannot find signatures: %s" % sig_dir)
        return 2

    data = open(args.exe, "rb").read()
    sections = read_sections(data)
    print("exe: %s" % args.exe)
    print("     %d bytes, %d sections" % (len(data), len(sections)))
    print()

    failures = []
    for name in sorted(os.listdir(sig_dir)):
        if not name.endswith(".lua"):
            continue
        label = name[:-4]
        pattern = pattern_from_lua(os.path.join(sig_dir, name))
        if not pattern:
            print("%-20s no pattern found in the file" % label)
            failures.append(label)
            continue

        hits = scan(data, pattern)
        kind, instr_len, disp_at = RESOLVERS.get(label, ("direct", None, None))

        resolved = set()
        for off in hits:
            rva = offset_to_rva(sections, off)
            if rva is None:
                continue
            if kind == "riprel":
                disp = struct.unpack_from("<i", data, off + disp_at)[0]
                resolved.add(rva + instr_len + disp)
            else:
                resolved.add(rva)

        if len(hits) == 0:
            verdict = "FAIL  pattern no longer matches"
            failures.append(label)
        elif len(resolved) == 1:
            verdict = "ok    resolves to 0x%X" % resolved.pop()
        else:
            verdict = ("FAIL  %d matches resolving to %d different addresses: %s"
                       % (len(hits), len(resolved),
                          ", ".join("0x%X" % r for r in sorted(resolved))))
            failures.append(label)

        print("%-20s %d match(es)  %s" % (label, len(hits), verdict))

    print()
    if failures:
        print("WOULD BE REJECTED: %s" % ", ".join(failures))
        print()
        print("Do not launch with the mod installed. A signature that matches but")
        print("resolves wrongly hands the engine a bad pointer, which crashes")
        print("rather than erroring. Safest recovery is to remove the affected")
        print("files from ue4ss/UE4SS_Signatures so the generic scanner tries")
        print("instead: a failed scan refuses to start, which is the safe outcome.")
        return 1

    print("All signatures resolve cleanly. Safe to launch.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Resolve an address in the shipping executable to its function, and disassemble it.

Written to answer "where did the main thread die" without waiting hours for a
full IDA auto-analysis. The executable is about 490 MB with roughly 430 MB marked
executable, so a disassembler that insists on analysing all of it is the slow way
to answer a question about one address.

The game's section names are scrambled (.rsrc holds code, .debug holds code), so
a padding scan for function starts guesses wrong. The x64 exception directory is
authoritative instead: every non-leaf function has a RUNTIME_FUNCTION entry giving
its exact bounds, and the UNWIND_INFO behind it records how much stack the
prologue reserves, which is the number that matters for a stack-overflow question.

Usage:
    python resolve-address.py <exe> <addr> [addr ...]

Addresses are hex, with or without 0x, and are absolute at the preferred image
base. A dump reports module+offset, so add the base: offset 0x15FD1 is 0x140015FD1.

Requires capstone:  python -m pip install capstone
"""
import struct
import sys

try:
    from capstone import Cs, CS_ARCH_X86, CS_MODE_64
except ImportError:
    sys.exit("needs capstone: python -m pip install capstone")

REG = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
       "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]
IMAGE_SCN_MEM_EXECUTE = 0x20000000


def load(path):
    data = open(path, "rb").read()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        sys.exit("%s is not a PE file" % path)
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    optsz = struct.unpack_from("<H", data, pe + 20)[0]
    magic = struct.unpack_from("<H", data, pe + 24)[0]
    if magic != 0x20B:
        sys.exit("only PE32+ (64-bit) is handled")
    base = struct.unpack_from("<Q", data, pe + 24 + 24)[0]
    exc_rva, exc_sz = struct.unpack_from("<II", data, pe + 24 + 112 + 3 * 8)
    secs = []
    for i in range(nsec):
        s = pe + 24 + optsz + i * 40
        name = data[s:s + 8].rstrip(b"\0").decode("latin1")
        vsz, vaddr, rsz, raddr = struct.unpack_from("<IIII", data, s + 8)
        chars = struct.unpack_from("<I", data, s + 36)[0]
        secs.append((name, vaddr, vsz, raddr, rsz, chars))
    return data, base, secs, exc_rva, exc_sz


def to_offset(secs, rva):
    """File offset for an RVA, or None when the RVA is in a section's virtual tail."""
    for name, vaddr, vsz, raddr, rsz, chars in secs:
        if vaddr <= rva < vaddr + max(vsz, rsz):
            if rva - vaddr >= rsz:
                return None, name
            return raddr + (rva - vaddr), name
    return None, None


def unwind_alloc(data, secs, uw_rva):
    """Stack bytes the prologue reserves, and the ops that reserve them."""
    off, _ = to_offset(secs, uw_rva)
    if off is None:
        return None
    flags = data[off] >> 3
    ncodes = data[off + 2]
    codes = off + 4
    ops, alloc, i = [], 0, 0
    while i < ncodes:
        op = data[codes + i * 2 + 1] & 0xF
        info = data[codes + i * 2 + 1] >> 4
        if op == 0:                                  # PUSH_NONVOL
            ops.append("push %s" % REG[info])
            alloc += 8
            i += 1
        elif op == 2:                                # ALLOC_SMALL
            n = info * 8 + 8
            ops.append("sub rsp, 0x%X" % n)
            alloc += n
            i += 1
        elif op == 1:                                # ALLOC_LARGE
            if info == 0:
                n = struct.unpack_from("<H", data, codes + (i + 1) * 2)[0] * 8
                i += 2
            else:
                n = struct.unpack_from("<I", data, codes + (i + 1) * 2)[0]
                i += 3
            ops.append("sub rsp, 0x%X" % n)
            alloc += n
        elif op == 3:                                # SET_FPREG
            ops.append("frame ptr %s" % REG[info])
            i += 1
        elif op in (4, 8):
            i += 2
        elif op in (5, 9):
            i += 3
        else:
            i += 1
    return {"alloc": alloc, "ops": ops, "flags": flags, "chained": bool(flags & 4)}


def callers(data, base, secs, target_va, limit=20):
    """Direct E8 rel32 calls to an address. Names a function by who reaches it."""
    found = []
    for name, vaddr, vsz, raddr, rsz, chars in secs:
        if not (chars & IMAGE_SCN_MEM_EXECUTE) or not rsz:
            continue
        blob = data[raddr:raddr + rsz]
        i = 0
        while True:
            i = blob.find(b"\xe8", i)
            if i < 0 or i + 5 > len(blob):
                break
            rel = struct.unpack_from("<i", blob, i + 1)[0]
            src = base + vaddr + i
            if src + 5 + rel == target_va:
                found.append((src, name))
                if len(found) >= limit:
                    return found
            i += 1
    return found


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    path = argv[1]
    data, base, secs, exc_rva, exc_sz = load(path)
    eoff, esec = to_offset(secs, exc_rva)
    nfun = exc_sz // 12
    print("%s" % path)
    print("image base 0x%X, %d bytes, %d RUNTIME_FUNCTION entries in %s\n"
          % (base, len(data), nfun, esec))

    md = Cs(CS_ARCH_X86, CS_MODE_64)

    for arg in argv[2:]:
        va = int(arg, 16)
        rva = va - base
        print("=" * 74)
        print("0x%X  (RVA 0x%X)" % (va, rva))

        lo, hi, hit = 0, nfun - 1, None
        while lo <= hi:
            mid = (lo + hi) // 2
            b, e, u = struct.unpack_from("<III", data, eoff + mid * 12)
            if rva < b:
                hi = mid - 1
            elif rva >= e:
                lo = mid + 1
            else:
                hit = (b, e, u)
                break
        if not hit:
            print("   no RUNTIME_FUNCTION covers it: a leaf function, or data\n")
            continue

        b, e, u = hit
        foff, fsec = to_offset(secs, b)
        print("   function 0x%X .. 0x%X (0x%X bytes) in %s, +0x%X in"
              % (base + b, base + e, e - b, fsec, rva - b))
        info = unwind_alloc(data, secs, u)
        if info:
            print("   prologue reserves 0x%X bytes (%d): %s"
                  % (info["alloc"], info["alloc"], ", ".join(info["ops"])))
        cs = callers(data, base, secs, base + b)
        if cs:
            print("   direct callers: %s" % ", ".join("0x%X" % c for c, _ in cs))
        else:
            print("   direct callers: none found (reached indirectly, via a vtable "
                  "or a dispatch table)")
        print()

        # the prologue, then a window around the address itself
        for label, start, length in (("prologue", foff, 0x60),
                                     ("around 0x%X" % va,
                                      max(foff, foff + (rva - b) - 0x30), 0x80)):
            print("   %s:" % label)
            for ins in md.disasm(data[start:start + length], base + b + (start - foff)):
                if ins.address >= base + e:
                    break
                print("      %016X  %-23s %s %s%s"
                      % (ins.address,
                         " ".join("%02x" % x for x in ins.bytes)[:23],
                         ins.mnemonic, ins.op_str,
                         "   <<<<" if ins.address == va else ""))
            print()


if __name__ == "__main__":
    main(sys.argv)

#!/usr/bin/env python3
"""
fix_ios6_bindings.py — make a 9.3-SDK-linked armv7 binary loadable on iOS 6.

Why this exists
---------------
The project links against theos/sdks iPhoneOS9.3.sdk. In that SDK,
Foundation.tbd re-exports several Objective-C classes to other libraries:

  * NSURL / NSURLRequest / NSMutableURLRequest / NSURLConnection -> CFNetwork
  * NSArray / NSMutableArray / NSDictionary / NSMutableDictionary /
    NSCache / NSUserDefaults                              -> CoreFoundation

ld follows the re-export chain, so the bind table in the produced binary
points those symbols at CFNetwork / CoreFoundation. That is correct on
iOS 8+, where those frameworks really export the classes — but on iOS 6
the classes live ONLY in Foundation, and dyld aborts at launch with
"Symbol not found: _OBJC_CLASS_$_NSMutableURLRequest, Expected in:
CFNetwork" (EXC_BREAKPOINT before main()).

What this script does
---------------------
1. Parse the Mach-O (32-bit armv7, MH_EXECUTE) load commands and the
   dyld_info bind / weak_bind / lazy_bind tables.
2. Re-point every binding of the affected ObjC class symbols from
   CFNetwork / CoreFoundation to Foundation.
3. If CFNetwork ends up with zero references, retarget its LC_LOAD_DYLIB
   to /usr/lib/libSystem.B.dylib (already loaded; keeps every ordinal
   stable so no re-numbering is needed).
4. Strip the now-invalid code signature bytes; the CI caller re-signs
   with `ldid -S`.

The patch never changes any byte length, so all other file offsets stay
valid. The script is idempotent and fails loudly (exit 1) whenever the
binary does not match expectations, so CI never packages a silently
unpatched build.
"""

import struct
import sys

# --- dyld_info opcodes -----------------------------------------------------
OP_DONE = 0x00
OP_SET_DYLIB_ORDINAL_IMM = 0x10
OP_SET_DYLIB_ORDINAL_ULEB = 0x20
OP_SET_DYLIB_SPECIAL_IMM = 0x30
OP_SET_SYMBOL_TRAILING_FLAGS = 0x40
OP_SET_TYPE_IMM = 0x50
OP_SET_ADDEND_SLEB = 0x60
OP_SET_SEGMENT_AND_OFFSET_ULEB = 0x70
OP_ADD_ADDR_ULEB = 0x80
OP_DO_BIND = 0x90
OP_DO_BIND_ADD_ADDR_ULEB = 0xA0
OP_DO_BIND_ADD_ADDR_IMM_SCALED = 0xB0
OP_DO_BIND_ULEB_TIMES_SKIPPING_ULEB = 0xC0

DO_BIND_OPS = (
    OP_DO_BIND,
    OP_DO_BIND_ADD_ADDR_ULEB,
    OP_DO_BIND_ADD_ADDR_IMM_SCALED,
    OP_DO_BIND_ULEB_TIMES_SKIPPING_ULEB,
)

LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x18
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_CODE_SIGNATURE = 0x1D

MH_MAGIC = 0xFEEDFACE
MH_EXECUTE = 0x02
CPU_TYPE_ARM = 12

# Classes that must be bound to Foundation on iOS 6 (see header comment).
RELOCATE_TO_FOUNDATION = {
    b"_OBJC_CLASS_$_NSMutableURLRequest",
    b"_OBJC_CLASS_$_NSURLRequest",
    b"_OBJC_CLASS_$_NSURLConnection",
    b"_OBJC_CLASS_$_NSURL",
    b"_OBJC_CLASS_$_NSArray",
    b"_OBJC_CLASS_$_NSMutableArray",
    b"_OBJC_CLASS_$_NSDictionary",
    b"_OBJC_CLASS_$_NSMutableDictionary",
    b"_OBJC_CLASS_$_NSCache",
    b"_OBJC_CLASS_$_NSUserDefaults",
}

# CoreFoundation symbols that legitimately stay in CoreFoundation on iOS 6.
KEEP_IN_COREFOUNDATION = {
    b"_CFRelease",
    b"___CFConstantStringClassReference",
}


def die(msg):
    sys.stderr.write("fix_ios6_bindings: ERROR: %s\n" % msg)
    sys.exit(1)


def skip_uleb(data, p):
    """Return position just past the ULEB128 that starts at p."""
    while data[p] & 0x80:
        p += 1
    return p + 1


def read_uleb(data, p):
    result = 0
    shift = 0
    while True:
        b = data[p]
        p += 1
        result |= (b & 0x7F) << shift
        shift += 7
        if not (b & 0x80):
            break
    return result, p


class MachO(object):
    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = bytearray(f.read())
        self._parse()

    def _parse(self):
        d = self.data
        if len(d) < 28:
            die("file too small to be Mach-O")
        magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags = struct.unpack_from(
            "<7I", d, 0
        )
        if magic != MH_MAGIC:
            die("not a 32-bit Mach-O (magic=0x%x)" % magic)
        if filetype != MH_EXECUTE:
            die("not an executable (filetype=0x%x)" % filetype)
        if cputype != CPU_TYPE_ARM:
            die("not ARM (cputype=%d)" % cputype)
        self.nccmds = ncmds
        self.cmds = []  # (cmd, cmdsize, offset)
        off = 28
        for _ in range(ncmds):
            if off + 8 > len(d):
                die("load command overruns file")
            cmd, cmdsize = struct.unpack_from("<II", d, off)
            if cmdsize < 8 or off + cmdsize > len(d):
                die("bad load command size at offset %d" % off)
            self.cmds.append((cmd, cmdsize, off))
            off += cmdsize

        # dylib list; ordinal N == dylibs[N-1]
        self.dylibs = []  # (ordinal, cmd, cmdsize, offset, path)
        for cmd, cmdsize, off in self.cmds:
            if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
                nameoff = struct.unpack_from("<I", d, off + 8)[0]
                stop = d.index(b"\x00", off + nameoff)
                path = bytes(d[off + nameoff : stop]).decode("utf-8", "replace")
                self.dylibs.append((len(self.dylibs) + 1, cmd, cmdsize, off, path))

        # dyld info
        self.info = None
        for cmd, cmdsize, off in self.cmds:
            if cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
                f = struct.unpack_from("<10I", d, off + 8)
                self.info = {
                    "lc_off": off,
                    "bind_off": f[2], "bind_size": f[3],
                    "weak_off": f[4], "weak_size": f[5],
                    "lazy_off": f[6], "lazy_size": f[7],
                }
        if self.info is None:
            die("no LC_DYLD_INFO load command found")

    def lib_of_ordinal(self, ordinal):
        for idx, cmd, cmdsize, off, path in self.dylibs:
            if idx == ordinal:
                return path
        return "?"

    def tables(self):
        info = self.info
        for label, off_key, size_key in (
            ("bind", "bind_off", "bind_size"),
            ("weak", "weak_off", "weak_size"),
            ("lazy", "lazy_off", "lazy_size"),
        ):
            off, size = info[off_key], info[size_key]
            if off and size:
                yield label, off, size

    def walk_bindings(self):
        """Yield (ordinal, symbol, ord_opcode_pos, ord_is_uleb, do_bind_pos)
        for every binding across all tables.

        ord_opcode_pos is the position of the opcode byte that established
        the current ordinal (for ULEB opcodes: position of the opcode, with
        the payload starting at ord_opcode_pos + 1).
        """
        d = self.data
        for label, off, size in self.tables():
            p = off
            end = off + size
            ordinal = 0
            symbol = b""
            ord_pos = None
            ord_is_uleb = False
            while p < end:
                op = d[p]
                imm = op & 0x0F
                top = op & 0xF0
                if op == OP_DONE:
                    break
                if top == OP_SET_DYLIB_ORDINAL_IMM:
                    ordinal = imm
                    ord_pos, ord_is_uleb = p, False
                elif top == OP_SET_DYLIB_ORDINAL_ULEB:
                    v, p = read_uleb(d, p + 1)
                    ordinal = v
                    ord_pos, ord_is_uleb = p - 1, True  # opcode byte
                elif top == OP_SET_DYLIB_SPECIAL_IMM:
                    ordinal = -imm if imm else 0
                    ord_pos, ord_is_uleb = p, False
                elif top == OP_SET_SYMBOL_TRAILING_FLAGS:
                    stop = d.index(b"\x00", p + 1)
                    symbol = bytes(d[p + 1 : stop])
                    p = stop
                elif top == OP_SET_ADDEND_SLEB:
                    p = skip_uleb(d, p + 1) - 1  # SLEB same shape as ULEB
                elif top == OP_SET_SEGMENT_AND_OFFSET_ULEB or top == OP_ADD_ADDR_ULEB:
                    p = skip_uleb(d, p + 1) - 1
                elif top == OP_DO_BIND_ADD_ADDR_ULEB:
                    p = skip_uleb(d, p + 1) - 1
                elif top == OP_DO_BIND_ULEB_TIMES_SKIPPING_ULEB:
                    p = skip_uleb(d, p + 1) - 1
                    p = skip_uleb(d, p + 1) - 1
                if top in DO_BIND_OPS:
                    yield ordinal, symbol, ord_pos, ord_is_uleb, p
                p += 1

    def bindings_by_ordinal(self):
        result = {}
        for ordinal, symbol, _, _, _ in self.walk_bindings():
            result.setdefault(ordinal, set()).add(symbol)
        return result

    def set_ordinal(self, ord_pos, ord_is_uleb, new_ordinal):
        """Rewrite the ordinal-setting opcode at ord_pos to new_ordinal.
        Byte length is preserved (small ordinals only)."""
        d = self.data
        if not ord_is_uleb:
            if new_ordinal > 15:
                die("ordinal %d does not fit an IMM opcode" % new_ordinal)
            d[ord_pos] = OP_SET_DYLIB_ORDINAL_IMM | new_ordinal
        else:
            if new_ordinal > 127:
                die("ordinal %d does not fit a 1-byte ULEB" % new_ordinal)
            # The old ULEB payload must itself be a single byte, otherwise
            # rewriting it in place would corrupt the opcode stream.
            pos = ord_pos + 1
            if d[pos] & 0x80:
                die("multi-byte ordinal ULEB at %d; in-place rewrite unsafe" % pos)
            d[pos] = new_ordinal & 0x7F
        return True

    def retarget_dylib(self, ordinal, new_path):
        d = self.data
        for idx, cmd, cmdsize, off, path in self.dylibs:
            if idx == ordinal:
                nameoff = struct.unpack_from("<I", d, off + 8)[0]
                old_len = d.index(b"\x00", off + nameoff) - (off + nameoff)
                new = new_path.encode("ascii")
                if len(new) > old_len:
                    die("cannot retarget dylib: new path longer than old")
                d[off + nameoff : off + cmdsize] = b"\x00" * (cmdsize - nameoff)
                start = off + nameoff
                d[start : start + len(new)] = new
                return True
        return False

    def strip_code_signature(self):
        """Remove the stale code signature bytes (they no longer match after
        patching) and shrink the file so ldid can append a fresh one.
        Also fixes up __LINKEDIT's filesize so the truncated file stays
        self-consistent."""
        d = self.data
        sig_dataoff = None
        for cmd, cmdsize, off in self.cmds:
            if cmd == LC_CODE_SIGNATURE:
                dataoff, datasize = struct.unpack_from("<II", d, off + 8)
                if datasize:
                    d[dataoff : dataoff + datasize] = b"\x00" * datasize
                struct.pack_into("<II", d, off + 8, dataoff, 0)
                sig_dataoff = dataoff
                if datasize:
                    del d[dataoff:]
                break
        if sig_dataoff is None:
            return False
        # __LINKEDIT must not claim file bytes past the truncation point.
        for cmd, cmdsize, off in self.cmds:
            if cmd == 0x01:  # LC_SEGMENT
                segname = bytes(d[off + 8 : off + 24]).rstrip(b"\x00")
                if segname == b"__LINKEDIT":
                    vmaddr, vmsize, fileoff, filesize = struct.unpack_from(
                        "<IIII", d, off + 24
                    )
                    newsize = sig_dataoff - fileoff
                    if 0 < newsize < filesize:
                        struct.pack_into(
                            "<IIII", d, off + 24, vmaddr, vmsize, fileoff, newsize
                        )
                    break
        return True

    def save(self, path):
        with open(path, "wb") as f:
            f.write(bytes(self.data))


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: fix_ios6_bindings.py <mach-o binary>\n")
        return 1
    path = sys.argv[1]
    mo = MachO(path)

    # --- 1. report current state -----------------------------------------
    by_ord = mo.bindings_by_ordinal()
    suspects = []
    for ordinal in sorted(by_ord):
        lib = mo.lib_of_ordinal(ordinal)
        for s in by_ord[ordinal]:
            if s in RELOCATE_TO_FOUNDATION and ("CFNetwork" in lib or "CoreFoundation" in lib):
                suspects.append((ordinal, lib, s))
    print(
        "fix_ios6_bindings: %d ObjC class bindings target CFNetwork/CoreFoundation:"
        % len(suspects)
    )
    for ordinal, lib, s in suspects:
        print("  ord %d (%s): %s" % (ordinal, lib.split("/")[-1], s.decode()))

    if not suspects:
        print("fix_ios6_bindings: nothing to patch - binary already iOS 6 clean")
        return 0

    # --- 2. relocate bindings to Foundation -------------------------------
    fnd_idx = None
    for idx, cmd, cmdsize, off, p in mo.dylibs:
        if p.endswith("Foundation.framework/Foundation"):
            fnd_idx = idx
    if fnd_idx is None:
        die("Foundation not linked; cannot relocate bindings")

    patched = 0
    for ordinal, symbol, ord_pos, ord_is_uleb, _bind_pos in mo.walk_bindings():
        if symbol not in RELOCATE_TO_FOUNDATION:
            continue
        if ordinal == fnd_idx:
            continue
        if ord_pos is None:
            die("binding for %s has no ordinal opcode" % symbol.decode())
        if ord_is_uleb:
            die("unexpected multi-byte ordinal ULEB for %s" % symbol.decode())
        mo.set_ordinal(ord_pos, ord_is_uleb, fnd_idx)
        patched += 1
    print("fix_ios6_bindings: relocated %d bindings to Foundation" % patched)

    # --- 3. verify ----------------------------------------------------------
    after = mo.bindings_by_ordinal()
    for ordinal in sorted(after):
        lib = mo.lib_of_ordinal(ordinal)
        for s in after[ordinal]:
            if s in RELOCATE_TO_FOUNDATION and "Foundation" not in lib:
                die("post-patch verification failed: %s still bound to %s" % (s.decode(), lib))

    # CoreFoundation keeps only its C symbols
    for ordinal in sorted(after):
        lib = mo.lib_of_ordinal(ordinal)
        if "CoreFoundation" in lib:
            for s in after[ordinal]:
                if s not in KEEP_IN_COREFOUNDATION and s.startswith(b"_OBJC_CLASS"):
                    die("CoreFoundation still exports ObjC class binding %s" % s.decode())

    # --- 4. drop CFNetwork if unused ---------------------------------------
    for idx, cmd, cmdsize, off, p in mo.dylibs:
        if p.endswith("CFNetwork.framework/CFNetwork"):
            remaining = after.get(idx, set())
            if not remaining:
                mo.retarget_dylib(idx, "/usr/lib/libSystem.B.dylib")
                print(
                    "fix_ios6_bindings: CFNetwork unreferenced -> LC_LOAD_DYLIB retargeted to libSystem.B.dylib"
                )
            else:
                print(
                    "fix_ios6_bindings: CFNetwork still referenced by %d symbol(s); kept"
                    % len(remaining)
                )
            break

    # --- 5. strip stale signature ------------------------------------------
    if mo.strip_code_signature():
        print("fix_ios6_bindings: stale code signature cleared (re-sign with ldid -S)")

    mo.save(path)
    print("fix_ios6_bindings: patched %s in place" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main())

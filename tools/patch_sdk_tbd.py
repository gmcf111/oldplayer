#!/usr/bin/env python3
"""
patch_sdk_tbd.py — fill in export gaps in the theos/sdks iPhoneOS9.3.sdk stubs.

Why this exists
---------------
The CI build links against the community iPhoneOS9.3.sdk published by
theos/sdks. That SDK ships .tbd text stubs rather than real dylibs, and a
few stubs are incomplete. Two gaps break the armv7 link:

1. liblaunch.tbd is absent entirely, even though libSystem.tbd re-exports
   /usr/lib/system/liblaunch.dylib. ld reports:
       file not found: /usr/lib/system/liblaunch.dylib

2. libsystem_platform.tbd exports the *internal* implementation names
   (__platform_memset, __platform_memmove, __platform_memcmp, ...) but not
   the public aliases (_memset, _memcpy, _memmove, _memcmp, _bzero) that
   libsystem_platform.dylib really provides on device. ld reports:
       Undefined symbols for architecture armv7: "_memset"

   Gap 2 is easy to miss because it is optimisation-dependent. At -O2 clang
   inlines small struct zeroing, so release builds happened to link; at -O0
   (make DEBUG=1) it emits real calls to memset, so every debug build failed.
   Verified against the archive: _strlen and _malloc are exported normally,
   while the whole mem* group is missing.

Both gaps are link-time only. The real dylibs on a device export these
symbols, so stubbing them here changes nothing about runtime behaviour.

Usage
-----
    patch_sdk_tbd.py <path to iPhoneOS9.3.sdk>

Idempotent: patching an already-patched SDK reports "nothing to patch" and
exits 0, so it is safe to run on a cached SDK.
"""

import os
import sys

# Public aliases that libsystem_platform.dylib exports on device but that the
# .tbd stub omits. Kept to the compiler-emitted memory/string primitives -
# these are the ones clang generates calls to without an explicit #include.
PLATFORM_ALIASES = [
    "_memset",
    "_memcpy",
    "_memmove",
    "_memcmp",
    "_memchr",
    "_bzero",
    "_strchr",
    "_strcmp",
    "_strncmp",
]

LIBLAUNCH_STUB = """---
archs:                 [ armv7, armv7s, arm64 ]
platform:              ios
install-name:          /usr/lib/system/liblaunch.dylib
current-version:       442.1.1
compatibility-version: 1
...
"""


def exported_symbols(path):
    """Symbol names a .tbd exports, as a set.

    .tbd export lists are comma-separated and wrap across lines, so a plain
    substring search gives false positives (__platform_memset contains
    _memset). Split on the list punctuation and compare whole tokens.
    """
    with open(path) as f:
        text = f.read()
    for ch in ",[]":
        text = text.replace(ch, "\n")
    return {tok.strip() for tok in text.splitlines() if tok.strip()}


def patch_platform_tbd(sdk):
    """Append the missing public mem*/str* aliases to libsystem_platform.tbd."""
    path = os.path.join(sdk, "usr/lib/system/libsystem_platform.tbd")
    if not os.path.isfile(path):
        sys.exit("error: %s not found; is this an iPhoneOS SDK?" % path)

    have = exported_symbols(path)
    missing = [s for s in PLATFORM_ALIASES if s not in have]
    if not missing:
        print("libsystem_platform.tbd: already exports %s, nothing to patch"
              % ", ".join(PLATFORM_ALIASES[:3]))
        return False

    with open(path) as f:
        lines = f.read().splitlines()

    # Drop the trailing end-of-document marker, add our own export block, then
    # restore the marker. Appending a second `- archs:` entry under `exports:`
    # leaves the SDK's existing entries untouched.
    while lines and lines[-1].strip() in ("", "..."):
        lines.pop()

    lines.append("  - archs:              [ armv7, armv7s, arm64 ]")
    lines.append("    symbols:            [ %s ]" % ", ".join(missing))
    lines.append("...")

    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")

    # Read back rather than trusting the write: a malformed block would fail
    # much later, as an opaque link error.
    if not set(missing) <= exported_symbols(path):
        sys.exit("error: libsystem_platform.tbd patch did not take effect")

    print("libsystem_platform.tbd: added %d public aliases (%s)"
          % (len(missing), ", ".join(missing)))
    return True


def patch_liblaunch(sdk):
    """Create the liblaunch.tbd stub libSystem.tbd re-exports but SDK omits."""
    path = os.path.join(sdk, "usr/lib/system/liblaunch.tbd")
    if os.path.isfile(path):
        print("liblaunch.tbd: already present, nothing to patch")
        return False

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(LIBLAUNCH_STUB)
    print("liblaunch.tbd: created link-time stub")
    return True


def main(argv):
    if len(argv) != 2:
        sys.exit("usage: %s <path to iPhoneOS9.3.sdk>" % os.path.basename(argv[0]))

    sdk = argv[1]
    if not os.path.isdir(sdk):
        sys.exit("error: %s is not a directory" % sdk)

    changed = patch_liblaunch(sdk)
    changed |= patch_platform_tbd(sdk)

    print("SDK patch complete%s" % ("" if changed else " (no changes needed)"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

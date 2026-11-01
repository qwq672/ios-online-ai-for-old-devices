#!/usr/bin/env python3
"""Patch Mach-O: change LC_VERSION_MIN_MACOSX (0x25) → LC_VERSION_MIN_IPHONEOS (0x24).

ONLY changes the load command TYPE, NOT the version value.
- Version stays at 6.0 (from deployment target) → iOS 6 dyld safe (weak-linking)
- Type changes to IPHONEOS → iOS recognizes it as an iOS binary (not macOS)

Changing the version to 7.0 caused crashes on iOS 6 (dyld treated it as
requiring iOS 7+ → hard-linked symbols → crash on UIKit calls).
"""
import struct, sys

def patch(path):
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    magic = struct.unpack('>I', data[:4])[0]
    patched = 0
    if magic == 0xCAFEBABE:
        n = struct.unpack('>I', data[4:8])[0]
        for i in range(n):
            off = 8 + i * 20
            _, _, archoff, archsize, _ = struct.unpack('>iiIII', data[off:off+20])
            mh = struct.unpack('<I', data[archoff:archoff+4])[0]
            if mh == 0xFEEDFACE:
                ncmds = struct.unpack('<I', data[archoff+16:archoff+20])[0]
                pos = archoff + 28
                for j in range(ncmds):
                    cmd, cmdsize = struct.unpack('<II', data[pos:pos+8])
                    if cmd == 0x25:  # LC_VERSION_MIN_MACOSX → IPHONEOS
                        struct.pack_into('<I', data, pos, 0x24)
                        # DO NOT change version — keep 6.0 for iOS 6 safety
                        patched += 1
                    pos += cmdsize
                    if pos >= archoff + archsize: break
    elif magic == 0xFEEDFACE:
        ncmds = struct.unpack('<I', data[16:20])[0]
        pos = 28
        for j in range(ncmds):
            cmd, cmdsize = struct.unpack('<II', data[pos:pos+8])
            if cmd == 0x25:
                struct.pack_into('<I', data, pos, 0x24)
                patched += 1
            pos += cmdsize
    if patched > 0:
        with open(path, 'wb') as f:
            f.write(data)
    print(f'patch_macho: {patched} cmd type MACOSX→IPHONEOS (version unchanged)')

if __name__ == '__main__':
    patch(sys.argv[1])

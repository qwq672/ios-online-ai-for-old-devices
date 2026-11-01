#!/usr/bin/env python3
"""Patch Mach-O: 
1. LC_VERSION_MIN_MACOSX (0x25) → LC_VERSION_MIN_IPHONEOS (0x24)
2. version field: 6.0 (0x060000) → 7.0 (0x070000)

This separates install-time check (Info.plist MinimumOSVersion=6.0,
allows iOS 6 installation) from runtime compat-mode check (Mach-O
says 7.0 → iOS 7 doesn't apply compat mode → flat UI).

The cctools linker emits MACOSX with version=6.0 (from deployment
target). We patch both the cmd type AND the version value.
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
                    if cmd == 0x25:  # LC_VERSION_MIN_MACOSX
                        # Change cmd type to IPHONEOS
                        struct.pack_into('<I', data, pos, 0x24)
                        # Change version to 7.0 (0x070000)
                        struct.pack_into('<I', data, pos + 8, 0x070000)
                        patched += 1
                    elif cmd == 0x24:  # Already IPHONEOS
                        # Just patch version to 7.0 if it's < 7.0
                        v = struct.unpack('<I', data[pos+8:pos+12])[0]
                        if v < 0x070000:
                            struct.pack_into('<I', data, pos + 8, 0x070000)
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
                struct.pack_into('<I', data, pos + 8, 0x070000)
                patched += 1
            elif cmd == 0x24:
                v = struct.unpack('<I', data[pos+8:pos+12])[0]
                if v < 0x070000:
                    struct.pack_into('<I', data, pos + 8, 0x070000)
                    patched += 1
            pos += cmdsize
    if patched > 0:
        with open(path, 'wb') as f:
            f.write(data)
    print(f'patch_macho: {patched} load commands patched (cmd→IPHONEOS, ver→7.0)')

if __name__ == '__main__':
    patch(sys.argv[1])

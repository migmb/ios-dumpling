#!/usr/bin/env python3
"""Minimal Android boot.img packer (header v1 and v2), mkbootimg-compatible
for the flags shim/build.sh uses. Written because the host has no mkbootimg.

Layout (both versions): header page, kernel pages, ramdisk pages, [dtb page].
v1 puts the DTB inside the kernel blob (Image.gz-dtb) and has no dtb section;
ABL derives the total image size from the section sizes, so the trailing
zero padding is optional (we emit it anyway, like mkbootimg).
"""
import argparse, hashlib, struct, sys

PAGE = 4096
V1_SIG = b'ANDROID!\x00'
V2_SIG = b'ANDROID!\x00\x00'


def parse_os_version(s):
    if not s:
        return 0
    parts = s.split('.') + ['0'] * 3
    major, minor, micro = (int(p) for p in parts[:3])
    return (major << 25) | (minor << 18) | (micro << 11)


def parse_pl(s):
    if not s:
        return 0
    if '-' in s:
        y, m = s.split('-')
        return int(y) * 100 + int(m)
    return int(s)


def pad(f, data, name):
    n = (len(data) + PAGE - 1) // PAGE * PAGE
    if n != len(data):
        sys.stderr.write(f'mkbootimg-python: warning: {name} padded {len(data)} -> {n}\n')
        data = data + b'\0' * (n - len(data))
    return data


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument('--header_version', type=int, default=1)
    ap.add_argument('--kernel', required=True)
    ap.add_argument('--ramdisk', required=True)
    ap.add_argument('--dtb')
    ap.add_argument('--base', type=lambda x: int(x, 0), default=0)
    ap.add_argument('--kernel_offset', type=lambda x: int(x, 0), default=0x8000)
    ap.add_argument('--ramdisk_offset', type=lambda x: int(x, 0), default=0x1000000)
    ap.add_argument('--tags_offset', type=lambda x: int(x, 0), default=0x100)
    ap.add_argument('--dtb_offset', type=lambda x: int(x, 0), default=0)
    ap.add_argument('--pagesize', type=int, default=4096)
    ap.add_argument('--os_version', default='')
    ap.add_argument('--os_patch_level', default='')
    ap.add_argument('--cmdline', default='')
    ap.add_argument('--dtb_start', type=lambda x: int(x, 0), default=0)
    ap.add_argument('-o', '--output', required=True)
    a = ap.parse_args()
    if a.pagesize != PAGE:
        sys.exit(f'mkbootimg-python: pagesize {a.pagesize} unsupported (only 4096)')

    kern = pad(None, open(a.kernel, 'rb').read(), 'kernel')
    rd = pad(None, open(a.ramdisk, 'rb').read(), 'ramdisk')
    dtb = pad(None, open(a.dtb, 'rb').read(), 'dtb') if a.dtb else b''
    if a.header_version == 1 and a.dtb:
        sys.exit('mkbootimg-python: header v1 has no dtb section (append the DTB to the kernel blob)')

    hdr = bytearray(PAGE)
    # Explicit offsets (AOSP bootimg.h): the header stores section *load*
    # addresses only, never file offsets - those are implied by page-aligned
    # ordering. Getting this wrong shifts pagesize/os_version/name/cmdline
    # and ABL misparses the image.
    hdr[0:9] = b'ANDROID!\0'
    P = lambda n: (n + PAGE - 1) // PAGE * PAGE
    ko, ro = PAGE, PAGE + P(len(kern))
    do = ro + P(len(rd))
    if a.header_version == 1:
        struct.pack_into('<II', hdr, 9,  len(kern), a.base + a.kernel_offset)
        struct.pack_into('<II', hdr, 17, len(rd),   a.base + a.ramdisk_offset)
        struct.pack_into('<II', hdr, 25, 0,         a.base + a.tags_offset)
        struct.pack_into('<I',  hdr, 33, a.pagesize)
        struct.pack_into('<I',  hdr, 37, parse_os_version(a.os_version))
        struct.pack_into('<I',  hdr, 41, parse_pl(a.os_patch_level))
        name = b'ios-dumpling-shim'
        struct.pack_into('<16s', hdr, 57, name[:16].ljust(16, b'\0'))
        struct.pack_into('<512s', hdr, 73, (a.cmdline + '\0').encode().ljust(512, b'\0'))
        hdr[2032:2064] = hashlib.sha256(kern).digest()
        hdr[2064:2096] = hashlib.sha256(rd).digest()
    else:
        hdr[9:10] = b'\0'   # 10-byte signature
        struct.pack_into('<II', hdr, 10, len(kern), a.base + a.kernel_offset)
        struct.pack_into('<II', hdr, 18, len(rd),   a.base + a.ramdisk_offset)
        struct.pack_into('<II', hdr, 26, 0,         a.base + a.tags_offset)
        struct.pack_into('<II', hdr, 34, len(dtb),  a.base + (a.dtb_offset or a.ramdisk_offset))
        struct.pack_into('<I',  hdr, 42, a.pagesize)
        struct.pack_into('<I',  hdr, 46, parse_os_version(a.os_version))
        struct.pack_into('<I',  hdr, 50, parse_pl(a.os_patch_level))
        struct.pack_into('<16s', hdr, 54, b'\0' * 16)
        struct.pack_into('<256s', hdr, 70, (a.cmdline + '\0').encode().ljust(256, b'\0'))
        struct.pack_into('<II', hdr, 326, a.dtb_start, 0)   # recovery_dtbo size/offset
        struct.pack_into('<I',  hdr, 334, 2048)             # header_size
        hdr[1632:1664] = hashlib.sha256(kern).digest()
        hdr[1664:1696] = hashlib.sha256(rd).digest()
        if dtb:
            hdr[1696:1728] = hashlib.sha256(dtb).digest()

    with open(a.output, 'wb') as f:
        f.write(hdr)
        f.write(kern)
        f.write(rd)
        if dtb:
            f.write(dtb)
    total = PAGE + len(kern) + len(rd) + len(dtb)
    sys.stderr.write(f'mkbootimg-python: {a.output}: hdr v{a.header_version} '
                     f'kernel={len(kern)} ramdisk={len(rd)} dtb={len(dtb)} total={total}\n')


if __name__ == '__main__':
    main()

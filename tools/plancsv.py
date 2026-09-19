#!/usr/bin/env python3
"""Read one file out of a FAT12 image without mounting it.

PLAN's arithmetic is checked by SAVING rather than by reading the glass: a
CSV is exact text, where a screenshot is pixels and a formula bar is one cell
at a time.  os88disk.py builds images and os88flush.py reads them back
through a running MartyPC; this is the third case - a QEMU run has already
written the floppy and the host just wants a file out of it.
"""
import struct, sys

def read(img, name):
    d = open(img, 'rb').read()
    bps = struct.unpack_from('<H', d, 11)[0]
    spc = d[13]
    res = struct.unpack_from('<H', d, 14)[0]
    nfat = d[16]
    nroot = struct.unpack_from('<H', d, 17)[0]
    spf = struct.unpack_from('<H', d, 22)[0]
    root = (res + nfat * spf) * bps
    data = root + nroot * 32
    fat = d[res * bps:res * bps + spf * bps]

    def chain(c):
        out = []
        while 2 <= c < 0xFF8:
            out.append(c)
            off = c * 3 // 2
            v = struct.unpack_from('<H', fat, off)[0]
            c = (v >> 4) if c & 1 else (v & 0xFFF)
        return out

    for i in range(nroot):
        e = d[root + i * 32:root + i * 32 + 32]
        if not e[0] or e[0] == 0xE5:
            continue
        n = e[:8].decode('latin1').strip() + '.' + e[8:11].decode('latin1').strip()
        if n != name:
            continue
        cl = struct.unpack_from('<H', e, 26)[0]
        sz = struct.unpack_from('<I', e, 28)[0]
        return b''.join(d[data + (c - 2) * spc * bps:
                          data + (c - 2) * spc * bps + spc * bps]
                        for c in chain(cl))[:sz]
    return None


if __name__ == '__main__':
    b = read(sys.argv[1], sys.argv[2])
    if b is None:
        sys.exit('plancsv: %s holds no %s' % (sys.argv[1], sys.argv[2]))
    sys.stdout.write(b.decode('latin1'))

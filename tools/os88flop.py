#!/usr/bin/env python3
"""os88flop: write os8088's floppy images to real floppies (docs/FLOPPY-WRITING.md).

    python3 tools/os88flop.py                     # every image + its dd line
    python3 tools/os88flop.py --size 1440         # one geometry only
    python3 tools/os88flop.py --boot              # only the ones that boot
    python3 tools/os88flop.py --write IMG DEVICE  # actually write one

THE LIST IS GENERATED, NEVER TYPED. It is read out of build/ on every run:
an image's geometry is its byte count, and whether it BOOTS is decided by
looking for a boot signature and a KERNEL.SYS in its root directory - not by
a table in this file that would start drifting the day a disk is added. A
hard-coded list is the staleness this tree keeps paying for elsewhere.

WHY --write IS NOT JUST A dd. tools/os88burn.py says it for the USB case and
it is the same sentence here: a mistyped device node is somebody's backup
drive. So this refuses before it asks, on four separate grounds, and only
then makes the destructive step a deliberate act:

  - the target must be a BLOCK DEVICE;
  - it must be REMOVABLE (/sys/block/<dev>/removable), which is what keeps
    an internal disk out of reach entirely rather than behind a warning;
  - nothing on it may be MOUNTED;
  - its capacity must EQUAL the image's. A 1.44MB image on a 720KB disk is
    a truncated write, and a 1.44MB image aimed at a hard disk is the
    accident this check exists for. Equality, not "big enough".

Then it asks for the device name to be TYPED BACK - `y` is muscle memory,
and this is the one step where muscle memory costs a disk - writes, fsyncs,
and READS THE WHOLE IMAGE BACK to compare SHA-256. A write that errors is
loud; a floppy that silently drops a sector is not, and the read-back is the
only thing that catches it. Old media fails this way often enough that the
verify is the point rather than a formality.

It needs root only for the write, so it takes none until then.
"""
import argparse
import hashlib
import os
import struct
import subprocess
import sys

GEOM = {1474560: '1.44MB', 1228800: '1.2MB', 737280: '720KB', 368640: '360KB'}
ORDER = ['1.44MB', '1.2MB', '720KB', '360KB']


def boots(path):
    """a boot signature AND a KERNEL.SYS in the root directory"""
    try:
        with open(path, 'rb') as fh:
            head = fh.read(512)
            if len(head) < 512 or head[510:512] != b'\x55\xaa' or head[0] == 0:
                return False
            bps = struct.unpack_from('<H', head, 11)[0]
            rsv = struct.unpack_from('<H', head, 14)[0]
            nfat, spf = head[16], struct.unpack_from('<H', head, 22)[0]
            rootent = struct.unpack_from('<H', head, 17)[0]
            if not bps or not rootent:
                return False
            fh.seek((rsv + nfat * spf) * bps)
            return b'KERNEL  SYS' in fh.read(rootent * 32)
    except (OSError, struct.error):
        return False


def images(build='build'):
    out = []
    for name in sorted(os.listdir(build)):
        if not name.endswith('.img'):
            continue
        p = os.path.join(build, name)
        g = GEOM.get(os.path.getsize(p))
        if g:
            out.append((g, p, boots(p)))
    return out


def do_list(args):
    rows = images()
    if args.size:
        want = GEOM.get(args.size * 1024) or args.size
        rows = [r for r in rows if r[0] == want]
    if args.boot:
        rows = [r for r in rows if r[2]]
    if not rows:
        print("os88flop: no image matches - is build/ populated? (`make`)")
        return 1
    dev = args.device or '/dev/fd0'
    for g in ORDER:
        grp = [r for r in rows if r[0] == g]
        if not grp:
            continue
        print("\n# ---- %s media ----" % g)
        for _, p, b in sorted(grp, key=lambda r: (not r[2], r[1])):
            print("sudo dd if=%-28s of=%s bs=512 conv=fsync%s"
                  % (p, dev, "    # BOOTABLE" if b else ""))
    print("\n# %d image(s). CHECK THE DEVICE FIRST: lsblk -o NAME,SIZE,RM,TRAN"
          % len(rows))
    return 0


def _refuse(msg):
    print("os88flop: %s" % msg, file=sys.stderr)
    return 1


def do_write(args):
    img, dev = args.write
    if not os.path.isfile(img):
        return _refuse("%s is not a file" % img)
    size = os.path.getsize(img)
    if size not in GEOM:
        return _refuse("%s is %d bytes, which is no floppy geometry - this "
                       "tool writes floppies only" % (img, size))
    try:
        st = os.stat(dev)
    except OSError as e:
        return _refuse("%s: %s" % (dev, e.strerror))
    import stat as _s
    if not _s.S_ISBLK(st.st_mode):
        return _refuse("%s is not a block device" % dev)

    # Resolve to the PARENT DISK via sysfs rather than by trimming digits off
    # the name. Trimming is wrong for every naming scheme that ends in a
    # number legitimately - loop0 became `loop`, nvme0n1 would become `nvme`,
    # and fd0 only survived by a special case. A partition says so in sysfs
    # and names its own parent; everything else is already a disk.
    name = os.path.basename(os.path.realpath(dev))
    node = '/sys/class/block/%s' % name
    if os.path.exists(node + '/partition'):
        base = os.path.basename(os.path.dirname(os.path.realpath(node)))
    else:
        base = name
    rm = '/sys/block/%s/removable' % base
    if not os.path.exists(rm):
        return _refuse("cannot tell whether %s is removable (%s missing) - "
                       "refusing rather than guessing" % (dev, rm))
    if open(rm).read().strip() != '1':
        return _refuse("%s is NOT removable. This tool will not write to a "
                       "fixed disk." % dev)
    mounts = [l.split()[1] for l in open('/proc/mounts')
              if l.split()[0].startswith(dev)]
    if mounts:
        return _refuse("%s has something mounted (%s) - unmount it first"
                       % (dev, ', '.join(mounts)))
    with open(dev, 'rb') as fh:
        fh.seek(0, os.SEEK_END)
        cap = fh.tell()
    if cap != size:
        return _refuse("%s holds %d bytes and %s is %d (%s). The media must "
                       "MATCH the image, not merely fit it."
                       % (dev, cap, os.path.basename(img), size, GEOM[size]))

    print("  image   %s  (%s, %s)" % (img, GEOM[size],
                                      "bootable" if boots(img) else "data"))
    print("  device  %s  (%d bytes, removable)" % (dev, cap))
    print("\nThis ERASES %s. Type the device name to confirm: " % dev, end='')
    sys.stdout.flush()
    if sys.stdin.readline().strip() != dev:
        return _refuse("not confirmed - nothing written")

    want = hashlib.sha256(open(img, 'rb').read()).hexdigest()
    r = subprocess.run(['dd', 'if=' + img, 'of=' + dev, 'bs=512',
                        'conv=fsync', 'status=progress'])
    if r.returncode:
        return _refuse("dd failed (%d) - nothing verified" % r.returncode)
    with open(dev, 'rb') as fh:
        got = hashlib.sha256(fh.read(size)).hexdigest()
    if got != want:
        return _refuse("READ-BACK DIFFERS. The disk did not take the image - "
                       "bad media, most likely. Do not ship it.")
    print("os88flop: %s -> %s, read back and SHA-256 identical" % (img, dev))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--size', type=int, metavar='KB',
                    help='only this geometry (1440, 1200, 720, 360)')
    ap.add_argument('--boot', action='store_true',
                    help='only images that boot on their own')
    ap.add_argument('--device', metavar='DEV',
                    help='the device the printed commands name (/dev/fd0)')
    ap.add_argument('--write', nargs=2, metavar=('IMG', 'DEVICE'),
                    help='write one image, with confirmation and verify')
    args = ap.parse_args()
    return do_write(args) if args.write else do_list(args)


if __name__ == '__main__':
    sys.exit(main())

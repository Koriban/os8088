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

AND THAT INCLUDES THE DEVICE NAME, which used to be the one guess left in
here: the commands said `/dev/fd0` on a machine whose only floppy drive is a
USB one at `/dev/sdb`. A printed command that has to be hand-edited before it
is run is worse than no command at all, because the thing being edited sits
one letter away from `/dev/sda`. So the drive is LOOKED FOR (find_floppy
below), and when it cannot be identified the commands say so instead of
naming a device that is not there.

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

It needs root only for the WRITE, and that is load-bearing rather than a
nicety: every refusal above is answerable from sysfs and /proc, so a disk of
the wrong size, a fixed disk or a mounted one is all rejected before anybody
is asked for a password. Root is checked for explicitly once the refusals
have passed, and the message names the command to re-run.
"""
import argparse
import hashlib
import os
import struct
import subprocess
import sys

GEOM = {1474560: '1.44MB', 1228800: '1.2MB', 737280: '720KB', 368640: '360KB'}
ORDER = ['1.44MB', '1.2MB', '720KB', '360KB']


FLOPPY_SECTORS = {2880: '1.44MB', 2400: '1.2MB', 1440: '720KB', 720: '360KB'}


def find_floppy():
    """Every attached whole block device that is a floppy drive.

    Three tests, and an internal disk fails all three: it must be REMOVABLE,
    it must be a whole device rather than a partition, and its capacity must
    be one of the four floppy geometries. The user's 4.5TB USB disk is
    removable and whole and is excluded by size alone; a USB stick likewise.
    A drive named fd* is taken on its name, since a real floppy controller
    with no disk in it reports a size of 0.

    A drive with NO DISK IN IT reports a size of 0, so it cannot be told from
    an empty card reader by size - but it is still worth naming, because the
    alternative is telling someone no drive exists while they are looking at
    one. It comes back flagged as empty, and the capacity refusal below stops
    anything being written to it anyway (0 never equals an image's size).

    Returns [(node, has_disk, label)], and the caller decides - this never
    picks when there is more than one, because picking between two floppy
    drives is a guess with a disk on the end of it.
    """
    out = []
    try:
        names = sorted(os.listdir('/sys/class/block'))
    except OSError:
        return out
    for name in names:
        node = '/sys/class/block/%s' % name
        if os.path.exists(node + '/partition'):
            continue                    # a partition, not a drive
        try:
            with open(node + '/removable') as fh:
                removable = fh.read().strip() == '1'
            with open(node + '/size') as fh:
                sectors = int(fh.read().strip())
        except (OSError, ValueError):
            continue
        if not removable:
            continue
        if sectors in FLOPPY_SECTORS:
            out.append(('/dev/' + name, True,
                        '%s disk in it' % FLOPPY_SECTORS[sectors]))
        elif name.startswith('fd'):
            out.append(('/dev/' + name, False, 'floppy controller, no disk'))
        elif sectors == 0:
            out.append(('/dev/' + name, False, '%s, NO DISK IN IT'
                        % (_model(name) or 'removable drive')))
    return out


def _model(name):
    """the drive's own name, for telling two empty slots apart"""
    try:
        with open('/sys/class/block/%s/device/model' % name) as fh:
            return fh.read().strip()
    except OSError:
        return None


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
    found = find_floppy()
    ready = [f for f in found if f[1]]
    if args.device:
        dev, note = args.device, 'named on the command line'
    elif len(ready) == 1:
        dev, note = ready[0][0], ready[0][2]
    elif len(found) == 1:
        dev, note = found[0][0], found[0][2]
    elif found:
        dev, note = None, ('%d drives attached, say which: %s'
                           % (len(found), ', '.join(d for d, _, _ in found)))
    else:
        dev, note = None, ('no floppy drive found - a USB drive with no disk '
                           'in it reports a size of 0')

    menu = []
    for g in ORDER:
        grp = [r for r in rows if r[0] == g]
        if not grp:
            continue
        print("\n# ---- %s media ----" % g)
        for _, path, b in sorted(grp, key=lambda r: (not r[2], r[1])):
            menu.append(path)
            print("%3d  sudo dd if=%-28s of=%s bs=512 conv=fsync%s"
                  % (len(menu), path, dev or '<DEVICE>',
                     "    # BOOTABLE" if b else ""))

    print("\n# %d image(s). Device %s - %s"
          % (len(rows), dev or '<DEVICE>', note))
    print("# CHECK IT: lsblk -d -o NAME,SIZE,RM,TRAN,MODEL")

    if args.list or not (sys.stdin.isatty() and sys.stdout.isatty()):
        return 0                        # piped, redirected or --list: the
                                        # list IS the output, and a prompt
                                        # nobody can answer would hang a script
    return prompt_write(menu, dev)


def prompt_write(menu, dev):
    """Pick an image by number, confirm the device, then write_one.

    The listing above is the menu, so the number beside an image is the whole
    of what has to be typed - which is the point: the alternative was copying
    a dd line and editing the device in it by hand, one letter away from the
    4.5TB disk at /dev/sda.

    NOTHING here weakens the write: it ends in write_one, which still refuses
    on all four grounds and still makes the operator type the device name back.
    """
    try:
        print("\nWhich image? [1-%d, Enter to quit]: " % len(menu), end='')
        sys.stdout.flush()
        pick = sys.stdin.readline().strip()
        if not pick:
            return 0
        try:
            img = menu[int(pick) - 1]
            if int(pick) < 1:
                raise IndexError
        except (ValueError, IndexError):
            return _refuse("%r is not one of 1-%d" % (pick, len(menu)))

        print("Device%s: " % ((" [%s]" % dev) if dev else ""), end='')
        sys.stdout.flush()
        target = sys.stdin.readline().strip() or dev
        if not target:
            return _refuse("no device given")
        print()
        return write_one(img, target)
    except KeyboardInterrupt:
        print("\nnothing written")
        return 0
    return 0


def _refuse(msg):
    print("os88flop: %s" % msg, file=sys.stderr)
    return 1


def do_write(args):
    img, dev = args.write
    return write_one(img, dev)


def write_one(img, dev):
    """the four refusals, the typed confirmation and the read-back verify.

    The prompt flow and --write come through HERE and nowhere else: a second
    path to the destructive step is a second place for one of the refusals to
    be missing.
    """
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
    # THE CAPACITY COMES OUT OF SYSFS, not from opening the device. Opening
    # a block device needs root, and every refusal above is meant to be
    # answerable WITHOUT it - learning that the disk is the wrong size should
    # not cost a password, and reaching for one turned this check into an
    # unhandled PermissionError instead of a refusal.
    try:
        with open('/sys/block/%s/size' % base) as fh:
            cap = int(fh.read().strip()) * 512
    except (OSError, ValueError):
        return _refuse("cannot read %s's capacity from sysfs" % dev)
    if cap == 0:
        return _refuse("%s has no disk in it" % dev)
    if cap != size:
        return _refuse("%s holds %d bytes and %s is %d (%s). The media must "
                       "MATCH the image, not merely fit it."
                       % (dev, cap, os.path.basename(img), size, GEOM[size]))

    if not os.access(dev, os.R_OK | os.W_OK):
        return _refuse("no read/write access to %s - the checks above all "
                       "passed, so re-run this under sudo:\n"
                       "    sudo %s %s --write %s %s"
                       % (dev, sys.executable, sys.argv[0], img, dev))

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
                    help='name the device instead of looking for it')
    ap.add_argument('--write', nargs=2, metavar=('IMG', 'DEVICE'),
                    help='write one image, with confirmation and verify')
    ap.add_argument('--list', action='store_true',
                    help='print the list and stop, without prompting')
    args = ap.parse_args()
    return do_write(args) if args.write else do_list(args)


if __name__ == '__main__':
    sys.exit(main())

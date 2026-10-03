# Writing os8088's floppy images to real floppies

`docs/LIVE-MEDIA.md` is the guide for the **live USB stick and CD** (§80).
This is the one for **floppies** — the 75-odd images `make` and its on-demand
targets leave in `build/`, which is how os8088 reaches every machine in
`docs/FIELD-MACHINES.md`.

**Do not type the command list out of this file.** It goes stale the day a
disk is added or a geometry changes. Ask the tree instead:

```sh
python3 tools/os88flop.py                 # every image, with its dd line
python3 tools/os88flop.py --boot          # only the ones that boot on their own
python3 tools/os88flop.py --size 720      # only that geometry
python3 tools/os88flop.py --device /dev/sdb   # name your own device in the output
```

It reads `build/` on every run: an image's geometry is its byte count, and
whether it boots is decided by looking for a boot signature and a `KERNEL.SYS`
in its root directory. Nothing about that list is typed anywhere.

## Which disk do I actually want?

| if you have | write |
|---|---|
| one 1.44MB drive and want a machine that works | **`combo144.img`** — boots, and carries the applications, the games and the benchmarks on one disk |
| one 720KB drive | **`combo720.img`** |
| one 360KB drive | **`combo.img`** |
| a field or bench request | `combo*.img` for the geometry, unless `docs/FIELD-MACHINES.md` names one of the `make field` disks |
| two drives | `os8088*.img` in A: and `apps*.img` in B: |
| more software than one disk holds | a second floppy: `apps-all.img`, or the category disks `office360` / `games360` / `network360` / `media360` |

A **bootable** image has the kernel on it; everything else is a data disk and
needs a system disk booted first.

## Writing one

Run it with no arguments. It lists every image with a number, **finds the
floppy drive**, and asks which one to write:

```sh
python3 tools/os88flop.py
```

```
  5  sudo dd if=build/vbeprobeboot.img    of=/dev/sdb bs=512 conv=fsync    # BOOTABLE
  6  sudo dd if=build/vbeset.img          of=/dev/sdb bs=512 conv=fsync    # BOOTABLE

# 6 image(s). Device /dev/sdb - 1.44MB disk in it

Which image? [1-6, Enter to quit]: 6
Device [/dev/sdb]:
```

**The device is looked for, not assumed.** It used to print `/dev/fd0`, which
is wrong on every machine whose only floppy drive is a USB one — and a printed
command that has to be hand-edited before it runs is worse than no command,
because the thing being edited sits one letter away from `/dev/sda`. The
drive is identified by being a whole removable block device whose capacity is
a floppy geometry; a drive with **no disk in it** reports a size of 0, so it
is named by its model and flagged as empty rather than going unmentioned.
`--device` overrides, and `--list` prints without prompting (as does any
non-interactive run, so pipes and scripts are unchanged).

Picking a number ends in the same checked write as `--write`, which is also
still there for a scripted one:

```sh
python3 tools/os88flop.py --write build/combo144.img /dev/sdb
```

Either way it refuses on four separate grounds before asking for anything —
the target must be a block device, it must be **removable**, nothing on it
may be mounted, and its capacity must **equal** the image's. All four are
answered out of sysfs and `/proc`, so a wrong disk is rejected *before*
anybody is asked for a password; root is checked for separately, once they
have passed, and the message names the command to re-run. Then it asks for the
device name to be typed back, writes, and reads the whole image back to
compare SHA-256s.

The raw equivalent, if you would rather do it yourself:

```sh
lsblk -d -o NAME,SIZE,RM,TRAN,MODEL        # FIND THE DEVICE FIRST
sudo dd if=build/combo144.img of=/dev/sdb bs=512 conv=fsync status=progress
```

On **Windows**, use [rawwrite](http://www.chrysocome.net/rawwrite) or Rufus;
Explorer and drag-and-drop will not do it, because these are raw sector images
and not a filesystem to copy files into.

## Four ways to get it wrong

- **The device.** A USB floppy drive is `/dev/sdX`, not `/dev/fd0`, and
  `/dev/sda` is very often the disk you are running from — a mistyped device
  node is somebody's backup drive. This is why `tools/os88flop.py` looks the
  drive up instead of printing a guess, and why it refuses a non-removable
  device *by name* rather than warning about it, which is
  `tools/os88burn.py`'s rule for the same reason.
- **The media.** The image's size and the disk's must match. A 1.44MB image
  on 720KB media is a truncated write that will mount and then fail somewhere
  in the middle; a 720KB image on 1.44MB media needs the **HD hole taped
  over** or the drive formats it at the wrong density.
- **The flush.** `conv=fsync` makes `dd` wait for the write to reach the
  media before it returns. Without it, a disk pulled when the prompt comes
  back can be short several sectors.
- **The media again.** Floppies that have sat in a drawer for thirty years
  fail silently far more often than they fail loudly. The read-back verify is
  the point of `--write`, not a formality — a disk that takes the write and
  returns different bytes is the normal failure of old media, and nothing
  else in the chain will tell you.

## After it is written

`docs/FIELD-MACHINES.md` is the authority on what to do on the machine: which
disk answers which question, how to run `gfxbench` and `sysbench`, and the
provenance lines a report needs. `README.md` lists what each image carries.

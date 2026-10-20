# VESA 1024x768 display

`VBE.DRV` runs the desktop at **1024x768** on a video card whose VESA BIOS
offers that size, instead of the 640x480 a plain VGA gives. It is four times
the room: more windows side by side, more of a spreadsheet or a document at
once, and a menu bar with space to spare.

The picture stays **16 colours**, the same sixteen a VGA desktop uses. That
is deliberate. Every program on this machine draws through the system, and
the system's drawing is built around four colour planes; a 256-colour screen
would be a second way of drawing everything, not a bigger version of this
one.

## What is inside it

- Asking the video BIOS which modes it offers, and whether 1024x768 in 16
  colours is one of them.
- Setting that mode, and reading back from the card how wide a row really
  is, where its window sits in memory and how big the screen came out, so
  nothing here is assumed.
- Programming all sixteen colours, so the desktop looks the same on every
  card rather than inheriting whatever the card's BIOS left behind.
- Moving the window the processor writes through. At 1024 pixels across, a
  screen is more than one 64K window, and this is the part that steps from
  one to the next.

## Why it is on the system disk

A machine either has a card that offers the mode or it does not. On an IBM
PC or XT with an ordinary VGA, and on every Hercules and CGA machine, this
file is never read and costs nothing. Keeping it in the system itself would
charge those machines memory for a mode they cannot set.

## Using it

Open the **Control Panel**, choose **Display**, and look at the list of
display modes. **Vbe 1024x768** is there when the card offers it, below
Vga 640x480, Hercules 720x348, Cga 640x200 and Ega 640x350. Choose it and
**Set Primary**, and the desktop comes back at the new size with the windows
where they were.

If the row is not in the list, the card's BIOS did not offer the mode. There
is nothing to switch on and no tick box: a machine that has the mode is
offered it, and one that has not is not.

> A card that advertises the mode and sets it wrongly is a real kind of
> card. If the desktop comes back scrambled, choose another mode on the
> Display page and the machine returns to it.

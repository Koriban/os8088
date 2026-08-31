# IMGCONV-PLAN — one image converter, on the host

A design note for a tool that does not exist yet: convert JPEG and PNG into
the two raster formats os8088 can actually draw, `.PIX` and `.BMP`.

Nothing here is built. This is the record of what the tree already has, what
it cannot have, and the shape the tool should therefore take — written now so
the reasoning survives the gap between deciding and doing.

## 1. Why the host, and not a package

**PNG needs DEFLATE, and there is no inflate anywhere in the guest.** The only
occurrence of the word in `apps/` is an unrelated comment in taskmgr. Writing
one means Huffman tables plus a 32KB LZ77 window, on a machine where a
package's image + bss is capped at `APP_MAX_SIZE` (61,440) and SHEET.O88 is
already at ~57,400. Then PNG's five per-scanline filters, then CRC32, and then
- because PNG is usually truecolour and the screen is sixteen colours -
quantisation and dithering, which is a second algorithm as large as the first.

JPEG is worse: an IDCT, Huffman tables of its own, and YCbCr to RGB before the
same quantiser.

**That is a package's worth of work to arrive where the host already is.**
`tools/os88pix.py` decodes PNG today from stdlib `zlib`, and hands anything
else to `sips`/Pillow to become a PNG first. Converting on the host is also
simply the house idiom: `os88ttf.py` rasterises TrueType at build time,
`os88face.py` packs the faces, `os88pix.py` builds the picture archives. The
guest draws; it does not decode.

## 2. What the tree can draw, and what compresses

| format | who reads it | compression |
|---|---|---|
| `.PIX` | Frotz only (`apps/frotz/zpic.inc`) | **none** - packed 4bpp, two pixels a byte, 16-byte-aligned blocks |
| `.BMP` | Paint only (`paint.asm`) | **none accepted** - `biCompression` must be `BI_RGB`; RLE4, RLE8 and bitfields are refused |
| `.GIF` | Paint only, both directions | LZW, with a 64KB transient claim and `PT_LZW_KB` of tables |

**No image format in this tree uses RLE.** BMP's RLE4/RLE8 variants exist and
Paint declines them; GIF is LZW; `.PIX` is uncompressed. The one run-length
codec in the guest is `CMem` in Quetzal saves, which is not an image at all -
and Infocom's `.mg1` was *assumed* to be "RLE over a 4-bit palette" by
docs/FROTZ-PLAN.md 6 and turned out to be an LZW variant, which is why that
picture path was refused (SPEC.md 61.7).

That matters here: `.PIX` and `.BMP` are both uncompressed, so a converted
photograph is large. A 240x160 4bpp image is 19,318 bytes as BMP. **RLE is the
obvious cheap answer if size ever bites** - a decoder is genuinely small, which
is what the Frotz plan hoped for and did not get - but it is not needed to
start, and adding it means teaching Paint's reader a compression it currently
refuses by contract.

## 3. Shape

One tool, two outputs, sharing the decode and the quantiser:

    python3 tools/os88img.py -o OUT.BMP photo.jpg
    python3 tools/os88img.py -o OUT.PIX 1=cover.png 5=map.jpg

`.PIX` output already exists as `tools/os88pix.py` and is defined by
`apps/frotz/zpic.inc`, which stays the authority - the tool matches the
format, never the other way round. The new half is `.BMP`: a 54-byte header,
the 16-colour palette, bottom-up rows, `BI_RGB`, which is the exact shape
`ch_bmp_write` already emits and `pt_bmp_in` already reads.

The interesting work is neither header. It is **quantisation to sixteen
colours**, which both outputs need and neither has: `os88pix.py` currently
maps to the fixed palette, and a photograph wants dithering to survive it.
That code is written once and serves both.

## 3a. `.BM4` - BMP RLE4, under an extension of its own

A 240x160 chart is 19,318 bytes uncompressed and charts are mostly flat
colour, which is the case RLE4 was made for. The container is already here:
`ch_bmp_write` emits the header Paint's `pt_bmp_in` reads, and RLE4 is
`biCompression = 2` inside that same header - encoded mode is `(count, index)`
pairs with two nibbles per byte, and `count == 0` escapes to end-of-line (0),
end-of-bitmap (1), delta (2, then dx/dy) or an absolute run (3..255).

**It gets a distinct extension, `.BM4`, and that is a deliberate divergence.**
By the letter of the format such a file is a perfectly ordinary `.BMP`, and an
outside program would read it as one. But this tree gates its decoders on the
extension - `pt_readable` matches a table of three-character extensions before
anything is read (SPEC.md 38.6), 8.3 names being all a mount gives it - so a
compressed BMP called `.BMP` would be handed to a reader that refuses it at
`biCompression` and reports a broken file. `.BM4` lets the gate route it, and
keeps `.BMP` meaning the one thing every existing reader can take.

The cost is stated rather than hidden: a `.BM4` copied to another machine will
not be recognised by name, though its bytes are valid. That is the right trade
for a format whose only readers are in this tree.

## 3b. A `.PCX` decoder

PCX is the format DOS-era artwork actually shipped in, and the cheapest of the
three to decode: a 128-byte header, then bytes where `(b & 0xC0) == 0xC0`
means the low six bits are a run of 1..63 and the next byte is the value, and
anything else is a literal. Twenty instructions.

It also fits the hardware better than BMP does. PCX is **planar** - one plane
per pass, `nplanes` x `bytesperline` per row - which is the layout
`OSAPI_GFX_BLITP` already takes, and 4bpp/4-plane is exactly EGA's. A PCX 5
file carries its 256-colour palette after a `0x0C` marker at the end; a 16
colour one carries it in the header.

Two details to check against a real file rather than a summary, because both
decode fine against your own encoder and fail against everyone else's:
`bytesperline` is padded to an EVEN number independently of the image width,
and the run tag can legally encode a run of one, so a literal byte >= 0xC0
MUST be written as a run.

## 3c. What Word takes

`Picture...` reads **`.PIX`, `.BMP` and `.PCX`** - and not GIF. PIX because it
is free (a seek and one blit, no decoder); BMP because it is what Sheet and
Chart already export; PCX because it is what outside artwork arrives as. GIF
stays Paint's alone: its LZW codec wants a 64KB transient claim and
`PT_LZW_KB` of tables, which is a great deal to carry for a format nothing in
this tree emits.

That argues for the decoders living in a shared `apps/os88img.inc` rather than
inside Word, since Paint already has BMP and would want PCX too - the same
move `os88chartbss.inc` made, for the same reason.

## 4. What this unblocks

Today a `.BMP` has exactly one consumer - Paint - because nothing else reads
one. Sheet and Chart write them; Word's `Picture...` is `WDMF_DIS`. With this
tool, artwork from outside reaches the machine in a format the tree can
already draw, and it is the same format Sheet and Chart export, so the same
reader serves both directions.

Pairs naturally with lifting Paint's BMP decoder into a shared
`apps/os88img.inc`, so Word does not grow a second copy of it - the same move
`os88chartbss.inc` made for the chart working set, and for the same reason.

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

## 4. What this unblocks

Today a `.BMP` has exactly one consumer - Paint - because nothing else reads
one. Sheet and Chart write them; Word's `Picture...` is `WDMF_DIS`. With this
tool, artwork from outside reaches the machine in a format the tree can
already draw, and it is the same format Sheet and Chart export, so the same
reader serves both directions.

Pairs naturally with lifting Paint's BMP decoder into a shared
`apps/os88img.inc`, so Word does not grow a second copy of it - the same move
`os88chartbss.inc` made for the chart working set, and for the same reason.

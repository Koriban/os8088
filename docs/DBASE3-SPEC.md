# DBASE3 — the dBASE III `.DBF` file format, pinned (`apps/dbase/`, not yet built)

**The binding contract for the `.DBF` storage layer**, per
`docs/plans/DBASE3-PLAN.md` §1.1/§6: *"Before any code: a real `.DBF` file,
inspected byte for byte, or a primary specification pinned by URL/checksum...
`DBASE3-SPEC.md` gets the table only once it is taken that way."* This is
that table. **Nothing is built yet** — this document clears the plan's one
blocking prerequisite for the storage format; the language (the dot prompt,
`.PRG`) is a separate, later wave and is not pinned here.

It lives outside SPEC.md by the C64-SPEC/WEAVE-SPEC precedent. A bare `§N.M`
in this file is a section of THIS file.

---

## 0. Method, and why it matters here specifically

Every byte below is marked by how it was confirmed:

- **[BYTES]** — read directly off a real, authentic dBASE III `.DBF` file,
  hex-dumped by hand. This is the strongest evidence this project's own rule
  recognizes (`os8088_false_premise_in_comment`'s class of defect: a byte
  written down with confidence stops being questioned).
- **[SRC]** — stated by a published secondary source, cited by URL, but not
  independently confirmed against a real file here.

**One disagreement was caught this way and is worth recording**, because it
is exactly the failure mode the method exists to catch: fileformat.info's
"corion-dbase-iii" page labels header offsets 1/2/3 as Month/Day/Year. The
real bytes (DBASE3-SPEC §1 below) and two independent sources (dbase.com, Wikipedia)
agree the order is Year/Month/Day — and the real bytes alone are decisive,
since a Month byte of `0x72` (114) is not a legal month. The real-byte
evidence is what should settle a disagreement like this, not a vote among
secondary sources.

**A second thing the real bytes corrected**: one of the three sample files
first pulled for this (`memotest.dbf` / `no_memofile.dbf` from
`olemb/dbfread`'s test suite, identical files under two names) carries
version byte `0x30`. That is **Visual FoxPro**, not dBASE III (LOC's format
registry and fileformat.info both give dBASE III's with-memo byte as `0x83`,
not `0x30`). The memo field's *shape* in that sample (name/type/length/
decimals, 32-byte descriptor) is almost certainly still representative —
FoxPro inherited dBASE III's layout for the common types — but nothing below
claims memo support is byte-verified against genuine dBASE III. It is
**[SRC]**-only and flagged as such in §3.

---

## 1. The header (32 bytes, fixed)

**[BYTES]**, confirmed identically across three real files: `people.dbf`
(SHA-256 `ab8795cbeb44420f64b202cfac75d1a1d9ebfdead70e94308873a2410b33f48`,
olemb/dbfread `examples/files/people.dbf`, also independently confirmed by
Unix `file(1)` as `FoxBase+/dBase III DBF`), `poly.dbf` (SHA-256
`dbca6244bc29a54b87a02c554e6d24b87984bf6bc06492c783b32a0e0938809`,
OSGeo/gdal `autotest/ogr/data/poly.dbf`, same `file(1)` identification), and
cross-checked against **[SRC]** dbase.com's official KB (covers dBASE
Level 5/7 — a *later*, larger-header format, cited only for the bytes that
carry over unchanged), the Library of Congress format registry
(`fdd000325.shtml`), `fileformat.info/format/corion-dbase-iii.htm`,
`independent-software.com/dbase-dbf-dbt-file-format.html`, and Wikipedia's
`.dbf` article.

| Offset | Size | Field | Value |
|---|---|---|---|
| `0x00` | 1 | Version/type | `0x03` = plain dBASE III, no memo **[BYTES]**. `0x83` = with memo, **[SRC]** only (§0) |
| `0x01`–`0x03` | 3 | Last update | Year (since 1900), Month, Day — **in that order** **[BYTES]**, see §0's correction |
| `0x04`–`0x07` | 4 | Record count | 32-bit little-endian **[BYTES]** |
| `0x08`–`0x09` | 2 | Header length | 16-bit little-endian, bytes — **[BYTES]**, and cross-checked arithmetically: `32 + 32×(field count) + 1` matched exactly in both real files (97 for `people.dbf`'s 2 fields, 129 for `poly.dbf`'s 3) |
| `0x0A`–`0x0B` | 2 | Record length | 16-bit little-endian, bytes — **[BYTES]**, cross-checked arithmetically: `1 + Σ(field lengths)` matched exactly in both (25 and 40) |
| `0x0C`–`0x0D` | 2 | Reserved | zero in both samples **[BYTES]**; **[SRC]** says reserved |
| `0x0E` | 1 | Incomplete-transaction flag | zero in both samples **[BYTES]**; dBASE IV-era field per **[SRC]** |
| `0x0F` | 1 | Encryption flag | zero in both samples **[BYTES]**; dBASE IV-era field per **[SRC]** |
| `0x10`–`0x1B` | 12 | Reserved (multi-user) | zero in both samples **[BYTES]** |
| `0x1C` | 1 | Production `.MDX` flag | zero in both samples **[BYTES]** |
| `0x1D` | 1 | Language driver ID | zero in both samples **[BYTES]** |
| `0x1E`–`0x1F` | 2 | Reserved | zero in both samples **[BYTES]** |

Field descriptors start at offset `0x20` (32), immediately after the header.

---

## 2. The field descriptor (32 bytes each)

**[BYTES]**, confirmed against five real field descriptors across the two
files (`NAME`/`BIRTHDATE` in `people.dbf`; `AREA`/`EAS_ID`/`PRFEDEA` in
`poly.dbf`), cross-checked against **[SRC]** independent-software.com, which
is the one source among those checked that names the bytes this table marks
`[SRC]` rather than leaving them "reserved."

| Offset | Size | Field | Value |
|---|---|---|---|
| `0x00`–`0x0A` | 11 | Field name | ASCII, NUL-padded **[BYTES]** |
| `0x0B` | 1 | Field type | ASCII type code, §3 **[BYTES]** |
| `0x0C`–`0x0F` | 4 | Field data address | RAM-only; on disk, nonzero garbage in every sample (`0x00000001` for `NAME`, `0x00000011` for `BIRTHDATE`) that a reader must not interpret as meaningful **[BYTES]**, matches **[SRC]**'s "has no meaning in a `.dbf` file on disk" |
| `0x10` | 1 | Field length | binary **[BYTES]** |
| `0x11` | 1 | Decimal count | binary, numeric fields only **[BYTES]** |
| `0x12`–`0x13` | 2 | Reserved | zero in every sample **[BYTES]** |
| `0x14` | 1 | Work area ID | zero in every sample **[BYTES]**; named by **[SRC]** only |
| `0x15`–`0x16` | 2 | Reserved | zero in every sample **[BYTES]** |
| `0x17` | 1 | SET FIELDS flag | zero in every sample **[BYTES]**; named by **[SRC]** only |
| `0x18`–`0x1F` | 8 | Reserved | zero in every sample **[BYTES]** |

The field descriptor array is terminated by a single `0x0D` byte **[BYTES]**,
immediately followed by the first data record. Header length (§1) accounts
for this terminator exactly: `0x20 + 32×N + 1`.

---

## 3. Field types

| Code | Type | Storage | Confirmed |
|---|---|---|---|
| `C` | Character | ASCII, space-padded to field length | **[BYTES]** (`NAME`, `PRFEDEA`) |
| `D` | Date | 8 bytes, `YYYYMMDD` ASCII | **[BYTES]** (`BIRTHDATE`: `"19870301"`) |
| `N` | Numeric | Right-justified ASCII, space-padded; literal `-` and `.` where needed | **[BYTES]** (`AREA`: `"  215229.266"`, width 12 decimals 3; a later record in `poly.dbf` carries `"-596610.313"`, confirming the sign is literal text inside the field, not a separate flag) |
| `L` | Logical | One byte: `Y`/`y`/`N`/`n`/`T`/`t`/`F`/`f`, or `?` uninitialized | **[SRC]** only (independent-software.com, Wikipedia agree) — no real sample with an `L` field found yet |
| `M` | Memo | 10-byte ASCII block-number string into a companion `.DBT`, space-padded, blank = no memo | **[SRC]** only (§0's correction — the one real sample found was Visual FoxPro, not dBASE III) |
| `F` | Float | Right-justified ASCII, like `N` | **[SRC]** only (Wikipedia; not in the owner's dBASE III field-type table on dbase.com, which lists it as a later addition) |

**Record format**: one delete-flag byte (`0x20` space = live, `0x2A` `*` =
deleted **[BYTES]**, both states present in `people.dbf`'s three records)
then the fields in descriptor order, no delimiters. End of file is marked by
a single `0x1A` byte after the last record **[BYTES]**.

---

## 4. The `.DBT` memo companion file — not yet byte-verified

**[SRC]** only, independent-software.com: a 4-byte next-free-block index
(big-endian) and a block-size word (the source and a page comment disagree
on whether it sits at offset `0x04` or `0x06` — flagged, not resolved); each
block is a 4-byte type, a 4-byte length, then data, space-padded to the
block boundary. A `.DBF` memo field holds the block index as a space-padded
ASCII string in genuine old dBASE III/FoxBase (field length > 4) versus a
binary `uint32` in later variants (field length == 4) — the field length
itself is what tells a reader which shape it is reading.

**None of this is confirmed against a real file.** Per DBASE3-PLAN.md §1.2's own staging, memo support is not required for wave 1 (`.DBF` read/write
with no language, no index); when it is picked up, get a real `.DBF`+`.DBT`
pair that is confirmed genuine dBASE III (version byte `0x83`, not `0x30`)
before trusting this section.

---

## 5. What is still open before wave 1 can close its own story

- A real sample with an `L` (Logical) field, to move §3's Logical row from
  **[SRC]** to **[BYTES]**.
- A real, *confirmed-genuine* dBASE III `.DBF`+`.DBT` pair (version byte
  `0x83`) for §4.
- The language reference (`DBASE3-PLAN.md` §1.3) is covered separately: the
  20 books under `~/Documents/_LIBRARY/books/programming_-_reference/dbase/`
  carry extensive real `.PRG` program listings and command syntax
  (`USE`/`DO WHILE`/`ENDDO` and the rest), verified present by direct text
  search of each book, but no attempt has been made yet to pin individual
  command *edge-case* behaviour the way `DBASE3-PLAN.md` §1.3 asks — that is
  wave 3/4's work, not wave 1's.

#!/usr/bin/env python3
"""SYLK, DIF and BIFF2 read and written on the HOST — SHEET's second opinion.

    python3 tools/os88sheetfmt.py <file>           # dump whatever it is
    python3 tools/os88sheetfmt.py --selfcheck      # the grammars against themselves

SPEC.md 81.38.  `tests/sheetfmt.py` is the gate this exists for, and the whole
point of it is that **nothing here was written by reading `apps/sheet/sheet.asm`**.

A round trip that only ever asks SHEET is worth very little: a writer and a
reader that share a misunderstanding agree with each other perfectly, and the
file they agree about is one no other program can open.  So these come from the
published grammars instead —

  * SYLK and DIF from Jeff Walden, *File Formats for Popular PC Software: A
    Programmer's Reference* (the copy under `File_Formats/`), which is also
    what corrected SHEET's own DIF value-indicator line when it was written.
  * BIFF2 from the OpenOffice.org *Microsoft Excel File Format* document —
    record ids 0001H BLANK / 0002H INTEGER / 0003H NUMBER / 0004H LABEL /
    0005H BOOLERR / 0006H FORMULA / 0009H BOF / 000AH EOF, the BIFF2 cell
    header of row(2) col(2) attributes(3), and the error codes of its §2.4.

`write_sylk` is here for the same reason.  The gate hands SHEET a file the HOST
authored, so a defect in SHEET's reader cannot be cancelled out by the matching
defect in its writer — which is the failure mode a save/load round trip is
least able to see.

A cell value is one of:

    float                     a number
    str                       text
    ('bool', True|False)      a logical
    ('err',  '#DIV/0!')       an error
    ('formula', expr, value)  a formula and its cached result

Keys are ``(row, col)``, **0-based**, however the format on disk numbers them.
"""
import struct
import sys

# The BIFF2 record ids this understands.  Anything else is skipped by its
# length, which is what the format is designed for and what SYLK's own
# "ignore records you aren't prepared to handle" rule says in words.
BIFF_BLANK, BIFF_INTEGER, BIFF_NUMBER = 0x01, 0x02, 0x03
BIFF_LABEL, BIFF_BOOLERR, BIFF_FORMULA = 0x04, 0x05, 0x06
BIFF_BOF, BIFF_EOF, BIFF_DIMENSIONS = 0x09, 0x0A, 0x00
BIFF_RK = 0x7E                          # 027EH, BIFF3 on; replaces INTEGER

# BIFF3 renumbers the cell records into the 02xxH block and widens the cell
# header - row(2) col(2) then a 2-byte XF index where BIFF2 had 3 bytes of
# packed attributes.  SHEET writes BIFF3 deliberately (SPEC.md 81.10), so a
# reader that only knew the BIFF2 column of the tables would reject every file
# it has ever produced.  Both are read here, decided by the BOF.
BIFF3_BIT = 0x0200

# excelfileformat.pdf §2.4.  #N/A is written "#N/A!" there and "#N/A"
# everywhere a user sees it; the second is what SYLK and Excel's own UI use.
BIFF_ERRORS = {0x00: '#NULL!', 0x07: '#DIV/0!', 0x0F: '#VALUE!',
               0x17: '#REF!', 0x1D: '#NAME?', 0x24: '#NUM!', 0x2A: '#N/A'}
ERR_CODES = dict((v, k) for k, v in BIFF_ERRORS.items())


class FormatError(Exception):
    pass


def _num(s):
    """A number as the formats write one, or raise."""
    return float(s)


# -----------------------------------------------------------------------------
# SYLK.  Records are CRLF-separated; a record is an RTD, then semicolon-
# introduced fields whose meaning depends on the RTD.  ;X and ;Y are the column
# and row and are STICKY — Walden's "(ditt)": a field left out repeats the last
# one given, which is how a row of cells writes ;Y once.  A literal semicolon
# inside a field is doubled.
# -----------------------------------------------------------------------------
def _sylk_fields(rec):
    """Split one record into (letter, rest) pairs, honouring the ';;' escape."""
    out, i, n = [], 0, len(rec)
    while i < n:
        j = i
        buf = []
        while j < n:
            if rec[j] == ';':
                if j + 1 < n and rec[j + 1] == ';':
                    buf.append(';')
                    j += 2
                    continue
                break
            buf.append(rec[j])
            j += 1
        out.append(''.join(buf))
        i = j + 1
    return out


def read_sylk(data):
    if isinstance(data, bytes):
        data = data.decode('latin-1')
    cells = {}
    row = col = 1
    for raw in data.replace('\r\n', '\n').replace('\r', '\n').split('\n'):
        if not raw.strip():
            continue                       # "Empty records are ignored"
        parts = _sylk_fields(raw)
        rtd = parts[0]
        if rtd != 'C':                     # ID, B, F, O, E, P, W... not values
            continue
        val = None
        expr = None
        for f in parts[1:]:
            if not f:
                continue
            k, rest = f[0], f[1:]
            if k == 'X':
                col = int(rest)
            elif k == 'Y':
                row = int(rest)
            elif k == 'K':
                val = _sylk_value(rest)
            elif k == 'E':
                expr = rest
        if val is None and expr is None:
            continue
        key = (row - 1, col - 1)           # SYLK's origin is 1,1
        cells[key] = ('formula', expr, val) if expr is not None else val
    return cells


def _sylk_value(s):
    if s.startswith('"') and s.endswith('"') and len(s) >= 2:
        body = s[1:-1]
        if body == 'TRUE':
            return ('bool', True)
        if body == 'FALSE':
            return ('bool', False)
        return body
    if s.startswith('#'):                  # "An ERROR value is preceded by #"
        return ('err', s)
    return _num(s)


def write_sylk(cells, producer='OS88TEST'):
    """A SYLK file the HOST wrote, for handing to SHEET's reader."""
    rows = [r for r, _ in cells] or [0]
    cols = [c for _, c in cells] or [0]
    out = ['ID;P%s' % producer,
           'B;Y%d;X%d' % (max(rows) + 1, max(cols) + 1)]
    for (r, c) in sorted(cells):
        v = cells[(r, c)]
        out.append('C;Y%d;X%d;%s' % (r + 1, c + 1, _sylk_out(v)))
    out.append('E')
    return ('\r\n'.join(out) + '\r\n').encode('latin-1')


def _sylk_out(v):
    if isinstance(v, tuple) and v and v[0] == 'formula':
        _, expr, val = v
        return 'K%s;E%s' % (_sylk_scalar(val), expr)
    return 'K%s' % _sylk_scalar(v)


def _sylk_scalar(v):
    if isinstance(v, tuple):
        if v[0] == 'bool':
            return '"TRUE"' if v[1] else '"FALSE"'
        if v[0] == 'err':
            return v[1]
    if isinstance(v, str):
        return '"%s"' % v.replace(';', ';;')
    if v is None:
        return ''
    return _fmtnum(v)


def _fmtnum(x):
    """Shortest round-tripping decimal, and never an exponent — the era's
    readers are not obliged to parse one."""
    if x == int(x) and abs(x) < 1e15:
        return '%d' % int(x)
    return repr(float(x))


# -----------------------------------------------------------------------------
# DIF.  A header of <topic> / <vector>,<number> / "<string>" triples ending in
# DATA 0,0, then the data proper: one entry per cell as a two-line pair, tuples
# introduced by a -1,0 / BOT and the file closed by -1,0 / EOD.
# -----------------------------------------------------------------------------
def read_dif(data):
    if isinstance(data, bytes):
        data = data.decode('latin-1')
    lines = [l.rstrip('\r') for l in data.replace('\r\n', '\n').split('\n')]
    i, n = 0, len(lines)
    # Walk the header to DATA.  Nothing here needs VECTORS or TUPLES: the BOT
    # markers say where the rows are, and trusting a declared count over the
    # data itself is how a truncated file reads as a valid short one.
    while i < n and lines[i].strip() != 'DATA':
        i += 1
    if i >= n:
        raise FormatError('no DATA section')
    # A header entry is THREE lines - <topic>, <vector>,<number> and
    # "<string>" - and DATA is a header entry like any other.  Skipping only
    # two put every later pair half a line out, which does not fail: it reads
    # as a file with no cells in it.
    i += 2                                  # 'DATA' and its '0,0'
    if i < n and lines[i].strip().startswith('"'):
        i += 1                              # ...and its string, usually ""
    cells = {}
    row, col = -1, 0
    while i + 1 < n:
        head, body = lines[i].strip(), lines[i + 1].strip()
        i += 2
        if not head:
            continue
        try:
            tind, num = head.split(',', 1)
            tind = int(tind)
        except ValueError:
            continue
        if tind == -1:
            if body == 'BOT':
                row += 1
                col = 0
            elif body == 'EOD':
                break
            continue
        if tind == 0:                       # numeric, body is the indicator
            ind = body.strip('"')
            if ind == 'V':
                cells[(row, col)] = _num(num)
            elif ind == 'TRUE':
                cells[(row, col)] = ('bool', True)
            elif ind == 'FALSE':
                cells[(row, col)] = ('bool', False)
            elif ind == 'NA':
                cells[(row, col)] = ('err', '#N/A')
            elif ind.startswith('ERROR'):
                cells[(row, col)] = ('err', '#VALUE!')
            col += 1
        elif tind == 1:                     # string data
            cells[(row, col)] = body[1:-1] if body.startswith('"') else body
            col += 1
    return cells


# -----------------------------------------------------------------------------
# BIFF2.  <id:2><length:2><data>, and every cell record opens row(2) col(2)
# attributes(3).
# -----------------------------------------------------------------------------
def read_biff(data):
    cells, i, n = {}, 0, len(data)
    vstart = None                       # where a cell record's value begins
    while i + 4 <= n:
        rid, ln = struct.unpack_from('<HH', data, i)
        i += 4
        if i + ln > n:
            raise FormatError('record 0x%04X at %d runs past the end'
                              % (rid, i))
        body = data[i:i + ln]
        i += ln
        if rid in (BIFF_BOF, BIFF_BOF | BIFF3_BIT):
            vstart = 7 if rid == BIFF_BOF else 6
            continue
        if rid == BIFF_EOF:
            break
        if vstart is None:
            continue
        kind = rid & ~BIFF3_BIT if rid >= BIFF3_BIT else rid
        if kind in (BIFF_BLANK, BIFF_INTEGER, BIFF_NUMBER, BIFF_LABEL,
                    BIFF_BOOLERR, BIFF_FORMULA, BIFF_RK):
            if ln < vstart:
                raise FormatError('cell record 0x%04X is %d bytes' % (rid, ln))
            r, c = struct.unpack_from('<HH', body, 0)
            v = _biff_value(kind, body, vstart)
            if v is not None:
                cells[(r, c)] = v
    if vstart is None:
        raise FormatError('no BOF record — this is not a BIFF stream')
    return cells


def _rk(v):
    """An RK number.  Bit 1 says integer-or-double, bit 0 says the value was
    multiplied by 100 to fit; a double keeps only its high four bytes."""
    div100 = v & 1
    if v & 2:
        i = v - 0x100000000 if v & 0x80000000 else v
        out = float(i >> 2)             # arithmetic, and Python's >> is
    else:
        out = struct.unpack('<d', struct.pack('<II', 0, v & 0xFFFFFFFC))[0]
    return out / 100.0 if div100 else out


def _biff_value(rid, body, v):
    if rid == BIFF_BLANK:
        return None
    if rid == BIFF_INTEGER:
        return float(struct.unpack_from('<H', body, v)[0])
    if rid == BIFF_RK:
        return _rk(struct.unpack_from('<I', body, v)[0])
    if rid == BIFF_NUMBER:
        return struct.unpack_from('<d', body, v)[0]
    if rid == BIFF_LABEL:
        # BIFF2 counts a byte string's characters in ONE byte and BIFF3 in two
        # (§2.1, "either as 8-bit-integer or as 16-bit-integer, depending on
        # the current record").  Reading a BIFF3 label with the BIFF2 rule
        # does not fail; it returns the string shifted by one, with the high
        # half of the count on the front of it.
        if v == 6:                              # BIFF3
            ln = struct.unpack_from('<H', body, v)[0]
            return body[v + 2:v + 2 + ln].decode('latin-1')
        ln = body[v]
        return body[v + 1:v + 1 + ln].decode('latin-1')
    if rid == BIFF_BOOLERR:
        val, kind = body[v], body[v + 1]
        if kind == 0:
            return ('bool', val != 0)
        return ('err', BIFF_ERRORS.get(val, '#ERR%02X' % val))
    if rid == BIFF_FORMULA:
        # The cached result is 8 bytes.  Excel encodes a non-numeric result by
        # setting the last two bytes to FFFFH and typing it in the first — the
        # same trick a NaN payload is, and the reason a formula's result must
        # not simply be unpacked as a double.
        raw = body[v:v + 8]
        if len(raw) == 8 and raw[6] == 0xFF and raw[7] == 0xFF:
            kind = raw[0]
            if kind == 1:
                return ('formula', None, ('bool', raw[2] != 0))
            if kind == 2:
                return ('formula', None, ('err', BIFF_ERRORS.get(raw[2],
                                                                 '#ERR')))
            if kind == 3:
                return ('formula', None, '')
        return ('formula', None, struct.unpack_from('<d', raw, 0)[0])
    return None



# -----------------------------------------------------------------------------
# CSV and tab-delimited TEXT.  Two of the nine formats Excel 2.0's Reference
# Guide lists under "Supported file formats (open/save)" (p.273).  Quoting is
# the ordinary CSV rule and not DIF's: a field carrying the delimiter, a quote
# or a line break is wrapped in quotes, and its own quotes are doubled.
# -----------------------------------------------------------------------------
def read_sep(data, sep):
    if isinstance(data, bytes):
        data = data.decode('latin-1')
    cells, row, col, i, n = {}, 0, 0, 0, len(data)
    field, quoted, seen = [], False, False
    def flush():
        nonlocal field, quoted, seen
        txt = ''.join(field)
        if txt != '' or quoted:
            cells[(row, col)] = _sep_value(txt, quoted)
        field, quoted, seen = [], False, False
    while i < n:
        c = data[i]
        if not seen and c == '"':
            quoted, seen, i = True, True, i + 1
            while i < n:
                if data[i] == '"':
                    if i + 1 < n and data[i + 1] == '"':
                        field.append('"'); i += 2; continue
                    i += 1
                    break
                field.append(data[i]); i += 1
            continue
        seen = True
        if c == sep:
            flush(); col += 1; i += 1; continue
        if c in '\r\n':
            flush(); col = 0; row += 1
            while i < n and data[i] in '\r\n':
                i += 1
            continue
        field.append(c); i += 1
    flush()
    return cells


def _sep_value(txt, quoted):
    if quoted:
        return txt                      # quotes mean TEXT, always
    try:
        return float(txt)
    except ValueError:
        return txt


def read_csv(data):
    return read_sep(data, ',')


def read_txt(data):
    return read_sep(data, '\t')


# -----------------------------------------------------------------------------
def sniff(path, data):
    if data[:2] in (b'\x09\x00', b'\x09\x02', b'\x09\x04'):
        return 'biff'
    head = data[:512].decode('latin-1', 'replace')
    if head.startswith('TABLE'):
        return 'dif'
    if head.startswith('ID;'):
        return 'sylk'
    low = path.lower()
    for ext, kind in (('.bif', 'biff'), ('.xls', 'biff'), ('.dif', 'dif'),
                      ('.slk', 'sylk'), ('.csv', 'csv'), ('.txt', 'txt')):
        if low.endswith(ext):
            return kind
    raise FormatError('cannot tell what %s is' % path)


def read(path, data=None, kind=None):
    if data is None:
        data = open(path, 'rb').read()
    kind = kind or sniff(path, data)
    return {'sylk': read_sylk, 'dif': read_dif, 'biff': read_biff,
            'csv': read_csv, 'txt': read_txt}[kind](data)


def scalar(v):
    """The comparable part of a value: a formula compares by its RESULT,
    because DIF cannot carry an expression at all and a cross-format
    comparison that demanded one would only ever be testing SYLK."""
    if isinstance(v, tuple) and v and v[0] == 'formula':
        return v[2]
    return v


def close(a, b, tol=1e-9):
    """Compare two cell values.  Numbers get a tolerance because the three
    formats do not agree about how a double is spelled: BIFF stores the bits,
    SYLK and DIF store a decimal rendering of them."""
    a, b = scalar(a), scalar(b)
    if isinstance(a, float) and isinstance(b, float):
        if a == b:
            return True
        return abs(a - b) <= tol * max(1.0, abs(a), abs(b))
    return a == b


def _selfcheck():
    """The grammars against themselves.  This proves the readers parse what
    this file writes; it CANNOT prove either matches SHEET, which is what
    tests/sheetfmt.py is for and why that gate is the one that counts."""
    cells = {(0, 0): 1.5, (1, 0): -2.25, (2, 0): 'Hello',
             (3, 0): ('bool', True), (4, 0): ('err', '#DIV/0!'),
             (0, 1): 42.0, (1, 1): ('formula', 'A1+A2', -0.75)}
    back = read_sylk(write_sylk(cells))
    bad = []
    for k, v in cells.items():
        if k not in back:
            bad.append('%r missing' % (k,))
        elif not close(v, back[k]):
            bad.append('%r: wrote %r read %r' % (k, v, back[k]))
    # A semicolon in text is the escape the grammar calls for and the one
    # thing here a naive split gets wrong.
    tricky = {(0, 0): 'a;b'}
    if read_sylk(write_sylk(tricky)).get((0, 0)) != 'a;b':
        bad.append('the ;; escape does not round trip')
    if bad:
        for b in bad:
            print('os88sheetfmt: %s' % b)
        return 1
    print('os88sheetfmt: selfcheck ok (%d cells, ;; escape)' % len(cells))
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == '--selfcheck':
        return _selfcheck()
    if len(argv) != 2:
        print(__doc__.strip().split('\n\n')[1])
        return 2
    cells = read(argv[1])
    for k in sorted(cells):
        print('%s%d\t%r' % (chr(ord('A') + k[1]) if k[1] < 26 else '?%d' % k[1],
                            k[0] + 1, cells[k]))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))

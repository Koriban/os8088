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
import os
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

# BIFF4 renumbers again, into 04xxH, and adds the WORKBOOK: one globals
# substream (BOF dt=0100H) carrying FONT/XF and the sheet directory, then one
# BOF..EOF substream per sheet, each introduced by a SHEETHDR naming it.  SHEET
# writes this whenever a document uses more than one of its grids (SPEC.md
# 81.10.5), so a reader that stopped at the first EOF - as this one did - saw
# the globals, no cells at all, and called it an empty file.
BIFF4_BIT = 0x0400
BIFF_SHEETHDR = 0x008F                  # <length:4><name length:1><name>
# The text a string formula answered, directly after its FORMULA record
# (5.102): 0007H in BIFF2 with an 8-bit length, 0207H from BIFF3 with 16.
BIFF_STRING = 0x07
_PENDING = object()                     # a FORMULA's text is in the next record

# excelfileformat.pdf §2.4.  #N/A is written "#N/A!" there and "#N/A"
# everywhere a user sees it; the second is what SYLK and Excel's own UI use.
BIFF_ERRORS = {0x00: '#NULL!', 0x07: '#DIV/0!', 0x0F: '#VALUE!',
               0x17: '#REF!', 0x1D: '#NAME?', 0x24: '#NUM!', 0x2A: '#N/A'}
ERR_CODES = dict((v, k) for k, v in BIFF_ERRORS.items())

# Every built-in sheet function of BIFF2-BIFF4: index -> (name, (min, max) in
# BIFF3 or None if it is not in BIFF3, (min, max) in BIFF4). GENERATED from
# revision 1.42 of the OpenOffice.org "Microsoft Excel File Format" document,
# section 3.11 - the revision that HAS the table; the copy in docs/ is the 2002
# one, whose 3.11 reads "2do". Footnote numbers the PDF glues to a name
# (TRUNC11, DAYS36010) were stripped by hand, not by pattern, because LOG10,
# ATAN2 and SUMX2MY2 really end in digits. Two indices change name between
# the versions (204 YEN -> USDOLLAR, 215 JIS -> DBCS); the BIFF4 name is kept.
#
# It is here, in the SECOND reader, for the reason this whole file exists: a
# table SHEET copied by hand had six wrong entries (UPPER/LOWER swapped, INDEX
# as DATE, PMT as DMIN, RATE and MIRR one place off) that nothing noticed,
# because SHEET wrote function numbers and never read one back. _check_functab
# below holds sheet.asm's tables to this one on every build.
BIFF_FUNCS = {
      0: ('COUNT'     , (0, 30) , (0, 30)),
      1: ('IF'        , (2, 3)  , (2, 3)),
      2: ('ISNA'      , (1, 1)  , (1, 1)),
      3: ('ISERROR'   , (1, 1)  , (1, 1)),
      4: ('SUM'       , (0, 30) , (0, 30)),
      5: ('AVERAGE'   , (1, 30) , (1, 30)),
      6: ('MIN'       , (1, 30) , (1, 30)),
      7: ('MAX'       , (1, 30) , (1, 30)),
      8: ('ROW'       , (0, 1)  , (0, 1)),
      9: ('COLUMN'    , (0, 1)  , (0, 1)),
     10: ('NA'        , (0, 0)  , (0, 0)),
     11: ('NPV'       , (2, 30) , (2, 30)),
     12: ('STDEV'     , (1, 30) , (1, 30)),
     13: ('DOLLAR'    , (1, 2)  , (1, 2)),
     14: ('FIXED'     , (2, 2)  , (2, 3)),
     15: ('SIN'       , (1, 1)  , (1, 1)),
     16: ('COS'       , (1, 1)  , (1, 1)),
     17: ('TAN'       , (1, 1)  , (1, 1)),
     18: ('ATAN'      , (1, 1)  , (1, 1)),
     19: ('PI'        , (0, 0)  , (0, 0)),
     20: ('SQRT'      , (1, 1)  , (1, 1)),
     21: ('EXP'       , (1, 1)  , (1, 1)),
     22: ('LN'        , (1, 1)  , (1, 1)),
     23: ('LOG10'     , (1, 1)  , (1, 1)),
     24: ('ABS'       , (1, 1)  , (1, 1)),
     25: ('INT'       , (1, 1)  , (1, 1)),
     26: ('SIGN'      , (1, 1)  , (1, 1)),
     27: ('ROUND'     , (2, 2)  , (2, 2)),
     28: ('LOOKUP'    , (2, 3)  , (2, 3)),
     29: ('INDEX'     , (2, 4)  , (2, 4)),
     30: ('REPT'      , (2, 2)  , (2, 2)),
     31: ('MID'       , (3, 3)  , (3, 3)),
     32: ('LEN'       , (1, 1)  , (1, 1)),
     33: ('VALUE'     , (1, 1)  , (1, 1)),
     34: ('TRUE'      , (0, 0)  , (0, 0)),
     35: ('FALSE'     , (0, 0)  , (0, 0)),
     36: ('AND'       , (1, 30) , (1, 30)),
     37: ('OR'        , (1, 30) , (1, 30)),
     38: ('NOT'       , (1, 1)  , (1, 1)),
     39: ('MOD'       , (2, 2)  , (2, 2)),
     40: ('DCOUNT'    , (3, 3)  , (3, 3)),
     41: ('DSUM'      , (3, 3)  , (3, 3)),
     42: ('DAVERAGE'  , (3, 3)  , (3, 3)),
     43: ('DMIN'      , (3, 3)  , (3, 3)),
     44: ('DMAX'      , (3, 3)  , (3, 3)),
     45: ('DSTDEV'    , (3, 3)  , (3, 3)),
     46: ('VAR'       , (1, 30) , (1, 30)),
     47: ('DVAR'      , (3, 3)  , (3, 3)),
     48: ('TEXT'      , (2, 2)  , (2, 2)),
     49: ('LINEST'    , (1, 4)  , (1, 4)),
     50: ('TREND'     , (1, 4)  , (1, 4)),
     51: ('LOGEST'    , (1, 4)  , (1, 4)),
     52: ('GROWTH'    , (1, 4)  , (1, 4)),
     56: ('PV'        , (3, 5)  , (3, 5)),
     57: ('FV'        , (3, 5)  , (3, 5)),
     58: ('NPER'      , (3, 5)  , (3, 5)),
     59: ('PMT'       , (3, 5)  , (3, 5)),
     60: ('RATE'      , (3, 6)  , (3, 6)),
     61: ('MIRR'      , (3, 3)  , (3, 3)),
     62: ('IRR'       , (1, 2)  , (1, 2)),
     63: ('RAND'      , (0, 0)  , (0, 0)),
     64: ('MATCH'     , (2, 3)  , (2, 3)),
     65: ('DATE'      , (3, 3)  , (3, 3)),
     66: ('TIME'      , (3, 3)  , (3, 3)),
     67: ('DAY'       , (1, 1)  , (1, 1)),
     68: ('MONTH'     , (1, 1)  , (1, 1)),
     69: ('YEAR'      , (1, 1)  , (1, 1)),
     70: ('WEEKDAY'   , (1, 1)  , (1, 1)),
     71: ('HOUR'      , (1, 1)  , (1, 1)),
     72: ('MINUTE'    , (1, 1)  , (1, 1)),
     73: ('SECOND'    , (1, 1)  , (1, 1)),
     74: ('NOW'       , (0, 0)  , (0, 0)),
     75: ('AREAS'     , (1, 1)  , (1, 1)),
     76: ('ROWS'      , (1, 1)  , (1, 1)),
     77: ('COLUMNS'   , (1, 1)  , (1, 1)),
     78: ('OFFSET'    , (3, 5)  , (3, 5)),
     82: ('SEARCH'    , (2, 3)  , (2, 3)),
     83: ('TRANSPOSE' , (1, 1)  , (1, 1)),
     86: ('TYPE'      , (1, 1)  , (1, 1)),
     97: ('ATAN2'     , (2, 2)  , (2, 2)),
     98: ('ASIN'      , (1, 1)  , (1, 1)),
     99: ('ACOS'      , (1, 1)  , (1, 1)),
    100: ('CHOOSE'    , (2, 30) , (2, 30)),
    101: ('HLOOKUP'   , (3, 3)  , (3, 3)),
    102: ('VLOOKUP'   , (3, 3)  , (3, 3)),
    105: ('ISREF'     , (1, 1)  , (1, 1)),
    109: ('LOG'       , (1, 2)  , (1, 2)),
    111: ('CHAR'      , (1, 1)  , (1, 1)),
    112: ('LOWER'     , (1, 1)  , (1, 1)),
    113: ('UPPER'     , (1, 1)  , (1, 1)),
    114: ('PROPER'    , (1, 1)  , (1, 1)),
    115: ('LEFT'      , (1, 2)  , (1, 2)),
    116: ('RIGHT'     , (1, 2)  , (1, 2)),
    117: ('EXACT'     , (2, 2)  , (2, 2)),
    118: ('TRIM'      , (1, 1)  , (1, 1)),
    119: ('REPLACE'   , (4, 4)  , (4, 4)),
    120: ('SUBSTITUTE', (3, 4)  , (3, 4)),
    121: ('CODE'      , (1, 1)  , (1, 1)),
    124: ('FIND'      , (2, 3)  , (2, 3)),
    125: ('CELL'      , (1, 2)  , (1, 2)),
    126: ('ISERR'     , (1, 1)  , (1, 1)),
    127: ('ISTEXT'    , (1, 1)  , (1, 1)),
    128: ('ISNUMBER'  , (1, 1)  , (1, 1)),
    129: ('ISBLANK'   , (1, 1)  , (1, 1)),
    130: ('T'         , (1, 1)  , (1, 1)),
    131: ('N'         , (1, 1)  , (1, 1)),
    140: ('DATEVALUE' , (1, 1)  , (1, 1)),
    141: ('TIMEVALUE' , (1, 1)  , (1, 1)),
    142: ('SLN'       , (3, 3)  , (3, 3)),
    143: ('SYD'       , (4, 4)  , (4, 4)),
    144: ('DDB'       , (4, 5)  , (4, 5)),
    148: ('INDIRECT'  , (1, 2)  , (1, 2)),
    162: ('CLEAN'     , (1, 1)  , (1, 1)),
    163: ('MDETERM'   , (1, 1)  , (1, 1)),
    164: ('MINVERSE'  , (1, 1)  , (1, 1)),
    165: ('MMULT'     , (2, 2)  , (2, 2)),
    167: ('IPMT'      , (4, 6)  , (4, 6)),
    168: ('PPMT'      , (4, 6)  , (4, 6)),
    169: ('COUNTA'    , (0, 30) , (0, 30)),
    183: ('PRODUCT'   , (0, 30) , (0, 30)),
    184: ('FACT'      , (1, 1)  , (1, 1)),
    189: ('DPRODUCT'  , (3, 3)  , (3, 3)),
    190: ('ISNONTEXT' , (1, 1)  , (1, 1)),
    193: ('STDEVP'    , (1, 30) , (1, 30)),
    194: ('VARP'      , (1, 30) , (1, 30)),
    195: ('DSTDEVP'   , (3, 3)  , (3, 3)),
    196: ('DVARP'     , (3, 3)  , (3, 3)),
    197: ('TRUNC'     , (1, 2)  , (1, 2)),
    198: ('ISLOGICAL' , (1, 1)  , (1, 1)),
    199: ('DCOUNTA'   , (3, 3)  , (3, 3)),
    204: ('USDOLLAR'  , (1, 2)  , (1, 2)),
    205: ('FINDB'     , (2, 3)  , (2, 3)),
    206: ('SEARCHB'   , (2, 3)  , (2, 3)),
    207: ('REPLACEB'  , (4, 4)  , (4, 4)),
    208: ('LEFTB'     , (1, 2)  , (1, 2)),
    209: ('RIGHTB'    , (1, 2)  , (1, 2)),
    210: ('MIDB'      , (3, 3)  , (3, 3)),
    211: ('LENB'      , (1, 1)  , (1, 1)),
    212: ('ROUNDUP'   , (2, 2)  , (2, 2)),
    213: ('ROUNDDOWN' , (2, 2)  , (2, 2)),
    214: ('ASC'       , (1, 1)  , (1, 1)),
    215: ('DBCS'      , (1, 1)  , (1, 1)),
    216: ('RANK'      , None    , (2, 3)),
    219: ('ADDRESS'   , (2, 5)  , (2, 5)),
    220: ('DAYS360'   , (2, 2)  , (2, 2)),
    221: ('TODAY'     , (0, 0)  , (0, 0)),
    222: ('VDB'       , (5, 7)  , (5, 7)),
    227: ('MEDIAN'    , (1, 30) , (1, 30)),
    228: ('SUMPRODUCT', (1, 30) , (1, 30)),
    229: ('SINH'      , (1, 1)  , (1, 1)),
    230: ('COSH'      , (1, 1)  , (1, 1)),
    231: ('TANH'      , (1, 1)  , (1, 1)),
    232: ('ASINH'     , (1, 1)  , (1, 1)),
    233: ('ACOSH'     , (1, 1)  , (1, 1)),
    234: ('ATANH'     , (1, 1)  , (1, 1)),
    235: ('DGET'      , (3, 3)  , (3, 3)),
    244: ('INFO'      , (1, 1)  , (1, 1)),
    247: ('DB'        , None    , (4, 5)),
    252: ('FREQUENCY' , None    , (2, 2)),
    261: ('ERROR.TYPE', None    , (1, 1)),
    269: ('AVEDEV'    , None    , (1, 30)),
    270: ('BETADIST'  , None    , (3, 5)),
    271: ('GAMMALN'   , None    , (1, 1)),
    272: ('BETAINV'   , None    , (3, 5)),
    273: ('BINOMDIST' , None    , (4, 4)),
    274: ('CHIDIST'   , None    , (2, 2)),
    275: ('CHIINV'    , None    , (2, 2)),
    276: ('COMBIN'    , None    , (2, 2)),
    277: ('CONFIDENCE', None    , (3, 3)),
    278: ('CRITBINOM' , None    , (3, 3)),
    279: ('EVEN'      , None    , (1, 1)),
    280: ('EXPONDIST' , None    , (3, 3)),
    281: ('FDIST'     , None    , (3, 3)),
    282: ('FINV'      , None    , (3, 3)),
    283: ('FISHER'    , None    , (1, 1)),
    284: ('FISHERINV' , None    , (1, 1)),
    285: ('FLOOR'     , None    , (2, 2)),
    286: ('GAMMADIST' , None    , (4, 4)),
    287: ('GAMMAINV'  , None    , (3, 3)),
    288: ('CEILING'   , None    , (2, 2)),
    289: ('HYPGEOMDIST', None    , (4, 4)),
    290: ('LOGNORMDIST', None    , (3, 3)),
    291: ('LOGINV'    , None    , (3, 3)),
    292: ('NEGBINOMDIST', None    , (3, 3)),
    293: ('NORMDIST'  , None    , (4, 4)),
    294: ('NORMSDIST' , None    , (1, 1)),
    295: ('NORMINV'   , None    , (3, 3)),
    296: ('NORMSINV'  , None    , (1, 1)),
    297: ('STANDARDIZE', None    , (3, 3)),
    298: ('ODD'       , None    , (1, 1)),
    299: ('PERMUT'    , None    , (2, 2)),
    300: ('POISSON'   , None    , (3, 3)),
    301: ('TDIST'     , None    , (3, 3)),
    302: ('WEIBULL'   , None    , (4, 4)),
    303: ('SUMXMY2'   , None    , (2, 2)),
    304: ('SUMX2MY2'  , None    , (2, 2)),
    305: ('SUMX2PY2'  , None    , (2, 2)),
    306: ('CHITEST'   , None    , (2, 2)),
    307: ('CORREL'    , None    , (2, 2)),
    308: ('COVAR'     , None    , (2, 2)),
    309: ('FORECAST'  , None    , (3, 3)),
    310: ('FTEST'     , None    , (2, 2)),
    311: ('INTERCEPT' , None    , (2, 2)),
    312: ('PEARSON'   , None    , (2, 2)),
    313: ('RSQ'       , None    , (2, 2)),
    314: ('STEYX'     , None    , (2, 2)),
    315: ('SLOPE'     , None    , (2, 2)),
    316: ('TTEST'     , None    , (4, 4)),
    317: ('PROB'      , None    , (3, 4)),
    318: ('DEVSQ'     , None    , (1, 30)),
    319: ('GEOMEAN'   , None    , (1, 30)),
    320: ('HARMEAN'   , None    , (1, 30)),
    321: ('SUMSQ'     , None    , (0, 30)),
    322: ('KURT'      , None    , (1, 30)),
    323: ('SKEW'      , None    , (1, 30)),
    324: ('ZTEST'     , None    , (2, 3)),
    325: ('LARGE'     , None    , (2, 2)),
    326: ('SMALL'     , None    , (2, 2)),
    327: ('QUARTILE'  , None    , (2, 2)),
    328: ('PERCENTILE', None    , (2, 2)),
    329: ('PERCENTRANK', None    , (2, 3)),
    330: ('MODE'      , None    , (1, 30)),
    331: ('TRIMMEAN'  , None    , (2, 2)),
    332: ('TINV'      , None    , (2, 2)),
}

# The tokens decode_rpn turns back into text (excelfileformat 3.5-3.10), and
# the text each operator is. Anything else answers None: THE CALLER KEEPS THE
# CACHED VALUE, which is what SHEET's reader did for every formula before it
# learned to decode, so an unknown token costs a formula its liveness and never
# its number. That is the whole policy, and SHEET's own decoder
# follows it token for token - this is its reference implementation.
_RPN_BIN = {0x03: '+', 0x04: '-', 0x05: '*', 0x06: '/', 0x07: '^', 0x08: '&',
            0x09: '<', 0x0A: '<=', 0x0B: '=', 0x0C: '>=', 0x0D: '>', 0x0E: '<>'}


def colname(c):
    """0 -> A, 25 -> Z, 26 -> AA: bijective base 26."""
    out = ''
    c += 1
    while c:
        c, r = divmod(c - 1, 26)
        out = chr(65 + r) + out
    return out


def _cellref(roww, col):
    """A BIFF2-5 encoded address (3.3.3): bit 15 of the row word is 'row is
    RELATIVE' and bit 14 'column is relative' - set means no '$'."""
    return ('%s%s%s%d' % ('' if roww & 0x4000 else '$', colname(col),
                          '' if roww & 0x8000 else '$', (roww & 0x3FFF) + 1))


def decode_rpn(tok, ver, known=None):
    """A BIFF3/4 FORMULA token array -> formula text without the '=', or None.

    `known` restricts function calls to a set of names - SHEET's own, so a
    formula calling something SHEET cannot compute keeps its value rather
    than becoming #NAME?. RPN with explicit tParen needs no precedence of its
    own: a parenthesis the author wrote is a token, and one they did not
    write was not needed by the grammar that produced the tokens."""
    if ver not in (3, 4):
        return None
    st, i, n = [], 0, len(tok)
    try:
        while i < n:
            t = tok[i]
            if t >= 0x20:
                t = (t & 0x1F) | 0x20           # R, V and A classes alike
            if t in _RPN_BIN:
                b, a = st.pop(), st.pop()
                st.append(a + _RPN_BIN[t] + b); i += 1
            elif t == 0x12:                     # unary plus: the identity
                i += 1
            elif t == 0x13:
                st.append('-' + st.pop()); i += 1
            elif t == 0x15:
                st.append('(' + st.pop() + ')'); i += 1
            elif t == 0x17:
                ln = tok[i + 1]
                txt = tok[i + 2:i + 2 + ln].decode('latin-1')
                st.append('"' + txt.replace('"', '""') + '"'); i += 2 + ln
            elif t == 0x19:
                flags = tok[i + 1]
                if flags & 0x04:                # CHOOSE's jump table: two
                    return None                 # sources disagree on its length
                if flags & 0x10:                # SUM with one argument
                    st.append('SUM(' + st.pop() + ')')
                i += 4
            elif t == 0x1C:
                st.append(BIFF_ERRORS[tok[i + 1]]); i += 2
            elif t == 0x1D:
                st.append('TRUE()' if tok[i + 1] else 'FALSE()'); i += 2
            elif t == 0x1E:
                st.append('%d' % struct.unpack_from('<H', tok, i + 1)[0]); i += 3
            elif t == 0x1F:
                st.append('%.15g' % struct.unpack_from('<d', tok, i + 1)[0])
                i += 9
            elif t in (0x21, 0x22):
                if t == 0x22:
                    argc = tok[i + 1] & 0x7F
                    j = i + 2
                else:
                    j = i + 1
                idx = tok[j] if ver == 3 else struct.unpack_from('<H', tok, j)[0]
                if idx & 0x8000:
                    return None                 # a macro command
                ent = BIFF_FUNCS.get(idx)
                if ent is None:
                    return None
                name = ent[0]
                if known is not None and name not in known:
                    return None
                if t == 0x21:
                    mm = ent[1] if ver == 3 else ent[2]
                    if mm is None:
                        return None
                    argc = mm[0]
                i = j + (1 if ver == 3 else 2)
                args = st[len(st) - argc:] if argc else []
                del st[len(st) - argc:]
                st.append(name + '(' + ','.join(args) + ')')
            elif t == 0x24:
                roww, col = struct.unpack_from('<HB', tok, i + 1)
                st.append(_cellref(roww, col)); i += 4
            elif t == 0x25:
                r1, r2, c1, c2 = struct.unpack_from('<HHBB', tok, i + 1)
                st.append(_cellref(r1, c1) + ':' + _cellref(r2, c2)); i += 7
            else:
                return None
    except (IndexError, KeyError, struct.error):
        return None
    return st[0] if len(st) == 1 else None


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
        # A quote INSIDE the value is doubled - the rule SHEET's writer and
        # reader both keep (sh_dowrite_sylk .kdup, sh_parsecrec .ktkeep), the
        # same one ';' already had. This read it raw, and so answered 'a""bc'
        # for a cell holding a"bc.
        body = s[1:-1].replace('""', '"')
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
        # doubled, for the reader's reason above: SHEET ends the field at a
        # SINGLE quote, so an undoubled one would cut the value short
        return '"%s"' % v.replace('"', '""').replace(';', ';;')
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
def _biff_walk(data):
    """[(name, {(row, col): value})] - one entry per sheet, in file order.

    A single-sheet BIFF2/3 stream is one unnamed entry, which is what makes
    this the only walk: the workbook is the general case and the plain stream
    is the workbook with the directory left out.
    """
    sheets, cells, names = [], {}, []
    i, n, vstart, depth, ver, pending = 0, len(data), None, 0, 3, None
    while i + 4 <= n:
        rid, ln = struct.unpack_from('<HH', data, i)
        i += 4
        if i + ln > n:
            raise FormatError('record 0x%04X at %d runs past the end'
                              % (rid, i))
        body = data[i:i + ln]
        i += ln
        if rid in (BIFF_BOF, BIFF_BOF | BIFF3_BIT, BIFF_BOF | BIFF4_BIT):
            # BIFF2's cell header is row(2) col(2) attributes(3); BIFF3 and
            # BIFF4 replace those three bytes with a 2-byte XF index.
            vstart = 7 if rid == BIFF_BOF else 6
            ver = 2 if rid == BIFF_BOF else (3 if rid & BIFF3_BIT else 4)
            depth += 1
            if depth > 1 or ln < 4 or struct.unpack_from('<H', body, 2)[0] != 0x0100:
                cells = {}              # a SHEET substream, or a plain stream
            continue
        if rid == BIFF_EOF:
            if vstart is not None and depth:
                depth -= 1
                if cells or len(sheets) < len(names):
                    sheets.append((names[len(sheets)] if len(sheets) < len(names)
                                   else None, cells))
                    cells = {}
            continue
        if rid == BIFF_SHEETHDR and ln >= 5:
            # <substream length:4><name length:1><name>.  Taken from the
            # writer that produces it rather than from the table: 11 bytes is
            # 4 + 1 + "SheetN", and reading the count one byte late turns
            # every name into "heetN" without failing anything.
            ln_name = body[4]
            names.append(body[5:5 + ln_name].decode('latin-1'))
            continue
        if vstart is None:
            continue
        kind = rid & ~(BIFF3_BIT | BIFF4_BIT)
        if kind == BIFF_STRING:
            if pending is not None and pending in cells:
                ln_s = body[0] if ver == 2 else struct.unpack_from('<H', body, 0)[0]
                at = 1 if ver == 2 else 2
                f = cells[pending]
                cells[pending] = (f[0], f[1], body[at:at + ln_s].decode('latin-1'))
            pending = None
            continue
        pending = None
        if kind in (BIFF_BLANK, BIFF_INTEGER, BIFF_NUMBER, BIFF_LABEL,
                    BIFF_BOOLERR, BIFF_FORMULA, BIFF_RK):
            if ln < vstart:
                raise FormatError('cell record 0x%04X is %d bytes' % (rid, ln))
            r, c = struct.unpack_from('<HH', body, 0)
            v = _biff_value(kind, body, vstart, ver)
            if v is not None:
                if isinstance(v, tuple) and len(v) == 3 and v[2] is _PENDING:
                    v = (v[0], v[1], '')    # until its STRING record says
                    pending = (r, c)
                cells[(r, c)] = v
    if vstart is None:
        raise FormatError('no BOF record - this is not a BIFF stream')
    if cells or not sheets:
        sheets.append((names[len(sheets)] if len(sheets) < len(names) else None,
                       cells))
    return sheets


def read_biff_book(data):
    """Every sheet, as [(name, cells)].  A single-sheet stream is one entry."""
    return _biff_walk(data)


def read_biff(data):
    """The FIRST sheet's cells, which for a single-sheet stream is all of them.

    Kept flat because every caller predates the workbook and asks about one
    grid; read_biff_book is the one that can see the rest.
    """
    return _biff_walk(data)[0][1]


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


def _biff_value(rid, body, v, ver=3):
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
        # BIFF3/4: result(8) flags(2) cce(2) then the tokens (4.7, 5.50) - the
        # expression the value came from, which this reader used to skip
        # exactly as SHEET's did.
        expr = None
        if ver in (3, 4) and len(body) >= v + 12:
            cce = struct.unpack_from('<H', body, v + 10)[0]
            expr = decode_rpn(body[v + 12:v + 12 + cce], ver)
        if len(raw) == 8 and raw[6] == 0xFF and raw[7] == 0xFF:
            kind = raw[0]
            if kind == 1:
                return ('formula', expr, ('bool', raw[2] != 0))
            if kind == 2:
                return ('formula', expr, ('err', BIFF_ERRORS.get(raw[2],
                                                                 '#ERR')))
            if kind == 3:
                return ('formula', expr, '')
            if kind == 0:
                return ('formula', expr, _PENDING)
        return ('formula', expr, struct.unpack_from('<d', raw, 0)[0])
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
# dBASE III .DBF.  Header 32 bytes, then one 32-byte descriptor per field, a
# 0Dh terminator, then fixed-width records each opening with a deletion flag.
# From the published layout, not from sheet.asm.
# -----------------------------------------------------------------------------
def read_dbf(data):
    if data[0] != 0x03:
        raise FormatError('version byte %02Xh is not dBASE III' % data[0])
    nrec, hdrlen, reclen = struct.unpack_from('<IHH', data, 4)
    nf = (hdrlen - 33) // 32
    fields = []
    for f in range(nf):
        d = data[32 + f * 32: 64 + f * 32]
        name = d[:11].split(b'\x00')[0].rstrip(b' ').decode('latin-1')
        fields.append((name, chr(d[11]), d[16]))
    cells = {}
    for f, (name, _t, _w) in enumerate(fields):
        cells[(0, f)] = name             # the field names are row 0
    row = 1
    for r in range(nrec):
        base = hdrlen + r * reclen
        if base + reclen > len(data):
            break
        if data[base:base + 1] == b'*':  # deleted
            continue
        off = base + 1
        for f, (_n, t, w) in enumerate(fields):
            raw = data[off:off + w].decode('latin-1').strip()
            off += w
            if raw == '':
                continue
            if t in 'NF':
                try:
                    cells[(row, f)] = float(raw)
                except ValueError:
                    cells[(row, f)] = raw
            else:
                cells[(row, f)] = raw
        row += 1
    return cells


# -----------------------------------------------------------------------------
def sniff(path, data):
    if data[:1] == b'\x03' and len(data) > 32:
        return 'dbf'
    if data[:2] in (b'\x09\x00', b'\x09\x02', b'\x09\x04'):
        return 'biff'
    head = data[:512].decode('latin-1', 'replace')
    if head.startswith('TABLE'):
        return 'dif'
    if head.startswith('ID;'):
        return 'sylk'
    low = path.lower()
    for ext, kind in (('.bif', 'biff'), ('.xls', 'biff'), ('.dif', 'dif'),
                      ('.slk', 'sylk'), ('.csv', 'csv'), ('.txt', 'txt'),
                      ('.dbf', 'dbf')):
        if low.endswith(ext):
            return kind
    raise FormatError('cannot tell what %s is' % path)


def read(path, data=None, kind=None):
    if data is None:
        data = open(path, 'rb').read()
    kind = kind or sniff(path, data)
    return {'sylk': read_sylk, 'dif': read_dif, 'biff': read_biff,
            'csv': read_csv, 'txt': read_txt, 'dbf': read_dbf}[kind](data)


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


def _sheet_tables(path='apps/sheet/sheet.asm'):
    """SHEET's function tables, read out of its source: [(name, fid, fvar,
    fargc)] in sh_functab's order. fargc is None until the decoder's own
    table exists in the source."""
    import re
    src = open(path).read()
    names = dict(re.findall(r"^(sh_f_[a-z0-9]+):\s+db\s+'([A-Z0-9.]+)'", src,
                            re.M))
    ft = re.search(r'^sh_functab:\n(.*?)\n\s+dw 0\n', src, re.M | re.S)
    order = [names[x] for x in re.findall(r'(sh_f_[a-z0-9]+)', ft.group(1))]

    def table(label):
        m = re.search(r'^' + label + r':\n(.*?)^' + label + r'_end:', src,
                      re.M | re.S)
        if m is None:
            return None
        return [int(x, 0) for line in m.group(1).split('\n')
                for x in re.findall(r'0x[0-9A-Fa-f]+|\b\d+\b',
                                    line.split(';')[0].replace('db', ''))]
    fid, fvar, fargc = (table('sh_rpn_fid'), table('sh_rpn_fvar'),
                        table('sh_rpn_fargc'))
    return [(nm, fid[i], fvar[i], fargc[i] if fargc else None)
            for i, nm in enumerate(order)]


# SHEET writes one table for BIFF3 and BIFF4 both, so a function whose arity
# changed between them cannot be right for both. The only one it has: FIXED is
# 2/2 in BIFF3 and 2-3 from BIFF4, and SHEET writes it as tFuncVar - right for
# a workbook, and a variable-count token for a fixed function in a BIFF3 file.
_FVAR_KNOWN = {'FIXED'}


def _check_functab(bad):
    rows = _sheet_tables()
    for nm, fid, fvar, fargc in rows:
        if fid == 0xFF:
            continue
        ent = BIFF_FUNCS.get(fid)
        if ent is None or ent[0] != nm:
            bad.append('sh_rpn_fid: %s is written as index %d, which is %s'
                       % (nm, fid, ent[0] if ent else 'no function'))
            continue
        mn, mx = ent[2]
        if bool(fvar) != (mn != mx) and nm not in _FVAR_KNOWN:
            bad.append('sh_rpn_fvar: %s is %s, but it takes %d-%d arguments'
                       % (nm, 'variable' if fvar else 'fixed', mn, mx))
        fixed = [mm for mm in (ent[1], ent[2]) if mm and mm[0] == mm[1]]
        if fargc is not None and fixed and fargc != fixed[0][0]:
            bad.append('sh_rpn_fargc: %s says %d arguments, the table %d'
                       % (nm, fargc, fixed[0][0]))
    return len(rows)


def _check_rpn(bad, book):
    """decode_rpn against tokens SHEET really wrote (KODAK.BIF, a BIFF4
    workbook made in the emulator) and against hand-built arrays for every
    token that file does not carry - including the ones that must say None."""
    sheet1 = book[0][1] if book else {}
    for (r, c), want in (((1, 4), 'ROUND(D2/B2*100,1)'), ((4, 1), 'SUM(B2:B4)'),
                         ((1, 3), 'C2-B2')):
        got = sheet1.get((r, c))
        if not (isinstance(got, tuple) and got[1] == want):
            bad.append('KODAK.BIF %s%d decodes to %r, wanted %r'
                       % (colname(c), r + 1, got and got[1], want))
    ref = lambda roww, col: bytes([0x44]) + struct.pack('<HB', roww, col)
    num = lambda x: bytes([0x1F]) + struct.pack('<d', x)
    cases = [
        (3, ref(0x0000, 0) + ref(0xC001, 1) + b'\x05', '$A$1*B2'),
        (3, ref(0xC000, 0) + b'\x13' + b'\x15' + num(0.01) + b'\x03',
         '(-A1)+0.01'),
        (3, b'\x17\x03a"b' + b'\x1d\x01' + b'\x08', '"a""b"&TRUE()'),
        (3, b'\x1c\x07' + b'\x1e\x05\x00' + b'\x0b', '#DIV/0!=5'),
        (3, b'\x19\x01\x00\x00' + bytes([0x45]) + struct.pack('<HHBB', 0xC000,
         0xC009, 0, 0) + b'\x19\x10\x00\x00', 'SUM(A1:A10)'),
        (3, ref(0xC000, 0) + b'\x41\x18', 'ABS(A1)'),              # 1-byte
        (4, ref(0xC000, 0) + b'\x41\x18\x00', 'ABS(A1)'),          # 2-byte
        (4, b'\x1e\x01\x00\x1e\x02\x00\x42\x02\x04\x00', 'SUM(1,2)'),
        (3, b'\x1e\x05\x00\x14', None),      # tPercent: SHEET has no %
        (3, b'\x43\x01\x00' + bytes(8), None),  # tName
        (3, b'\x19\x04\x01\x00\x02\x00', None),  # tAttrChoose
        (3, ref(0xC000, 0) + b'\x41\xff', None),   # no function 255
    ]
    for ver, tok, want in cases:
        got = decode_rpn(tok, ver)
        if got != want:
            bad.append('decode_rpn(BIFF%d %s) = %r, wanted %r'
                       % (ver, tok.hex(), got, want))
    if decode_rpn(ref(0xC000, 0) + b'\x41\x18', 3, known={'SUM'}) is not None:
        bad.append('decode_rpn decoded a function outside `known`')


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
    # --- the BIFF4 WORKBOOK, against a file this app actually wrote ---------
    # apps/sheet/KODAK.BIF is three sheets in one stream, made in the emulator
    # by hand (docs/KODAK-EXAMPLE.md).  It is here because the round trip above
    # cannot reach the workbook at all: write_sylk has no notion of a second
    # sheet, so until this reader learned BIFF4 the multi-sheet path had NO
    # host-side check of any kind - which is exactly how a writer bug that put
    # every sheet's borders on the active sheet survived (SPEC.md 81.47.6).
    book_file = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             '..', 'apps', 'sheet', 'KODAK.BIF')
    if os.path.exists(book_file):
        try:
            book = read_biff_book(open(book_file, 'rb').read())
        except FormatError as e:
            # A reader that cannot open it must SAY so.  This raised an
            # uncaught FormatError first, which is a traceback where a gate
            # owes a sentence.
            book, got = [], 'unreadable: %s' % e
        else:
            got = [(n, len(c)) for n, c in book]
        if got != [('Sheet1', 25), ('Sheet2', 6), ('Sheet3', 6)]:
            bad.append('KODAK.BIF reads as %s' % (got,))
        else:
            # Sheet 3 is the one that cannot be RK: 1.42 does not fit, so it
            # goes out as an IEEE-754 NUMBER and comes back verbatim or not
            # at all.  Both record kinds in one file is the point of it.
            want = [1.42, 1.86, 2.15]
            third = [book[2][1].get((r, 1)) for r in range(3)]
            if third != want:
                bad.append('KODAK.BIF sheet 3 reads %r, wanted %r'
                           % (third, want))
    _check_rpn(bad, book if not isinstance(book, list) or book else [])
    nfun = _check_functab(bad)
    if bad:
        for b in bad:
            print('os88sheetfmt: %s' % b)
        return 1
    print('os88sheetfmt: selfcheck ok (%d cells, ;; escape, KODAK.BIF as 3 '
          'sheets and its formulas decoded, %d SHEET functions against 3.11)'
          % (len(cells), nfun))
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

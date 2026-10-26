"""Text-editing engine for PDF Text Editor.

Runs as a long-lived process: reads one JSON request per line on stdin and
writes one JSON response per line on stdout.

Requests:
  {"cmd": "lines", "path": str, "page": int}
  {"cmd": "edit", "path": str, "out": str, "page": int, "line": str, "text": str,
   "expect": str (original text, guards against stale ids)}

Editing removes only the text glyphs of a line (vector graphics such as boxes,
borders, table rules and shaded cells are left untouched), then writes the new
text at the same baseline, size and colour, fitted to the box the line sits in.

Fonts are preserved in this order:
  1. "original" - the PDF's own font resource is reused, writing glyph codes
     directly, so the text is drawn with exactly the same embedded font.
     Works whenever every new character exists in the (often subset) font.
  2. "system"   - the same font family installed on this Mac is embedded.
  3. "substitute" - the closest standard PDF font (reported to the user).
"""

import difflib
import io
import json
import logging
import math
import os
import re
import sys

import pymupdf
from fontTools import agl
from fontTools.cffLib import CFFFontSet
from fontTools.ttLib import TTFont

pymupdf.TOOLS.mupdf_display_errors(False)
logging.getLogger("fontTools").setLevel(logging.ERROR)

# Lines are addressed as "block:line" using the order from get_text("dict").
TEXT_FLAGS = pymupdf.TEXT_PRESERVE_WHITESPACE | pymupdf.TEXT_MEDIABOX_CLIP

FONT_DIRS = [
    "/System/Library/Fonts",
    "/System/Library/Fonts/Supplemental",
    "/Library/Fonts",
    os.path.expanduser("~/Library/Fonts"),
]
CACHE_DIR = os.path.expanduser("~/Library/Application Support/PDFTextEditor")
FONT_INDEX_PATH = os.path.join(CACHE_DIR, "font-index.json")

SPACES = (" ", "\u00a0")

# A gap wider than this many ems between words starts a new column.
COLUMN_GAP = 0.8

MONO_HINTS = ("mono", "courier", "consol", "menlo", "code")
SANS_HINTS = ("sans", "arial", "helvetica", "avenir", "calibri", "verdana", "segoe",
              "futura", "gill", "tahoma", "roboto", "inter", "lato", "gothic", "grotesk")
SERIF_HINTS = ("serif", "times", "georgia", "garamond", "roman", "cambria", "palatino",
               "baskerville", "didot", "minion", "book", "caslon", "bodoni")

_font_index = None


# ---------------------------------------------------------------- extraction

def page_lines(page):
    """Return editable lines of a page, keyed "block:line", with char positions."""
    data = page.get_text("rawdict", flags=TEXT_FLAGS)
    lines = []
    for bi, block in enumerate(data["blocks"]):
        if block.get("type") != 0:
            continue
        for li, line in enumerate(block["lines"]):
            spans, chars = [], []
            for raw in line["spans"]:
                text = "".join(ch["c"] for ch in raw["chars"])
                if not text:
                    continue
                span = {k: v for k, v in raw.items() if k != "chars"}
                span["text"] = text
                spans.append(span)
                chars += [{"c": ch["c"], "bbox": ch["bbox"], "origin": ch["origin"], "span": span}
                          for ch in raw["chars"]]
            text = "".join(ch["c"] for ch in chars)
            if not text.strip():
                continue
            lines.append({
                "id": f"{bi}:{li}",
                "bbox": line["bbox"],
                "dir": line["dir"],
                "wmode": line["wmode"],
                "spans": spans,
                "chars": chars,
                "text": text,
            })
    return lines


def pdf_matrix(page):
    """Maps MuPDF page coordinates to PDF user space (what PDFKit uses).

    Text extraction reports unrotated coordinates, so /Rotate plays no part.
    """
    return ~page.transformation_matrix


def to_pdf_space(page, rect):
    r = pymupdf.Rect(rect) * pdf_matrix(page)
    r.normalize()
    return [r.x0, r.y0, r.x1, r.y1]


def describe(page, line):
    span = main_span(line)
    return {
        "id": line["id"],
        "text": norm_text(line["text"]),
        "rect": to_pdf_space(page, line["bbox"]),
        "textRect": to_pdf_space(page, ink_rect(line)),
        "font": clean_font_name(span["font"]),
        "size": round(span["size"], 2),
        "color": "#%06x" % span["color"],
        "editable": line["wmode"] == 0,
    }


def ink_rect(line):
    """Bounds of the line's visible characters, without layout spaces."""
    rect = pymupdf.Rect()
    for ch in line["chars"]:
        if ch["c"].strip():
            rect |= pymupdf.Rect(ch["bbox"])
    return rect if not rect.is_empty else pymupdf.Rect(line["bbox"])


def main_span(line):
    """The span covering the most characters decides the line's style."""
    return max(line["spans"], key=lambda s: len(s["text"].strip()))


def clean_font_name(name):
    return re.sub(r"^[A-Z]{6}\+", "", name)


def norm_text(t):
    return t.replace("\u00a0", " ")


# ---------------------------------------------------------------- original font

class OriginalFont:
    """An existing font resource of the PDF, written to with raw glyph codes."""

    def __init__(self, doc, xref):
        self.doc, self.xref = doc, xref
        subtype = self._name(xref, "Subtype")
        if subtype not in ("Type0", "TrueType", "Type1", "MMType1"):
            raise ValueError(f"unsupported font type {subtype}")
        self.cid = subtype == "Type0"
        if self.cid and self._name(xref, "Encoding") not in ("Identity-H",):
            raise ValueError("unsupported CID encoding")
        self.codes = {}  # character -> code
        tu = doc.xref_get_key(xref, "ToUnicode")
        if tu[0] == "xref":
            for code, uni in parse_tounicode(doc.xref_stream(ref_xref(tu[1]))):
                if len(uni) == 1:
                    self.codes.setdefault(uni, code)
        self.widths, self.default_width = self._widths()
        if not self.cid and not self.codes:
            self._simple_codes()
        self.glyphs = GlyphCheck(doc, xref, self.cid, self._cid_to_gid())

    def _cid_to_gid(self):
        if not self.cid:
            return None
        desc = self.doc.xref_get_key(self.xref, "DescendantFonts")
        dx = ref_xref(re.search(r"\d+ 0 R", desc[1]).group(0))
        kind, val = self.doc.xref_get_key(dx, "CIDToGIDMap")
        if kind != "xref":
            return None  # Identity
        data = self.doc.xref_stream(ref_xref(val))
        return {i // 2: (data[i] << 8) | data[i + 1] for i in range(0, len(data) - 1, 2)}

    def _name(self, xref, key):
        kind, val = self.doc.xref_get_key(xref, key)
        return val.lstrip("/") if kind == "name" else None

    def _array(self, xref, key):
        kind, val = self.doc.xref_get_key(xref, key)
        if kind == "xref":
            val = self.doc.xref_object(ref_xref(val))
        elif kind != "array":
            return []
        return parse_array(val)

    def _number(self, xref, key, default=0.0):
        kind, val = self.doc.xref_get_key(xref, key)
        if kind == "xref":
            val = self.doc.xref_object(ref_xref(val)).strip()
        try:
            return float(val)
        except (TypeError, ValueError):
            return default

    def _widths(self):
        widths = {}
        if self.cid:
            desc = self.doc.xref_get_key(self.xref, "DescendantFonts")
            dx = ref_xref(re.search(r"\d+ 0 R", desc[1]).group(0))
            w = self._array(dx, "W")
            i = 0
            while i < len(w):
                first = int(w[i])
                if isinstance(w[i + 1], list):
                    for k, val in enumerate(w[i + 1]):
                        widths[first + k] = float(val)
                    i += 2
                else:
                    for c in range(first, int(w[i + 1]) + 1):
                        widths[c] = float(w[i + 2])
                    i += 3
            return widths, self._number(dx, "DW", 1000.0)
        first = int(self._number(self.xref, "FirstChar", 0))
        for k, val in enumerate(self._array(self.xref, "Widths")):
            widths[first + k] = float(val)
        missing = 0.0
        fd = self.doc.xref_get_key(self.xref, "FontDescriptor")
        if fd[0] == "xref":
            missing = self._number(ref_xref(fd[1]), "MissingWidth", 0.0)
        return widths, missing

    def _simple_codes(self):
        """Simple font without ToUnicode: map through its declared encoding."""
        kind, enc = self.doc.xref_get_key(self.xref, "Encoding")
        base, diffs = "WinAnsiEncoding", ""
        if kind == "name":
            base = enc.lstrip("/")
        elif kind in ("dict", "xref"):
            obj = enc if kind == "dict" else self.doc.xref_object(ref_xref(enc))
            m = re.search(r"/BaseEncoding\s*/(\w+)", obj)
            base = m.group(1) if m else base
            m = re.search(r"/Differences\s*\[(.*?)\]", obj, re.S)
            diffs = m.group(1) if m else ""
        codec = {"MacRomanEncoding": "mac_roman"}.get(base, "cp1252")
        for code in range(32, 256):
            try:
                self.codes.setdefault(bytes([code]).decode(codec), code)
            except UnicodeDecodeError:
                continue
        code = 0
        for tok in re.findall(r"/[^\s/\[\]]+|\d+", diffs):
            if tok[0] != "/":
                code = int(tok)
                continue
            ch = agl.toUnicode(tok[1:])
            if len(ch) == 1:
                for k in [k for k, v in self.codes.items() if v == code]:
                    del self.codes[k]
                self.codes[ch] = code
            code += 1

    def covers(self, text):
        """True only if every character has a real glyph in the embedded font.

        Subsetting keeps ToUnicode entries for glyphs it removed, so a mapping
        alone does not prove the glyph is still there.
        """
        for c in text:
            if c in SPACES:
                continue  # blank glyphs have no outline; width alone matters
            code = self.codes.get(c)
            if code is None or not self.glyphs.present(code, c):
                return False
        return True

    def space_code(self):
        for s in SPACES:
            if s in self.codes:
                return self.codes[s]
        return None

    def width(self, code):
        return self.widths.get(code, self.default_width)

    def text_length(self, text, size):
        space = self.space_code()
        total = 0.0
        for c in text:
            if c in SPACES and space is None:
                total += 278
            else:
                total += self.width(self.codes[c] if c not in SPACES else space)
        return total * size / 1000

    def tj_array(self, text):
        """TJ operand; spaces missing from the subset become positioning gaps."""
        nbytes = 2 if self.cid else 1
        space = self.space_code()
        parts, run = [], ""
        for c in text:
            if c in SPACES and space is None:
                if run:
                    parts.append(f"<{run}>")
                    run = ""
                parts.append("-278")
                continue
            code = space if c in SPACES else self.codes[c]
            run += f"{code:0{nbytes * 2}x}"
        if run:
            parts.append(f"<{run}>")
        return "[" + " ".join(parts) + "]"


class GlyphCheck:
    """Answers whether the embedded font program still contains a glyph."""

    def __init__(self, doc, xref, cid, cid_to_gid):
        self.cid, self.cid_to_gid = cid, cid_to_gid
        self.tt = self.cff = None
        fx = xref
        if cid:
            desc = doc.xref_get_key(xref, "DescendantFonts")
            fx = ref_xref(re.search(r"\d+ 0 R", desc[1]).group(0))
        fd = doc.xref_get_key(fx, "FontDescriptor")
        self.embedded = fd[0] == "xref" and any(
            doc.xref_get_key(ref_xref(fd[1]), k)[0] == "xref"
            for k in ("FontFile", "FontFile2", "FontFile3"))
        if not self.embedded:
            return  # a standard font the viewer supplies in full
        _, ext, _, buf = doc.extract_font(xref)
        if ext in ("ttf", "otf"):
            self.tt = TTFont(io.BytesIO(buf), lazy=True)
            if "CFF " in self.tt:
                self.cff = self.tt["CFF "].cff
        elif ext == "cff":
            self.cff = CFFFontSet()
            self.cff.decompile(io.BytesIO(buf), None)
        else:
            raise ValueError(f"cannot inspect {ext} font")

    def present(self, code, char):
        if not self.embedded:
            return True
        if self.cff is not None:
            top = self.cff[self.cff.fontNames[0]]
            names = top.CharStrings
            if self.cid and hasattr(top, "ROS"):
                return f"cid{code:05d}" in names
            if self.cid:
                order = top.charset
                return code < len(order)
            return agl.UV2AGL.get(ord(char), f"uni{ord(char):04X}") in names
        order = self.tt.getGlyphOrder()
        if self.cid:
            gid = self.cid_to_gid.get(code, 0) if self.cid_to_gid else code
        else:
            name = self._simple_glyph(code, char)
            return name is not None and self._has_outline(name)
        if gid <= 0 or gid >= len(order):
            return False
        return self._has_outline(order[gid])

    def _simple_glyph(self, code, char):
        """Glyph name for a simple TrueType font, following PDF's cmap rules."""
        if "cmap" not in self.tt:
            return None
        cmap = self.tt["cmap"]
        uni = cmap.getcmap(3, 1)
        if uni is not None and ord(char) in uni.cmap:
            return uni.cmap[ord(char)]
        sym = cmap.getcmap(3, 0)
        if sym is not None:
            return sym.cmap.get(0xF000 + code) or sym.cmap.get(code)
        mac = cmap.getcmap(1, 0)
        return mac.cmap.get(code) if mac is not None else None

    def _has_outline(self, name):
        if "glyf" in self.tt:
            g = self.tt["glyf"][name]
            return g.numberOfContours != 0
        return True


def ref_xref(ref):
    return int(ref.split()[0])


def parse_array(src):
    """Parse a PDF array of numbers / nested arrays into Python lists."""
    tokens = re.findall(r"\[|\]|-?\d*\.?\d+", src)
    stack = [[]]
    for t in tokens:
        if t == "[":
            stack.append([])
        elif t == "]":
            done = stack.pop()
            stack[-1].append(done)
        else:
            stack[-1].append(float(t))
    out = stack[0]
    return out[0] if len(out) == 1 and isinstance(out[0], list) else out


def parse_tounicode(data):
    """Yield (code, unicode string) pairs from a ToUnicode CMap stream."""
    text = data.decode("latin-1")

    def uni(h):
        return bytes.fromhex(h).decode("utf-16-be", errors="ignore")

    for block in re.findall(r"beginbfchar(.*?)endbfchar", text, re.S):
        for src, dst in re.findall(r"<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]*)>", block):
            yield int(src, 16), uni(dst)
    for block in re.findall(r"beginbfrange(.*?)endbfrange", text, re.S):
        for lo, hi, rest in re.findall(
                r"<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>\s*(<[0-9a-fA-F]*>|\[[^\]]*\])", block):
            lo, hi = int(lo, 16), int(hi, 16)
            if rest.startswith("["):
                for k, h in enumerate(re.findall(r"<([0-9a-fA-F]*)>", rest)):
                    yield lo + k, uni(h)
            else:
                base = int(rest[1:-1] or "0", 16)
                width = len(rest) - 2
                for k in range(hi - lo + 1):
                    yield lo + k, uni(f"{base + k:0{width}x}")


def original_font(doc, page, span):
    xref = font_xref(page, span["font"])
    if not xref:
        return None
    try:
        return OriginalFont(doc, xref)
    except Exception:
        return None


def font_xref(page, fontname):
    for f in page.get_fonts(full=True):
        if f[3] == fontname or clean_font_name(f[3]) == clean_font_name(fontname):
            return f[0]
    return 0


# ---------------------------------------------------------------- other fonts

def font_index():
    """Normalised font name -> font file, for fonts installed on this Mac."""
    global _font_index
    if _font_index is not None:
        return _font_index
    try:
        with open(FONT_INDEX_PATH) as f:
            _font_index = json.load(f)
            return _font_index
    except (OSError, ValueError):
        pass
    index = {}
    for d in FONT_DIRS:
        if not os.path.isdir(d):
            continue
        for fn in os.listdir(d):
            if not fn.lower().endswith((".ttf", ".otf")):
                continue
            path = os.path.join(d, fn)
            try:
                f = pymupdf.Font(fontfile=path)
            except Exception:
                continue
            index.setdefault(normalize_font_key(f.name), path)
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(FONT_INDEX_PATH, "w") as f:
        json.dump(index, f)
    _font_index = index
    return index


def normalize_font_key(name):
    name = clean_font_name(name).split(",")[0]
    name = re.sub(r"(MT|PS|PSMT)$", "", name)
    name = re.sub(r"[^a-z0-9]", "", name.lower())
    return re.sub(r"(regular|roman|book)$", "", name)


def base14_for(span):
    """Closest built-in font, used when nothing better covers the new text."""
    flags, name = span["flags"], span["font"].lower()
    bold = bool(flags & 16) or any(w in name for w in ("bold", "black", "heavy"))
    italic = bool(flags & 2) or "italic" in name or "oblique" in name
    # Judge by name first: the serif flag in PDFs is frequently wrong.
    if flags & 8 or any(w in name for w in MONO_HINTS):
        family = "co"
    elif any(w in name for w in SANS_HINTS):
        family = "he"
    elif any(w in name for w in SERIF_HINTS):
        family = "ti"
    else:
        family = "ti" if flags & 4 else "he"
    if family == "ti":
        return {(0, 0): "tiro", (1, 0): "tibo", (0, 1): "tiit", (1, 1): "tibi"}[bold, italic]
    suffix = {(0, 0): "", (1, 0): "bo", (0, 1): "it", (1, 1): "bi"}[bold, italic]
    return {"he": "helv", "co": "cour"}[family] if not suffix else family + suffix


def font_covers(font, text):
    return all(font.has_glyph(ord(c)) for c in text if c not in SPACES)


def installed_font(span, text):
    path = font_index().get(normalize_font_key(span["font"]))
    if not path:
        return None
    try:
        f = pymupdf.Font(fontfile=path)
    except Exception:
        return None
    return (f, path) if font_covers(f, text) else None


# ---------------------------------------------------------------- boxes

def enclosing_box(page, bbox):
    """Smallest drawn rectangle (or ruled table cell) that contains the line."""
    line = pymupdf.Rect(bbox)
    drawings = page.get_drawings()
    best = None
    for d in drawings:
        for item in d["items"]:
            if item[0] == "re":
                r = pymupdf.Rect(item[1])
            elif item[0] == "qu":
                r = item[1].rect
            else:
                continue
            if r.width < 2 or r.height < 2:
                continue
            if r.contains(line):
                if best is None or r.get_area() < best.get_area():
                    best = r
    cell = table_cell(drawings, line)
    if cell is not None and (best is None or cell.get_area() < best.get_area()):
        best = cell
    return best


def table_cell(drawings, line):
    """Cell bounded by ruled lines (tables drawn with separate strokes)."""
    h, v = [], []
    for d in drawings:
        for item in d["items"]:
            if item[0] == "l":
                segments = [(item[1], item[2])]
            elif item[0] == "re":  # rectangle edges count as rules too
                r = pymupdf.Rect(item[1])
                segments = [(r.tl, r.tr), (r.bl, r.br), (r.tl, r.bl), (r.tr, r.br)]
            else:
                continue
            for p1, p2 in segments:
                add_rule(h, v, p1, p2)
    cy, cx = (line.y0 + line.y1) / 2, (line.x0 + line.x1) / 2
    above = [y for y, a, b in h if y <= line.y0 + 1 and a <= cx <= b]
    below = [y for y, a, b in h if y >= line.y1 - 1 and a <= cx <= b]
    left = [x for x, a, b in v if x <= line.x0 + 1 and a <= cy <= b]
    right = [x for x, a, b in v if x >= line.x1 - 1 and a <= cy <= b]
    if above and below and left and right:
        return pymupdf.Rect(max(left), max(above), min(right), min(below))
    return None


def add_rule(h, v, p1, p2):
    if abs(p1.y - p2.y) < 0.5 and abs(p1.x - p2.x) >= 2:
        h.append((p1.y, min(p1.x, p2.x), max(p1.x, p2.x)))
    elif abs(p1.x - p2.x) < 0.5 and abs(p1.y - p2.y) >= 2:
        v.append((p1.x, min(p1.y, p2.y), max(p1.y, p2.y)))


def alignment(pad_l, pad_r, box_width):
    if abs(pad_l - pad_r) <= max(2.0, box_width * 0.04):
        return "center"
    if pad_r < pad_l * 0.5:
        return "right"
    return "left"


# ---------------------------------------------------------------- editing

def find_line(page, line_id, expect=None):
    """Find a line by id; if its text no longer matches, fall back to the text."""
    lines = page_lines(page)
    want = norm_text(expect).strip() if expect is not None else None
    for line in lines:
        if line["id"] == line_id and (want is None or norm_text(line["text"]).strip() == want):
            return line
    if want is not None:
        for line in lines:
            if norm_text(line["text"]).strip() == want:
                return line
    raise ValueError("that line has changed since it was selected; please click it again")


def line_columns(line):
    """Split a line into columns: runs of words separated by a wide gap.

    Statements and tables often draw a whole row as one line of text, using
    runs of spaces or explicit positioning to place each column. Treating the
    columns separately lets an edit leave the other columns exactly in place.
    """
    cols, cur, prev = [], None, None
    for i, ch in enumerate(line["chars"]):
        if not ch["c"].strip():
            continue
        r = pymupdf.Rect(ch["bbox"])
        if cur is not None and r.x0 - prev.x1 <= COLUMN_GAP * ch["span"]["size"]:
            cur["end"] = i + 1
            cur["rect"] |= r
        else:
            cur = {"start": i, "end": i + 1, "rect": pymupdf.Rect(r),
                   "origin": pymupdf.Point(ch["origin"]), "span": ch["span"]}
            cols.append(cur)
        prev = r
    for c in cols:
        c["text"] = norm_text(line["text"][c["start"]:c["end"]])
    return cols


def plan_edits(line, cols, new_text):
    """Work out which columns the edit changed and their new text.

    Returns [(column, text)] or None when the change can't be tied to
    individual columns (for example text typed into the gap between two).
    """
    old, new = norm_text(line["text"]), norm_text(new_text)
    ops = difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes()
    touched = set()
    for tag, i1, i2, j1, j2 in ops:
        if tag == "equal":
            continue
        whitespace_only = not (old[i1:i2] + new[j1:j2]).strip()
        if whitespace_only:
            hit = [k for k, c in enumerate(cols) if c["start"] < i1 and i2 < c["end"]]
        else:
            hit = [k for k, c in enumerate(cols) if c["start"] <= i2 and i1 <= c["end"]]
            if len(hit) != 1:
                return None
        touched.update(hit)

    def mapped(x, start):
        found = []
        for tag, i1, i2, j1, j2 in ops:
            if i1 <= x <= i2:
                found.append(j1 + x - i1 if tag == "equal" else (j1 if start else j2))
        return min(found) if start else max(found)

    return [(cols[k], new[mapped(cols[k]["start"], True):mapped(cols[k]["end"], False)].strip())
            for k in sorted(touched)]


def column_alignment(col, others):
    """Alignment of a column judged from columns on other lines it lines up with."""
    r = col["rect"]
    votes = {"right": 0, "left": 0, "center": 0}
    for o in (c["rect"] for c in others):
        if abs(o.width - r.width) < 1 or o.x1 < r.x0 or o.x0 > r.x1:
            continue  # equal widths line up on every edge, so they prove nothing
        votes["right"] += abs(o.x1 - r.x1) < 1
        votes["left"] += abs(o.x0 - r.x0) < 1
        votes["center"] += abs((o.x0 + o.x1) / 2 - (r.x0 + r.x1) / 2) < 1
    ranked = sorted(votes.items(), key=lambda kv: -kv[1])
    if ranked[0][1] == 0 or ranked[0][1] == ranked[1][1]:
        return None
    return ranked[0][0]


def is_numeric(text):
    return bool(re.fullmatch(r"[-+(]?[$€£¥]?\s?[\d.,]+\s?(%|CR|DR|Cr|Dr|\))?-?", text.strip()))


def choose_font(doc, page, span, text):
    """Returns (source, font_used, measure, writer-info) for text in span's style."""
    orig = original_font(doc, page, span)
    if orig is not None and orig.covers(text):
        return {"source": "original", "used": clean_font_name(span["font"]), "orig": orig,
                "text": text, "measure": orig.text_length}
    found = installed_font(span, text)
    if found:
        font, fontfile, source = found[0], found[1], "system"
    else:
        font, fontfile, source = pymupdf.Font(base14_for(span)), None, "substitute"
    if font.has_glyph(0x20):
        text = norm_text(text)
    return {"source": source, "used": font.name, "font": font, "fontfile": fontfile,
            "text": text, "measure": lambda t, s: font.text_length(t, fontsize=s)}


def edit_line(path, out, pno, line_id, new_text, expect=None):
    doc = pymupdf.open(path)
    page = doc[pno]
    lines = page_lines(page)
    line = find_line(page, line_id, expect)
    if line["wmode"] != 0:
        raise ValueError("vertical text is not supported")

    cols = line_columns(line)
    edits = plan_edits(line, cols, new_text)
    if edits is None:
        # Rewrite the whole line as one piece, anchored where its text starts.
        whole = {"rect": pymupdf.Rect(cols[0]["rect"]), "origin": cols[0]["origin"],
                 "span": main_span(line), "text": norm_text(line["text"]).strip()}
        for c in cols[1:]:
            whole["rect"] |= c["rect"]
        cols, edits = [whole], [(whole, norm_text(new_text).strip())]

    others = [c for ln in lines if ln["id"] != line["id"] for c in line_columns(ln)]
    left_margin = min([ln["bbox"][0] for ln in lines] + [page.rect.x1])
    page_room = pymupdf.Rect(min(left_margin, page.rect.x0 + 18), 0,
                             page.rect.x1 - max(left_margin - page.rect.x0, 18), 0)

    # Plan every change before touching the page.
    jobs = []
    for col, text in edits:
        r, span = col["rect"], col["span"]
        k = cols.index(col)
        box = enclosing_box(page, r)
        if box is not None:
            pad = max(min(r.x0 - box.x0, box.x1 - r.x1), 1)
            outer = (box.x0 + pad, box.x1 - pad)
        else:
            outer = (page_room.x0, page_room.x1)
        gap = 0.3 * span["size"]
        x0 = max(outer[0], cols[k - 1]["rect"].x1 + gap if k > 0 else outer[0])
        x1 = min(outer[1], cols[k + 1]["rect"].x0 - gap if k + 1 < len(cols) else outer[1])
        x0, x1 = min(x0, r.x0), max(x1, r.x1)

        align = column_alignment(col, others)
        if align is None and box is not None and len(cols) == 1:
            align = alignment(r.x0 - box.x0, box.x1 - r.x1, box.width)
        if align is None:
            align = "right" if is_numeric(col["text"]) else "left"

        font = choose_font(doc, page, span, text) if text else None
        size = span["size"]
        if font:
            width = font["measure"](font["text"], size)
            room = {"left": x1 - r.x0, "right": r.x1 - x0,
                    "center": 2 * min((r.x0 + r.x1) / 2 - x0, x1 - (r.x0 + r.x1) / 2)}[align]
            if width > room:
                size = max(size * room / width, size * 0.5)
                width = font["measure"](font["text"], size)
            x = {"left": r.x0, "right": r.x1 - width, "center": (r.x0 + r.x1 - width) / 2}[align]
            jobs.append((col, font, size, pymupdf.Point(x, col["origin"].y)))
        h = r.height
        page.add_redact_annot(pymupdf.Rect(r.x0 - 0.5, r.y0 + h * 0.2, r.x1 + 0.5, r.y1 - h * 0.2),
                              fill=False, cross_out=False)

    # Remove only the text glyphs of the changed columns; keep images and line art.
    page.apply_redactions(
        images=pymupdf.PDF_REDACT_IMAGE_NONE,
        graphics=pymupdf.PDF_REDACT_LINE_ART_NONE,
        text=pymupdf.PDF_REDACT_TEXT_REMOVE,
    )

    embedded_new_font = False
    for col, font, size, start in jobs:
        span = col["span"]
        color = pymupdf.sRGB_to_pdf(span["color"])
        if font["source"] == "original":
            write_original(doc, page, font["orig"], start, line["dir"], font["text"], size, color)
            continue
        fontname = base14_for(span)
        if font["fontfile"]:
            fontname = unique_font_name(page)
            page.insert_font(fontname=fontname, fontfile=font["fontfile"])
            embedded_new_font = True
        page.insert_text(start, font["text"], fontname=fontname, fontsize=size,
                         color=color, morph=direction_morph(start, line["dir"]))
    if embedded_new_font:
        try:
            doc.subset_fonts()
        except Exception:
            pass

    doc.save(out, garbage=3, deflate=True)
    doc.close()
    rank = {"original": 0, "system": 1, "substitute": 2}
    worst = max(jobs, key=lambda j: rank[j[1]["source"]], default=None)
    first = (worst or (edits[0][0], None, None, None))[0]["span"]
    return {
        "ok": True,
        "font": clean_font_name(first["font"]),
        "fontUsed": worst[1]["used"] if worst else clean_font_name(first["font"]),
        "fontSource": worst[1]["source"] if worst else "original",
        "size": round(min((j[2] for j in jobs), default=first["size"]), 2),
        "shrunk": any(round(j[2], 2) < round(j[0]["span"]["size"], 2) for j in jobs),
    }


def unique_font_name(page):
    used = {f[4] for f in page.get_fonts(full=True)}
    n = 1
    while f"PTE{n}" in used:
        n += 1
    return f"PTE{n}"


def direction_morph(start, direction):
    dx, dy = direction
    if abs(dx - 1) < 1e-3 and abs(dy) < 1e-3:
        return None
    angle = -math.degrees(math.atan2(dy, dx))
    return (start, pymupdf.Matrix(angle))


def write_original(doc, page, font, start, direction, text, size, color):
    """Append a content stream drawing text with the page's existing font."""
    m = pdf_matrix(page)
    p0 = start * m
    p1 = (start + pymupdf.Point(direction)) * m
    v = p1 - p0
    length = abs(v) or 1.0
    c, s = v.x / length, v.y / length

    res_name = f"PTEF{font.xref}"
    ensure_own_resources(doc, page)
    doc.xref_set_key(page.xref, f"Resources/Font/{res_name}", f"{font.xref} 0 R")

    if not page.is_wrapped:
        page.wrap_contents()
    rgb = " ".join(f"{v:g}" for v in (color if isinstance(color, (list, tuple)) else (0, 0, 0)))
    stream = (
        f"q BT /{res_name} {size:g} Tf {rgb} rg "
        f"{c:g} {s:g} {-s:g} {c:g} {p0.x:g} {p0.y:g} Tm "
        f"{font.tj_array(text)} TJ ET Q\n"
    ).encode("latin-1")
    xref = doc.get_new_xref()
    doc.update_object(xref, "<<>>")
    doc.update_stream(xref, stream, new=True)
    contents = page.get_contents() + [xref]
    doc.xref_set_key(page.xref, "Contents", "[" + " ".join(f"{x} 0 R" for x in contents) + "]")


def ensure_own_resources(doc, page):
    """Copy inherited /Resources onto the page so adding a font can't hide others."""
    if doc.xref_get_key(page.xref, "Resources")[0] != "null":
        return
    node = page.xref
    while True:
        kind, parent = doc.xref_get_key(node, "Parent")
        if kind != "xref":
            doc.xref_set_key(page.xref, "Resources", "<<>>")
            return
        node = ref_xref(parent)
        kind, res = doc.xref_get_key(node, "Resources")
        if kind != "null":
            doc.xref_set_key(page.xref, "Resources", res)
            return


# ---------------------------------------------------------------- protocol

def handle(req):
    cmd = req["cmd"]
    if cmd == "ping":
        return {"ok": True, "version": pymupdf.VersionBind}
    if cmd == "lines":
        doc = pymupdf.open(req["path"])
        page = doc[req["page"]]
        lines = [describe(page, ln) for ln in page_lines(page)]
        doc.close()
        return {"ok": True, "lines": lines}
    if cmd == "edit":
        return edit_line(req["path"], req["out"], req["page"], req["line"], req["text"],
                         req.get("expect"))
    raise ValueError(f"unknown command {cmd}")


def main():
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            resp = handle(json.loads(raw))
        except Exception as e:  # report every failure back to the app
            resp = {"ok": False, "error": f"{type(e).__name__}: {e}"}
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()

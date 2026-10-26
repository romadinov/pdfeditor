"""End-to-end checks for the engine: run with the engine's venv python.

    python Tests/run_engine_tests.py <scratch dir>

Builds the sample PDFs, applies edits through the JSON protocol and verifies
text, fonts, and that every vector drawing (the boxes) is still present.
"""
import json
import os
import subprocess
import sys

import pymupdf

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.join(HERE, "..", "Engine", "pdftext_engine.py")
out = sys.argv[1]


def drawings(path):
    page = pymupdf.open(path)[0]
    return sorted((tuple(round(v, 1) for v in d["rect"]), d.get("fill"), d.get("color"))
                  for d in page.get_drawings())


def spans(path):
    page = pymupdf.open(path)[0]
    return {s["text"].replace(" ", " ").strip(): s for b in page.get_text("dict")["blocks"]
            for l in b.get("lines", []) for s in l["spans"] if s["text"].strip()}


def run(src, edits):
    proc = subprocess.Popen([sys.executable, ENGINE], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, text=True)
    cur = src
    results = []
    for i, (expect, text) in enumerate(edits):
        nxt = os.path.join(out, f"{os.path.basename(src)}.{i}.pdf")
        proc.stdin.write(json.dumps({"cmd": "edit", "path": cur, "out": nxt, "page": 0,
                                     "line": "?", "expect": expect, "text": text}) + "\n")
        proc.stdin.flush()
        r = json.loads(proc.stdout.readline())
        assert r["ok"], r
        results.append(r)
        cur = nxt
    proc.stdin.close()
    return cur, results


failures = 0


def check(cond, msg):
    global failures
    print(("PASS " if cond else "FAIL ") + msg)
    failures += not cond


sample = os.path.join(out, "sample.pdf")
subprocess.run([sys.executable, os.path.join(HERE, "make_sample.py"), sample], check=True)
edits = [("ACME Corporation — Invoice", "Globex Industries Pty Ltd — Tax Invoice"),
         ("Consulting services", "Strategy workshop (2 days)"),
         ("Invoice #10023", "Invoice #10032"),
         ("$1,500.00", "$12,480.00"),
         ("12 Collins Street, Melbourne", "Level 42, 1 Very Long Boulevard Name, Southbank VIC 3006")]
final, results = run(sample, edits)
check(drawings(sample) == drawings(final), "all boxes, fills and table rules unchanged")
got = spans(final)
for (old, new), r in zip(edits, results):
    check(new in got, f"text replaced: {new!r}")
    check(old not in got, f"old text removed: {old!r}")
    check(r["fontSource"] in ("original", "system"), f"font preserved for {new!r}: {r['fontUsed']} ({r['fontSource']})")
check(results[2]["fontSource"] == "original", "reuses the embedded font when glyphs exist")
amount = got["$12,480.00"]
check(abs(amount["bbox"][2] - 547) < 1.5, "right-aligned table cell stays right-aligned")
inv = got["Invoice #10032"]
check(abs((inv["bbox"][0] + inv["bbox"][2]) / 2 - 437.5) < 1.5, "centred box text stays centred")
addr = got["Level 42, 1 Very Long Boulevard Name, Southbank VIC 3006"]
check(addr["bbox"][2] <= 290, "long text shrinks to stay inside its box")
check(got["Globex Industries Pty Ltd — Tax Invoice"]["color"] == 0xFFFFFF, "text colour kept")

for rot in (90, 180, 270):
    rotated = os.path.join(out, f"rotated{rot}.pdf")
    doc = pymupdf.open(sample)
    doc[0].set_rotation(rot)
    doc.save(rotated)
    for new in ("Invoice #10032", "Invoice #99999"):  # original font, then installed font
        edited, _ = run(rotated, [("Invoice #10023", new)])
        before = pymupdf.open(rotated)[0].search_for("Invoice #10023")[0]
        after = pymupdf.open(edited)[0].search_for(new)
        check(bool(after) and all(abs(a - b) < 1.5 for a, b in zip(before, after[0])),
              f"rotated {rot}°: {new!r} lands where the old text was")

print(f"\n{failures} failure(s)")
sys.exit(1 if failures else 0)

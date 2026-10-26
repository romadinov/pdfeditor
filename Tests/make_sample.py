"""Build a sample invoice-style PDF with boxes, a ruled table and subset fonts."""
import sys
import pymupdf

out = sys.argv[1]
doc = pymupdf.open()
page = doc.new_page(width=595, height=842)
arial = "/System/Library/Fonts/Supplemental/Arial.ttf"
arialb = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
page.insert_font(fontname="ar", fontfile=arial)
page.insert_font(fontname="arb", fontfile=arialb)

# Shaded header bar with white text
page.draw_rect(pymupdf.Rect(40, 40, 555, 90), color=None, fill=(0.12, 0.3, 0.55))
page.insert_text((60, 72), "ACME Corporation — Invoice", fontname="arb", fontsize=20, color=(1, 1, 1))

# Bordered box with left-aligned text
page.draw_rect(pymupdf.Rect(40, 110, 290, 190), color=(0, 0, 0), width=1)
page.insert_text((50, 130), "Bill to:", fontname="arb", fontsize=11)
page.insert_text((50, 148), "Jane Smith", fontname="ar", fontsize=11)
page.insert_text((50, 166), "12 Collins Street, Melbourne", fontname="ar", fontsize=11)

# Light-filled box with centred text
box = pymupdf.Rect(320, 110, 555, 150)
page.draw_rect(box, color=(0.4, 0.4, 0.4), fill=(0.93, 0.93, 0.93), width=1)
t = "Invoice #10023"
w = pymupdf.get_text_length(t, fontname="helv", fontsize=14)
page.insert_text((box.x0 + (box.width - w) / 2, 135), t, fontname="ar", fontsize=14)

# Ruled table built from separate strokes
xs, ys = [40, 300, 400, 555], [220, 245, 270, 295]
for y in ys:
    page.draw_line((xs[0], y), (xs[-1], y), color=(0, 0, 0), width=0.8)
for x in xs:
    page.draw_line((x, ys[0]), (x, ys[-1]), color=(0, 0, 0), width=0.8)
rows = [("Description", "Qty", "Amount"), ("Consulting services", "10", "$1,500.00"), ("Travel", "1", "$320.00")]
for r, row in enumerate(rows):
    for c, cell in enumerate(row):
        fn = "arb" if r == 0 else "ar"
        if c == 2:
            w = pymupdf.get_text_length(cell, fontname="helv", fontsize=11)
            x = xs[3] - 8 - pymupdf.Font(fontfile=arialb if r == 0 else arial).text_length(cell, 11)
        else:
            x = xs[c] + 8
        page.insert_text((x, ys[r] + 17), cell, fontname=fn, fontsize=11)

page.insert_text((40, 340), "Thank you for your business.", fontname="ar", fontsize=10, color=(0.3, 0.3, 0.3))
doc.subset_fonts()
doc.save(out, garbage=3, deflate=True)

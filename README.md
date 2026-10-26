# PDF Text Editor

A Mac app for changing the text in a PDF while keeping everything else
exactly as it was: boxes, borders, table rules, shaded cells, images and fonts.

## Build and run

```bash
./build.sh                          # builds "build/PDF Text Editor.app"
open "build/PDF Text Editor.app"
```

The app needs Python 3. On first run it creates a private environment in
`~/Library/Application Support/PDFTextEditor/venv` with PyMuPDF and fontTools
(`build.sh` does this up front). To install the app, drag it to /Applications.

## Using it

- Hover over text: a blue outline shows the line, and the status bar shows its font and size.
- Click to edit it in place. Return applies the change, Esc cancels.
- ⌘Z / ⇧⌘Z undo and redo. ⌘S saves and ⇧⌘S saves a copy.
- The status bar reports which font was used for each edit and warns in orange if it had to substitute one.

## How text is replaced

1. **Only the text is removed.** Redaction is set to remove text glyphs and leave line art and
   images alone, so drawn boxes and backgrounds are left in place. It does not paint over them.
2. **The font is kept.** The engine tries these in order:
   - **The document's own embedded font.** It writes glyph codes straight to the original font
     resource. This needs every new character to exist in the embedded subset, which the engine
     checks inside the font program itself.
   - **The same font installed on this Mac**, when the subset lacks a character you typed.
   - **A close standard font, with a warning.** Install the original font and redo the edit for
     an exact match.
3. **Text stays in its box.** The engine finds the enclosing rectangle or table cell and keeps the
   text's left, right or centre alignment. It reduces the font size (to no less than half) only
   when the new text would overflow the box.

Size, colour, baseline and page rotation are preserved.

## Limitations

- You edit one line at a time. Text does not reflow across lines or paragraphs.
- If a line mixes styles (for example, one bold word), the whole line takes the line's main style.
- Vertical text, Type3 fonts and scanned (image-only) PDFs can't be edited.
- Password-protected PDFs must be unlocked first.

## Layout

| Path | What |
| --- | --- |
| `Sources/PDFTextEditor/` | AppKit app: `NSDocument` (open, save, undo), PDFKit view, inline editor |
| `Engine/pdftext_engine.py` | Text engine (PyMuPDF + fontTools), JSON over stdin/stdout |
| `Tests/run_engine_tests.py` | End-to-end engine checks: `<venv>/bin/python Tests/run_engine_tests.py <tmpdir>` |
| `Tests/make_sample.py`, `Tests/make_quartz_sample.swift` | Sample PDF generators |
| `scripts/make_icon.swift` | Draws the app icon: `swift scripts/make_icon.swift AppIcon.iconset && iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns` |

PyMuPDF is AGPL-licensed. That's fine for personal and internal use, but distributing the app
commercially would need an Artifex licence.

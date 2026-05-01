#!/usr/bin/env python3
"""Build a v1.80 fix-showcase .docx from scratch.

Showcases:
  #53 — body Normal style with <w:bidi w:val="0"/> (LibreOffice artifact).
        Pre-fix would force text-align:right on body. Post-fix renders LTR.
  #57 — <w:titlePg/> + separate first/default header & footer references.
        Page 1 gets the title-page header, pages 2+ get the default.
  #58 — Image with explicit wp:extent + intentionally-mismatched native dims.
        Post-fix locks display size via HTML width/height attrs.
  #56 — One image authored at 8.27" wide on a 7.27" content area triggers
        the pre-flight overflow warning during extractAndSaveTemplateImages.

Output: /tmp/v180-proof/v180-showcase.docx
"""
import os, struct, zlib, zipfile

OUT = '/tmp/v180-proof/v180-showcase.docx'

# ---- Build a tiny PNG (1x1 red) twice — same image, two display sizes ----
# Minimal PNG: signature + IHDR + IDAT + IEND, 1x1 red pixel
def make_png():
    sig = bytes.fromhex('89504E470D0A1A0A')
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    ihdr = struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)  # 1x1, 8-bit RGB
    raw = b'\x00\xff\x00\x00'  # filter byte + RGB(255,0,0)
    idat = zlib.compress(raw)
    return sig + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b'')

png = make_png()

# ---- DOCX parts ----

CONTENT_TYPES = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="png" ContentType="image/png"/>
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
<Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
<Override PartName="/word/header2.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
<Override PartName="/word/footer2.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
</Types>'''

ROOT_RELS = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>'''

DOC_RELS = '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>
<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header2.xml"/>
<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>
<Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer2.xml"/>
<Relationship Id="rId6" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>
</Relationships>'''

# Header1 = DEFAULT (pages 2+). Small badge on the right.
HEADER1_RELS = '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rIdHdrDefault" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>
</Relationships>'''

# Header2 = FIRST PAGE. Bigger banner — would overflow without #58 lock.
HEADER2_RELS = HEADER1_RELS  # same image, different display size

FOOTER1_RELS = HEADER1_RELS
FOOTER2_RELS = HEADER1_RELS

# Styles.xml — INCLUDES the LibreOffice <w:bidi w:val="0"/> artifact
# in the Normal style. Pre-1.80 this would falsely flag the doc as RTL.
STYLES = '''<?xml version="1.0" encoding="UTF-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:style w:type="paragraph" w:styleId="Normal" w:default="1">
<w:name w:val="Normal"/>
<w:qFormat/>
<w:pPr><w:widowControl/><w:bidi w:val="0"/></w:pPr>
<w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/></w:rPr>
</w:style>
<w:style w:type="paragraph" w:styleId="Heading1">
<w:name w:val="heading 1"/>
<w:basedOn w:val="Normal"/>
<w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/></w:pPr>
<w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:b/><w:sz w:val="36"/><w:color w:val="2E5C8A"/></w:rPr>
</w:style>
</w:styles>'''

# HEADER #2 — first page. Banner image: 8.27" wide → triggers #56 warning.
# 8.27" * 914400 = 7562088 EMU. At 96 DPI that's 794 px display.
# Native PNG is 1px so renders red bar. With #58 fix, locks at 794px.
HEADER2 = '''<?xml version="1.0" encoding="UTF-8"?>
<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
       xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
       xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
       xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
       xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
<w:p><w:pPr><w:jc w:val="center"/></w:pPr>
<w:r><w:rPr><w:b/><w:sz w:val="48"/><w:color w:val="2E5C8A"/></w:rPr>
<w:t>DocGen v1.80 — Title Page Header</w:t></w:r></w:p>
<w:p><w:pPr><w:jc w:val="center"/></w:pPr>
<w:r><w:drawing>
<wp:inline distT="0" distB="0" distL="0" distR="0">
<wp:extent cx="7562088" cy="304800"/>
<wp:docPr id="1" name="Banner"/>
<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
<pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="Banner"/><pic:cNvPicPr/></pic:nvPicPr>
<pic:blipFill><a:blip r:embed="rIdHdrDefault"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="7562088" cy="304800"/></a:xfrm>
<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>
</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
</w:hdr>'''

# HEADER #1 — default (pages 2+). Smaller right-aligned label.
HEADER1 = '''<?xml version="1.0" encoding="UTF-8"?>
<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
       xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
       xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
       xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
       xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
<w:p><w:pPr><w:jc w:val="right"/></w:pPr>
<w:r><w:rPr><w:sz w:val="20"/><w:color w:val="666666"/></w:rPr>
<w:t>DocGen v1.80 Showcase &#8212; default header (pages 2+)</w:t></w:r></w:p>
</w:hdr>'''

# FOOTER #2 — first page footer
FOOTER2 = '''<?xml version="1.0" encoding="UTF-8"?>
<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:p><w:pPr><w:jc w:val="center"/></w:pPr>
<w:r><w:rPr><w:b/><w:sz w:val="20"/><w:color w:val="2E5C8A"/></w:rPr>
<w:t>Title-Page Footer &#183; v1.80 Fix #57</w:t></w:r></w:p>
</w:ftr>'''

# FOOTER #1 — default footer (pages 2+)
FOOTER1 = '''<?xml version="1.0" encoding="UTF-8"?>
<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:p><w:pPr><w:jc w:val="center"/></w:pPr>
<w:r><w:rPr><w:sz w:val="18"/><w:color w:val="999999"/></w:rPr>
<w:t>Default footer &#8212; rendered on pages 2 and beyond</w:t></w:r></w:p>
</w:ftr>'''

# Document body. Page 1 = title page that exercises #53 + #58.
# Page break, then page 2+ that exercise #57 by showing a different header/footer.
# Image at 1in x 1in for #58 verification (1in = 914400 EMU, displays at 96px).
DOCUMENT = '''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
            xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
<w:body>

<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
<w:r><w:t>DocGen v1.80 Word-Fidelity Showcase</w:t></w:r></w:p>

<w:p><w:r><w:rPr><w:i/><w:sz w:val="20"/><w:color w:val="666666"/></w:rPr>
<w:t>Generated for {Name} &#183; this body must render LEFT-ALIGNED. (Fix #53)</w:t></w:r></w:p>

<w:p><w:r><w:t></w:t></w:r></w:p>

<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Fix #53 &#8212; LibreOffice RTL false positive</w:t></w:r></w:p>
<w:p><w:r><w:t>This template's styles.xml contains </w:t></w:r>
<w:r><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/></w:rPr>
<w:t>&lt;w:bidi w:val="0"/&gt;</w:t></w:r>
<w:r><w:t> in the Normal style &#8212; the artifact LibreOffice's .doc&#8594;.docx conversion injects into every English document. Before v1.80 the renderer matched the substring "&lt;w:bidi " and incorrectly flagged the doc as right-to-left, emitting </w:t></w:r>
<w:r><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/></w:rPr><w:t>text-align: right</w:t></w:r>
<w:r><w:t> on body. After the fix, this paragraph renders left-aligned as authored.</w:t></w:r></w:p>

<w:p><w:r><w:t></w:t></w:r></w:p>

<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Fix #58 &#8212; image dimension binding</w:t></w:r></w:p>
<w:p><w:r><w:t>The 1-inch test image below has wp:extent of 914400&#215;914400 EMU (1in&#215;1in display). Its native PNG is 1px&#215;1px. Without v1.80's HTML width/height attribute fix, Flying Saucer's image scaler would have read native pixel dims and rendered a 1px dot. With the fix, it renders as a 96px&#215;96px square exactly as authored.</w:t></w:r></w:p>

<w:p><w:pPr><w:jc w:val="center"/></w:pPr>
<w:r><w:drawing>
<wp:inline distT="0" distB="0" distL="0" distR="0">
<wp:extent cx="914400" cy="914400"/>
<wp:docPr id="2" name="TestImage"/>
<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
<pic:pic><pic:nvPicPr><pic:cNvPr id="2" name="TestImage"/><pic:cNvPicPr/></pic:nvPicPr>
<pic:blipFill><a:blip r:embed="rId6"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm>
<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>
</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>

<w:p><w:r><w:rPr><w:i/><w:sz w:val="18"/><w:color w:val="666666"/></w:rPr>
<w:t>(Square should be ~1 inch wide on the page, not a single pixel.)</w:t></w:r></w:p>

<w:p><w:r><w:t></w:t></w:r></w:p>

<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Fix #56 &#8212; pre-flight overflow warning</w:t></w:r></w:p>
<w:p><w:r><w:t>The blue banner in this title-page header is authored at 8.27" wide. The page content area (8.5" - 0.5" - 0.5" margins) is only 7.5". When extractAndSaveTemplateImages ran, it emitted a System.debug WARN entry surfacing the overflow so admins can resize before users hit it.</w:t></w:r></w:p>

<w:p><w:r><w:t></w:t></w:r></w:p>

<w:p><w:r><w:rPr><w:b/><w:color w:val="2E5C8A"/></w:rPr><w:t>&#8595; Page 2 should look noticeably different &#8212; smaller right-aligned default header, plain footer.</w:t></w:r></w:p>

<w:p><w:r><w:br w:type="page"/></w:r></w:p>

<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
<w:r><w:t>Fix #57 &#8212; First-Page-Distinct Headers/Footers</w:t></w:r></w:p>

<w:p><w:r><w:t>This is page 2. The doc has </w:t></w:r>
<w:r><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/></w:rPr><w:t>&lt;w:titlePg/&gt;</w:t></w:r>
<w:r><w:t> set in sectPr, plus separate "first" and "default" headerReference entries. Before v1.80 the renderer concatenated all headers into one block and rendered all of them on every page. After the fix:</w:t></w:r></w:p>

<w:p><w:r><w:t>&#8226; Page 1 used the FIRST-typed header (the big blue banner you saw) and FIRST-typed footer.</w:t></w:r></w:p>

<w:p><w:r><w:t>&#8226; Pages 2+ use the DEFAULT header (the small grey label, top-right) and DEFAULT footer (small grey text, bottom-center).</w:t></w:r></w:p>

<w:p><w:r><w:t>If you are reading this on page 2 and the headers/footers look different from page 1, the fix is working.</w:t></w:r></w:p>

<w:p><w:r><w:t></w:t></w:r></w:p>

<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Quick reference of the four v1.80 fixes:</w:t></w:r></w:p>
<w:p><w:r><w:t>&#8226; #53 OOXML on/off parser &#8212; correctly handles w:val="0" disabled form across 11 element types</w:t></w:r></w:p>
<w:p><w:r><w:t>&#8226; #56 Pre-flight image-overflow warning &#8212; debug-log alerts when wp:extent exceeds page area</w:t></w:r></w:p>
<w:p><w:r><w:t>&#8226; #57 First-page-distinct headers/footers &#8212; @page :first running elements wired to first-typed refs</w:t></w:r></w:p>
<w:p><w:r><w:t>&#8226; #58 Image dimension binding &#8212; HTML width/height attrs lock display size at Flying Saucer's authoritative layer</w:t></w:r></w:p>

<w:sectPr>
<w:headerReference w:type="first" r:id="rId3"/>
<w:headerReference w:type="default" r:id="rId2"/>
<w:footerReference w:type="first" r:id="rId5"/>
<w:footerReference w:type="default" r:id="rId4"/>
<w:type w:val="continuous"/>
<w:pgSz w:w="12240" w:h="15840"/>
<w:pgMar w:top="1440" w:right="720" w:bottom="1440" w:left="720" w:header="720" w:footer="720" w:gutter="0"/>
<w:titlePg/>
</w:sectPr>

</w:body>
</w:document>'''

with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('[Content_Types].xml', CONTENT_TYPES)
    z.writestr('_rels/.rels', ROOT_RELS)
    z.writestr('word/_rels/document.xml.rels', DOC_RELS)
    z.writestr('word/_rels/header1.xml.rels', HEADER1_RELS)
    z.writestr('word/_rels/header2.xml.rels', HEADER2_RELS)
    z.writestr('word/_rels/footer1.xml.rels', FOOTER1_RELS)
    z.writestr('word/_rels/footer2.xml.rels', FOOTER2_RELS)
    z.writestr('word/document.xml', DOCUMENT)
    z.writestr('word/styles.xml', STYLES)
    z.writestr('word/header1.xml', HEADER1)
    z.writestr('word/header2.xml', HEADER2)
    z.writestr('word/footer1.xml', FOOTER1)
    z.writestr('word/footer2.xml', FOOTER2)
    z.writestr('word/media/image1.png', png)

print(f'Built: {OUT}')
print(f'Size: {os.path.getsize(OUT)} bytes')

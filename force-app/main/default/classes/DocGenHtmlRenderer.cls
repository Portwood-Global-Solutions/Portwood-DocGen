/**
 * Converts processed DOCX XML (post-merge) to HTML suitable for Blob.toPdf().
 * Uses string-based XML parsing for DOCX-specific namespace handling.
 */
public with sharing class DocGenHtmlRenderer {
    private static final String HTML_PREFIX =
        '<html><head><meta charset="utf-8"/><style>' +
        '@page { size: letter; margin: 1in; }' + // default — overridden by convertToHtmlWithHeaderFooter
        'body { font-family: Arial, "Arial Unicode MS", sans-serif; font-size: 11pt; line-height: 1.15; color: #000; }' +
        'h1 { font-size: 20pt; font-weight: bold; margin: 0 0 6pt 0; }' +
        'h2 { font-size: 16pt; font-weight: bold; margin: 0 0 4pt 0; }' +
        'h3 { font-size: 14pt; font-weight: bold; margin: 0 0 4pt 0; }' +
        'h4 { font-size: 12pt; font-weight: bold; margin: 0 0 4pt 0; }' +
        'h5 { font-size: 11pt; font-weight: bold; margin: 0 0 4pt 0; }' +
        'h6 { font-size: 10pt; font-weight: bold; margin: 0 0 4pt 0; }' +
        'h1, h2, h3, h4, h5, h6 { page-break-after: avoid; }' +
        'table { border-collapse: collapse; width: 100%; page-break-inside: auto; }' +
        'tr { page-break-inside: avoid; page-break-after: auto; }' +
        // Tight defaults: Word always emits explicit <w:spacing>/<w:tcMar> when authors
        // want padding, so a non-zero default ends up "flabby" (extra space the author
        // never asked for). Keep horizontal cell padding because Word's tcMar defaults
        // to ~108 twips (~5.4pt) on each side and zeroing it makes tables visually fuse.
        'td, th { padding: 0 4pt; vertical-align: top; }' +
        'p { margin: 0; orphans: 2; widows: 2; page-break-inside: avoid; }' +
        'img { max-width: 100%; }' +
        'ul, ol { margin: 0; padding-left: 36pt; }' +
        'li { margin: 0; page-break-inside: avoid; }' +
        'hr { border: none; border-top: 1px solid #000; margin: 6pt 0; }' +
        'sub { vertical-align: sub; font-size: 0.8em; }' +
        'sup { vertical-align: super; font-size: 0.8em; }' +
        '</style></head><body>';

    private static final String HTML_SUFFIX = '</body></html>';

    // Styles XML from template — set before calling convertToHtml for style resolution
    public static String stylesXml;
    // Admin-set orientation override ('Landscape' | 'Portrait'). When set, uses
    // canonical 11×8.5 / 8.5×11 dimensions regardless of what the source DOCX
    // declares — DOCX page dims are often stale or carry old margins from the
    // author's environment, so the field is the source of truth.
    public static String orientationOverride;
    // 1.68 — page size + margins overrides. When set, parsePageDimensions resolves
    // canonical dimensions from the (size × orientation) matrix instead of reading
    // <w:pgSz>/<w:pgMar> from the source DOCX. Margins follow the preset, or parse
    // Custom_Margins__c when marginsOverride == 'Custom'. Cleared in renderPdf finally.
    public static String pageSizeOverride;
    public static String marginsOverride;
    public static String customMarginsOverride;
    // Document XML for the current render — set at top of convertToHtml so deeper
    // helpers (e.g. processPict for watermark sizing) can call parsePageDimensions
    // without threading documentXml through every method signature.
    private static String currentDocumentXml;
    // Admin-uploaded watermark/background image (ContentVersion ID). Set by
    // callers before convertToHtml when the template has a watermark configured
    // via the docGenAdmin LWC. When set, it OVERRIDES any Word VML watermark
    // extracted from the template's headers — first-class watermarks beat
    // embedded ones because the admin controlled both the size and the image.
    public static String overrideWatermarkCvId;
    // #28 async-safe fallback: map of table-style-name → border CSS, pre-extracted in admin
    // context and cached in Signature_Data__c. Checked by resolveTableStyleBorder BEFORE
    // parsing stylesXml, so queueables running as Automated Process (which can't access
    // the pre-decomposed ContentVersions) still render table-style borders correctly.
    public static Map<String, String> tableStyleBorderMap;
    // #28 async fallback: styleName → {color, fontFamily, fontSize, bold, italic} — pre-
    // extracted in admin context, cached in Signature_Data__c, consulted by
    // resolveStyleTextAttributes before parsing stylesXml. Same rationale as the borders map.
    public static Map<String, Map<String, String>> styleTextAttrsMap;

    /**
     * Extracts a compact borders map from styles.xml for async fallback use.
     * Walks every <w:style w:type="table" w:styleId="X"> element, captures the first-found
     * border side if the style has <w:tblBorders>, and returns a name→CSS map. Callers can
     * serialize this to JSON and stash it on a record for later retrieval — useful when
     * the async render context can't re-query the full styles.xml ContentVersion.
     */
    /**
     * Extracts a compact styleName → text-attributes map from styles.xml for async
     * fallback use. Covers color, font, size, bold, italic — enough to fix
     * styles.xml-dependent text rendering in the signature PDF queueable context
     * where the full stylesXml can't be loaded (Automated Process user + ContentVersion).
     */
    public static Map<String, Map<String, String>> extractStyleTextAttributeMap(String stylesXmlSource) {
        Map<String, Map<String, String>> out = new Map<String, Map<String, String>>();
        if (String.isBlank(stylesXmlSource))
            return out;
        Pattern p = Pattern.compile('<w:style [^>]*w:styleId="([^"]+)"[^>]*>([\\s\\S]*?)</w:style>');
        Matcher m = p.matcher(stylesXmlSource);
        while (m.find()) {
            String styleName = m.group(1);
            String styleDef = m.group(2);
            Map<String, String> attrs = new Map<String, String>();
            String color = extractAttr(styleDef, 'w:color', 'w:val');
            if (color != null && color != 'auto' && color.length() >= 6)
                attrs.put('color', color);
            String font = extractAttr(styleDef, 'w:rFonts', 'w:ascii');
            if (font == null)
                font = extractAttr(styleDef, 'w:rFonts', 'w:hAnsi');
            if (String.isNotBlank(font))
                attrs.put('fontFamily', font);
            String sz = extractAttr(styleDef, 'w:sz', 'w:val');
            if (sz != null && sz.isNumeric())
                attrs.put('fontSize', sz);
            if (isOoxmlOnOffElementTrue(styleDef, 'w:b'))
                attrs.put('bold', 'true');
            if (isOoxmlOnOffElementTrue(styleDef, 'w:i'))
                attrs.put('italic', 'true');
            if (!attrs.isEmpty())
                out.put(styleName, attrs);
        }
        return out;
    }

    public static Map<String, String> extractTableStyleBorderMap(String stylesXmlSource) {
        Map<String, String> out = new Map<String, String>();
        if (String.isBlank(stylesXmlSource))
            return out;
        Pattern p = Pattern.compile('<w:style [^>]*w:styleId="([^"]+)"[^>]*>([\\s\\S]*?)</w:style>');
        Matcher m = p.matcher(stylesXmlSource);
        while (m.find()) {
            String styleName = m.group(1);
            String styleDef = m.group(2);
            if (!styleDef.contains('<w:tblBorders'))
                continue;
            String border = parseBorderSide(styleDef, 'w:top');
            if (border == null)
                border = parseBorderSide(styleDef, 'w:insideH');
            if (border == null)
                border = '0.5pt solid #000';
            out.put(styleName, border);
        }
        return out;
    }

    // Numbering XML from template — set before calling convertToHtml for list type resolution
    public static String numberingXml;

    // Unit conversions
    private static final Decimal HALF_POINTS_TO_PT = 0.5; // half-points → pt (÷2)
    private static final Decimal TWIPS_TO_PT = 0.05; // twips → pt (÷20)
    private static final Decimal EMU_TO_PX = 0.000104987; // EMU → px (÷9525)

    // Standard Word heading style IDs → HTML heading levels
    private static final Map<String, Integer> HEADING_STYLE_MAP = new Map<String, Integer>{
        'Heading1' => 1,
        'heading1' => 1,
        'Heading 1' => 1,
        'Heading2' => 2,
        'heading2' => 2,
        'Heading 2' => 2,
        'Heading3' => 3,
        'heading3' => 3,
        'Heading 3' => 3,
        'Heading4' => 4,
        'heading4' => 4,
        'Heading 4' => 4,
        'Heading5' => 5,
        'heading5' => 5,
        'Heading 5' => 5,
        'Heading6' => 6,
        'heading6' => 6,
        'Heading 6' => 6
    };

    // Word style IDs that imply a list item
    private static final Set<String> LIST_STYLE_IDS = new Set<String>{
        'ListParagraph',
        'listparagraph',
        'ListBullet',
        'ListNumber',
        'List Paragraph',
        'List Bullet',
        'List Number'
    };

    /**
     * Converts processed DOCX XML content and associated images into an HTML string
     * suitable for Blob.toPdf().
     * @param documentXml The processed word/document.xml content (post-merge)
     * @param images Map of relationship IDs to base64-encoded image data
     * @return HTML string ready for Blob.toPdf()
     */
    public static String convertToHtml(String documentXml, Map<String, String> images) {
        return convertToHtml(documentXml, images, null);
    }

    /**
     * Converts document XML to HTML with custom font CSS injected into the style block.
     * @param documentXml The processed word/document.xml content (post-merge)
     * @param images Map of relationship IDs to image URLs or base64 data
     * @param fontFaceCss @font-face CSS declarations to inject (null = no custom fonts)
     * @return HTML string ready for Blob.toPdf()
     */
    public static String convertToHtml(String documentXml, Map<String, String> images, String fontFaceCss) {
        if (String.isBlank(documentXml)) {
            return HTML_PREFIX + HTML_SUFFIX;
        }
        if (images == null) {
            images = new Map<String, String>();
        }
        currentDocumentXml = documentXml;

        // Extract header/footer markers if present. Six possible markers:
        //   DEFAULT (every page) / FIRST (page 1 when w:titlePg is set) / EVEN (rare)
        // for both header and footer. Older templates only emit DEFAULT — keeping
        // backward compat with the original two-marker behavior.
        String mainXml = documentXml;
        String headerXml = '';
        String footerXml = '';
        String headerFirstXml = '';
        String footerFirstXml = '';
        Map<String, String> extracted = extractMarkerSection(mainXml, 'DOCGEN_HEADER_START', 'DOCGEN_HEADER_END');
        headerXml = extracted.get('content');
        mainXml = extracted.get('remainder');
        extracted = extractMarkerSection(mainXml, 'DOCGEN_HEADER_FIRST_START', 'DOCGEN_HEADER_FIRST_END');
        headerFirstXml = extracted.get('content');
        mainXml = extracted.get('remainder');
        extracted = extractMarkerSection(mainXml, 'DOCGEN_FOOTER_START', 'DOCGEN_FOOTER_END');
        footerXml = extracted.get('content');
        mainXml = extracted.get('remainder');
        extracted = extractMarkerSection(mainXml, 'DOCGEN_FOOTER_FIRST_START', 'DOCGEN_FOOTER_FIRST_END');
        footerFirstXml = extracted.get('content');
        mainXml = extracted.get('remainder');
        // Even-page distinct markers are stripped but not yet wired to a separate
        // CSS @page rule — Flying Saucer's @page :left/:right support is partial
        // and the customer use case for even-only headers is rare. They render
        // as part of the default pair for now.
        extracted = extractMarkerSection(mainXml, 'DOCGEN_HEADER_EVEN_START', 'DOCGEN_HEADER_EVEN_END');
        if (String.isNotBlank(extracted.get('content'))) {
            headerXml += extracted.get('content');
        }
        mainXml = extracted.get('remainder');
        extracted = extractMarkerSection(mainXml, 'DOCGEN_FOOTER_EVEN_START', 'DOCGEN_FOOTER_EVEN_END');
        if (String.isNotBlank(extracted.get('content'))) {
            footerXml += extracted.get('content');
        }
        mainXml = extracted.get('remainder');

        String bodyContent = extractBodyContent(mainXml);
        String html = processBodyContent(bodyContent, images);

        // Watermark resolution order:
        //   1. Admin-uploaded watermark (overrideWatermarkCvId set by caller) —
        //      first-class path, admin controlled both size and image, no VML
        //      parsing needed
        //   2. Word-embedded VML watermark extracted from headers — legacy path
        //      with documented Scale/Washout/rotation limitations
        String watermarkPageBgCss = '';
        if (String.isNotBlank(overrideWatermarkCvId)) {
            // overrideWatermarkCvId is a static set by callers — sanitize defensively
            // so it can't break out of the url('...') token even if a future caller
            // passes through unvalidated input.
            watermarkPageBgCss =
                'background-image: url(\'/sfc/servlet.shepherd/version/download/' +
                sanitizeCssUrlToken(overrideWatermarkCvId) +
                '\'); ' +
                'background-position: center center; background-repeat: no-repeat; background-size: contain;';
        }
        Map<String, String> bodyExtract = extractWatermarks(html);
        html = bodyExtract.get('html');
        if (String.isBlank(watermarkPageBgCss) && String.isNotBlank(bodyExtract.get('pageBgCss'))) {
            watermarkPageBgCss = bodyExtract.get('pageBgCss');
        }

        // Process header/footer HTML for Flying Saucer running elements
        String headerHtml = '';
        String footerHtml = '';
        String headerFirstHtml = '';
        String footerFirstHtml = '';
        if (
            String.isNotBlank(headerXml) ||
            String.isNotBlank(footerXml) ||
            String.isNotBlank(headerFirstXml) ||
            String.isNotBlank(footerFirstXml)
        ) {
            headerHtml = String.isNotBlank(headerXml) ? processBodyContent(extractBodyContent(headerXml), images) : '';
            footerHtml = String.isNotBlank(footerXml) ? processBodyContent(extractBodyContent(footerXml), images) : '';
            headerFirstHtml = String.isNotBlank(headerFirstXml)
                ? processBodyContent(extractBodyContent(headerFirstXml), images)
                : '';
            footerFirstHtml = String.isNotBlank(footerFirstXml)
                ? processBodyContent(extractBodyContent(footerFirstXml), images)
                : '';

            // Watermarks may live in any header XML (most common); pick up @page bg from there too.
            // Walk all four header/footer HTMLs in order until we find a watermark.
            for (String htmlVar : new List<String>{ 'header', 'headerFirst', 'footer', 'footerFirst' }) {
                String content;
                if (htmlVar == 'header') {
                    content = headerHtml;
                } else if (htmlVar == 'headerFirst') {
                    content = headerFirstHtml;
                } else if (htmlVar == 'footer') {
                    content = footerHtml;
                } else {
                    content = footerFirstHtml;
                }
                Map<String, String> wExtract = extractWatermarks(content);
                String stripped = wExtract.get('html');
                if (htmlVar == 'header') {
                    headerHtml = stripped;
                } else if (htmlVar == 'headerFirst') {
                    headerFirstHtml = stripped;
                } else if (htmlVar == 'footer') {
                    footerHtml = stripped;
                } else {
                    footerFirstHtml = stripped;
                }
                if (String.isBlank(watermarkPageBgCss) && String.isNotBlank(wExtract.get('pageBgCss'))) {
                    watermarkPageBgCss = wExtract.get('pageBgCss');
                }
            }

            // Zero out paragraph margins inside header/footer for tight spacing
            headerHtml = headerHtml.replace('<p>', '<p style="margin:0;">');
            footerHtml = footerHtml.replace('<p>', '<p style="margin:0;">');
            headerFirstHtml = headerFirstHtml.replace('<p>', '<p style="margin:0;">');
            footerFirstHtml = footerFirstHtml.replace('<p>', '<p style="margin:0;">');
        }

        // Build dynamic page CSS from document dimensions + styles
        Map<String, Decimal> pageDims = parsePageDimensions(documentXml);
        String cellPadding = resolveDefaultCellPadding();
        Boolean hasHeader = String.isNotBlank(headerHtml);
        Boolean hasFooter = String.isNotBlank(footerHtml);
        Boolean hasHeaderFirst = String.isNotBlank(headerFirstHtml);
        Boolean hasFooterFirst = String.isNotBlank(footerFirstHtml);

        // Check if document has a title page (Different First Page in Word)
        // <w:titlePg/> in the final <w:sectPr> means page 1 gets a separate
        // header/footer pair (or none, if no first-typed reference exists).
        Boolean hasTitlePage = isOoxmlOnOffElementTrue(documentXml, 'w:titlePg');

        // Build @page rule with running header/footer margin boxes (Flying Saucer)
        // CSS @page rule order: properties before nested margin boxes.
        // CRITICAL: the @page `size` property is EITHER `<length> <length>` for
        // explicit dimensions OR `<page-name> [landscape|portrait]` for a named
        // size. Mixing the two (e.g. `size: 11in 8.5in landscape`) is invalid
        // CSS and Flying Saucer falls back to default 8.5×11 portrait. Keep
        // the explicit-dimension form: width > height implicitly produces
        // landscape orientation through the engine's MediaBox derivation.
        String dynamicPageCss =
            '@page { size: ' +
            pageDims.get('pageWidth') +
            'in ' +
            pageDims.get('pageHeight') +
            'in; ' +
            'margin: ' +
            pageDims.get('marginTop') +
            'in ' +
            pageDims.get('marginRight') +
            'in ' +
            pageDims.get('marginBottom') +
            'in ' +
            pageDims.get('marginLeft') +
            'in;';
        if (String.isNotBlank(watermarkPageBgCss)) {
            dynamicPageCss += ' ' + watermarkPageBgCss;
        }
        if (hasHeader) {
            dynamicPageCss += ' @top-center { content: element(docgen-running-header); }';
        }
        if (hasFooter) {
            dynamicPageCss += ' @bottom-center { content: element(docgen-running-footer); }';
        }
        dynamicPageCss += ' }';

        // Title page handling. With <w:titlePg/> the doc tells us page 1 is distinct.
        // Three cases:
        //   1. Has explicit first-typed header/footer → swap in those running elements.
        //   2. Has only default pair → suppress on page 1 (legacy v1 behavior).
        //   3. No headers/footers at all → no rule needed.
        if (hasTitlePage) {
            String firstPageCss = '';
            if (hasHeaderFirst) {
                firstPageCss += '@top-center { content: element(docgen-running-header-first); }';
            } else if (hasHeader) {
                firstPageCss += '@top-center { content: normal; }';
            }
            if (hasFooterFirst) {
                firstPageCss += '@bottom-center { content: element(docgen-running-footer-first); }';
            } else if (hasFooter) {
                firstPageCss += '@bottom-center { content: normal; }';
            }
            if (String.isNotBlank(firstPageCss)) {
                dynamicPageCss += ' @page :first { ' + firstPageCss + ' }';
            }
        }

        // Running element CSS — tells Flying Saucer to pull these divs out of flow
        // and place them in the @page margin boxes on every page
        String runningCss = '';
        if (hasHeader) {
            runningCss += '#docgen-header { position: running(docgen-running-header); }';
        }
        if (hasFooter) {
            runningCss += '#docgen-footer { position: running(docgen-running-footer); }';
        }
        if (hasHeaderFirst) {
            runningCss += '#docgen-header-first { position: running(docgen-running-header-first); }';
        }
        if (hasFooterFirst) {
            runningCss += '#docgen-footer-first { position: running(docgen-running-footer-first); }';
        }

        // Check if document default style is RTL (Normal style with <w:bidi/> in styles.xml)
        // Spring '26 Blob.toPdf() uses the Visualforce PDF engine (Flying Saucer).
        // Flying Saucer does NOT properly implement Unicode Bidi Algorithm —
        // direction:rtl causes double-reversal. Use text-align:right for layout
        // and Arial Unicode MS for glyph rendering (the only multibyte-capable font).
        Boolean isDocRtl = isDefaultStyleRtl();
        String bodyFont = isDocRtl ? '\'Arial Unicode MS\', Arial, sans-serif' : 'Arial, sans-serif';

        String rtlBodyCss = isDocRtl ? ' text-align: right;' : '';
        String dynamicCss =
            dynamicPageCss +
            runningCss +
            'body { font-family: ' +
            bodyFont +
            '; font-size: 11pt; line-height: 1.15; color: #000;' +
            rtlBodyCss +
            ' }' +
            'h1 { font-size: 20pt; font-weight: bold; margin: 0 0 6pt 0; }' +
            'h2 { font-size: 16pt; font-weight: bold; margin: 0 0 4pt 0; }' +
            'h3 { font-size: 14pt; font-weight: bold; margin: 0 0 4pt 0; }' +
            'h4 { font-size: 12pt; font-weight: bold; margin: 0 0 4pt 0; }' +
            'h5 { font-size: 11pt; font-weight: bold; margin: 0 0 4pt 0; }' +
            'h6 { font-size: 10pt; font-weight: bold; margin: 0 0 4pt 0; }' +
            'h1, h2, h3, h4, h5, h6 { page-break-after: avoid; }' +
            // max-width: 100% clamps tables whose authored <w:tblW> is slightly wider
            // than the page content area (e.g. 14696tw / 10.21" on a 10" landscape area
            // with 0.5" margins). Word silently shrink-to-fits; without this clamp the
            // overflow gets clipped by Flying Saucer at the page edge.
            'table { border-collapse: collapse; width: 100%; max-width: 100%; page-break-inside: auto; }' +
            'tr { page-break-inside: avoid; page-break-after: auto; }' +
            // box-sizing: border-box matches Word's <w:tcW> semantics — the declared cell
            // width is the OUTER width (including tcMar padding). Without this the default
            // content-box adds padding on top of width, so each cell renders ~10.8pt wider
            // than authored and multi-column tables overflow the page margins.
            'td, th { padding: ' +
            cellPadding +
            '; vertical-align: top; box-sizing: border-box; }' +
            // Tight defaults: Word always emits explicit <w:spacing> when authors want
            // paragraph spacing — letting it default to 8pt produces "flabby" output the
            // author never asked for (especially noticeable in tight address blocks).
            'p { margin: 0; orphans: 2; widows: 2; page-break-inside: avoid; }' +
            'img { max-width: 100%; }' +
            'ul, ol { margin: 0; padding-left: 36pt; }' +
            'li { margin: 0; page-break-inside: avoid; }' +
            'hr { border: none; border-top: 1px solid #000; margin: 6pt 0; }' +
            'sub { vertical-align: sub; font-size: 0.8em; }' +
            'sup { vertical-align: super; font-size: 0.8em; }' +
            '.docgen-page-num::before { content: counter(page); }' +
            '.docgen-page-total::before { content: counter(pages); }' +
            '.docgen-body-content { position: relative; z-index: 2; }';
        String bodyTag = '<body>';
        String dynamicPrefix = '<html><head><meta charset="utf-8"/><style>' + dynamicCss + '</style></head>' + bodyTag;

        // Always use dynamic prefix — it has resolved page dimensions and cell padding
        // Inject font-face CSS if provided
        if (String.isNotBlank(fontFaceCss)) {
            dynamicPrefix =
                '<html><head><meta charset="utf-8"/><style>' +
                fontFaceCss +
                dynamicCss +
                '</style></head>' +
                bodyTag;
        }

        // Insert running header/footer divs at top of body — Flying Saucer pulls them
        // out of normal flow and places them in @page margin boxes on every page.
        // Watermarks render via @page background-image (set above) and never appear
        // in body DOM — that's how they extend to true page bleed.
        String bodyHtml = '';
        if (hasHeader) {
            bodyHtml += '<div id="docgen-header">' + headerHtml + '</div>';
        }
        if (hasFooter) {
            bodyHtml += '<div id="docgen-footer">' + footerHtml + '</div>';
        }
        if (hasHeaderFirst) {
            bodyHtml += '<div id="docgen-header-first">' + headerFirstHtml + '</div>';
        }
        if (hasFooterFirst) {
            bodyHtml += '<div id="docgen-footer-first">' + footerFirstHtml + '</div>';
        }
        bodyHtml += html;

        return dynamicPrefix + wrapNonLatinGlyphs(bodyHtml) + HTML_SUFFIX;
    }

    /**
     * Overload for when no images are present.
     * @param documentXml The processed word/document.xml content (post-merge)
     * @return HTML string ready for Blob.toPdf()
     */
    public static String convertToHtml(String documentXml) {
        return convertToHtml(documentXml, new Map<String, String>(), null);
    }

    /**
     * Converts DOCX XML to an HTML fragment (no html/head/body wrapper).
     * Used for rendering header/footer content separately.
     */
    public static String convertToHtmlFragment(String xml, Map<String, String> images) {
        if (String.isBlank(xml)) {
            return '';
        }
        if (images == null) {
            images = new Map<String, String>();
        }
        String bodyContent = extractBodyContent(xml);
        if (String.isBlank(bodyContent)) {
            bodyContent = xml;
        }
        return processBodyContent(bodyContent, images);
    }

    /**
     * Converts DOCX XML to HTML with header/footer positioned via CSS running elements.
     * Flying Saucer (Blob.toPdf engine) supports position:running() and @page margin boxes.
     */
    public static String convertToHtmlWithHeaderFooter(
        String documentXml,
        Map<String, String> images,
        String headerHtml,
        String footerHtml
    ) {
        if (String.isBlank(documentXml)) {
            return HTML_PREFIX + HTML_SUFFIX;
        }
        if (images == null) {
            images = new Map<String, String>();
        }

        String bodyContent = extractBodyContent(documentXml);
        String html = processBodyContent(bodyContent, images);

        // Build CSS with fixed-position header/footer for Flying Saucer
        String css =
            '@page { size: letter; margin: 1in; margin-top: ' +
            (String.isNotBlank(headerHtml) ? '1.75in' : '1in') +
            '; margin-bottom: ' +
            (String.isNotBlank(footerHtml) ? '1.75in' : '1in') +
            '; }';
        css += 'body { font-family: Arial, "Arial Unicode MS", sans-serif; font-size: 11pt; line-height: 1.15; color: #000; }';
        css += 'h1 { font-size: 20pt; font-weight: bold; margin: 0 0 6pt 0; }';
        css += 'h2 { font-size: 16pt; font-weight: bold; margin: 0 0 4pt 0; }';
        css += 'h3 { font-size: 14pt; font-weight: bold; margin: 0 0 4pt 0; }';
        css += 'h4 { font-size: 12pt; font-weight: bold; margin: 0 0 4pt 0; }';
        css += 'h5 { font-size: 11pt; font-weight: bold; margin: 0 0 4pt 0; }';
        css += 'h6 { font-size: 10pt; font-weight: bold; margin: 0 0 4pt 0; }';
        css += 'h1, h2, h3, h4, h5, h6 { page-break-after: avoid; }';
        css += 'table { border-collapse: collapse; width: 100%; page-break-inside: auto; }';
        css += 'tr { page-break-inside: avoid; page-break-after: auto; }';
        css += 'td, th { padding: 4pt; vertical-align: top; }';
        css += 'p { margin: 0 0 8pt 0; orphans: 2; widows: 2; page-break-inside: avoid; }';
        css += 'img { max-width: 100%; }';
        css += 'ul, ol { margin: 0 0 8pt 0; padding-left: 36pt; }';
        css += 'li { margin: 0 0 2pt 0; page-break-inside: avoid; }';
        css += 'hr { border: none; border-top: 1px solid #000; margin: 6pt 0; }';
        css += 'sub { vertical-align: sub; font-size: 0.8em; }';
        css += 'sup { vertical-align: super; font-size: 0.8em; }';
        css += '.docgen-header { border-bottom: 1px solid #ccc; padding-bottom: 6pt; margin-bottom: 12pt; font-size: 9pt; }';
        css += '.docgen-footer { border-top: 1px solid #ccc; padding-top: 6pt; margin-top: 12pt; font-size: 9pt; }';
        css += '.docgen-header table, .docgen-footer table { border-collapse: collapse; width: 100%; }';
        css += '.docgen-header td, .docgen-footer td { padding: 2pt; vertical-align: middle; }';

        String result = '<html><head><meta charset="utf-8"/><style>' + css + '</style></head><body>';

        if (String.isNotBlank(headerHtml)) {
            result += '<div class="docgen-header">' + headerHtml + '</div>';
        }

        result += html;

        if (String.isNotBlank(footerHtml)) {
            result += '<div class="docgen-footer">' + footerHtml + '</div>';
        }

        result += HTML_SUFFIX;
        return wrapNonLatinGlyphsInBody(result);
    }

    // Wraps body content's non-Latin glyphs without touching <head>/<style>.
    private static String wrapNonLatinGlyphsInBody(String html) {
        if (String.isBlank(html))
            return html;
        Integer bodyStart = html.indexOf('<body>');
        Integer bodyEnd = html.lastIndexOf('</body>');
        if (bodyStart == -1 || bodyEnd == -1 || bodyEnd <= bodyStart)
            return html;
        Integer contentStart = bodyStart + '<body>'.length();
        String prefix = html.substring(0, contentStart);
        String body = html.substring(contentStart, bodyEnd);
        String suffix = html.substring(bodyEnd);
        return prefix + wrapNonLatinGlyphs(body) + suffix;
    }

    @TestVisible
    private static String wrapNonLatinGlyphs(String s) {
        if (String.isBlank(s))
            return s;
        s = decodeHighCodepointEntities(s);
        Integer len = s.length();
        Boolean needsWrap = false;
        for (Integer i = 0; i < len; i++) {
            if (codepointNeedsUnicodeFont(s.charAt(i))) {
                needsWrap = true;
                break;
            }
        }
        if (!needsWrap)
            return s;

        String out = '';
        Integer i = 0;
        Boolean inTag = false;
        Integer runStart = -1;
        while (i < len) {
            Integer cp = s.charAt(i);
            if (cp == 60) {
                if (runStart >= 0) {
                    out +=
                        '<span style="font-family:\'Arial Unicode MS\', sans-serif;">' +
                        s.substring(runStart, i) +
                        '</span>';
                    runStart = -1;
                }
                inTag = true;
                out += s.substring(i, i + 1);
                i++;
                continue;
            }
            if (cp == 62) {
                inTag = false;
                out += s.substring(i, i + 1);
                i++;
                continue;
            }
            if (inTag) {
                out += s.substring(i, i + 1);
                i++;
                continue;
            }
            if (codepointNeedsUnicodeFont(cp)) {
                if (runStart < 0)
                    runStart = i;
            } else {
                if (runStart >= 0) {
                    out +=
                        '<span style="font-family:\'Arial Unicode MS\', sans-serif;">' +
                        s.substring(runStart, i) +
                        '</span>';
                    runStart = -1;
                }
                out += s.substring(i, i + 1);
            }
            i++;
        }
        if (runStart >= 0) {
            out +=
                '<span style="font-family:\'Arial Unicode MS\', sans-serif;">' +
                s.substring(runStart, len) +
                '</span>';
        }
        return out;
    }

    private static Boolean codepointNeedsUnicodeFont(Integer cp) {
        if (cp <= 591)
            return false;
        if (cp == 8211 || cp == 8212)
            return false;
        if (cp == 8216 || cp == 8217)
            return false;
        if (cp == 8220 || cp == 8221)
            return false;
        if (cp == 8226 || cp == 8230)
            return false;
        if (cp == 8224 || cp == 8225)
            return false;
        if (cp == 8482)
            return false;
        if (cp == 8364)
            return false;
        return true;
    }

    // String.escapeHtml4() converts Greek / math / dingbat Unicode chars back into
    // named HTML entities. Flying Saucer renders them, but our font-wrap scan needs
    // literal codepoints to detect chars Helvetica lacks. Decode the entities for
    // glyphs that need the Arial Unicode MS span before wrap-time.
    private static Map<String, Integer> highCodepointEntityMap;
    private static Map<String, Integer> getHighCodepointEntityMap() {
        if (highCodepointEntityMap != null)
            return highCodepointEntityMap;
        highCodepointEntityMap = new Map<String, Integer>{
            // Greek lowercase
            'alpha' => 945,
            'beta' => 946,
            'gamma' => 947,
            'delta' => 948,
            'epsilon' => 949,
            'zeta' => 950,
            'eta' => 951,
            'theta' => 952,
            'iota' => 953,
            'kappa' => 954,
            'lambda' => 955,
            'mu' => 956,
            'nu' => 957,
            'xi' => 958,
            'omicron' => 959,
            'pi' => 960,
            'rho' => 961,
            'sigmaf' => 962,
            'sigma' => 963,
            'tau' => 964,
            'upsilon' => 965,
            'phi' => 966,
            'chi' => 967,
            'psi' => 968,
            'omega' => 969,
            'thetasym' => 977,
            'upsih' => 978,
            'piv' => 982,
            // Greek uppercase
            'Alpha' => 913,
            'Beta' => 914,
            'Gamma' => 915,
            'Delta' => 916,
            'Epsilon' => 917,
            'Zeta' => 918,
            'Eta' => 919,
            'Theta' => 920,
            'Iota' => 921,
            'Kappa' => 922,
            'Lambda' => 923,
            'Mu' => 924,
            'Nu' => 925,
            'Xi' => 926,
            'Omicron' => 927,
            'Pi' => 928,
            'Rho' => 929,
            'Sigma' => 931,
            'Tau' => 932,
            'Upsilon' => 933,
            'Phi' => 934,
            'Chi' => 935,
            'Psi' => 936,
            'Omega' => 937,
            // Math operators
            'forall' => 8704,
            'part' => 8706,
            'exist' => 8707,
            'empty' => 8709,
            'nabla' => 8711,
            'isin' => 8712,
            'notin' => 8713,
            'ni' => 8715,
            'prod' => 8719,
            'sum' => 8721,
            'minus' => 8722,
            'lowast' => 8727,
            'radic' => 8730,
            'prop' => 8733,
            'infin' => 8734,
            'ang' => 8736,
            'and' => 8743,
            'or' => 8744,
            'cap' => 8745,
            'cup' => 8746,
            'int' => 8747,
            'there4' => 8756,
            'sim' => 8764,
            'cong' => 8773,
            'asymp' => 8776,
            'ne' => 8800,
            'equiv' => 8801,
            'le' => 8804,
            'ge' => 8805,
            'sub' => 8834,
            'sup' => 8835,
            'nsub' => 8836,
            'sube' => 8838,
            'supe' => 8839,
            'oplus' => 8853,
            'otimes' => 8855,
            'perp' => 8869,
            'sdot' => 8901,
            // Misc symbols
            'lceil' => 8968,
            'rceil' => 8969,
            'lfloor' => 8970,
            'rfloor' => 8971,
            'lang' => 9001,
            'rang' => 9002,
            'loz' => 9674,
            'spades' => 9824,
            'clubs' => 9827,
            'hearts' => 9829,
            'diams' => 9830,
            'larr' => 8592,
            'uarr' => 8593,
            'rarr' => 8594,
            'darr' => 8595,
            'harr' => 8596,
            'crarr' => 8629,
            'lArr' => 8656,
            'uArr' => 8657,
            'rArr' => 8658,
            'dArr' => 8659,
            'hArr' => 8660
        };
        return highCodepointEntityMap;
    }

    private static String decodeHighCodepointEntities(String s) {
        if (String.isBlank(s) || s.indexOf('&') == -1)
            return s;
        Map<String, Integer> entityMap = getHighCodepointEntityMap();
        for (String name : entityMap.keySet()) {
            String token = '&' + name + ';';
            if (s.contains(token)) {
                s = s.replace(token, String.fromCharArray(new List<Integer>{ entityMap.get(name) }));
            }
        }
        return s;
    }

    /**
     * Extracts content from <w:hdr>, <w:body>, and <w:ftr> tags.
     */
    private static String extractBodyContent(String xml) {
        String combinedContent = '';

        // 1. Extract all headers
        Integer cursor = 0;
        while ((cursor = xml.indexOf('<w:hdr', cursor)) != -1) {
            Integer tagEnd = xml.indexOf('>', cursor);
            if (tagEnd == -1) {
                break;
            }
            Integer hdrEnd = findClosingTag(xml, cursor, 'w:hdr');
            if (hdrEnd != -1) {
                combinedContent += xml.substring(tagEnd + 1, hdrEnd);
                cursor = hdrEnd;
            } else {
                cursor = tagEnd + 1;
            }
        }

        // 2. Extract main body
        Integer bodyStart = xml.indexOf('<w:body');
        if (bodyStart != -1) {
            Integer bodyContentStart = xml.indexOf('>', bodyStart) + 1;
            Integer bodyEnd = xml.lastIndexOf('</w:body>');
            if (bodyEnd != -1) {
                String content = xml.substring(bodyContentStart, bodyEnd);
                // Handle <w:sectPr> elements in the body:
                // - Mid-body sectPr = section break → replace with page break marker
                // - Final sectPr = document-level settings → strip entirely
                // sectPr can appear inside <w:pPr> (paragraph properties) or standalone.
                // When inside <w:pPr>, just remove it — the containing paragraph handles spacing.
                // When standalone or the only content in a paragraph, replace with a page break.
                Integer sectCursor = 0;
                String processedContent = '';
                while (sectCursor < content.length()) {
                    Integer sectStart = content.indexOf('<w:sectPr', sectCursor);
                    if (sectStart == -1) {
                        processedContent += content.substring(sectCursor);
                        break;
                    }
                    Integer sectEnd = content.indexOf('</w:sectPr>', sectStart);
                    if (sectEnd == -1) {
                        sectEnd = content.indexOf('/>', sectStart);
                        if (sectEnd != -1) {
                            sectEnd += 2;
                        } else {
                            processedContent += content.substring(sectCursor);
                            break;
                        }
                    } else {
                        sectEnd += 11;
                    }
                    processedContent += content.substring(sectCursor, sectStart);
                    Boolean isLast = content.indexOf('<w:sectPr', sectEnd) == -1;
                    if (!isLast) {
                        // Mid-body section break — insert a page break run into the current context.
                        // If inside a <w:pPr>, just add a page break run after the paragraph closes.
                        // The sectPr is removed; the containing paragraph gets a page-break-after.
                        processedContent += '<w:docgen-section-break/>';
                    }
                    sectCursor = sectEnd;
                }
                content = processedContent;
                combinedContent += content;
            } else {
                combinedContent += xml.substring(bodyContentStart);
            }
        } else if (!xml.contains('<w:hdr') && !xml.contains('<w:ftr')) {
            // Fallback for raw content
            combinedContent = xml;
        }

        // 3. Extract all footers
        cursor = 0;
        while ((cursor = xml.indexOf('<w:ftr', cursor)) != -1) {
            Integer tagEnd = xml.indexOf('>', cursor);
            if (tagEnd == -1) {
                break;
            }
            Integer ftrEnd = findClosingTag(xml, cursor, 'w:ftr');
            if (ftrEnd != -1) {
                combinedContent += xml.substring(tagEnd + 1, ftrEnd);
                cursor = ftrEnd;
            } else {
                cursor = tagEnd + 1;
            }
        }

        return combinedContent;
    }

    /**
     * Processes body-level DOCX XML elements into HTML.
     * Handles consecutive list paragraphs by wrapping them in <ul>/<ol>.
     */
    private static String processBodyContent(String xml, Map<String, String> images) {
        // First pass: collect all paragraphs and tables in order
        List<String> elements = new List<String>();
        List<String> elementTypes = new List<String>(); // 'p' or 'tbl'
        Integer cursor = 0;

        while (cursor < xml.length()) {
            Integer nextTag = xml.indexOf('<', cursor);
            if (nextTag == -1) {
                break;
            }
            cursor = nextTag;

            if (xml.substring(cursor).startsWith('<w:tbl')) {
                Integer tblEnd = findClosingTag(xml, cursor, 'w:tbl');
                if (tblEnd != -1) {
                    elements.add(xml.substring(cursor, tblEnd));
                    elementTypes.add('tbl');
                    cursor = tblEnd;
                } else {
                    cursor++;
                }
            } else if (
                xml.substring(cursor).startsWith('<w:p ') ||
                xml.substring(cursor).startsWith('<w:p>') ||
                xml.substring(cursor).startsWith('<w:p/>')
            ) {
                Integer pEnd = findClosingTag(xml, cursor, 'w:p');
                if (pEnd != -1) {
                    elements.add(xml.substring(cursor, pEnd));
                    elementTypes.add('p');
                    cursor = pEnd;
                } else {
                    cursor++;
                }
            } else {
                Integer tagEnd = xml.indexOf('>', cursor);
                if (tagEnd != -1) {
                    cursor = tagEnd + 1;
                } else {
                    break;
                }
            }
        }

        // Second pass: render elements, grouping consecutive list paragraphs
        String result = '';
        Integer i = 0;
        while (i < elements.size()) {
            if (elementTypes[i] == 'tbl') {
                result += processTable(elements[i], images);
                i++;
            } else {
                // Check if this paragraph is a list item
                ListInfo li = getListInfo(elements[i]);
                if (li.isList) {
                    // Collect consecutive list paragraphs
                    List<String> listItems = new List<String>();
                    Boolean isNumbered = li.isNumbered;
                    listItems.add(elements[i]);
                    Integer j = i + 1;
                    while (j < elements.size() && elementTypes[j] == 'p') {
                        ListInfo nextLi = getListInfo(elements[j]);
                        if (!nextLi.isList) {
                            break;
                        }
                        listItems.add(elements[j]);
                        j++;
                    }
                    result += renderList(listItems, isNumbered, images);
                    i = j;
                } else {
                    result += processParagraph(elements[i], images);
                    i++;
                }
            }
        }

        return result;
    }

    /**
     * Detects if a paragraph is a list item by checking for w:numPr or list-style pStyle.
     */
    private static ListInfo getListInfo(String pXml) {
        ListInfo li = new ListInfo();
        li.isList = false;
        li.isNumbered = false;

        String pPr = extractElement(pXml, 'w:pPr');
        if (String.isBlank(pPr)) {
            return li;
        }

        // Check for explicit numbering properties
        if (pPr.contains('<w:numPr')) {
            li.isList = true;
            // numId 0 means "no list" in OOXML
            String numId = extractAttr(pPr, 'w:numId', 'w:val');
            if (numId == '0') {
                li.isList = false;
                return li;
            }
            // Determine list type from numbering.xml definitions
            String ilvl = extractAttr(pPr, 'w:ilvl', 'w:val');
            if (ilvl == null) {
                ilvl = '0';
            }
            li.isNumbered = isNumberedList(numId, ilvl);
            return li;
        }

        // Check for list paragraph style
        String pStyleVal = extractAttr(pPr, 'w:pStyle', 'w:val');
        if (pStyleVal != null && LIST_STYLE_IDS.contains(pStyleVal)) {
            li.isList = true;
            li.isNumbered = pStyleVal.containsIgnoreCase('Number');
        }

        return li;
    }

    /**
     * Renders a group of consecutive list paragraphs as <ul> or <ol>.
     */
    private static String renderList(List<String> listItems, Boolean isNumbered, Map<String, String> images) {
        String tag = isNumbered ? 'ol' : 'ul';
        String result = '<' + tag + '>';
        for (String pXml : listItems) {
            String content = processRuns(pXml, images);
            if (String.isBlank(content)) {
                content = '&nbsp;';
            }

            // Extract paragraph-level styles for the <li>
            String pPr = extractElement(pXml, 'w:pPr');
            String style = '';
            if (String.isNotBlank(pPr)) {
                style = parseParagraphStyle(pPr);
            }

            result += '<li' + (String.isNotBlank(style) ? ' style="' + style + '"' : '') + '>' + content + '</li>';
        }
        result += '</' + tag + '>';
        return result;
    }

    /**
     * Processes a <w:p> element into an HTML paragraph, heading, or horizontal rule.
     */
    private static String processParagraph(String pXml, Map<String, String> images) {
        String style = '';
        Integer headingLevel = 0;
        Boolean pageBreakBefore = false;
        Boolean isTitle = false;
        // RTL: explicit <w:bidi/> on paragraph OR inherited from Normal style
        Boolean isRtl = isDefaultStyleRtl();

        // Extract paragraph properties
        String pPr = extractElement(pXml, 'w:pPr');
        if (String.isNotBlank(pPr)) {
            style = parseParagraphStyle(pPr);
            if (isOoxmlOnOffElementTrue(pPr, 'w:bidi')) {
                isRtl = true;
            }

            // Check for heading style
            String pStyleVal = extractAttr(pPr, 'w:pStyle', 'w:val');
            if (pStyleVal != null) {
                if (HEADING_STYLE_MAP.containsKey(pStyleVal)) {
                    headingLevel = HEADING_STYLE_MAP.get(pStyleVal);
                } else if (pStyleVal == 'Title' || pStyleVal == 'title') {
                    isTitle = true;
                } else if (pStyleVal == 'Subtitle' || pStyleVal == 'subtitle') {
                    // Render subtitle as styled paragraph
                    style += (String.isNotBlank(style) ? ';' : '') + 'font-size:14pt;color:#595959';
                }
                // Resolve additional attributes (color, font) from the referenced style —
                // applied at paragraph level so runs without explicit rPr inherit them. Inline
                // rPr on runs still overrides these via parseRunStyle.
                Map<String, String> pAttrs = resolveStyleTextAttributes(pStyleVal);
                if (pAttrs.containsKey('color')) {
                    style += (String.isNotBlank(style) ? ';' : '') + 'color:#' + pAttrs.get('color');
                }
                if (pAttrs.containsKey('fontFamily')) {
                    style +=
                        (String.isNotBlank(style) ? ';' : '') +
                        'font-family:\'' +
                        pAttrs.get('fontFamily').escapeHtml4() +
                        '\',sans-serif';
                }
            }

            // Check for page break before
            if (isOoxmlOnOffElementTrue(pPr, 'w:pageBreakBefore')) {
                pageBreakBefore = true;
            }
        }

        // Section break marker (injected by extractBodyContent for mid-body w:sectPr)
        Boolean sectionBreakAfter = pXml.contains('<w:docgen-section-break/>');

        // Process runs — for RTL paragraphs, reverse run order so first run (rightmost) renders last in HTML
        String content = processRuns(pXml, images, isRtl);

        // Check for page break in runs (w:br w:type="page")
        if (pXml.contains('w:type="page"') || pXml.contains('w:type=\'page\'')) {
            pageBreakBefore = true;
        }

        // Empty paragraph with bottom border = horizontal rule
        if (String.isBlank(content) && String.isNotBlank(pPr) && pPr.contains('<w:pBdr')) {
            String bottomBdr = extractElement(pPr, 'w:bottom');
            String bdrVal = extractAttr(bottomBdr, 'w:bottom', 'w:val');
            if (String.isNotBlank(bottomBdr) && bdrVal != 'nil' && bdrVal != 'none') {
                return (pageBreakBefore ? '<div style="page-break-before:always"></div>' : '') + '<hr/>';
            }
        }

        String pageBreakDiv = pageBreakBefore ? '<div style="page-break-before:always"></div>' : '';

        // Section break after this paragraph (mid-body w:sectPr)
        if (sectionBreakAfter) {
            style += (String.isNotBlank(style) ? ';' : '') + 'page-break-after:always';
        }

        // Empty paragraph = line break
        if (String.isBlank(content)) {
            return pageBreakDiv + '<p' + (String.isNotBlank(style) ? ' style="' + style + '"' : '') + '>&nbsp;</p>';
        }

        // Heading
        if (headingLevel > 0) {
            String tag = 'h' + headingLevel;
            return pageBreakDiv +
                '<' +
                tag +
                (String.isNotBlank(style) ? ' style="' + style + '"' : '') +
                '>' +
                content +
                '</' +
                tag +
                '>';
        }

        // Title style
        if (isTitle) {
            return pageBreakDiv +
                '<h1 style="font-size:26pt;font-weight:normal' +
                (String.isNotBlank(style) ? ';' + style : '') +
                '">' +
                content +
                '</h1>';
        }

        return pageBreakDiv +
            '<p' +
            (String.isNotBlank(style) ? ' style="' + style + '"' : '') +
            '>' +
            content +
            '</p>';
    }

    /**
     * Parses <w:pPr> into CSS style string.
     */
    private static String parseParagraphStyle(String pPr) {
        List<String> styles = new List<String>();

        // RTL / Bidi: <w:bidi/> marks right-to-left paragraph (Hebrew, Arabic)
        // Flying Saucer: use text-align:right (not direction:rtl which causes double-reversal)
        if (isOoxmlOnOffElementTrue(pPr, 'w:bidi')) {
            styles.add('text-align:right');
        }

        // Alignment: <w:jc w:val="center"/>
        String jcVal = extractAttr(pPr, 'w:jc', 'w:val');
        if (jcVal != null) {
            if (jcVal == 'center') {
                styles.add('text-align:center');
            } else if (jcVal == 'right' || jcVal == 'end') {
                styles.add('text-align:right');
            } else if (jcVal == 'both' || jcVal == 'distribute') {
                styles.add('text-align:justify');
            }
        }

        // Spacing: <w:spacing w:before="120" w:after="120" w:line="240" w:lineRule="auto"/>
        String spacingBefore = extractAttr(pPr, 'w:spacing', 'w:before');
        if (spacingBefore != null && spacingBefore.isNumeric()) {
            styles.add('margin-top:' + twipsToPt(Integer.valueOf(spacingBefore)) + 'pt');
        }
        String spacingAfter = extractAttr(pPr, 'w:spacing', 'w:after');
        if (spacingAfter != null && spacingAfter.isNumeric()) {
            styles.add('margin-bottom:' + twipsToPt(Integer.valueOf(spacingAfter)) + 'pt');
        }

        // Line spacing: <w:spacing w:line="360" w:lineRule="auto"/>
        // In "auto" mode: 240 = single, 360 = 1.5, 480 = double
        // In "exact"/"atLeast" mode: value is in twips
        String lineSpacing = extractAttr(pPr, 'w:spacing', 'w:line');
        String lineRule = extractAttr(pPr, 'w:spacing', 'w:lineRule');
        if (lineSpacing != null && lineSpacing.isNumeric()) {
            Integer lineVal = Integer.valueOf(lineSpacing);
            if (lineRule == 'exact' || lineRule == 'atLeast') {
                styles.add('line-height:' + twipsToPt(lineVal) + 'pt');
            } else {
                // "auto" or default — value/240 gives the multiplier
                Decimal multiplier = lineVal / 240.0;
                styles.add('line-height:' + multiplier);
            }
        }

        // Indent: <w:ind w:left="720" w:right="0" w:firstLine="360" w:hanging="360"/>
        // Also supports bidi-aware w:start/w:end as fallback for w:left/w:right
        String indLeft = extractAttr(pPr, 'w:ind', 'w:left');
        if (indLeft == null) {
            indLeft = extractAttr(pPr, 'w:ind', 'w:start');
        }
        String indHanging = extractAttr(pPr, 'w:ind', 'w:hanging');
        if (indLeft != null && indLeft.isNumeric()) {
            styles.add('margin-left:' + twipsToPt(Integer.valueOf(indLeft)) + 'pt');
        }
        String indRight = extractAttr(pPr, 'w:ind', 'w:right');
        if (indRight == null) {
            indRight = extractAttr(pPr, 'w:ind', 'w:end');
        }
        if (indRight != null && indRight.isNumeric()) {
            styles.add('margin-right:' + twipsToPt(Integer.valueOf(indRight)) + 'pt');
        }
        String indFirst = extractAttr(pPr, 'w:ind', 'w:firstLine');
        if (indFirst != null && indFirst.isNumeric()) {
            styles.add('text-indent:' + twipsToPt(Integer.valueOf(indFirst)) + 'pt');
        }
        // Hanging indent: negative text-indent
        if (indHanging != null && indHanging.isNumeric()) {
            Decimal hangPt = twipsToPt(Integer.valueOf(indHanging));
            styles.add('text-indent:-' + hangPt + 'pt');
            // If no explicit left indent, add padding to compensate
            if (indLeft == null) {
                styles.add('padding-left:' + hangPt + 'pt');
            }
        }

        // Paragraph shading: <w:shd w:val="clear" w:fill="FFFF00"/>
        String pFill = extractAttr(pPr, 'w:shd', 'w:fill');
        if (pFill != null && pFill != 'auto') {
            styles.add('background-color:#' + sanitizeCssToken(pFill));
        }

        // Paragraph borders: <w:pBdr><w:top w:val="single" w:sz="4" w:color="000000"/>...
        if (pPr.contains('<w:pBdr')) {
            String pBdr = extractElement(pPr, 'w:pBdr');
            if (String.isNotBlank(pBdr)) {
                String topBdr = parseBorderSide(pBdr, 'w:top');
                String bottomBdr = parseBorderSide(pBdr, 'w:bottom');
                String leftBdr = parseBorderSide(pBdr, 'w:left');
                String rightBdr = parseBorderSide(pBdr, 'w:right');

                if (String.isNotBlank(topBdr) && topBdr != 'none' && topBdr != 'nil') {
                    styles.add('border-top:' + topBdr);
                }
                if (String.isNotBlank(bottomBdr) && bottomBdr != 'none' && bottomBdr != 'nil') {
                    styles.add('border-bottom:' + bottomBdr);
                }
                if (String.isNotBlank(leftBdr) && leftBdr != 'none' && leftBdr != 'nil') {
                    styles.add('border-left:' + leftBdr);
                }
                if (String.isNotBlank(rightBdr) && rightBdr != 'none' && rightBdr != 'nil') {
                    styles.add('border-right:' + rightBdr);
                }

                if (
                    (String.isNotBlank(topBdr) &&
                    topBdr != 'none' &&
                    topBdr != 'nil') ||
                    (String.isNotBlank(bottomBdr) &&
                    bottomBdr != 'none' &&
                    bottomBdr != 'nil') ||
                    (String.isNotBlank(leftBdr) &&
                    leftBdr != 'none' &&
                    leftBdr != 'nil') ||
                    (String.isNotBlank(rightBdr) &&
                    rightBdr != 'none' &&
                    rightBdr != 'nil')
                ) {
                    styles.add('padding:4pt');
                }
            }
        }

        // Keep with next (avoid page break after this paragraph)
        if (isOoxmlOnOffElementTrue(pPr, 'w:keepNext')) {
            styles.add('page-break-after:avoid');
        }

        // Keep lines together (avoid page break inside this paragraph)
        if (isOoxmlOnOffElementTrue(pPr, 'w:keepLines')) {
            styles.add('page-break-inside:avoid');
        }

        return String.join(styles, ';');
    }

    /**
     * Parses a single border shorthand from a tcBorders element.
     * E.g., <w:top w:val="single" w:sz="4" w:color="000000"/> → "1pt solid #000000"
     */
    private static String parseBorderSide(String bdrXml, String side) {
        String val = extractAttr(bdrXml, side, 'w:val');
        if (val == null || val == 'none' || val == 'nil') {
            return null;
        }

        String sz = extractAttr(bdrXml, side, 'w:sz');
        String color = extractAttr(bdrXml, side, 'w:color');

        // sz is in 8ths of a point
        Decimal widthPt = 1;
        if (sz != null && sz.isNumeric()) {
            widthPt = Integer.valueOf(sz) / 8.0;
            if (widthPt < 0.5) {
                widthPt = 0.5;
            }
        }

        String cssColor = '#000000';
        if (color != null && color != 'auto') {
            cssColor = '#' + color;
        }

        // Map common Word border styles to CSS
        String cssStyle = 'solid';
        if (val == 'dashed' || val == 'dashSmallGap') {
            cssStyle = 'dashed';
        } else if (val == 'dotted') {
            cssStyle = 'dotted';
        } else if (val == 'double') {
            cssStyle = 'double';
        }

        return widthPt + 'pt ' + cssStyle + ' ' + cssColor;
    }

    /**
     * Processes all <w:r> (run) elements within a paragraph.
     */
    private static String processRuns(String pXml, Map<String, String> images) {
        return processRuns(pXml, images, false);
    }

    private static String processRuns(String pXml, Map<String, String> images, Boolean isRtlParagraph) {
        // Resolve Word field codes (PAGE, NUMPAGES) that span multiple runs.
        // Field structure: <w:fldChar begin/> ... <w:instrText> PAGE </w:instrText> ...
        // <w:fldChar separate/> ... cached value ... <w:fldChar end/>
        // Also handles <w:fldSimple w:instr=" PAGE ">...</w:fldSimple>
        pXml = resolveFieldCodes(pXml);

        List<String> parts = new List<String>();
        Integer cursor = 0;

        while (cursor < pXml.length()) {
            Integer runStart = pXml.indexOf('<w:r>', cursor);
            Integer runStart2 = pXml.indexOf('<w:r ', cursor);
            Integer drawingStart = pXml.indexOf('<w:drawing>', cursor);
            Integer drawingStart2 = pXml.indexOf('<w:drawing ', cursor);
            Integer pictStart = pXml.indexOf('<w:pict>', cursor);
            Integer pictStart2 = pXml.indexOf('<w:pict ', cursor);
            Integer hyperlinkStart = pXml.indexOf('<w:hyperlink', cursor);

            Integer nextRun = -1;
            if (runStart != -1 && runStart2 != -1) {
                nextRun = Math.min(runStart, runStart2);
            } else if (runStart != -1) {
                nextRun = runStart;
            } else if (runStart2 != -1) {
                nextRun = runStart2;
            }

            Integer nextDrawing = -1;
            if (drawingStart != -1 && drawingStart2 != -1) {
                nextDrawing = Math.min(drawingStart, drawingStart2);
            } else if (drawingStart != -1) {
                nextDrawing = drawingStart;
            } else if (drawingStart2 != -1) {
                nextDrawing = drawingStart2;
            }

            Integer nextPict = -1;
            if (pictStart != -1 && pictStart2 != -1) {
                nextPict = Math.min(pictStart, pictStart2);
            } else if (pictStart != -1) {
                nextPict = pictStart;
            } else if (pictStart2 != -1) {
                nextPict = pictStart2;
            }

            Integer nextElement = -1;
            String elementType = '';
            if (nextRun != -1) {
                nextElement = nextRun;
                elementType = 'run';
            }
            if (nextDrawing != -1 && (nextElement == -1 || nextDrawing < nextElement)) {
                nextElement = nextDrawing;
                elementType = 'drawing';
            }
            if (nextPict != -1 && (nextElement == -1 || nextPict < nextElement)) {
                nextElement = nextPict;
                elementType = 'pict';
            }
            if (hyperlinkStart != -1 && (nextElement == -1 || hyperlinkStart < nextElement)) {
                nextElement = hyperlinkStart;
                elementType = 'hyperlink';
            }
            if (nextElement == -1) {
                break;
            }

            if (elementType == 'run') {
                Integer runEnd = findClosingTag(pXml, nextRun, 'w:r');
                if (runEnd != -1) {
                    parts.add(processRun(pXml.substring(nextRun, runEnd), images));
                    cursor = runEnd;
                } else {
                    cursor = nextRun + 1;
                }
            } else if (elementType == 'drawing') {
                Integer drawEnd = findClosingTag(pXml, nextDrawing, 'w:drawing');
                if (drawEnd != -1) {
                    parts.add(processDrawing(pXml.substring(nextDrawing, drawEnd), images));
                    cursor = drawEnd;
                } else {
                    cursor = nextDrawing + 1;
                }
            } else if (elementType == 'pict') {
                Integer pictEnd = findClosingTag(pXml, nextPict, 'w:pict');
                if (pictEnd != -1) {
                    parts.add(processPict(pXml.substring(nextPict, pictEnd), images));
                    cursor = pictEnd;
                } else {
                    cursor = nextPict + 1;
                }
            } else if (elementType == 'hyperlink') {
                Integer hlEnd = findClosingTag(pXml, hyperlinkStart, 'w:hyperlink');
                if (hlEnd != -1) {
                    parts.add(processHyperlink(pXml.substring(hyperlinkStart, hlEnd), images));
                    cursor = hlEnd;
                } else {
                    cursor = hyperlinkStart + 1;
                }
            }
        }

        // RTL paragraph: reverse run order so first run (rightmost) renders last in LTR HTML
        if (isRtlParagraph && parts.size() > 1) {
            List<String> reversed = new List<String>();
            for (Integer i = parts.size() - 1; i >= 0; i--) {
                reversed.add(parts[i]);
            }
            parts = reversed;
        }

        return String.join(parts, '');
    }

    /**
     * Processes a <w:hyperlink> element — extracts inner runs and wraps in <a> if possible.
     */
    private static String processHyperlink(String hlXml, Map<String, String> images) {
        // Hyperlinks may have an anchor (bookmark) or r:id (external link).
        // We can't resolve r:id without the .rels file, so render the text with underline styling.
        String innerContent = '';
        Integer cursor = 0;
        while (cursor < hlXml.length()) {
            Integer runStart = hlXml.indexOf('<w:r>', cursor);
            Integer runStart2 = hlXml.indexOf('<w:r ', cursor);
            Integer nextRun = -1;
            if (runStart != -1 && runStart2 != -1) {
                nextRun = Math.min(runStart, runStart2);
            } else if (runStart != -1) {
                nextRun = runStart;
            } else if (runStart2 != -1) {
                nextRun = runStart2;
            }
            if (nextRun == -1) {
                break;
            }

            Integer runEnd = findClosingTag(hlXml, nextRun, 'w:r');
            if (runEnd != -1) {
                innerContent += processRun(hlXml.substring(nextRun, runEnd), images);
                cursor = runEnd;
            } else {
                cursor = nextRun + 1;
            }
        }

        if (String.isBlank(innerContent)) {
            return '';
        }

        // Check for direct URL from rich text (custom attribute set by DocGenService)
        String directUrl = null;
        Integer urlAttr = hlXml.indexOf('w:docgen-url="');
        if (urlAttr != -1) {
            Integer urlStart = urlAttr + 14;
            Integer urlEnd = hlXml.indexOf('"', urlStart);
            if (urlEnd != -1) {
                directUrl = hlXml.substring(urlStart, urlEnd);
            }
        }

        if (String.isNotBlank(directUrl)) {
            return '<a href="' +
                directUrl +
                '" style="color:#0563C1;text-decoration:underline">' +
                innerContent +
                '</a>';
        }
        // No URL available (template hyperlink without rels) — render as styled text
        return '<span style="color:#0563C1;text-decoration:underline">' + innerContent + '</span>';
    }

    /**
     * Processes a single <w:r> (run) element into an HTML <span>.
     */
    private static String processRun(String rXml, Map<String, String> images) {
        // Extract run properties
        String rPr = extractElement(rXml, 'w:rPr');
        String style = (String.isNotBlank(rPr)) ? parseRunStyle(rPr) : '';
        // RTL run: Flying Saucer renders all chars LTR, so we reverse RTL text in Apex
        Boolean isRtlRun = String.isNotBlank(rPr) && isOoxmlOnOffElementTrue(rPr, 'w:rtl');

        String openTags = '';
        String closeTags = '';
        if (String.isNotBlank(rPr)) {
            // Bold
            if (isOoxmlOnOffElementTrue(rPr, 'w:b')) {
                openTags += '<b>';
                closeTags = '</b>' + closeTags;
            }
            // Italic
            if (isOoxmlOnOffElementTrue(rPr, 'w:i')) {
                openTags += '<i>';
                closeTags = '</i>' + closeTags;
            }
            // Underline: w:u takes a value enum (single/double/none/...) rather than on/off,
            // so don't route through isOoxmlOnOffElementTrue. "none" disables it.
            String uVal = extractAttr(rPr, 'w:u', 'w:val');
            if (uVal != null && uVal != 'none') {
                openTags += '<u>';
                closeTags = '</u>' + closeTags;
            }
            // Strikethrough
            if (isOoxmlOnOffElementTrue(rPr, 'w:strike')) {
                openTags += '<s>';
                closeTags = '</s>' + closeTags;
            }
            // Superscript / Subscript
            String vertAlign = extractAttr(rPr, 'w:vertAlign', 'w:val');
            if (vertAlign == 'superscript') {
                openTags += '<sup>';
                closeTags = '</sup>' + closeTags;
            } else if (vertAlign == 'subscript') {
                openTags += '<sub>';
                closeTags = '</sub>' + closeTags;
            }
        }

        String runContent = '';
        Integer cursor = 0;

        // Walk through the run elements in order
        while (cursor < rXml.length()) {
            Integer nextBr = rXml.indexOf('<w:br', cursor);
            Integer nextTab = rXml.indexOf('<w:tab', cursor);
            Integer nextDrawing = rXml.indexOf('<w:drawing', cursor);
            Integer nextPict = rXml.indexOf('<w:pict', cursor);
            Integer nextSym = rXml.indexOf('<w:sym', cursor);
            // Find <w:t> or <w:t  but NOT <w:tab — indexOf('<w:t') false-matches <w:tab
            Integer nextT = -1;
            Integer tSearch = cursor;
            while (tSearch < rXml.length()) {
                Integer candidate = rXml.indexOf('<w:t', tSearch);
                if (candidate == -1) {
                    break;
                }
                Integer afterTag = candidate + 4;
                if (afterTag < rXml.length()) {
                    String ch = rXml.substring(afterTag, afterTag + 1);
                    if (ch == '>' || ch == ' ') {
                        nextT = candidate;
                        break;
                    }
                }
                tSearch = afterTag;
            }

            // Find the earliest element
            Integer nextPos = -1;
            String type = '';

            if (nextT != -1 && (nextPos == -1 || nextT < nextPos)) {
                nextPos = nextT;
                type = 't';
            }
            if (nextBr != -1 && (nextPos == -1 || nextBr < nextPos)) {
                nextPos = nextBr;
                type = 'br';
            }
            if (nextTab != -1 && (nextPos == -1 || nextTab < nextPos)) {
                nextPos = nextTab;
                type = 'tab';
            }
            if (nextDrawing != -1 && (nextPos == -1 || nextDrawing < nextPos)) {
                nextPos = nextDrawing;
                type = 'drawing';
            }
            if (nextPict != -1 && (nextPos == -1 || nextPict < nextPos)) {
                nextPos = nextPict;
                type = 'pict';
            }
            if (nextSym != -1 && (nextPos == -1 || nextSym < nextPos)) {
                nextPos = nextSym;
                type = 'sym';
            }

            if (nextPos == -1) {
                break;
            }

            if (type == 't') {
                Integer tagEnd = rXml.indexOf('>', nextPos);
                if (tagEnd != -1 && rXml.substring(tagEnd - 1, tagEnd) != '/') {
                    Integer tEnd = rXml.indexOf('</w:t>', tagEnd);
                    if (tEnd != -1) {
                        String text = unescapeXmlEntities(rXml.substring(tagEnd + 1, tEnd));
                        if (text.contains('<span class="docgen-page-')) {
                            // Page counter spans — pass through as raw HTML (injected by resolveFieldCodes)
                            runContent += text;
                        } else if (text.contains('##BARCODE:')) {
                            runContent += renderBarcodeHtml(text);
                        } else {
                            // Check for caps in rPr
                            if (String.isNotBlank(rPr)) {
                                if (isOoxmlOnOffElementTrue(rPr, 'w:caps')) {
                                    text = text.toUpperCase();
                                }
                                if (isOoxmlOnOffElementTrue(rPr, 'w:smallCaps')) {
                                    text = text.toUpperCase();
                                    if (!style.contains('font-variant:small-caps')) {
                                        style += (String.isNotBlank(style) ? ';' : '') + 'font-variant:small-caps';
                                    }
                                }
                            }
                            if (isRtlRun) {
                                text = reverseRtlText(text);
                            }
                            runContent += wrapUnicodeCheckmarks(text.escapeHtml4());
                        }
                        cursor = tEnd + 6;
                    } else {
                        cursor = tagEnd + 1;
                    }
                } else {
                    cursor = (tagEnd != -1) ? tagEnd + 1 : nextPos + 1;
                }
            } else if (type == 'br') {
                if (rXml.substring(nextPos).contains('w:type="page"')) {
                    runContent += '<div style="page-break-before:always"></div>';
                } else if (rXml.substring(nextPos).contains('w:type="column"')) {
                    runContent += '<br/>';
                } else {
                    runContent += '<br/>';
                }
                Integer tagEnd = rXml.indexOf('>', nextPos);
                cursor = (tagEnd != -1) ? tagEnd + 1 : nextPos + 1;
            } else if (type == 'tab') {
                runContent += '<span style="display:inline-block;width:36pt"></span>';
                Integer tagEnd = rXml.indexOf('>', nextPos);
                cursor = (tagEnd != -1) ? tagEnd + 1 : nextPos + 1;
            } else if (type == 'drawing') {
                Integer drawEnd = findClosingTag(rXml, nextDrawing, 'w:drawing');
                if (drawEnd != -1) {
                    runContent += processDrawing(rXml.substring(nextDrawing, drawEnd), images);
                    cursor = drawEnd;
                } else {
                    cursor = nextDrawing + 1;
                }
            } else if (type == 'pict') {
                Integer pictEnd = findClosingTag(rXml, nextPict, 'w:pict');
                if (pictEnd != -1) {
                    runContent += processPict(rXml.substring(nextPict, pictEnd), images);
                    cursor = pictEnd;
                } else {
                    cursor = nextPict + 1;
                }
            } else if (type == 'sym') {
                Integer tagEnd = rXml.indexOf('>', nextPos);
                if (tagEnd != -1) {
                    runContent += processSym(rXml.substring(nextPos, tagEnd + 1));
                    cursor = tagEnd + 1;
                } else {
                    cursor = nextPos + 1;
                }
            }
        }

        if (runContent.length() == 0) {
            return '';
        }

        if (String.isNotBlank(style)) {
            return '<span style="' + style + '">' + openTags + runContent + closeTags + '</span>';
        }
        return openTags + runContent + closeTags;
    }

    // Wingdings/Symbol → Unicode for checkbox/check glyphs. Flying Saucer can't render
    // Wingdings at all, but Arial Unicode MS covers the equivalent Unicode codepoints.
    private static final Map<String, String> SYM_MAP = new Map<String, String>{
        'Wingdings|F0A8' => '☐', // empty box
        'Wingdings|F0FE' => '☑', // checked box
        'Wingdings|F0FD' => '☒', // x'd box
        'Wingdings|F0A2' => '✗', // ballot x
        'Wingdings|F0FC' => '✓', // check
        'Wingdings|F0FB' => '✔', // heavy check
        'Wingdings 2|F050' => '✗',
        'Wingdings 2|F051' => '✘',
        'Wingdings 2|F052' => '✓',
        'Wingdings 2|F053' => '✔',
        'Wingdings 2|F0A3' => '☐',
        'Wingdings 2|F0A4' => '☑',
        'Symbol|F0FC' => '✓'
    };

    private static final String[] CHECKMARK_CHARS = new List<String>{ '☐', '☑', '☒', '✓', '✔', '✗', '✘' };

    private static String processSym(String symXml) {
        String font = extractAttr(symXml, 'w:sym', 'w:font');
        String ch = extractAttr(symXml, 'w:sym', 'w:char');
        if (String.isBlank(ch))
            return '';
        ch = ch.toUpperCase();
        String key = (String.isBlank(font) ? '' : font) + '|' + ch;
        String mapped = SYM_MAP.get(key);
        if (mapped == null) {
            // Unknown Wingdings glyph — emit a neutral placeholder rather than tofu
            return '<span style="font-family:\'Arial Unicode MS\', sans-serif;">□</span>';
        }
        return '<span style="font-family:\'Arial Unicode MS\', sans-serif;">' + mapped + '</span>';
    }

    private static String wrapUnicodeCheckmarks(String s) {
        if (String.isBlank(s))
            return s;
        for (String c : CHECKMARK_CHARS) {
            if (s.contains(c)) {
                s = s.replace(c, '<span style="font-family:\'Arial Unicode MS\', sans-serif;">' + c + '</span>');
            }
        }
        return s;
    }

    /**
     * Processes a run containing a tab character into HTML.
     * Renders the tab as a fixed-width space and appends any styled text.
     */
    private static String processTabRun(String rXml) {
        String tabResult = '<span style="display:inline-block;width:36pt"></span>';
        String text = extractTextContent(rXml);
        if (String.isBlank(text)) {
            return tabResult;
        }

        String rPr = extractElement(rXml, 'w:rPr');
        if (String.isNotBlank(rPr)) {
            String style = parseRunStyle(rPr);
            tabResult += '<span style="' + style + '">' + text.escapeHtml4() + '</span>';
        } else {
            tabResult += text.escapeHtml4();
        }
        return tabResult;
    }

    /**
     * Resolves the key text-formatting attributes (color, font, size, bold, italic) from a
     * named style in styles.xml. Used to fill in values missing from inline rPr/pPr when
     * the run/paragraph references a named Word style (e.g. Heading 1 with a built-in color).
     * Returns a Map with keys: color, fontFamily, fontSize, bold, italic (any subset of those
     * that the style defines).
     */
    private static Map<String, String> resolveStyleTextAttributes(String styleName) {
        Map<String, String> out = new Map<String, String>();
        if (String.isBlank(styleName))
            return out;
        // Async-safe fast path — cached from admin context at request creation.
        if (styleTextAttrsMap != null && styleTextAttrsMap.containsKey(styleName)) {
            Map<String, String> cached = styleTextAttrsMap.get(styleName);
            if (cached != null)
                return cached;
        }
        if (String.isBlank(stylesXml))
            return out;
        // Find <w:style ... w:styleId="STYLENAME"> ... </w:style>
        String searchKey = 'w:styleId="' + styleName + '"';
        Integer idx = stylesXml.indexOf(searchKey);
        if (idx < 0)
            return out;
        Integer startIdx = stylesXml.lastIndexOf('<w:style', idx);
        Integer endIdx = stylesXml.indexOf('</w:style>', idx);
        if (startIdx < 0 || endIdx < 0)
            return out;
        String styleDef = stylesXml.substring(startIdx, endIdx);

        String color = extractAttr(styleDef, 'w:color', 'w:val');
        if (color != null && color != 'auto' && color.length() >= 6) {
            out.put('color', color);
        }
        String font = extractAttr(styleDef, 'w:rFonts', 'w:ascii');
        if (font == null)
            font = extractAttr(styleDef, 'w:rFonts', 'w:hAnsi');
        if (String.isNotBlank(font))
            out.put('fontFamily', font);
        String sz = extractAttr(styleDef, 'w:sz', 'w:val');
        if (sz != null && sz.isNumeric())
            out.put('fontSize', sz);
        if (isOoxmlOnOffElementTrue(styleDef, 'w:b'))
            out.put('bold', 'true');
        if (isOoxmlOnOffElementTrue(styleDef, 'w:i'))
            out.put('italic', 'true');
        return out;
    }

    /**
     * Parses <w:rPr> into CSS style string.
     */
    private static String parseRunStyle(String rPr) {
        List<String> styles = new List<String>();

        // Resolve run-style reference first — inline attributes can still override below.
        String rStyleVal = extractAttr(rPr, 'w:rStyle', 'w:val');
        Map<String, String> styleAttrs = (rStyleVal != null)
            ? resolveStyleTextAttributes(rStyleVal)
            : new Map<String, String>();

        // Font: <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="David"/>
        // w:cs = Complex Script font (Hebrew, Arabic) — try this first for RTL content
        String font = extractAttr(rPr, 'w:rFonts', 'w:ascii');
        if (font == null) {
            font = extractAttr(rPr, 'w:rFonts', 'w:hAnsi');
        }
        if (font == null) {
            font = styleAttrs.get('fontFamily');
        }
        String fontCs = extractAttr(rPr, 'w:rFonts', 'w:cs');
        // RTL run detection: <w:rtl/> marks a run as right-to-left
        Boolean isRtlRun = isOoxmlOnOffElementTrue(rPr, 'w:rtl');
        if (isRtlRun && fontCs != null) {
            // Use complex script font for RTL runs, fall back to Arial Unicode MS
            styles.add('font-family:\'Arial Unicode MS\',\'' + fontCs.escapeHtml4() + '\',sans-serif');
        } else if (font != null) {
            styles.add('font-family:\'' + font.escapeHtml4() + '\',sans-serif');
        }

        // Font size: <w:sz w:val="24"/> (half-points)
        String sz = extractAttr(rPr, 'w:sz', 'w:val');
        if (sz != null && sz.isNumeric()) {
            Decimal ptSize = Integer.valueOf(sz) * HALF_POINTS_TO_PT;
            styles.add('font-size:' + ptSize + 'pt');
        }

        // Color: <w:color w:val="FF0000"/> or <w:color w:val="auto" w:themeColor="accent1"/>
        // Note: sanitizeCssToken() guards against a malformed DOCX value smuggling
        // `;` or `}` to escape the surrounding `style="..."`. Trust boundary is admin,
        // but preview HTML reaches the browser via LWC innerHTML, so we harden anyway.
        String color = extractAttr(rPr, 'w:color', 'w:val');
        if (color != null && color != 'auto' && color.length() >= 6) {
            styles.add('color:#' + sanitizeCssToken(color));
        } else if (color == 'auto' || color == null) {
            // Check for theme color — Word stores colors as theme references
            String themeColor = extractAttr(rPr, 'w:color', 'w:themeColor');
            if (themeColor != null) {
                String resolved = resolveThemeColor(themeColor);
                if (resolved != null) {
                    styles.add('color:#' + sanitizeCssToken(resolved));
                }
            } else if (styleAttrs.containsKey('color')) {
                // Fall back to the color defined on the referenced style (Heading 1 / custom style / etc)
                styles.add('color:#' + sanitizeCssToken(styleAttrs.get('color')));
            }
        }

        // Highlight: <w:highlight w:val="yellow"/>
        String highlight = extractAttr(rPr, 'w:highlight', 'w:val');
        if (highlight != null) {
            styles.add('background-color:' + sanitizeCssToken(highlight));
        }

        // Shading (different from highlight): <w:shd w:val="clear" w:fill="FFFF00"/>
        String shdFill = extractAttr(rPr, 'w:shd', 'w:fill');
        if (shdFill != null && shdFill != 'auto' && highlight == null) {
            styles.add('background-color:#' + sanitizeCssToken(shdFill));
        }

        // Letter spacing: <w:spacing w:val="20"/> (in twips)
        String letterSpacing = extractAttr(rPr, 'w:spacing', 'w:val');
        if (letterSpacing != null && letterSpacing.isNumeric()) {
            Integer lsVal = Integer.valueOf(letterSpacing);
            if (lsVal != 0) {
                styles.add('letter-spacing:' + twipsToPt(lsVal) + 'pt');
            }
        }

        return String.join(styles, ';');
    }

    /**
     * Processes a <w:tbl> element into an HTML <table>.
     */
    private static String processTable(String tblXml, Map<String, String> images) {
        String tableStyle = 'border-collapse:collapse;width:100%';
        Boolean hasBorders = false;

        // Parse table properties
        String tblPr = extractElement(tblXml, 'w:tblPr');
        if (String.isNotBlank(tblPr)) {
            // Table width
            String tblW = extractAttr(tblPr, 'w:tblW', 'w:w');
            String tblWType = extractAttr(tblPr, 'w:tblW', 'w:type');
            if (tblWType == 'auto') {
                // Word's "auto" = shrink-wrap to sum of cell widths. Without explicitly
                // overriding, the global `table { width: 100% }` default makes auto tables
                // (typically right-aligned totals/summary tables) stretch full-width.
                tableStyle = 'border-collapse:collapse;width:auto';
            } else if (tblW != null && tblW.isNumeric()) {
                if (tblWType == 'pct') {
                    // OOXML pct is in 50ths of a percent. setScale avoids Decimal's
                    // scientific-notation toString (e.g. 50.0 → "5E+1") in CSS output.
                    Decimal pct = (Integer.valueOf(tblW) / 50.0).setScale(2);
                    tableStyle = 'border-collapse:collapse;width:' + pct + '%';
                } else if (tblWType == 'dxa' || tblWType == null) {
                    // dxa = twips. Without this branch the global `table { width: 100% }`
                    // default kicks in, which over-stretches authored tables on landscape
                    // pages (cells widen, paragraphs reflow, rows appear taller).
                    Decimal pt = twipsToPt(Integer.valueOf(tblW)).setScale(2);
                    tableStyle = 'border-collapse:collapse;width:' + pt + 'pt';
                }
            }

            // Table borders — check inline borders first, then style reference
            if (tblPr.contains('<w:tblBorders')) {
                // Parse actual border values — only set hasBorders if at least one is real (not none/nil)
                String tblBdr = extractElement(tblPr, 'w:tblBorders');
                if (String.isNotBlank(tblBdr)) {
                    String bTop = parseBorderSide(tblBdr, 'w:top');
                    String bBottom = parseBorderSide(tblBdr, 'w:bottom');
                    String bLeft = parseBorderSide(tblBdr, 'w:left');
                    String bRight = parseBorderSide(tblBdr, 'w:right');
                    String bInsH = parseBorderSide(tblBdr, 'w:insideH');
                    String bInsV = parseBorderSide(tblBdr, 'w:insideV');
                    if (
                        bTop != null ||
                        bBottom != null ||
                        bLeft != null ||
                        bRight != null ||
                        bInsH != null ||
                        bInsV != null
                    ) {
                        hasBorders = true;
                        // Use the first real border found for the table-level style
                        String rep = bTop != null
                            ? bTop
                            : (bInsH != null ? bInsH : (bLeft != null ? bLeft : '0.5pt solid #000'));
                        tableStyle += ';border:' + rep;
                    }
                }
            } else if (tblPr.contains('w:tblStyle')) {
                // Table uses a named style — resolve from styles.xml if available
                String styleVal = extractAttr(tblPr, 'w:tblStyle', 'w:val');
                if (styleVal != null) {
                    String resolvedBorder = resolveTableStyleBorder(styleVal);
                    if (resolvedBorder != null) {
                        hasBorders = true;
                        tableStyle += ';border:' + resolvedBorder;
                    }
                }
            }

            // RTL table: cells reversed manually in processTableRow

            // Table alignment
            String tblJc = extractAttr(tblPr, 'w:jc', 'w:val');
            if (tblJc == 'center') {
                tableStyle += ';margin-left:auto;margin-right:auto';
            } else if (tblJc == 'right' || tblJc == 'end') {
                tableStyle += ';margin-left:auto';
            }

            // Table cell margins (default padding for all cells)
            String tblCellMar = extractElement(tblPr, 'w:tblCellMar');
            if (String.isNotBlank(tblCellMar)) {
                String leftMar = extractAttr(tblCellMar, 'w:left', 'w:w');
                if (leftMar == null) {
                    leftMar = extractAttr(tblCellMar, 'w:start', 'w:w');
                }
                String rightMar = extractAttr(tblCellMar, 'w:right', 'w:w');
                if (rightMar == null) {
                    rightMar = extractAttr(tblCellMar, 'w:end', 'w:w');
                }
                // These values will be used on cells; for now they affect the table-level default
            }
        }

        // RTL table: reverse cell order manually
        Boolean isBidiVisual = String.isNotBlank(tblPr) && isOoxmlOnOffElementTrue(tblPr, 'w:bidiVisual');

        // Process rows
        String rows = '';
        Integer cursor = 0;
        while (cursor < tblXml.length()) {
            Integer trStart = tblXml.indexOf('<w:tr', cursor);
            if (trStart == -1) {
                break;
            }

            Integer trEnd = findClosingTag(tblXml, trStart, 'w:tr');
            if (trEnd == -1) {
                break;
            }

            rows += processTableRow(tblXml.substring(trStart, trEnd), images, tblPr, hasBorders, isBidiVisual);
            cursor = trEnd;
        }

        return '<table style="' + tableStyle + '">' + rows + '</table>';
    }

    /**
     * Processes a <w:tr> element into an HTML <tr>.
     */
    private static String processTableRow(
        String trXml,
        Map<String, String> images,
        String tblPr,
        Boolean hasBorders,
        Boolean isBidiVisual
    ) {
        Integer cursor = 0;

        // Check for header row
        String trPr = extractElement(trXml, 'w:trPr');
        Boolean isHeader = String.isNotBlank(trPr) && isOoxmlOnOffElementTrue(trPr, 'w:tblHeader');

        List<String> cellList = new List<String>();
        while (cursor < trXml.length()) {
            Integer tcStart = trXml.indexOf('<w:tc', cursor);
            if (tcStart == -1) {
                break;
            }

            Integer tcEnd = findClosingTag(trXml, tcStart, 'w:tc');
            if (tcEnd == -1) {
                break;
            }

            cellList.add(processTableCell(trXml.substring(tcStart, tcEnd), images, tblPr, hasBorders, isHeader));
            cursor = tcEnd;
        }

        // RTL table: reverse cell order so rightmost column appears first in HTML
        if (isBidiVisual) {
            List<String> reversed = new List<String>();
            for (Integer i = cellList.size() - 1; i >= 0; i--) {
                reversed.add(cellList[i]);
            }
            cellList = reversed;
        }

        return '<tr>' + String.join(cellList, '') + '</tr>';
    }

    /**
     * Processes a <w:tc> element into an HTML <td> or <th>.
     */
    private static String processTableCell(
        String tcXml,
        Map<String, String> images,
        String tblPr,
        Boolean hasBorders,
        Boolean isHeader
    ) {
        List<String> styles = new List<String>();
        Integer colspan = 0;

        // Cell properties
        String tcPr = extractElement(tcXml, 'w:tcPr');
        if (String.isNotBlank(tcPr)) {
            // Cell width: <w:tcW w:w="2880" w:type="dxa"/>
            String tcW = extractAttr(tcPr, 'w:tcW', 'w:w');
            String tcWType = extractAttr(tcPr, 'w:tcW', 'w:type');
            if (tcW != null && tcW.isNumeric()) {
                if (tcWType == 'pct') {
                    Decimal pct = Integer.valueOf(tcW) / 50.0;
                    styles.add('width:' + pct + '%');
                } else {
                    // dxa = twips
                    styles.add('width:' + twipsToPt(Integer.valueOf(tcW)) + 'pt');
                }
            }

            // Shading: <w:shd w:val="clear" w:fill="E2EFDA"/>
            String fill = extractAttr(tcPr, 'w:shd', 'w:fill');
            if (fill != null && fill != 'auto') {
                styles.add('background-color:#' + sanitizeCssToken(fill));
            }

            // Vertical alignment: <w:vAlign w:val="center"/>
            String vAlign = extractAttr(tcPr, 'w:vAlign', 'w:val');
            if (vAlign != null) {
                styles.add('vertical-align:' + sanitizeCssToken(vAlign));
            }

            // Cell-specific borders: <w:tcBorders>
            String tcBdr = tcPr.contains('<w:tcBorders') ? extractElement(tcPr, 'w:tcBorders') : null;
            if (String.isNotBlank(tcBdr)) {
                addBorderStyles(styles, tcBdr);
            } else if (hasBorders) {
                styles.add('border:0.5pt solid #000'); // from hasBorders (style or inline)
            }

            // Column span: <w:gridSpan w:val="2"/>
            String gridSpan = extractAttr(tcPr, 'w:gridSpan', 'w:val');
            if (gridSpan != null && gridSpan.isNumeric()) {
                colspan = Integer.valueOf(gridSpan);
            }

            // Cell padding: <w:tcMar>
            // Cell padding: <w:tcMar>
            String tcMar = tcPr.contains('<w:tcMar') ? extractElement(tcPr, 'w:tcMar') : null;
            if (String.isNotBlank(tcMar)) {
                addCellPaddingStyles(styles, tcMar);
            }
        } else if (hasBorders) {
            styles.add('border:0.5pt solid #000'); // from hasBorders (style or inline)
        }

        // Process cell content (paragraphs)
        String content = processBodyContent(tcXml, images);

        String styleStr = String.join(styles, ';');
        String tag = isHeader ? 'th' : 'td';
        String attrs = '';
        if (String.isNotBlank(styleStr)) {
            attrs += ' style="' + styleStr + '"';
        }
        if (colspan > 1) {
            attrs += ' colspan="' + colspan + '"';
        }

        return '<' + tag + attrs + '>' + content + '</' + tag + '>';
    }

    /**
     * Adds border CSS styles from a tcBorders element.
     */
    /**
     * Resolves a table style name to its border CSS by looking it up in stylesXml.
     * Returns a CSS border shorthand (e.g., "0.5pt solid #000") or null if not found.
     */
    /**
     * Calculates the usable content height from page dimensions in w:sectPr.
     * Parses pgSz (page height) and pgMar (top + bottom margins) from the XML.
     * Returns a CSS length value (e.g., "8.8in").
     */
    /**
     * Parses page dimensions from w:sectPr and returns usable content height.
     */
    private static String calculatePageContentHeight(String xml) {
        Map<String, Decimal> dims = parsePageDimensions(xml);
        Decimal usable = dims.get('contentHeight');
        return usable.setScale(1, System.RoundingMode.DOWN) + 'in';
    }

    /**
     * Parses page dimensions from w:sectPr. Returns map with keys:
     * pageWidth, pageHeight, marginTop, marginRight, marginBottom, marginLeft,
     * contentHeight, contentWidth (all in inches).
     */
    private static Map<String, Decimal> parsePageDimensions(String xml) {
        Map<String, Decimal> dims = new Map<String, Decimal>();
        // Defaults: Letter, 1in margins
        Integer pgW = 12240;
        Integer pgH = 15840;
        Integer mTop = 1440;
        Integer mRight = 1440;
        Integer mBottom = 1440;
        Integer mLeft = 1440;

        // 1.68 — admin override path. When orientationOverride OR pageSizeOverride
        // is set, resolve canonical dimensions from the (size × orientation) matrix
        // and skip parsing source pgSz/pgMar entirely. This is the source of truth
        // when admins set Page_Size__c / Page_Orientation__c on the template — DOCX
        // page dims are often stale or carry old margins from the author's tool.
        if (String.isNotBlank(orientationOverride) || String.isNotBlank(pageSizeOverride)) {
            Boolean isLandscape = 'Landscape'.equalsIgnoreCase(orientationOverride);
            String size = String.isNotBlank(pageSizeOverride) ? pageSizeOverride : 'Letter';
            // Portrait twips for each size (W, H)
            Integer portraitW;
            Integer portraitH;
            if ('Legal'.equalsIgnoreCase(size)) {
                portraitW = 12240;
                portraitH = 20160; // 8.5 x 14 in
            } else if ('A4'.equalsIgnoreCase(size)) {
                portraitW = 11906;
                portraitH = 16838; // 210 x 297 mm
            } else {
                portraitW = 12240;
                portraitH = 15840; // Letter 8.5 x 11 in
            }
            if (isLandscape) {
                pgW = portraitH;
                pgH = portraitW;
            } else {
                pgW = portraitW;
                pgH = portraitH;
            }
            // Resolve margins: preset → custom string → size-appropriate default
            // Special case: 'FromSource' parses <w:pgMar> from the source DOCX so
            // the admin keeps their authored margins while we still flip page dims.
            // Falls back to size-default if pgMar can't be parsed (HTML templates,
            // non-DOCX source, missing tag).
            if ('FromSource'.equalsIgnoreCase(marginsOverride)) {
                Integer[] sourceMargins = readSourceMargins(xml);
                if (sourceMargins != null) {
                    mTop = sourceMargins[0];
                    mRight = sourceMargins[1];
                    mBottom = sourceMargins[2];
                    mLeft = sourceMargins[3];
                } else {
                    // No source margins available — use size-default
                    Integer m = isLandscape ? 720 : 1440;
                    mTop = m;
                    mRight = m;
                    mBottom = m;
                    mLeft = m;
                }
            } else {
                Integer[] resolvedMargins = resolveMarginsForOverride(size, isLandscape);
                mTop = resolvedMargins[0];
                mRight = resolvedMargins[1];
                mBottom = resolvedMargins[2];
                mLeft = resolvedMargins[3];
            }
            return finalizePageDims(dims, pgW, pgH, mTop, mRight, mBottom, mLeft);
        }

        if (String.isNotBlank(xml) && xml.contains('<w:pgSz')) {
            try {
                String val;
                val = extractAttr(xml, 'w:pgSz', 'w:w');
                if (val != null && val.isNumeric()) {
                    pgW = Integer.valueOf(val);
                }
                val = extractAttr(xml, 'w:pgSz', 'w:h');
                if (val != null && val.isNumeric()) {
                    pgH = Integer.valueOf(val);
                }
                val = extractAttr(xml, 'w:pgMar', 'w:top');
                if (val != null && Pattern.matches('-?\\d+', val)) {
                    mTop = Math.abs(Integer.valueOf(val));
                }
                val = extractAttr(xml, 'w:pgMar', 'w:right');
                if (val != null && Pattern.matches('-?\\d+', val)) {
                    mRight = Math.abs(Integer.valueOf(val));
                }
                val = extractAttr(xml, 'w:pgMar', 'w:bottom');
                if (val != null && Pattern.matches('-?\\d+', val)) {
                    mBottom = Math.abs(Integer.valueOf(val));
                }
                val = extractAttr(xml, 'w:pgMar', 'w:left');
                if (val != null && Pattern.matches('-?\\d+', val)) {
                    mLeft = Math.abs(Integer.valueOf(val));
                }
            } catch (Exception e) {
                // Intentionally swallowed — page dimension parsing failed, using defaults
                String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
            }
        }

        return finalizePageDims(dims, pgW, pgH, mTop, mRight, mBottom, mLeft);
    }

    /** Shared finalization for parsePageDimensions — assembles the inch-converted map. */
    private static Map<String, Decimal> finalizePageDims(
        Map<String, Decimal> dims,
        Integer pgW,
        Integer pgH,
        Integer mTop,
        Integer mRight,
        Integer mBottom,
        Integer mLeft
    ) {
        dims.put('pageWidth', pgW / 1440.0);
        dims.put('pageHeight', pgH / 1440.0);
        dims.put('marginTop', mTop / 1440.0);
        dims.put('marginRight', mRight / 1440.0);
        dims.put('marginBottom', mBottom / 1440.0);
        dims.put('marginLeft', mLeft / 1440.0);
        dims.put('contentHeight', (pgH - mTop - mBottom - 288) / 1440.0);
        dims.put('contentWidth', (pgW - mLeft - mRight) / 1440.0);
        return dims;
    }

    /**
     * 1.68 — reads <w:pgMar> from the source DOCX XML (twips, T/R/B/L). Returns
     * null when the tag is missing or the document isn't DOCX (e.g. HTML body).
     * Used by the FromSource margins preset so admins can carry authored margins
     * forward while still using our canonical page-size dimensions.
     */
    private static Integer[] readSourceMargins(String xml) {
        if (String.isBlank(xml) || !xml.contains('<w:pgMar'))
            return null;
        try {
            String t = extractAttr(xml, 'w:pgMar', 'w:top');
            String r = extractAttr(xml, 'w:pgMar', 'w:right');
            String b = extractAttr(xml, 'w:pgMar', 'w:bottom');
            String l = extractAttr(xml, 'w:pgMar', 'w:left');
            if (t == null || r == null || b == null || l == null)
                return null;
            if (
                !Pattern.matches('-?\\d+', t) ||
                !Pattern.matches('-?\\d+', r) ||
                !Pattern.matches('-?\\d+', b) ||
                !Pattern.matches('-?\\d+', l)
            )
                return null;
            return new List<Integer>{
                Math.abs(Integer.valueOf(t)),
                Math.abs(Integer.valueOf(r)),
                Math.abs(Integer.valueOf(b)),
                Math.abs(Integer.valueOf(l))
            };
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * 1.68 — resolves margins (in twips, T/R/B/L order) for the override path.
     * Preset takes priority: Narrow/Normal/Wide are uniform; Custom parses the
     * Custom_Margins__c string; Default falls back to size-appropriate defaults.
     * 1 inch = 1440 twips. A4 defaults: 2.54cm portrait / 1.27cm landscape.
     */
    private static Integer[] resolveMarginsForOverride(String size, Boolean isLandscape) {
        String preset = String.isNotBlank(marginsOverride) ? marginsOverride : 'Default';
        if ('Narrow'.equalsIgnoreCase(preset)) {
            return new List<Integer>{ 720, 720, 720, 720 };
        }
        if ('Normal'.equalsIgnoreCase(preset)) {
            return new List<Integer>{ 1440, 1440, 1440, 1440 };
        }
        if ('Wide'.equalsIgnoreCase(preset)) {
            return new List<Integer>{ 2160, 2160, 2160, 2160 };
        }
        if ('Custom'.equalsIgnoreCase(preset)) {
            Integer[] parsed = parseCustomMargins(customMarginsOverride);
            if (parsed != null)
                return parsed;
            // Fall through to default if parse failed
        }
        // Default for size — A4 uses metric defaults, Letter/Legal use 1in/0.5in
        if ('A4'.equalsIgnoreCase(size)) {
            // 2.54cm = 1.0in = 1440 twips ; 1.27cm = 0.5in = 720 twips
            Integer m = isLandscape ? 720 : 1440;
            return new List<Integer>{ m, m, m, m };
        }
        // Letter / Legal default
        Integer mm = isLandscape ? 720 : 1440;
        return new List<Integer>{ mm, mm, mm, mm };
    }

    /**
     * Parses Custom_Margins__c. Accepts "T,R,B,L" or "T R B L" in inches,
     * or a single value applied to all four sides. Returns twips array or null.
     */
    private static Integer[] parseCustomMargins(String raw) {
        if (String.isBlank(raw))
            return null;
        try {
            String cleaned = raw.replaceAll('\\s+', ' ').trim();
            List<String> parts;
            if (cleaned.contains(',')) {
                parts = cleaned.split('\\s*,\\s*');
            } else {
                parts = cleaned.split(' ');
            }
            if (parts.isEmpty())
                return null;
            Decimal t = Decimal.valueOf(parts[0].trim());
            Decimal r = parts.size() >= 2 ? Decimal.valueOf(parts[1].trim()) : t;
            Decimal b = parts.size() >= 3 ? Decimal.valueOf(parts[2].trim()) : t;
            Decimal l = parts.size() >= 4 ? Decimal.valueOf(parts[3].trim()) : r;
            // Clamp to sane range (0.1in - 3in) to prevent rendering disasters
            t = clampMargin(t);
            r = clampMargin(r);
            b = clampMargin(b);
            l = clampMargin(l);
            return new List<Integer>{
                (Integer) (t * 1440),
                (Integer) (r * 1440),
                (Integer) (b * 1440),
                (Integer) (l * 1440)
            };
        } catch (Exception e) {
            return null;
        }
    }

    private static Decimal clampMargin(Decimal v) {
        if (v < 0.1)
            return 0.1;
        if (v > 3.0)
            return 3.0;
        return v;
    }

    /**
     * Resolves default table cell padding from TableNormal style in stylesXml.
     * Returns CSS padding value (e.g., "0pt 5.4pt").
     */
    /**
     * Resolves Word field codes (PAGE, NUMPAGES, fldSimple) within paragraph XML.
     * Complex fields span multiple <w:r> elements:
     *   <w:r><w:fldChar w:fldCharType="begin"/></w:r>
     *   <w:r><w:instrText> PAGE </w:instrText></w:r>
     *   <w:r><w:fldChar w:fldCharType="separate"/></w:r>
     *   <w:r><w:t>1</w:t></w:r>  (cached value — discard)
     *   <w:r><w:fldChar w:fldCharType="end"/></w:r>
     * Replaces the entire field construct with a single run containing a CSS-driven span.
     * Flying Saucer resolves counter(page)/counter(pages) at PDF render time.
     */
    private static String resolveFieldCodes(String pXml) {
        // Handle <w:fldSimple w:instr="..."> wrappers first
        pXml = resolveFldSimple(pXml);

        // Handle complex field codes (fldChar begin/separate/end)
        if (!pXml.contains('<w:fldChar')) {
            return pXml;
        }

        String result = '';
        Integer cursor = 0;
        Boolean inField = false;
        Boolean inFieldResult = false;
        String fieldInstr = '';
        String fieldRpr = '';
        Integer fieldStartPos = -1;

        while (cursor < pXml.length()) {
            Integer nextFldChar = pXml.indexOf('<w:fldChar', cursor);
            Integer nextInstrText = pXml.indexOf('<w:instrText', cursor);

            if (nextFldChar == -1 && !inField) {
                result += pXml.substring(cursor);
                break;
            }

            if (!inField) {
                // Look for field begin
                if (nextFldChar == -1) {
                    result += pXml.substring(cursor);
                    break;
                }
                if (
                    pXml.indexOf('fldCharType="begin"', nextFldChar) != -1 &&
                    pXml.indexOf('fldCharType="begin"', nextFldChar) < pXml.indexOf('>', nextFldChar) + 1
                ) {
                    // Found field begin — find the enclosing run start
                    fieldStartPos = pXml.lastIndexOf('<w:r>', nextFldChar);
                    if (fieldStartPos == -1) {
                        fieldStartPos = pXml.lastIndexOf('<w:r ', nextFldChar);
                    }
                    if (fieldStartPos == -1 || fieldStartPos < cursor) {
                        fieldStartPos = nextFldChar;
                    }
                    result += pXml.substring(cursor, fieldStartPos);
                    inField = true;
                    inFieldResult = false;
                    fieldInstr = '';
                    // Capture <w:rPr> from the begin run so page number spans preserve font size
                    fieldRpr = '';
                    Integer rprStart = pXml.indexOf('<w:rPr>', fieldStartPos);
                    if (rprStart != -1 && rprStart < nextFldChar) {
                        Integer rprEnd = pXml.indexOf('</w:rPr>', rprStart);
                        if (rprEnd != -1 && rprEnd < nextFldChar) {
                            fieldRpr = pXml.substring(rprStart, rprEnd + 8);
                        }
                    }
                    // Skip past this fldChar tag
                    Integer tagEnd = pXml.indexOf('>', nextFldChar);
                    cursor = (tagEnd != -1) ? tagEnd + 1 : nextFldChar + 1;
                } else {
                    // Not a begin — pass through
                    Integer tagEnd = pXml.indexOf('>', nextFldChar);
                    result += pXml.substring(cursor, (tagEnd != -1) ? tagEnd + 1 : nextFldChar + 1);
                    cursor = (tagEnd != -1) ? tagEnd + 1 : nextFldChar + 1;
                }
            } else {
                // Inside a field — look for instrText, separate, or end
                if (nextInstrText != -1 && (nextFldChar == -1 || nextInstrText < nextFldChar)) {
                    // Capture instruction text
                    Integer tagEnd = pXml.indexOf('>', nextInstrText);
                    if (tagEnd != -1) {
                        Integer closeInstr = pXml.indexOf('</w:instrText>', tagEnd);
                        if (closeInstr != -1) {
                            fieldInstr += pXml.substring(tagEnd + 1, closeInstr).trim().toUpperCase();
                            cursor = closeInstr + '</w:instrText>'.length();
                        } else {
                            cursor = tagEnd + 1;
                        }
                    } else {
                        cursor = nextInstrText + 1;
                    }
                } else if (nextFldChar != -1) {
                    Integer fldTagEnd = pXml.indexOf('>', nextFldChar);
                    String fldTag = (fldTagEnd != -1) ? pXml.substring(nextFldChar, fldTagEnd + 1) : '';

                    if (fldTag.contains('fldCharType="separate"')) {
                        inFieldResult = true;
                        cursor = (fldTagEnd != -1) ? fldTagEnd + 1 : nextFldChar + 1;
                    } else if (fldTag.contains('fldCharType="end"')) {
                        // Field complete — skip to end of enclosing run
                        Integer runEnd = pXml.indexOf('</w:r>', nextFldChar);
                        cursor = (runEnd != -1) ? runEnd + 6 : ((fldTagEnd != -1) ? fldTagEnd + 1 : nextFldChar + 1);

                        // Emit replacement with preserved run properties (font size, color, etc.)
                        if (fieldInstr.contains('NUMPAGES')) {
                            result += '<w:r>' + fieldRpr + '<w:t><span class="docgen-page-total"></span></w:t></w:r>';
                        } else if (fieldInstr.contains('PAGE')) {
                            result += '<w:r>' + fieldRpr + '<w:t><span class="docgen-page-num"></span></w:t></w:r>';
                        }
                        // Other field types: silently drop (DATE, TIME, etc. have static cached values)
                        inField = false;
                    } else {
                        // Nested or other fldChar — skip
                        cursor = (fldTagEnd != -1) ? fldTagEnd + 1 : nextFldChar + 1;
                    }
                } else {
                    // No more fldChar/instrText — malformed field, dump remaining
                    cursor = pXml.length();
                    inField = false;
                }
            }
        }
        return result;
    }

    /**
     * Handles <w:fldSimple w:instr=" PAGE "> wrapper elements.
     * Replaces them with a run containing the appropriate CSS counter span.
     */
    private static String resolveFldSimple(String pXml) {
        if (!pXml.contains('<w:fldSimple')) {
            return pXml;
        }
        String result = '';
        Integer cursor = 0;
        while (cursor < pXml.length()) {
            Integer fldStart = pXml.indexOf('<w:fldSimple', cursor);
            if (fldStart == -1) {
                result += pXml.substring(cursor);
                break;
            }
            result += pXml.substring(cursor, fldStart);
            Integer tagEnd = pXml.indexOf('>', fldStart);
            if (tagEnd == -1) {
                result += pXml.substring(fldStart);
                break;
            }
            String tag = pXml.substring(fldStart, tagEnd + 1).toUpperCase();
            Integer closeTag = pXml.indexOf('</w:fldSimple>', tagEnd);
            if (closeTag == -1) {
                closeTag = pXml.indexOf('</w:fldSimple>', tagEnd);
            }
            if (closeTag == -1) {
                result += pXml.substring(fldStart);
                break;
            }

            // Capture <w:rPr> from the inner run to preserve font size on page number spans
            String innerContent = pXml.substring(tagEnd + 1, closeTag);
            String fldRpr = '';
            Integer rprIdx = innerContent.indexOf('<w:rPr>');
            if (rprIdx != -1) {
                Integer rprEndIdx = innerContent.indexOf('</w:rPr>', rprIdx);
                if (rprEndIdx != -1) {
                    fldRpr = innerContent.substring(rprIdx, rprEndIdx + 8);
                }
            }

            if (tag.contains('NUMPAGES')) {
                result += '<w:r>' + fldRpr + '<w:t><span class="docgen-page-total"></span></w:t></w:r>';
            } else if (tag.contains('PAGE')) {
                result += '<w:r>' + fldRpr + '<w:t><span class="docgen-page-num"></span></w:t></w:r>';
            }
            // Skip other fldSimple types
            cursor = closeTag + '</w:fldSimple>'.length();
        }
        return result;
    }

    /**
     * Checks if the document's default paragraph style (Normal) is RTL.
     * In Hebrew/Arabic documents, the Normal style typically has <w:bidi/> in its pPr,
     * meaning ALL paragraphs inherit RTL direction unless explicitly overridden.
     */
    /**
     * Reverses RTL character sequences for Flying Saucer compatibility.
     * Flying Saucer renders all characters LTR — reversing RTL text makes it
     * display correctly when read right-to-left.
     *
     * Only reverses text that actually contains RTL characters (Hebrew/Arabic).
     * English merge field values in RTL runs are left untouched.
     * Mixed content (Hebrew + English in one run) reverses RTL segments only.
     */

    private static Boolean isRtlCodePoint(Integer cp) {
        return (cp >= 1424 &&
            cp <= 1535) || // Hebrew (U+0590-U+05FF)
            (cp >= 1536 &&
            cp <= 1791) || // Arabic (U+0600-U+06FF)
            (cp >= 1872 &&
            cp <= 1919) || // Arabic Supplement (U+0750-U+077F)
            (cp >= 64336 &&
            cp <= 65023) || // Arabic Presentation Forms-A
            (cp >= 65136 &&
            cp <= 65279); // Arabic Presentation Forms-B
    }

    /**
     * Reverses RTL text for Flying Saucer. Full string reversal gives correct
     * character order + word order when rendered LTR with text-align:right.
     * English merge values are left untouched.
     */
    private static String reverseRtlText(String input) {
        if (String.isBlank(input)) {
            return input;
        }

        Boolean hasRtl = false;
        for (Integer i = 0; i < input.length(); i++) {
            if (isRtlCodePoint(input.charAt(i))) {
                hasRtl = true;
                break;
            }
        }
        if (!hasRtl) {
            return input;
        }

        // Check all chars are RTL + neutral ASCII
        for (Integer i = 0; i < input.length(); i++) {
            Integer cp = input.charAt(i);
            if (!isRtlCodePoint(cp) && cp > 127) {
                return input; // Mixed extended chars — don't reverse
            }
        }

        String result = '';
        for (Integer i = input.length() - 1; i >= 0; i--) {
            result += input.substring(i, i + 1);
        }
        return result;
    }

    /**
     * Extracts the content between an HTML-comment start/end marker pair (e.g.
     * `<!-- DOCGEN_HEADER_FIRST_START -->...<!-- DOCGEN_HEADER_FIRST_END -->`).
     * Returns a 2-key map: `content` (extracted body, or "") and `remainder`
     * (input with the marker section stripped, or unchanged when no match).
     */
    @TestVisible
    private static Map<String, String> extractMarkerSection(String input, String startMarker, String endMarker) {
        Map<String, String> result = new Map<String, String>{ 'content' => '', 'remainder' => input };
        if (String.isBlank(input)) {
            return result;
        }
        String startTag = '<!-- ' + startMarker + ' -->';
        String endTag = '<!-- ' + endMarker + ' -->';
        Integer startIdx = input.indexOf(startTag);
        if (startIdx == -1) {
            return result;
        }
        Integer contentStart = startIdx + startTag.length();
        Integer endIdx = input.indexOf(endTag, contentStart);
        if (endIdx == -1) {
            return result;
        }
        result.put('content', input.substring(contentStart, endIdx));
        result.put('remainder', input.substring(0, startIdx) + input.substring(endIdx + endTag.length()));
        return result;
    }

    private static Boolean isDefaultStyleRtl() {
        if (String.isBlank(stylesXml)) {
            return false;
        }
        try {
            // Find the Normal style (default paragraph style)
            Integer normalIdx = stylesXml.indexOf('w:styleId="Normal"');
            if (normalIdx == -1) {
                normalIdx = stylesXml.indexOf('w:styleId="normal"');
            }
            if (normalIdx == -1) {
                return false;
            }
            Integer styleStart = stylesXml.lastIndexOf('<w:style', normalIdx);
            Integer styleEnd = stylesXml.indexOf('</w:style>', normalIdx);
            if (styleStart == -1 || styleEnd == -1) {
                return false;
            }
            return isOoxmlOnOffElementTrue(stylesXml.substring(styleStart, styleEnd), 'w:bidi');
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * OOXML on/off element evaluator (ECMA-376 §17.17.4).
     *
     * Returns true if `<elementName/>` (self-closing, no attrs) is present, OR
     * `<elementName w:val="X"/>` where X is "1", "true", or "on". False otherwise.
     *
     * Critical: LibreOffice's .doc→.docx conversion emits `<w:bidi w:val="0"/>` in
     * the Normal style for every LTR document. A naive `contains('<w:bidi ')` check
     * matches this and incorrectly flags the doc as RTL — fixed in v1.80.
     */
    @TestVisible
    private static Boolean isOoxmlOnOffElementTrue(String xml, String elementName) {
        if (String.isBlank(xml) || String.isBlank(elementName)) {
            return false;
        }
        // Self-closing with no attributes — implicit val="1" per spec
        if (xml.contains('<' + elementName + '/>')) {
            return true;
        }
        Integer idx = xml.indexOf('<' + elementName + ' ');
        if (idx == -1) {
            return false;
        }
        Integer tagEnd = xml.indexOf('>', idx);
        if (tagEnd == -1) {
            return false;
        }
        String tag = xml.substring(idx, tagEnd);
        Integer valIdx = tag.indexOf('w:val="');
        if (valIdx == -1) {
            // Element present with attributes but no w:val — defaults to true per spec.
            return true;
        }
        String afterVal = tag.substring(valIdx + 7);
        Integer quoteIdx = afterVal.indexOf('"');
        if (quoteIdx == -1) {
            return true;
        }
        String val = afterVal.substring(0, quoteIdx).toLowerCase();
        return val == '1' || val == 'true' || val == 'on';
    }

    /**
     * Maps standard Word theme color names to default hex values.
     * These match the default Office theme (Office 2013+). Not perfect for custom
     * themes, but covers the vast majority of documents.
     */
    private static final Map<String, String> THEME_COLOR_DEFAULTS = new Map<String, String>{
        'dark1' => '000000',
        'light1' => 'FFFFFF',
        'dark2' => '44546A',
        'light2' => 'E7E6E6',
        'accent1' => '4472C4',
        'accent2' => 'ED7D31',
        'accent3' => 'A5A5A5',
        'accent4' => 'FFC000',
        'accent5' => '5B9BD5',
        'accent6' => '70AD47',
        'hyperlink' => '0563C1',
        'followedHyperlink' => '954F72',
        'text1' => '000000',
        'text2' => '44546A',
        'background1' => 'FFFFFF',
        'background2' => 'E7E6E6'
    };

    private static String resolveThemeColor(String themeColor) {
        if (themeColor == null) {
            return null;
        }
        return THEME_COLOR_DEFAULTS.get(themeColor);
    }

    /**
     * Determines if a list is numbered by looking up the numId in numbering.xml.
     * Falls back to style-name heuristic if numbering.xml is not available.
     * numbering.xml structure: <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
     * then: <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>
     * Bullet formats: "bullet"
     * Numbered formats: "decimal", "lowerLetter", "upperLetter", "lowerRoman", "upperRoman", etc.
     */
    private static Boolean isNumberedList(String numId, String ilvl) {
        if (String.isBlank(numberingXml) || numId == null) {
            // Fallback: assume bullet (safer default than the old odd/even heuristic)
            return false;
        }
        try {
            // Step 1: Find <w:num w:numId="X"> and get the abstractNumId
            String numSearch = 'w:numId="' + numId + '"';
            Integer numIdx = numberingXml.indexOf(numSearch);
            if (numIdx == -1) {
                return false;
            }

            // Find the abstractNumId within this <w:num> element
            Integer numStart = numberingXml.lastIndexOf('<w:num ', numIdx);
            Integer numEnd = numberingXml.indexOf('</w:num>', numIdx);
            if (numStart == -1 || numEnd == -1) {
                // Self-closing <w:num> — look for abstractNumId within the tag area
                numEnd = numberingXml.indexOf('>', numIdx);
                if (numEnd == -1) {
                    return false;
                }
            }
            String numBlock = numberingXml.substring(numStart, numEnd);
            String abstractNumId = extractAttr(numBlock, 'w:abstractNumId', 'w:val');
            if (abstractNumId == null) {
                return false;
            }

            // Step 2: Find <w:abstractNum w:abstractNumId="Y"> and get the numFmt for the ilvl
            String absSearch = 'w:abstractNumId="' + abstractNumId + '"';
            Integer absIdx = numberingXml.indexOf(absSearch);
            if (absIdx == -1) {
                return false;
            }

            Integer absStart = numberingXml.lastIndexOf('<w:abstractNum ', absIdx);
            Integer absEnd = numberingXml.indexOf('</w:abstractNum>', absIdx);
            if (absStart == -1 || absEnd == -1) {
                return false;
            }
            String absBlock = numberingXml.substring(absStart, absEnd);

            // Step 3: Find the <w:lvl w:ilvl="Z"> within the abstract definition
            String lvlSearch = 'w:ilvl="' + ilvl + '"';
            Integer lvlIdx = absBlock.indexOf(lvlSearch);
            if (lvlIdx == -1) {
                // Try ilvl 0 as fallback
                lvlIdx = absBlock.indexOf('w:ilvl="0"');
                if (lvlIdx == -1) {
                    return false;
                }
            }

            Integer lvlStart = absBlock.lastIndexOf('<w:lvl ', lvlIdx);
            Integer lvlEnd = absBlock.indexOf('</w:lvl>', lvlIdx);
            if (lvlStart == -1 || lvlEnd == -1) {
                return false;
            }
            String lvlBlock = absBlock.substring(lvlStart, lvlEnd);

            // Step 4: Get the numFmt value
            String numFmt = extractAttr(lvlBlock, 'w:numFmt', 'w:val');
            if (numFmt == null) {
                return false;
            }

            // "bullet" = bullet list, everything else = numbered
            return numFmt != 'bullet';
        } catch (Exception e) {
            return false;
        }
    }

    private static String resolveDefaultCellPadding() {
        if (String.isBlank(stylesXml)) {
            return '0pt 5.4pt';
        }
        try {
            Integer tnIdx = stylesXml.indexOf('w:styleId="TableNormal"');
            if (tnIdx == -1) {
                return '0pt 5.4pt';
            }
            Integer tnStart = stylesXml.lastIndexOf('<w:style', tnIdx);
            Integer tnEnd = stylesXml.indexOf('</w:style>', tnIdx);
            if (tnStart == -1 || tnEnd == -1) {
                return '0pt 5.4pt';
            }
            String tnDef = stylesXml.substring(tnStart, tnEnd + 10);

            String topW = extractAttr(tnDef, 'w:top', 'w:w');
            String leftW = extractAttr(tnDef, 'w:left', 'w:w');
            String bottomW = extractAttr(tnDef, 'w:bottom', 'w:w');
            String rightW = extractAttr(tnDef, 'w:right', 'w:w');

            Decimal top = (topW != null && topW.isNumeric()) ? twipsToPt(Integer.valueOf(topW)) : 0;
            Decimal left = (leftW != null && leftW.isNumeric()) ? twipsToPt(Integer.valueOf(leftW)) : 5.4;
            Decimal bottom = (bottomW != null && bottomW.isNumeric()) ? twipsToPt(Integer.valueOf(bottomW)) : 0;
            Decimal right = (rightW != null && rightW.isNumeric()) ? twipsToPt(Integer.valueOf(rightW)) : 5.4;

            return top + 'pt ' + right + 'pt ' + bottom + 'pt ' + left + 'pt';
        } catch (Exception e) {
            return '0pt 5.4pt';
        }
    }

    private static String resolveTableStyleBorder(String styleName) {
        if (String.isBlank(styleName))
            return null;
        // Async-safe fast path — borders map pre-extracted in admin context and cached.
        if (tableStyleBorderMap != null && tableStyleBorderMap.containsKey(styleName)) {
            return tableStyleBorderMap.get(styleName);
        }
        if (String.isBlank(stylesXml)) {
            return null;
        }

        // Find the style definition: <w:style ... w:styleId="TableGrid">
        String searchKey = 'w:styleId="' + styleName + '"';
        Integer styleIdx = stylesXml.indexOf(searchKey);
        if (styleIdx == -1) {
            return null;
        }

        Integer styleStart = stylesXml.lastIndexOf('<w:style', styleIdx);
        Integer styleEnd = stylesXml.indexOf('</w:style>', styleIdx);
        if (styleStart == -1 || styleEnd == -1) {
            return null;
        }

        String styleDef = stylesXml.substring(styleStart, styleEnd + 10);

        // Check for tblBorders
        if (!styleDef.contains('<w:tblBorders')) {
            return null;
        }

        // Parse the first border side to get size and color
        String topBorder = parseBorderSide(styleDef, 'w:top');
        if (topBorder != null) {
            return topBorder;
        }

        // Fallback: check for insideH (grid borders)
        String insideH = parseBorderSide(styleDef, 'w:insideH');
        if (insideH != null) {
            return insideH;
        }

        return '0.5pt solid #000'; // Default for styles with tblBorders
    }

    private static void addBorderStyles(List<String> styles, String bdrXml) {
        String topBdr = parseBorderSide(bdrXml, 'w:top');
        String bottomBdr = parseBorderSide(bdrXml, 'w:bottom');
        String leftBdr = parseBorderSide(bdrXml, 'w:left');
        if (leftBdr == null) {
            leftBdr = parseBorderSide(bdrXml, 'w:start');
        }
        String rightBdr = parseBorderSide(bdrXml, 'w:right');
        if (rightBdr == null) {
            rightBdr = parseBorderSide(bdrXml, 'w:end');
        }
        if (topBdr != null) {
            styles.add('border-top:' + topBdr);
        }
        if (bottomBdr != null) {
            styles.add('border-bottom:' + bottomBdr);
        }
        if (leftBdr != null) {
            styles.add('border-left:' + leftBdr);
        }
        if (rightBdr != null) {
            styles.add('border-right:' + rightBdr);
        }
    }

    /**
     * Adds cell padding CSS from a tcMar element.
     */
    private static void addCellPaddingStyles(List<String> styles, String tcMar) {
        String cellPadTop = extractAttr(tcMar, 'w:top', 'w:w');
        String cellPadBottom = extractAttr(tcMar, 'w:bottom', 'w:w');
        String cellPadLeft = extractAttr(tcMar, 'w:left', 'w:w');
        if (cellPadLeft == null) {
            cellPadLeft = extractAttr(tcMar, 'w:start', 'w:w');
        }
        String cellPadRight = extractAttr(tcMar, 'w:right', 'w:w');
        if (cellPadRight == null) {
            cellPadRight = extractAttr(tcMar, 'w:end', 'w:w');
        }

        List<String> padParts = new List<String>();
        padParts.add(
            (cellPadTop != null && cellPadTop.isNumeric()) ? twipsToPt(Integer.valueOf(cellPadTop)) + 'pt' : '4pt'
        );
        padParts.add(
            (cellPadRight != null && cellPadRight.isNumeric()) ? twipsToPt(Integer.valueOf(cellPadRight)) + 'pt' : '4pt'
        );
        padParts.add(
            (cellPadBottom != null && cellPadBottom.isNumeric())
                ? twipsToPt(Integer.valueOf(cellPadBottom)) + 'pt'
                : '4pt'
        );
        padParts.add(
            (cellPadLeft != null && cellPadLeft.isNumeric()) ? twipsToPt(Integer.valueOf(cellPadLeft)) + 'pt' : '4pt'
        );
        styles.add('padding:' + String.join(padParts, ' '));
    }

    /**
     * Processes a <w:drawing> element into an HTML <img> tag.
     */
    private static String processDrawing(String drawingXml, Map<String, String> images) {
        // Extract dimensions from <wp:extent cx="..." cy="..."/>
        Integer widthPx = 200; // default
        Integer heightPx = 150; // default

        String cx = extractAttr(drawingXml, 'wp:extent', 'cx');
        String cy = extractAttr(drawingXml, 'wp:extent', 'cy');
        if (cx == null) {
            cx = extractAttr(drawingXml, 'a:ext', 'cx');
        }
        if (cy == null) {
            cy = extractAttr(drawingXml, 'a:ext', 'cy');
        }

        if (cx != null && cx.isNumeric()) {
            widthPx = Math.round(Long.valueOf(cx) * EMU_TO_PX);
        }
        if (cy != null && cy.isNumeric()) {
            heightPx = Math.round(Long.valueOf(cy) * EMU_TO_PX);
        }

        // Extract relationship ID from <a:blip r:embed="rIdImg1"/>
        String relId = extractAttr(drawingXml, 'a:blip', 'r:embed');
        if (relId == null) {
            return '';
        }

        String imageValue = images.get(relId);
        if (imageValue == null) {
            return '';
        }

        // Sizing strategy: default to exact width/height from wp:extent — that's
        // the authoritative value Word stores for both template-embedded images
        // (matching native aspect) and rich text images with explicit user sizing.
        // The DOCGEN_AUTOSIZE marker (set by processRichTextImage when no width
        // OR height info was found in the rich text) flips us to max-width +
        // width:auto so we preserve aspect for unsized phone-photo style images.
        //
        // Critical for Flying Saucer (v1.80+): emit HTML width/height attributes
        // alongside CSS. For high-resolution embedded images (Mantis ROM example:
        // 15068×5731 px native, Word displays at 8.46"×2.39" = 813×229 px),
        // CSS-only sizing falls through to natural pixel dimensions because
        // Flying Saucer's image scaler reads HTML attrs first and uses them as
        // the authoritative size, regardless of the parent's `max-width: 100%`.
        Boolean autoSize = drawingXml.contains('DOCGEN_AUTOSIZE');
        String sizeStyle = autoSize
            ? ('max-width:' + widthPx + 'px;max-height:' + heightPx + 'px;width:auto;height:auto;')
            : ('width:' + widthPx + 'px;height:' + heightPx + 'px;');
        // Explicit HTML attributes are skipped in autoSize mode — there we want
        // Flying Saucer to compute the fitted size from max-width.
        String sizeAttrs = autoSize ? '' : (' width="' + widthPx + '" height="' + heightPx + '"');

        if (
            imageValue.startsWith('/sfc/') ||
            imageValue.startsWith('/servlet/') ||
            imageValue.startsWith('/apex/') ||
            imageValue.startsWithIgnoreCase('http')
        ) {
            return '<img src="' +
                imageValue +
                '"' +
                sizeAttrs +
                ' style="' +
                sizeStyle +
                'image-orientation:from-image;" />';
        }

        String mimeType = 'image/png';
        if (imageValue.startsWith('/9j/') || imageValue.startsWith('/9J/')) {
            mimeType = 'image/jpeg';
        }

        return '<img src="data:' +
            mimeType +
            ';base64,' +
            imageValue +
            '"' +
            sizeAttrs +
            ' style="' +
            sizeStyle +
            'image-orientation:from-image;" />';
    }

    /**
     * Processes a <w:pict> element (VML — used by Word watermarks and legacy images).
     * Extracts the image relationship from <v:imagedata r:id="..."/> and renders an <img>.
     * Watermark detection: the pict's <v:shape> usually has style containing "rotation:" or
     * "mso-position-horizontal:center" plus a <v:fill opacity=".5"/> child. When detected,
     * we render the image as a centered, rotated, semi-transparent overlay so Flying Saucer
     * approximates Word's watermark look.
     */
    private static String processPict(String pictXml, Map<String, String> images) {
        String relId = extractAttr(pictXml, 'v:imagedata', 'r:id');
        if (relId == null) {
            relId = extractAttr(pictXml, 'v:imagedata', 'r:pict');
        }
        if (relId == null) {
            return '';
        }

        String imageValue = images.get(relId);
        if (imageValue == null) {
            return '';
        }

        // Use 'v:shape ' (trailing space) to disambiguate from <v:shapetype>
        // which is the shape DEFINITION, not the instance with dimensions.
        // extractAttr's substring match would otherwise grab the shapetype's
        // style (none) and fall back to default sizes.
        String shapeStyle = extractAttr(pictXml, 'v:shape ', 'style');
        if (shapeStyle == null) {
            shapeStyle = '';
        }
        String shapeStyleLower = shapeStyle.toLowerCase();

        // Strict watermark detection: only the two Word-specific identifiers.
        // The mso-position-horizontal:center / rotation: heuristics matched any
        // centered/rotated header logo and incorrectly hijacked them as watermarks
        // (pushing them to @page background, removing them from inline body flow).
        Boolean isWatermark = pictXml.contains('PowerPlusWaterMarkObject') || pictXml.contains('WordPictureWatermark');

        Decimal opacity = null;
        Integer fillIdx = pictXml.indexOf('<v:fill ');
        if (fillIdx != -1) {
            Integer fillEnd = pictXml.indexOf('>', fillIdx);
            if (fillEnd != -1) {
                String fillTag = pictXml.substring(fillIdx, fillEnd);
                Integer opIdx = fillTag.indexOf('opacity="');
                if (opIdx != -1) {
                    Integer opStart = opIdx + 9;
                    Integer opEnd = fillTag.indexOf('"', opStart);
                    if (opEnd != -1) {
                        try {
                            opacity = Decimal.valueOf(fillTag.substring(opStart, opEnd));
                        } catch (Exception e) {
                        }
                    }
                }
            }
        }
        // Note: Word's "Washout" markers (<v:imagedata gain="..." blacklevel="..."/>)
        // are intentionally NOT translated into opacity. Flying Saucer's rendering
        // can't approximate Word's gain/contrast adjustments, and the resulting
        // values were too aggressive (showing the watermark at ~34% strength when
        // a true washout looks more like 5–15%). Default opacity below produces a
        // strong wash that matches what users expect from "Washout" in Word.

        Integer rotation = 0;
        Integer rotIdx = shapeStyleLower.indexOf('rotation:');
        if (rotIdx != -1) {
            Integer rotStart = rotIdx + 9;
            Integer rotEnd = rotStart;
            while (rotEnd < shapeStyle.length()) {
                String ch = shapeStyle.substring(rotEnd, rotEnd + 1);
                if (ch == ';' || ch == ' ') {
                    break;
                }
                rotEnd++;
            }
            String rotStr = shapeStyle.substring(rotStart, rotEnd).replace('deg', '').trim();
            try {
                rotation = Integer.valueOf(Decimal.valueOf(rotStr).round());
            } catch (Exception e) {
            }
        }

        Integer widthPx = 0;
        Integer heightPx = 0;
        Integer wIdx = shapeStyleLower.indexOf('width:');
        if (wIdx != -1) {
            Integer wStart = wIdx + 6;
            Integer wEnd = shapeStyle.indexOf(';', wStart);
            if (wEnd == -1) {
                wEnd = shapeStyle.length();
            }
            String wStr = shapeStyle.substring(wStart, wEnd).trim();
            widthPx = parseVmlLengthToPx(wStr);
        }
        Integer hIdx = shapeStyleLower.indexOf('height:');
        if (hIdx != -1) {
            Integer hStart = hIdx + 7;
            Integer hEnd = shapeStyle.indexOf(';', hStart);
            if (hEnd == -1) {
                hEnd = shapeStyle.length();
            }
            String hStr = shapeStyle.substring(hStart, hEnd).trim();
            heightPx = parseVmlLengthToPx(hStr);
        }
        if (widthPx <= 0) {
            widthPx = isWatermark ? 480 : 200;
        }
        if (heightPx <= 0) {
            heightPx = isWatermark ? 240 : 150;
        }

        String src;
        if (
            imageValue.startsWith('/sfc/') ||
            imageValue.startsWith('/servlet/') ||
            imageValue.startsWith('/apex/') ||
            imageValue.startsWithIgnoreCase('http')
        ) {
            src = imageValue;
        } else {
            String mimeType = 'image/png';
            if (imageValue.startsWith('/9j/') || imageValue.startsWith('/9J/')) {
                mimeType = 'image/jpeg';
            }
            src = 'data:' + mimeType + ';base64,' + imageValue;
        }

        if (isWatermark) {
            // Watermarks fill the entire page. The wrapper is sized to the parsed
            // page dimensions (or letter 8.5×11 default) and centered via top:50%/
            // left:50% + negative margins. The image inside uses width:100%/
            // height:100%/object-fit:contain so the watermark scales up to span
            // the full page while preserving its native aspect ratio. VML-declared
            // dimensions are intentionally ignored for watermarks — Word's defaults
            // (often 4–5 inches) leave too much empty space; users picking a
            // watermark expect it to span the page like a real document watermark.
            Decimal effOpacity = (opacity != null) ? opacity : 0.05;
            Decimal whiteAlpha = 1 - effOpacity;
            if (whiteAlpha > 0.95) {
                whiteAlpha = 0.95;
            }
            if (whiteAlpha < 0.85) {
                whiteAlpha = 0.85;
            }
            // Watermarks emit a marker; extractWatermarks() reads it and converts
            // into @page { background-image: url(...) } CSS — Flying Saucer's
            // documented page-background mechanism that truly extends to the
            // page bleed (position:fixed clips at the content-area boundary,
            // and oversizing tricks didn't escape the clip). Body content keeps
            // its normal margin behavior; watermark fills the entire page.
            return '<!--DGWM:src=' + src + '|wash=' + whiteAlpha + '|w=' + widthPx + '|h=' + heightPx + '-->';
        }

        String style =
            'max-width:' +
            widthPx +
            'px;max-height:' +
            heightPx +
            'px;height:auto;width:auto;image-orientation:from-image;';
        if (opacity != null) {
            style += 'opacity:' + opacity + ';';
        }
        return '<img src="' + src + '" style="' + style + '" />';
    }

    /**
     * Extracts an attribute value from a single tag string (no element search).
     * E.g., extractAttrFromTag('<v:imagedata gain=".26" blacklevel="22938f"/>', 'gain') → '.26'.
     */
    private static String extractAttrFromTag(String tag, String attrName) {
        if (String.isBlank(tag)) {
            return null;
        }
        String marker = ' ' + attrName + '="';
        Integer idx = tag.indexOf(marker);
        if (idx == -1) {
            marker = ' ' + attrName + '=\'';
            idx = tag.indexOf(marker);
            if (idx == -1) {
                return null;
            }
        }
        String quote = tag.substring(idx + marker.length() - 1, idx + marker.length());
        Integer valStart = idx + marker.length();
        Integer valEnd = tag.indexOf(quote, valStart);
        if (valEnd == -1) {
            return null;
        }
        return tag.substring(valStart, valEnd);
    }

    /**
     * Pulls <!--DGWM:src=...|wash=...--> markers out of header/footer HTML and
     * synthesizes the S-Docs-style background CSS:
     *   html { background: url(SRC) center center fixed no-repeat; background-size: 70% auto; }
     *   body { background-color: rgba(255,255,255, WASH); }
     * Returns map: 'html' (cleaned input), 'htmlBg' (CSS for html selector), 'bodyBg' (CSS for body selector).
     */
    private static Map<String, String> extractWatermarks(String html) {
        Map<String, String> result = new Map<String, String>{ 'html' => '', 'watermarks' => '', 'pageBgCss' => '' };
        if (String.isBlank(html)) {
            result.put('html', html != null ? html : '');
            return result;
        }

        String marker = '<!--DGWM:';
        String cleaned = '';
        String firstSrc = null;
        Decimal washAlpha = 0;
        Integer firstWidthPx = 0;
        Integer firstHeightPx = 0;
        Integer cursor = 0;
        while (cursor < html.length()) {
            Integer start = html.indexOf(marker, cursor);
            if (start == -1) {
                cleaned += html.substring(cursor);
                break;
            }
            cleaned += html.substring(cursor, start);
            Integer endMark = html.indexOf('-->', start);
            if (endMark == -1) {
                cleaned += html.substring(start);
                break;
            }
            String payload = html.substring(start + marker.length(), endMark);
            String src = null;
            String washStr = null;
            String wStr = null;
            String hStr = null;
            for (String part : payload.split('\\|')) {
                if (part.startsWith('src=')) {
                    src = part.substring(4);
                } else if (part.startsWith('wash=')) {
                    washStr = part.substring(5);
                } else if (part.startsWith('w=')) {
                    wStr = part.substring(2);
                } else if (part.startsWith('h=')) {
                    hStr = part.substring(2);
                }
            }
            if (src != null && firstSrc == null) {
                firstSrc = src;
                if (wStr != null && wStr.isNumeric()) {
                    firstWidthPx = Integer.valueOf(wStr);
                }
                if (hStr != null && hStr.isNumeric()) {
                    firstHeightPx = Integer.valueOf(hStr);
                }
            }
            if (washStr != null) {
                try {
                    Decimal w = Decimal.valueOf(washStr);
                    if (w > washAlpha) {
                        washAlpha = w;
                    }
                } catch (Exception e) {
                }
            }
            cursor = endMark + 3;
        }
        if (firstSrc != null) {
            // @page background-image is the only Flying Saucer mechanism that
            // bleeds past page margins. background-size with explicit pt/% is
            // ignored — but 'contain' IS honored (scales image to fit page,
            // preserving aspect). Since Word's VML watermark dimensions and
            // the page dimensions usually share the same aspect ratio (Word
            // sizes watermarks proportional to page), 'contain' produces the
            // user's intended scale automatically.
            // sanitizeCssUrlToken strips quotes/parens/whitespace so a malformed
            // watermark src can't break out of the surrounding url('...') token.
            String pageBgCss =
                'background-image: url(\'' +
                sanitizeCssUrlToken(firstSrc) +
                '\'); ' +
                'background-position: center center; background-repeat: no-repeat; ' +
                'background-size: contain;';
            result.put('pageBgCss', pageBgCss);
        }
        result.put('html', cleaned);
        return result;
    }

    /**
     * Parses a VML length value like "468pt", "6.5in", "240px" into pixels.
     */
    private static Integer parseVmlLengthToPx(String val) {
        if (String.isBlank(val)) {
            return 0;
        }
        String unit = '';
        String num = val;
        for (String u : new List<String>{ 'pt', 'in', 'cm', 'mm', 'px', 'em' }) {
            if (val.endsWith(u)) {
                unit = u;
                num = val.substring(0, val.length() - u.length());
                break;
            }
        }
        Decimal n;
        try {
            n = Decimal.valueOf(num.trim());
        } catch (Exception e) {
            return 0;
        }
        if (unit == 'pt') {
            return Math.round(n * 96 / 72);
        }
        if (unit == 'in') {
            return Math.round(n * 96);
        }
        if (unit == 'cm') {
            return Math.round(n * 96 / 2.54);
        }
        if (unit == 'mm') {
            return Math.round(n * 96 / 25.4);
        }
        if (unit == 'em') {
            return Math.round(n * 16);
        }
        return Math.round(n);
    }

    // ===== XML PARSING UTILITIES =====

    /**
     * Extracts all text content from <w:t> elements within the given XML.
     */
    private static String extractTextContent(String xml) {
        String result = '';
        Integer cursor = 0;

        while (cursor < xml.length()) {
            Integer tStart = xml.indexOf('<w:t', cursor);
            if (tStart == -1) {
                break;
            }

            // Skip self-closing <w:t/>
            Integer tagEnd = xml.indexOf('>', tStart);
            if (tagEnd == -1) {
                break;
            }

            if (xml.substring(tagEnd - 1, tagEnd) == '/') {
                cursor = tagEnd + 1;
                continue;
            }

            Integer contentStart = tagEnd + 1;
            Integer tEnd = xml.indexOf('</w:t>', contentStart);
            if (tEnd == -1) {
                break;
            }

            result += xml.substring(contentStart, tEnd);
            cursor = tEnd + 6; // length of </w:t>
        }

        return unescapeXmlEntities(result);
    }

    /**
     * Unescapes standard XML entities so downstream escapeHtml4() doesn't double-encode.
     */
    @TestVisible
    private static String unescapeXmlEntities(String text) {
        if (String.isBlank(text)) {
            return text;
        }
        text = decodeNumericEntities(text);
        text = text.replace('&amp;', '&');
        text = text.replace('&lt;', '<');
        text = text.replace('&gt;', '>');
        text = text.replace('&apos;', '\'');
        text = text.replace('&quot;', '"');
        return text;
    }

    /**
     * Decodes numeric character references: &#NNNN; (decimal) and &#xHH; (hex).
     * Leaves named entities and malformed sequences untouched. Skips C0 control codes
     * other than tab/LF/CR so we don't inject anything that breaks downstream XML.
     */
    @TestVisible
    private static String decodeNumericEntities(String text) {
        if (text == null || text.indexOf('&#') == -1) {
            return text;
        }
        String result = '';
        Integer cursor = 0;
        Integer len = text.length();
        while (cursor < len) {
            Integer amp = text.indexOf('&#', cursor);
            if (amp == -1) {
                result += text.substring(cursor);
                break;
            }
            result += text.substring(cursor, amp);
            Integer semi = text.indexOf(';', amp);
            if (semi == -1 || semi - amp > 10) {
                result += text.substring(amp, amp + 2);
                cursor = amp + 2;
                continue;
            }
            String body = text.substring(amp + 2, semi);
            Integer codepoint = -1;
            if (body.length() > 1 && (body.startsWith('x') || body.startsWith('X'))) {
                String hex = body.substring(1);
                if (hex.length() <= 6 && hex.toLowerCase().replaceAll('[0-9a-f]', '').length() == 0) {
                    codepoint = parseHex(hex);
                }
            } else if (body.length() > 0 && body.isNumeric()) {
                try {
                    codepoint = Integer.valueOf(body);
                } catch (Exception e) {
                    codepoint = -1;
                }
            }
            if (
                codepoint >= 0 &&
                codepoint <= 1114111 &&
                (codepoint == 9 ||
                codepoint == 10 ||
                codepoint == 13 ||
                codepoint >= 32)
            ) {
                result += String.fromCharArray(new List<Integer>{ codepoint });
                cursor = semi + 1;
            } else {
                result += text.substring(amp, amp + 2);
                cursor = amp + 2;
            }
        }
        return result;
    }

    private static Integer parseHex(String hex) {
        Integer value = 0;
        for (Integer i = 0; i < hex.length(); i++) {
            Integer code = hex.substring(i, i + 1).toLowerCase().charAt(0);
            Integer digit;
            if (code >= 48 && code <= 57) {
                digit = code - 48;
            } else if (code >= 97 && code <= 102) {
                digit = code - 87;
            } else {
                return -1;
            }
            value = value * 16 + digit;
        }
        return value;
    }

    /**
     * Extracts the first occurrence of an element's content.
     * Returns the content including the element's own tags.
     */
    private static String extractElement(String xml, String tagName) {
        Integer start = xml.indexOf('<' + tagName);
        if (start == -1) {
            return null;
        }

        // Check for self-closing
        Integer tagEnd = xml.indexOf('>', start);
        if (tagEnd == -1) {
            return null;
        }
        if (xml.substring(tagEnd - 1, tagEnd) == '/') {
            return xml.substring(start, tagEnd + 1);
        }

        Integer endPos = findClosingTag(xml, start, tagName);
        if (endPos == -1) {
            return xml.substring(start, tagEnd + 1);
        }
        return xml.substring(start, endPos);
    }

    /**
     * Extracts an attribute value from a specific element.
     * E.g., extractAttr(xml, 'w:jc', 'w:val') from <w:jc w:val="center"/>
     */
    private static String extractAttr(String xml, String tagName, String attrName) {
        Integer tagStart = xml.indexOf('<' + tagName);
        if (tagStart == -1) {
            return null;
        }

        Integer tagEnd = xml.indexOf('>', tagStart);
        if (tagEnd == -1) {
            return null;
        }

        String tagContent = xml.substring(tagStart, tagEnd + 1);

        // Try double quotes
        String searchDouble = attrName + '="';
        Integer attrStart = tagContent.indexOf(searchDouble);
        String quoteUsed = '"';

        if (attrStart == -1) {
            // Try single quotes
            String searchSingle = attrName + '=\'';
            attrStart = tagContent.indexOf(searchSingle);
            quoteUsed = '\'';
        }

        if (attrStart == -1) {
            return null;
        }

        Integer valueStart = attrStart + attrName.length() + 2; // skip attr=" or attr='
        Integer valueEnd = tagContent.indexOf(quoteUsed, valueStart);
        if (valueEnd == -1) {
            return null;
        }

        return tagContent.substring(valueStart, valueEnd);
    }

    /**
     * Finds the position after the closing tag, handling nesting.
     * Returns the position after </tagName>.
     */
    private static Integer findClosingTag(String xml, Integer startPos, String tagName) {
        String openTag = '<' + tagName;
        String closeTag = '</' + tagName + '>';
        Integer depth = 0;
        Integer cursor = startPos;

        while (cursor < xml.length()) {
            Integer nextOpen = xml.indexOf(openTag, cursor);
            Integer nextClose = xml.indexOf(closeTag, cursor);

            if (nextClose == -1) {
                return -1;
            }

            if (nextOpen != -1 && nextOpen < nextClose) {
                // Check if it's actually the tag (not a prefix match like <w:tblPr matching <w:tbl)
                Integer afterOpen = nextOpen + openTag.length();
                Boolean isRealTag =
                    afterOpen < xml.length() &&
                    (xml.substring(afterOpen, afterOpen + 1) == '>' ||
                    xml.substring(afterOpen, afterOpen + 1) == ' ' ||
                    xml.substring(afterOpen, afterOpen + 1) == '/');
                if (isRealTag) {
                    depth++;
                    cursor = afterOpen;
                    continue;
                }
                // Not a real match, skip past it
                cursor = afterOpen;
            } else {
                depth--;
                if (depth == 0) {
                    return nextClose + closeTag.length();
                }
                cursor = nextClose + closeTag.length();
            }
        }
        return -1;
    }

    /**
     * Converts twips to points.
     */
    private static Decimal twipsToPt(Integer twips) {
        return twips * TWIPS_TO_PT;
    }

    /**
     * Sanitizes a value bound for inline CSS (color/fill/font/etc.) so that a
     * malformed DOCX attribute can't break out of the surrounding `style="..."`
     * declaration. Strips the CSS reserved chars (`;` `}` `{` `:` `<` `>` `"` `'`
     * `(` `)` `\\` newline) and returns the cleaned value. Returns null if the
     * input is null. The trust boundary is "admin uploaded the DOCX," but the
     * preview HTML reaches a browser via LWC `innerHTML`, so this is
     * defense-in-depth against a malicious template.
     */
    private static String sanitizeCssToken(String val) {
        if (val == null) {
            return null;
        }
        // Block: control chars, quotes, parens, braces, semicolon, colon, lt/gt, backslash, whitespace newlines
        return val.replaceAll('[\\u0000-\\u001F;{}<>"\'\\\\()\\r\\n]', '');
    }

    /**
     * Sanitizes a value bound for a CSS `url(...)` token. Same treatment as
     * sanitizeCssToken plus blocks the comment sequences `/*` and `*\/`. The
     * watermark page-background path concatenates a CV-derived path here; the
     * caller-controlled portion is strictly numeric in normal flow, but a
     * malformed DOCX could otherwise smuggle a `'` to break out of url('...').
     */
    private static String sanitizeCssUrlToken(String val) {
        if (val == null) {
            return null;
        }
        String cleaned = val.replaceAll('[\\u0000-\\u001F"\'\\\\()\\r\\n\\s]', '');
        // Block CSS comment delimiters defensively
        cleaned = cleaned.replace('/*', '').replace('*/', '');
        return cleaned;
    }

    // Inner class for list detection
    private class ListInfo {
        Boolean isList;
        Boolean isNumbered;
    }

    // ---------------------------------------------------------------------------
    // Barcode rendering — CSS bars for Blob.toPdf()
    // ---------------------------------------------------------------------------

    /**
     * Detects ##BARCODE:type:value## markers in text and renders as HTML/CSS bars.
     * No images needed — Blob.toPdf() renders CSS perfectly.
     */
    public static String renderBarcodeHtml(String text) {
        // Extract marker: ##BARCODE:type:size:VALUE##
        Integer startIdx = text.indexOf('##BARCODE:');
        if (startIdx == -1) {
            return text.escapeHtml4();
        }
        Integer endIdx = text.indexOf('##', startIdx + 10);
        if (endIdx == -1) {
            return text.escapeHtml4();
        }

        String marker = text.substring(startIdx + 10, endIdx);
        List<String> parts = marker.split(':', 3);
        String barcodeType = parts[0];
        String sizeSpec = parts.size() > 1 ? parts[1] : '';
        String value = parts.size() > 2 ? parts[2] : '';

        // Unescape XML entities
        value = value.replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>');

        String pattern = BarcodeGenerator.getPattern(value, barcodeType);
        if (pattern == null) {
            return value.escapeHtml4();
        }

        String html;
        if (barcodeType == 'qr') {
            html = renderQrHtml(pattern, sizeSpec);
        } else {
            html = renderCode128Html(pattern, sizeSpec);
        }

        String before = text.substring(0, startIdx);
        String after = text.substring(endIdx + 2);
        return (String.isNotBlank(before) ? before.escapeHtml4() : '') +
            html +
            (String.isNotBlank(after) ? after.escapeHtml4() : '');
    }

    /** Renders Code 128 as inline CSS bars. */
    private static String renderCode128Html(String pattern, String sizeSpec) {
        // Parse size: "300x80" or default
        Integer barWidth = 1;
        Integer barHeight = 50;
        if (String.isNotBlank(sizeSpec) && sizeSpec.contains('x')) {
            List<String> dims = sizeSpec.split('x');
            if (dims.size() == 2 && dims[0].trim().isNumeric() && dims[1].trim().isNumeric()) {
                barWidth = Math.max(1, Integer.valueOf(dims[0].trim()) / pattern.length());
                barHeight = Integer.valueOf(dims[1].trim());
            }
        }

        String html = '<div style="display:inline-block;white-space:nowrap;line-height:0;">';
        for (Integer i = 0; i < pattern.length(); i++) {
            String color = pattern.substring(i, i + 1) == '1' ? '#000' : '#fff';
            html +=
                '<span style="display:inline-block;width:' +
                barWidth +
                'px;height:' +
                barHeight +
                'px;background:' +
                color +
                ';"></span>';
        }
        html += '</div>';
        return html;
    }

    /** Renders QR code with absolute positioning — zero-gap guarantee in Flying Saucer. */
    private static String renderQrHtml(String pattern, String sizeSpec) {
        List<String> rows = pattern.split('\n');
        Integer modules = rows.size();

        // Parse size: single number = total px, default 250 (square)
        Integer totalPx = 250;
        if (String.isNotBlank(sizeSpec) && sizeSpec.trim().isNumeric()) {
            totalPx = Integer.valueOf(sizeSpec.trim());
        }

        // QR spec requires 4-module quiet zone on each side
        Integer quietZone = 4;
        Integer totalModules = modules + (quietZone * 2);
        Integer cellPx = Math.max(3, totalPx / totalModules);
        Integer quietPx = cellPx * quietZone;
        Integer totalSizePx = cellPx * totalModules;

        // Relative container with white background; only black modules are emitted
        // as absolutely positioned spans. No layout engine gaps possible.
        String html =
            '<div style="position:relative;display:inline-block;width:' +
            totalSizePx +
            'px;height:' +
            totalSizePx +
            'px;background:#fff;">';

        Integer yPx = quietPx;
        for (Integer r = 0; r < rows.size(); r++) {
            String row = rows[r];
            Integer c = 0;
            while (c < row.length()) {
                String bit = row.substring(c, c + 1);
                Integer run = 1;
                while (c + run < row.length() && row.substring(c + run, c + run + 1) == bit) {
                    run++;
                }
                // Only emit black modules; white is the container background
                if (bit == '1') {
                    Integer xPx = quietPx + (c * cellPx);
                    html +=
                        '<span style="position:absolute;left:' +
                        xPx +
                        'px;top:' +
                        yPx +
                        'px;width:' +
                        (cellPx * run) +
                        'px;height:' +
                        cellPx +
                        'px;background:#000;"></span>';
                }
                c += run;
            }
            yPx += cellPx;
        }

        html += '</div>';
        return html;
    }
}

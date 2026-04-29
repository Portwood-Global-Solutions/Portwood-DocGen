/**
 * Extracts the first embedded image from a PDF (base64-encoded).
 *
 * Use case: server renders a single-image PDF via Blob.toPdf() — the only
 * Salesforce-platform path that can fetch Lightning rich text inline images
 * (0EM ContentReference) without session-ID exposure or LWS/CORS issues.
 * We pull the embedded /XObject /Image stream out of that PDF and use it
 * as the image bytes for DOCX assembly.
 *
 * Filters handled:
 *   - DCTDecode: raw JPEG bytes — use directly
 *   - JPXDecode: JPEG 2000 — pass through (Word may or may not render it)
 *   - FlateDecode: zlib-compressed raw pixels — re-encoded as PNG via the
 *     browser-native DecompressionStream / CompressionStream APIs (no deps)
 *
 * Returns { base64, mediaType, ext } or null if no extractable image found.
 */

function latin1Decode(bytes) {
    let s = '';
    for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    return s;
}

function base64ToBytes(b64) {
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
}

function bytesToBase64(bytes) {
    let bin = '';
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) {
        bin += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return btoa(bin);
}

function indexAllImageObjects(bytes) {
    const str = latin1Decode(bytes);
    const objRe = /\b(\d+)\s+0\s+obj\b/g;
    let m;
    const byObjNum = new Map();
    const list = [];
    while ((m = objRe.exec(str)) !== null) {
        const objNum = parseInt(m[1], 10);
        const headerEnd = m.index + m[0].length;
        const endIdx = str.indexOf('endobj', headerEnd);
        if (endIdx === -1) continue;
        const body = str.substring(headerEnd, endIdx);
        if (!/\/Subtype\s*\/Image/.test(body)) continue;
        const si = body.indexOf('stream');
        if (si === -1) continue;
        const dictText = body.substring(0, si);
        let dStart = headerEnd + si + 6;
        if (bytes[dStart] === 0x0d) dStart++;
        if (bytes[dStart] === 0x0a) dStart++;
        const lenMatch = dictText.match(/\/Length\s+(\d+)(?!\s+\d+\s+R)/);
        let streamBytes;
        if (lenMatch) {
            const len = parseInt(lenMatch[1], 10);
            streamBytes = bytes.slice(dStart, dStart + len);
        } else {
            const esIdx = str.indexOf('endstream', dStart);
            let dEnd = esIdx;
            if (bytes[dEnd - 1] === 0x0a) dEnd--;
            if (bytes[dEnd - 1] === 0x0d) dEnd--;
            streamBytes = bytes.slice(dStart, dEnd);
        }
        const isColor = /\/(?:Cal)?RGB/.test(dictText) || /\/DeviceRGB/.test(dictText);
        const isGray = /\/(?:Cal)?Gray/.test(dictText) || /\/DeviceGray/.test(dictText);
        const smaskMatch = dictText.match(/\/SMask\s+(\d+)\s+0\s+R/);
        const smaskRef = smaskMatch ? parseInt(smaskMatch[1], 10) : null;
        const entry = { objNum, dictText, streamBytes, isColor, isGray, smaskRef };
        list.push(entry);
        byObjNum.set(objNum, entry);
    }
    return { list, byObjNum };
}

function pickPrimaryImage(index) {
    if (index.list.length === 0) return null;
    // Prefer a color image; fall back to first available
    const color = index.list.find((c) => c.isColor);
    return color || index.list[0];
}

// ===== PNG re-encoding for FlateDecode'd PDF images =====

const CRC_TABLE = (() => {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
        t[n] = c;
    }
    return t;
})();

function crc32(bytes) {
    let c = 0xffffffff;
    for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
}

function writeUint32BE(arr, offset, val) {
    arr[offset] = (val >>> 24) & 0xff;
    arr[offset + 1] = (val >>> 16) & 0xff;
    arr[offset + 2] = (val >>> 8) & 0xff;
    arr[offset + 3] = val & 0xff;
}

function buildPngChunk(typeStr, data) {
    const typeBytes = new Uint8Array(4);
    for (let i = 0; i < 4; i++) typeBytes[i] = typeStr.charCodeAt(i);
    const chunk = new Uint8Array(8 + data.length + 4);
    writeUint32BE(chunk, 0, data.length);
    chunk.set(typeBytes, 4);
    chunk.set(data, 8);
    // CRC covers type + data
    const crcInput = new Uint8Array(4 + data.length);
    crcInput.set(typeBytes, 0);
    crcInput.set(data, 4);
    writeUint32BE(chunk, 8 + data.length, crc32(crcInput));
    return chunk;
}

async function inflate(deflated) {
    // PDF FlateDecode is zlib-wrapped (RFC 1950), not raw deflate. Use 'deflate' format.
    const stream = new Blob([deflated]).stream().pipeThrough(new DecompressionStream('deflate'));
    const buf = await new Response(stream).arrayBuffer();
    return new Uint8Array(buf);
}

async function deflate(rawData) {
    const stream = new Blob([rawData]).stream().pipeThrough(new CompressionStream('deflate'));
    const buf = await new Response(stream).arrayBuffer();
    return new Uint8Array(buf);
}

/**
 * Reverses PDF's PNG-up predictor (Predictor 11–15). Each scanline is prefixed
 * with a filter byte; for "PNG None" (the only one Flying Saucer typically
 * emits), the filter byte is 0 and the row is raw pixels. We strip the filter
 * bytes for our re-encoding (we'll re-add filter 0 ourselves).
 */
function stripPdfPngPredictor(pixels, width, bytesPerPixel) {
    const rowLen = width * bytesPerPixel;
    const rowsWithFilter = rowLen + 1;
    const rows = pixels.length / rowsWithFilter;
    if (!Number.isInteger(rows)) return pixels; // not predictor-encoded
    const out = new Uint8Array(rowLen * rows);
    for (let r = 0; r < rows; r++) {
        out.set(pixels.subarray(r * rowsWithFilter + 1, r * rowsWithFilter + 1 + rowLen), r * rowLen);
    }
    return out;
}

function parseImageDictParams(dictText) {
    const widthMatch = dictText.match(/\/Width\s+(\d+)/);
    const heightMatch = dictText.match(/\/Height\s+(\d+)/);
    const bitDepthMatch = dictText.match(/\/BitsPerComponent\s+(\d+)/);
    const csMatch = dictText.match(/\/ColorSpace\s*\[?\s*\/(\w+)/);
    if (!widthMatch || !heightMatch) return null;
    return {
        width: parseInt(widthMatch[1], 10),
        height: parseInt(heightMatch[1], 10),
        bitDepth: bitDepthMatch ? parseInt(bitDepthMatch[1], 10) : 8,
        colorSpace: csMatch ? csMatch[1] : 'DeviceRGB',
        hasPredictor: /\/Predictor\s+(\d+)/.test(dictText)
    };
}

async function decodeFlatePixels(streamBytes, params) {
    let pixels;
    try {
        pixels = await inflate(streamBytes);
    } catch (e) {
        console.warn('[DocGen PDF→PNG] inflate failed:', e);
        return null;
    }
    let bytesPerPixel;
    if (params.colorSpace === 'DeviceGray' || params.colorSpace === 'CalGray') bytesPerPixel = 1;
    else if (params.colorSpace === 'DeviceRGB' || params.colorSpace === 'CalRGB' || params.colorSpace === 'sRGB')
        bytesPerPixel = 3;
    else {
        console.warn('[DocGen PDF→PNG] unsupported color space:', params.colorSpace);
        return null;
    }
    if (params.hasPredictor) pixels = stripPdfPngPredictor(pixels, params.width, bytesPerPixel);
    return { pixels, bytesPerPixel };
}

function assemblePng(width, height, bitDepth, colorType, compressedIdat) {
    const sig = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    const ihdrData = new Uint8Array(13);
    writeUint32BE(ihdrData, 0, width);
    writeUint32BE(ihdrData, 4, height);
    ihdrData[8] = bitDepth;
    ihdrData[9] = colorType;
    ihdrData[10] = 0;
    ihdrData[11] = 0;
    ihdrData[12] = 0;
    const ihdr = buildPngChunk('IHDR', ihdrData);
    const idat = buildPngChunk('IDAT', compressedIdat);
    const iend = buildPngChunk('IEND', new Uint8Array(0));
    const png = new Uint8Array(sig.length + ihdr.length + idat.length + iend.length);
    let off = 0;
    png.set(sig, off);
    off += sig.length;
    png.set(ihdr, off);
    off += ihdr.length;
    png.set(idat, off);
    off += idat.length;
    png.set(iend, off);
    return png;
}

/**
 * Builds an RGBA PNG by composing a CalRGB/DeviceRGB color image with its
 * SMask DeviceGray alpha channel. Flying Saucer splits RGBA PNG sources into
 * separate color + alpha PDF objects; we re-merge them so DOCX gets proper
 * transparency instead of a black background where alpha was.
 */
async function buildRgbaPngFromColorPlusSMask(colorEntry, smaskEntry) {
    const cp = parseImageDictParams(colorEntry.dictText);
    const sp = parseImageDictParams(smaskEntry.dictText);
    if (!cp || !sp) return null;
    if (cp.width !== sp.width || cp.height !== sp.height) {
        console.warn('[DocGen PDF→PNG] color/SMask dim mismatch; falling back to opaque RGB');
        return null;
    }
    const color = await decodeFlatePixels(colorEntry.streamBytes, cp);
    const alpha = await decodeFlatePixels(smaskEntry.streamBytes, sp);
    if (!color || !alpha || color.bytesPerPixel !== 3 || alpha.bytesPerPixel !== 1) return null;
    const w = cp.width,
        h = cp.height;
    const rowLen = w * 4;
    const filtered = new Uint8Array((rowLen + 1) * h);
    for (let y = 0; y < h; y++) {
        filtered[y * (rowLen + 1)] = 0;
        for (let x = 0; x < w; x++) {
            const sRgb = (y * w + x) * 3;
            const sA = y * w + x;
            const dst = y * (rowLen + 1) + 1 + x * 4;
            filtered[dst] = color.pixels[sRgb];
            filtered[dst + 1] = color.pixels[sRgb + 1];
            filtered[dst + 2] = color.pixels[sRgb + 2];
            filtered[dst + 3] = alpha.pixels[sA];
        }
    }
    const compressed = await deflate(filtered);
    return assemblePng(w, h, 8, 6 /* RGBA */, compressed);
}

async function buildPngFromSingleEntry(entry) {
    const params = parseImageDictParams(entry.dictText);
    if (!params) return null;
    const decoded = await decodeFlatePixels(entry.streamBytes, params);
    if (!decoded) return null;
    let colorType;
    if (decoded.bytesPerPixel === 1) colorType = 0;
    else if (decoded.bytesPerPixel === 3) colorType = 2;
    else return null;
    const rowLen = params.width * decoded.bytesPerPixel;
    const filtered = new Uint8Array((rowLen + 1) * params.height);
    for (let y = 0; y < params.height; y++) {
        filtered[y * (rowLen + 1)] = 0;
        filtered.set(decoded.pixels.subarray(y * rowLen, (y + 1) * rowLen), y * (rowLen + 1) + 1);
    }
    const compressed = await deflate(filtered);
    return assemblePng(params.width, params.height, params.bitDepth, colorType, compressed);
}

/**
 * Fetches an image URL and returns its bytes as base64.
 * @param {string} pdfBase64 base64-encoded PDF rendered by DocGenController.renderImageAsPdfBase64
 * @returns {Promise<{base64:string,mediaType:string,ext:string}|null>}
 */
export async function extractFirstImageFromPdfBase64(pdfBase64) {
    if (!pdfBase64) return null;
    let bytes;
    try {
        bytes = base64ToBytes(pdfBase64);
    } catch (e) {
        console.warn('[DocGen] PDF base64 decode failed', e);
        return null;
    }

    const index = indexAllImageObjects(bytes);
    const primary = pickPrimaryImage(index);
    if (!primary) return null;

    const dictParams = parseImageDictParams(primary.dictText);
    const width = dictParams ? dictParams.width : null;
    const height = dictParams ? dictParams.height : null;

    if (/\/Filter\s*(?:\[\s*)?\/DCTDecode/.test(primary.dictText)) {
        return { base64: bytesToBase64(primary.streamBytes), mediaType: 'image/jpeg', ext: 'jpeg', width, height };
    }
    if (/\/Filter\s*(?:\[\s*)?\/JPXDecode/.test(primary.dictText)) {
        return { base64: bytesToBase64(primary.streamBytes), mediaType: 'image/jp2', ext: 'jp2', width, height };
    }
    if (/\/Filter\s*(?:\[\s*)?\/FlateDecode/.test(primary.dictText)) {
        if (primary.smaskRef && index.byObjNum.has(primary.smaskRef)) {
            const smask = index.byObjNum.get(primary.smaskRef);
            const rgba = await buildRgbaPngFromColorPlusSMask(primary, smask);
            if (rgba) return { base64: bytesToBase64(rgba), mediaType: 'image/png', ext: 'png', width, height };
        }
        const png = await buildPngFromSingleEntry(primary);
        if (png) return { base64: bytesToBase64(png), mediaType: 'image/png', ext: 'png', width, height };
    }

    console.warn('[DocGen] PDF image uses unsupported filter, dict:', primary.dictText.slice(0, 200));
    return null;
}

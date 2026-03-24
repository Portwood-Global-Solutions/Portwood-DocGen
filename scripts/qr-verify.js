#!/usr/bin/env node

/**
 * QR Code Verification Script
 *
 * Compares the Apex BarcodeGenerator QR output against a known-good
 * reference implementation (qrcode-generator npm package).
 *
 * Usage:
 *   # From file (paste Apex debug output):
 *   node scripts/qr-verify.js --value "HELLO" --file apex-output.txt
 *
 *   # From stdin:
 *   echo "<pattern>" | node scripts/qr-verify.js --value "HELLO"
 *
 *   # Just generate reference (no comparison):
 *   node scripts/qr-verify.js --value "HELLO" --ref-only
 *
 * Outputs:
 *   - scripts/qr-output/apex-<value>.html     (Apex pattern rendered)
 *   - scripts/qr-output/ref-<value>.html      (Reference pattern rendered)
 *   - scripts/qr-output/diff-<value>.html     (Side-by-side diff)
 *   - Console: module-by-module comparison report
 *
 * Dependencies:
 *   npm install qrcode-generator   (in the scripts/ directory or project root)
 */

const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);
let value = null;
let inputFile = null;
let refOnly = false;

for (let i = 0; i < args.length; i++) {
    if (args[i] === '--value' && args[i + 1]) value = args[++i];
    else if (args[i] === '--file' && args[i + 1]) inputFile = args[++i];
    else if (args[i] === '--ref-only') refOnly = true;
    else if (args[i] === '--help' || args[i] === '-h') {
        console.log(`Usage: node qr-verify.js --value "TEXT" [--file apex-output.txt] [--ref-only]`);
        process.exit(0);
    }
}

if (!value) {
    console.error('Error: --value is required');
    process.exit(1);
}

// ---------------------------------------------------------------------------
// Reference QR generation using qrcode-generator
// ---------------------------------------------------------------------------
let qrcodegen;
try {
    qrcodegen = require('qrcode-generator');
} catch (e) {
    console.error('Missing dependency: qrcode-generator');
    console.error('Run: npm install qrcode-generator');
    process.exit(1);
}

function generateReferenceQr(text) {
    // Type 0 = auto-detect version. ECL M = 'M'.
    // qrcode-generator uses typeNumber 0 for auto, but we want to force
    // the same version the Apex code would pick. Let's auto-detect first.
    const qr = qrcodegen(0, 'M');
    qr.addData(text, 'Byte');
    qr.make();

    const count = qr.getModuleCount();
    const rows = [];
    for (let r = 0; r < count; r++) {
        let row = '';
        for (let c = 0; c < count; c++) {
            row += qr.isDark(r, c) ? '1' : '0';
        }
        rows.push(row);
    }
    return { pattern: rows.join('\n'), size: count };
}

// ---------------------------------------------------------------------------
// Parse Apex pattern from file or stdin
// ---------------------------------------------------------------------------
function parseApexPattern(raw) {
    // Extract pattern between markers if present
    const startMarker = `===QR_START:${value}===`;
    const endMarker = `===QR_END:${value}===`;

    let pattern = raw;

    // Find markers in actual debug output lines (after |DEBUG| prefix), not Execute Anonymous lines
    const debugStartMarker = `|DEBUG|${startMarker}`;
    const debugEndMarker = `|DEBUG|${endMarker}`;
    let startIdx = raw.indexOf(debugStartMarker);
    if (startIdx === -1) startIdx = raw.indexOf(startMarker);
    if (startIdx !== -1) {
        const afterStart = raw.indexOf('\n', startIdx) + 1;
        let endIdx = raw.indexOf(debugEndMarker);
        if (endIdx === -1) endIdx = raw.indexOf(endMarker, afterStart);
        if (endIdx !== -1) {
            pattern = raw.substring(afterStart, endIdx);
        }
    }

    // Clean: remove debug log prefixes, blank lines, carriage returns
    const lines = pattern.split('\n')
        .map(line => {
            // Strip Salesforce debug log prefix like "XX:XX:XX.XXX (XXXXXXX)|USER_DEBUG|[N]|DEBUG|"
            const debugMatch = line.match(/\|DEBUG\|(.*)$/);
            if (debugMatch) return debugMatch[1].trim();
            return line.trim();
        })
        .filter(line => /^[01]+$/.test(line));

    if (lines.length === 0) return null;

    // Validate: all rows same length
    const width = lines[0].length;
    for (const line of lines) {
        if (line.length !== width) {
            console.error(`Row length mismatch: expected ${width}, got ${line.length}`);
            console.error(`Row: "${line}"`);
            return null;
        }
    }

    return { pattern: lines.join('\n'), size: lines.length };
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------
function compareMatrices(apexPattern, refPattern) {
    const apexRows = apexPattern.split('\n');
    const refRows = refPattern.split('\n');

    if (apexRows.length !== refRows.length) {
        return {
            match: false,
            message: `Size mismatch: Apex=${apexRows.length}x${apexRows[0].length}, Ref=${refRows.length}x${refRows[0].length}`,
            diffs: [],
            totalModules: 0,
            diffCount: 0
        };
    }

    const size = apexRows.length;
    const diffs = [];
    let totalModules = 0;

    for (let r = 0; r < size; r++) {
        for (let c = 0; c < size; c++) {
            totalModules++;
            const apexBit = apexRows[r][c];
            const refBit = refRows[r][c];
            if (apexBit !== refBit) {
                diffs.push({ row: r, col: c, apex: apexBit, ref: refBit });
            }
        }
    }

    return {
        match: diffs.length === 0,
        message: diffs.length === 0
            ? `MATCH: All ${totalModules} modules identical`
            : `MISMATCH: ${diffs.length}/${totalModules} modules differ`,
        diffs,
        totalModules,
        diffCount: diffs.length
    };
}

// ---------------------------------------------------------------------------
// HTML rendering (absolute-positioned CSS, same approach as DocGenHtmlRenderer)
// ---------------------------------------------------------------------------
function renderPatternHtml(pattern, title, diffCells) {
    const rows = pattern.split('\n');
    const size = rows.length;
    const cellPx = 8;
    const quietZone = 4;
    const totalModules = size + quietZone * 2;
    const totalSizePx = cellPx * totalModules;
    const quietPx = cellPx * quietZone;

    // Build diff lookup set
    const diffSet = new Set();
    if (diffCells) {
        for (const d of diffCells) {
            diffSet.add(`${d.row},${d.col}`);
        }
    }

    let spans = '';
    for (let r = 0; r < size; r++) {
        const row = rows[r];
        for (let c = 0; c < row.length; c++) {
            const isDiff = diffSet.has(`${r},${c}`);
            const bit = row[c];
            if (bit === '1' || isDiff) {
                const xPx = quietPx + c * cellPx;
                const yPx = quietPx + r * cellPx;
                let color = bit === '1' ? '#000' : '#fff';
                if (isDiff) color = bit === '1' ? '#c00' : '#fcc';
                spans += `<span style="position:absolute;left:${xPx}px;top:${yPx}px;width:${cellPx}px;height:${cellPx}px;background:${color};"></span>\n`;
            }
        }
    }

    return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>${title}</title>
<style>
body { font-family: monospace; padding: 20px; background: #f5f5f5; }
h2 { margin-bottom: 10px; }
.qr-container {
    position: relative;
    display: inline-block;
    width: ${totalSizePx}px;
    height: ${totalSizePx}px;
    background: #fff;
    border: 1px solid #ccc;
}
.info { margin-top: 10px; font-size: 14px; color: #333; }
</style>
</head>
<body>
<h2>${title}</h2>
<p class="info">Value: <strong>${value}</strong> | Size: ${size}x${size} (Version ${(size - 17) / 4})</p>
<div class="qr-container">
${spans}
</div>
<p class="info">Cell size: ${cellPx}px | Quiet zone: ${quietZone} modules | Total: ${totalSizePx}px</p>
${diffCells && diffCells.length > 0 ? `<p style="color:red;">Red cells = differences from reference</p>` : ''}
</body>
</html>`;
}

function renderDiffHtml(apexPattern, refPattern, comparison) {
    const apexRows = apexPattern.split('\n');
    const refRows = refPattern.split('\n');
    const size = Math.max(apexRows.length, refRows.length);
    const cellPx = 6;
    const quietZone = 4;
    const totalModules = size + quietZone * 2;
    const totalSizePx = cellPx * totalModules;
    const quietPx = cellPx * quietZone;

    const diffSet = new Set();
    for (const d of comparison.diffs) {
        diffSet.add(`${d.row},${d.col}`);
    }

    function renderGrid(rows, label) {
        let spans = '';
        for (let r = 0; r < rows.length; r++) {
            const row = rows[r];
            for (let c = 0; c < row.length; c++) {
                const isDiff = diffSet.has(`${r},${c}`);
                const bit = row[c];
                if (bit === '1' || isDiff) {
                    const xPx = quietPx + c * cellPx;
                    const yPx = quietPx + r * cellPx;
                    let color = bit === '1' ? '#000' : '#fff';
                    if (isDiff) color = bit === '1' ? '#c00' : '#fcc';
                    spans += `<span style="position:absolute;left:${xPx}px;top:${yPx}px;width:${cellPx}px;height:${cellPx}px;background:${color};"></span>\n`;
                }
            }
        }
        return `<div style="display:inline-block;margin:10px;">
<h3>${label}</h3>
<div style="position:relative;display:inline-block;width:${totalSizePx}px;height:${totalSizePx}px;background:#fff;border:1px solid #ccc;">
${spans}
</div></div>`;
    }

    return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>QR Diff: ${value}</title>
<style>
body { font-family: monospace; padding: 20px; background: #f5f5f5; }
.summary { font-size: 16px; margin: 10px 0; padding: 10px; border-radius: 4px; }
.match { background: #d4edda; color: #155724; }
.mismatch { background: #f8d7da; color: #721c24; }
table.diff-table { border-collapse: collapse; margin-top: 10px; font-size: 12px; }
table.diff-table th, table.diff-table td { border: 1px solid #ccc; padding: 2px 6px; }
</style>
</head>
<body>
<h2>QR Code Comparison: "${value}"</h2>
<div class="summary ${comparison.match ? 'match' : 'mismatch'}">
${comparison.message}
</div>
<div>
${renderGrid(apexRows, 'Apex (BarcodeGenerator)')}
${renderGrid(refRows, 'Reference (qrcode-generator)')}
</div>
${comparison.diffs.length > 0 && comparison.diffs.length <= 200 ? `
<h3>Differences (row, col): Apex vs Reference</h3>
<table class="diff-table">
<tr><th>Row</th><th>Col</th><th>Apex</th><th>Ref</th></tr>
${comparison.diffs.map(d => `<tr><td>${d.row}</td><td>${d.col}</td><td>${d.apex}</td><td>${d.ref}</td></tr>`).join('\n')}
</table>` : ''}
<p style="color:#999;margin-top:20px;">Red/pink cells indicate differences. Black=dark module, White=light module.</p>
</body>
</html>`;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
    const outDir = path.join(__dirname, 'qr-output');
    if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });

    const safeValue = value.replace(/[^a-zA-Z0-9_-]/g, '_').substring(0, 40);

    // Generate reference QR
    console.log(`\nGenerating reference QR for: "${value}"`);
    console.log(`  ECL: M, Mask: auto (qrcode-generator chooses optimal)`);
    console.log(`  Note: Apex forces mask 0; reference library picks optimal mask.`);
    console.log(`  If masks differ, modules in data region WILL differ — that is expected.`);

    const ref = generateReferenceQr(value);
    console.log(`  Reference size: ${ref.size}x${ref.size} (Version ${(ref.size - 17) / 4})`);

    // Write reference HTML
    const refHtmlPath = path.join(outDir, `ref-${safeValue}.html`);
    fs.writeFileSync(refHtmlPath, renderPatternHtml(ref.pattern, `Reference QR: ${value}`, null));
    console.log(`  Reference HTML: ${refHtmlPath}`);

    // Also generate a reference with forced mask 0 for true comparison
    // qrcode-generator doesn't expose mask selection, so we'll build one manually
    const refMask0 = generateReferenceQrMask0(value);
    if (refMask0) {
        const refMask0HtmlPath = path.join(outDir, `ref-mask0-${safeValue}.html`);
        fs.writeFileSync(refMask0HtmlPath, renderPatternHtml(refMask0.pattern, `Reference QR (mask 0): ${value}`, null));
        console.log(`  Reference (mask 0) HTML: ${refMask0HtmlPath}`);
    }

    if (refOnly) {
        console.log('\n--ref-only: skipping Apex comparison.');
        return;
    }

    // Read Apex pattern
    let raw;
    if (inputFile) {
        if (!fs.existsSync(inputFile)) {
            console.error(`File not found: ${inputFile}`);
            process.exit(1);
        }
        raw = fs.readFileSync(inputFile, 'utf8');
    } else {
        console.log('\nReading Apex pattern from stdin...');
        raw = fs.readFileSync('/dev/stdin', 'utf8');
    }

    const apex = parseApexPattern(raw);
    if (!apex) {
        console.error('Could not parse Apex QR pattern from input.');
        console.error('Expected rows of 0s and 1s, or debug log with ===QR_START/END=== markers.');
        process.exit(1);
    }

    console.log(`\nApex pattern: ${apex.size}x${apex.size} (Version ${(apex.size - 17) / 4})`);

    // Write Apex HTML
    const apexHtmlPath = path.join(outDir, `apex-${safeValue}.html`);

    // Compare against mask-0 reference if available, otherwise use auto-mask ref
    const comparisonRef = refMask0 || ref;
    const comparison = compareMatrices(apex.pattern, comparisonRef.pattern);

    fs.writeFileSync(apexHtmlPath, renderPatternHtml(apex.pattern, `Apex QR: ${value}`, comparison.diffs));
    console.log(`  Apex HTML: ${apexHtmlPath}`);

    // Write diff HTML
    const diffHtmlPath = path.join(outDir, `diff-${safeValue}.html`);
    fs.writeFileSync(diffHtmlPath, renderDiffHtml(apex.pattern, comparisonRef.pattern, comparison));
    console.log(`  Diff HTML: ${diffHtmlPath}`);

    // Report
    console.log(`\n${'='.repeat(60)}`);
    if (comparison.match) {
        console.log(`RESULT: PASS — ${comparison.totalModules} modules all match`);
    } else {
        console.log(`RESULT: FAIL — ${comparison.diffCount}/${comparison.totalModules} modules differ`);
        if (comparison.diffs.length <= 30) {
            console.log('\nDifferences:');
            for (const d of comparison.diffs) {
                console.log(`  [${d.row},${d.col}] apex=${d.apex} ref=${d.ref}`);
            }
        } else {
            console.log(`\n(${comparison.diffs.length} differences — see diff HTML for details)`);
        }
    }
    console.log('='.repeat(60));
}

// ---------------------------------------------------------------------------
// Manual QR generation with forced mask 0 (to match Apex)
// Uses qrcode-generator internals to extract pre-mask data, then applies mask 0
// ---------------------------------------------------------------------------
function generateReferenceQrMask0(text) {
    // We'll build the QR from scratch in JS to match Apex exactly:
    // Byte mode, ECL M, smallest version, mask 0

    const dataBytes = [];
    for (let i = 0; i < text.length; i++) {
        const c = text.charCodeAt(i);
        dataBytes.push(c > 255 ? 63 : c);
    }

    const DATA_CAPACITY = [0, 16, 28, 44, 64, 86, 108, 124, 154, 182, 216, 254, 290, 334, 365];
    // EC block structure: [ecPerBlock, grp1Count, grp1DataCW, grp2Count?, grp2DataCW?]
    const EC_BLOCKS = [
        [], [10,1,16], [16,1,28], [26,1,44], [18,2,32], [24,2,43],
        [16,4,27], [18,4,31], [22,2,38,2,39], [22,3,36,2,37],
        [26,4,43,1,44], [30,1,50,4,51], [22,6,36,2,37], [22,8,37,1,38], [24,4,40,5,41]
    ];
    const ALIGN_POS = [
        [], [], [6,18], [6,22], [6,26], [6,30], [6,34],
        [6,22,38], [6,24,42], [6,26,46], [6,28,50],
        [6,30,54], [6,32,58], [6,34,62], [6,26,46,66]
    ];

    // Find version
    let version = 0;
    for (let v = 1; v <= 14; v++) {
        const countBits = v <= 9 ? 8 : 16;
        const totalBits = 4 + countBits + dataBytes.length * 8;
        const needed = Math.ceil(totalBits / 8);
        if (needed <= DATA_CAPACITY[v]) { version = v; break; }
    }
    if (version === 0) return null;

    const size = 4 * version + 17;
    const totalDataCW = DATA_CAPACITY[version];
    const blockInfo = EC_BLOCKS[version];
    const ecPerBlock = blockInfo[0];

    // Build data bit stream
    const bits = [];
    function addBits(val, count) {
        for (let i = count - 1; i >= 0; i--) {
            bits.push((val >> i) & 1);
        }
    }
    addBits(4, 4); // Byte mode
    const countBitLen = version <= 9 ? 8 : 16;
    addBits(dataBytes.length, countBitLen);
    for (const b of dataBytes) addBits(b, 8);

    const targetBits = totalDataCW * 8;
    // Terminator
    for (let i = 0; i < 4 && bits.length < targetBits; i++) bits.push(0);
    // Pad to byte boundary
    while (bits.length % 8 !== 0 && bits.length < targetBits) bits.push(0);
    // Pad codewords
    const padBytes = [236, 17];
    let padIdx = 0;
    while (bits.length < targetBits) {
        const pb = padBytes[padIdx++ % 2];
        for (let i = 7; i >= 0; i--) bits.push((pb >> i) & 1);
    }

    // Convert to codewords
    const dataCodewords = [];
    for (let i = 0; i < bits.length; i += 8) {
        let cw = 0;
        for (let b = 0; b < 8 && (i + b) < bits.length; b++) {
            cw = cw * 2 + bits[i + b];
        }
        dataCodewords.push(cw);
    }

    // Split into blocks and generate RS per block
    const dataBlocks = [];
    const ecBlocks = [];
    let cwIdx = 0;
    const numGroups = blockInfo.length > 3 ? 2 : 1;
    for (let g = 0; g < numGroups; g++) {
        const bCount = blockInfo[1 + g * 2];
        const bDataCW = blockInfo[2 + g * 2];
        for (let b = 0; b < bCount; b++) {
            const block = dataCodewords.slice(cwIdx, cwIdx + bDataCW);
            cwIdx += bDataCW;
            dataBlocks.push(block);
            ecBlocks.push(generateRS(block, ecPerBlock));
        }
    }

    // Interleave data codewords
    const maxDataLen = Math.max(...dataBlocks.map(b => b.length));
    const finalBits = [];
    function addBits2(arr, val, count) {
        for (let i = count - 1; i >= 0; i--) arr.push((val >> i) & 1);
    }
    for (let i = 0; i < maxDataLen; i++) {
        for (const db of dataBlocks) {
            if (i < db.length) addBits2(finalBits, db[i], 8);
        }
    }
    // Interleave EC codewords
    for (let i = 0; i < ecPerBlock; i++) {
        for (const eb of ecBlocks) {
            if (i < eb.length) addBits2(finalBits, eb[i], 8);
        }
    }

    // Create matrix
    const matrix = Array.from({ length: size }, () => new Array(size).fill(0));
    const reserved = Array.from({ length: size }, () => new Array(size).fill(false));

    // Finder patterns
    function placeFinderPattern(row, col) {
        const pattern = [
            [1,1,1,1,1,1,1],
            [1,0,0,0,0,0,1],
            [1,0,1,1,1,0,1],
            [1,0,1,1,1,0,1],
            [1,0,1,1,1,0,1],
            [1,0,0,0,0,0,1],
            [1,1,1,1,1,1,1]
        ];
        for (let r = -1; r <= 7; r++) {
            for (let c = -1; c <= 7; c++) {
                const mr = row + r, mc = col + c;
                if (mr < 0 || mr >= size || mc < 0 || mc >= size) continue;
                if (r >= 0 && r < 7 && c >= 0 && c < 7) {
                    matrix[mr][mc] = pattern[r][c];
                } else {
                    matrix[mr][mc] = 0;
                }
                reserved[mr][mc] = true;
            }
        }
    }

    placeFinderPattern(0, 0);
    placeFinderPattern(size - 7, 0);
    placeFinderPattern(0, size - 7);

    // Timing patterns
    for (let i = 8; i < size - 8; i++) {
        const val = i % 2 === 0 ? 1 : 0;
        matrix[6][i] = val; reserved[6][i] = true;
        matrix[i][6] = val; reserved[i][6] = true;
    }

    // Reserve format info areas
    for (let i = 0; i < 8; i++) {
        if (!reserved[8][i]) reserved[8][i] = true;
        if (!reserved[i][8]) reserved[i][8] = true;
        if (i < 7) {
            if (!reserved[size - 1 - i][8]) reserved[size - 1 - i][8] = true;
        }
        if (!reserved[8][size - 1 - i]) reserved[8][size - 1 - i] = true;
    }
    reserved[8][8] = true;
    // Dark module
    matrix[size - 8][8] = 1;
    reserved[size - 8][8] = true;

    // Alignment patterns
    if (version >= 2) {
        const alignPos = ALIGN_POS[version];
        for (const aRow of alignPos) {
            for (const aCol of alignPos) {
                placeAlignmentPattern(matrix, reserved, aRow, aCol);
            }
        }
    }

    // Place data bits
    let bitIdx = 0;
    for (let right = size - 1; right >= 1; right -= 2) {
        if (right === 6) right = 5;
        for (let vert = 0; vert < size; vert++) {
            for (let j = 0; j < 2; j++) {
                const col = right - j;
                const upward = Math.floor((size - 1 - right) / 2) % 2 === 0;
                const row = upward ? size - 1 - vert : vert;
                if (col >= 0 && col < size && row >= 0 && row < size && !reserved[row][col]) {
                    if (bitIdx < finalBits.length) {
                        matrix[row][col] = finalBits[bitIdx++];
                    }
                }
            }
        }
    }

    // Apply mask 0: (row + col) % 2 === 0
    for (let r = 0; r < size; r++) {
        for (let c = 0; c < size; c++) {
            if (!reserved[r][c] && (r + c) % 2 === 0) {
                matrix[r][c] = matrix[r][c] === 1 ? 0 : 1;
            }
        }
    }

    // Format info: ECL M (00) + mask 0 (000) = 101010000010010
    const formatBits = [1,0,1,0,1,0,0,0,0,0,1,0,0,1,0];
    for (let i = 0; i < 15; i++) {
        const fb = formatBits[i];
        if (i < 6) matrix[8][i] = fb;
        else if (i === 6) matrix[8][7] = fb;
        else if (i === 7) matrix[8][8] = fb;
        else if (i === 8) matrix[7][8] = fb;
        else matrix[14 - i][8] = fb;

        if (i < 7) matrix[size - 1 - i][8] = fb;
        else matrix[8][size - 15 + i] = fb;
    }

    // Serialize
    const rows = [];
    for (let r = 0; r < size; r++) {
        rows.push(matrix[r].join(''));
    }
    return { pattern: rows.join('\n'), size };
}

function placeAlignmentPattern(matrix, reserved, centerRow, centerCol) {
    // Check overlap with finder
    for (let r = -2; r <= 2; r++) {
        for (let c = -2; c <= 2; c++) {
            if (reserved[centerRow + r][centerCol + c]) return;
        }
    }
    for (let r = -2; r <= 2; r++) {
        for (let c = -2; c <= 2; c++) {
            const mr = centerRow + r, mc = centerCol + c;
            const absR = Math.abs(r), absC = Math.abs(c);
            matrix[mr][mc] = (absR === 2 || absC === 2 || (absR === 0 && absC === 0)) ? 1 : 0;
            reserved[mr][mc] = true;
        }
    }
}

// Reed-Solomon over GF(256) with polynomial 285
function generateRS(data, ecCount) {
    const GF_POLY = 285;
    const gfExp = new Array(256).fill(0);
    const gfLog = new Array(256).fill(0);
    let x = 1;
    for (let i = 0; i < 255; i++) {
        gfExp[i] = x;
        gfLog[x] = i;
        x *= 2;
        if (x >= 256) x = (x % 256) ^ (GF_POLY - 256);
    }

    function gfMul(a, b) {
        if (a === 0 || b === 0) return 0;
        return gfExp[(gfLog[a] + gfLog[b]) % 255];
    }

    // Build generator polynomial
    let gen = [1];
    for (let i = 0; i < ecCount; i++) {
        const newGen = new Array(gen.length + 1).fill(0);
        for (let j = 0; j < gen.length; j++) {
            newGen[j] ^= gfMul(gen[j], gfExp[i]);
            newGen[j + 1] ^= gen[j];
        }
        gen = newGen;
    }

    // Reverse to descending degree
    const genDesc = gen.slice().reverse();

    // Polynomial division
    const result = [...data, ...new Array(ecCount).fill(0)];
    for (let i = 0; i < data.length; i++) {
        const coef = result[i];
        if (coef !== 0) {
            for (let j = 0; j < genDesc.length; j++) {
                result[i + j] ^= gfMul(genDesc[j], coef);
            }
        }
    }

    return result.slice(data.length);
}

main().catch(err => {
    console.error(err);
    process.exit(1);
});

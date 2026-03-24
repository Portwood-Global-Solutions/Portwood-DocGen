/**
 * Pure Apex barcode image generator. No external dependencies.
 * Generates Code 128 barcodes as BMP image blobs.
 * BMP format requires no compression — just a header + raw pixel data.
 *
 * Usage:
 *   Blob bmp = BarcodeGenerator.generate('ABC-12345', 'code128');
 */
public class BarcodeGenerator {

    // Code 128B encoding table — each entry is 11 modules (bars + spaces)
    // Index = character ASCII value - 32 (space = 0, ! = 1, ... z = 90)
    private static final List<String> CODE128B = new List<String>{
        '11011001100', // 0: Space
        '11001101100', // 1: !
        '11001100110', // 2: "
        '10010011000', // 3: #
        '10010001100', // 4: $
        '10001001100', // 5: %
        '10011001000', // 6: &
        '10011000100', // 7: '
        '10001100100', // 8: (
        '11001001000', // 9: )
        '11001000100', // 10: *
        '11000100100', // 11: +
        '10110011100', // 12: ,
        '10011011100', // 13: -
        '10011001110', // 14: .
        '10111001100', // 15: /
        '10011101100', // 16: 0
        '10011100110', // 17: 1
        '11001110010', // 18: 2
        '11001011100', // 19: 3
        '11001001110', // 20: 4
        '11011100100', // 21: 5
        '11001110100', // 22: 6
        '11101101110', // 23: 7
        '11101001100', // 24: 8
        '11100101100', // 25: 9
        '11100100110', // 26: :
        '11101100100', // 27: ;
        '11100110100', // 28: <
        '11100110010', // 29: =
        '11011011000', // 30: >
        '11011000110', // 31: ?
        '11000110110', // 32: @
        '10100011000', // 33: A
        '10001011000', // 34: B
        '10001000110', // 35: C
        '10110001000', // 36: D
        '10001101000', // 37: E
        '10001100010', // 38: F
        '11010001000', // 39: G
        '11000101000', // 40: H
        '11000100010', // 41: I
        '10110111000', // 42: J
        '10110001110', // 43: K
        '10001101110', // 44: L
        '10111011000', // 45: M
        '10111000110', // 46: N
        '10001110110', // 47: O
        '11101110110', // 48: P
        '11010001110', // 49: Q
        '11000101110', // 50: R
        '11011101000', // 51: S
        '11011100010', // 52: T
        '11011101110', // 53: U
        '11101011000', // 54: V
        '11101000110', // 55: W
        '11100010110', // 56: X
        '11101101000', // 57: Y
        '11101100010', // 58: Z
        '11100011010', // 59: [
        '11101111010', // 60: \
        '11001000010', // 61: ]
        '11110001010', // 62: ^
        '10100110000', // 63: _
        '10100001100', // 64: `
        '10010110000', // 65: a
        '10010000110', // 66: b
        '10000101100', // 67: c
        '10000100110', // 68: d
        '10110010000', // 69: e
        '10110000100', // 70: f
        '10011010000', // 71: g
        '10011000010', // 72: h
        '10000110100', // 73: i
        '10000110010', // 74: j
        '11000010010', // 75: k
        '11001010000', // 76: l
        '11110111010', // 77: m
        '11000010100', // 78: n
        '10001111010', // 79: o
        '10100111100', // 80: p
        '10010111100', // 81: q
        '10010011110', // 82: r
        '10111100100', // 83: s
        '10011110100', // 84: t
        '10011110010', // 85: u
        '11110100100', // 86: v
        '11110010100', // 87: w
        '11110010010', // 88: x
        '11011011110', // 89: y
        '11011110110', // 90: z
        '11110110110', // 91: {
        '10101111000', // 92: |
        '10100011110', // 93: }
        '10001011110', // 94: ~
        '10111101000'  // 95: DEL
    };

    private static final String START_B = '11010010000';
    private static final String STOP = '1100011101011';

    /**
     * Generates a barcode image as a BMP blob.
     * @param value The text to encode
     * @param barcodeType 'code128' (default)
     * @return BMP image blob, or null if encoding fails
     */
    /**
     * Returns the bar pattern string ('1' = black bar, '0' = white space).
     * Used by DocGenHtmlRenderer to render as CSS bars for PDF.
     */
    /**
     * Returns the bar/grid pattern.
     * Code 128: single line of '0' and '1' characters.
     * QR: rows separated by '\n', each row is '0'/'1' per module.
     */
    public static String getPattern(String value, String barcodeType) {
        if (String.isBlank(value)) return null;
        if (barcodeType == 'qr') {
            return buildQrPattern(value);
        }
        if (barcodeType == null || barcodeType == 'code128') {
            return buildCode128Pattern(value);
        }
        return null;
    }

    public static Blob generate(String value, String barcodeType) {
        if (String.isBlank(value)) return null;
        if (barcodeType == null || barcodeType == 'code128') {
            return generateCode128(value);
        }
        return null;
    }

    // ---------------------------------------------------------------------------
    // QR Code — Version 1-14, Error Correction Level M, Byte mode
    // ---------------------------------------------------------------------------

    // Total data codewords per version, Level M (versions 1-14)
    private static final List<Integer> QR_DATA_CAPACITY = new List<Integer>{
        0, 16, 28, 44, 64, 86, 108, 124, 154, 182, 216, 254, 290, 334, 365
    };

    // EC block structure per version, ECL M: {ecPerBlock, grp1Count, grp1DataCW [, grp2Count, grp2DataCW]}
    // Derived from ISO 18004 Table 9 / qrcode-generator RS_BLOCK_TABLE.
    private static final List<List<Integer>> QR_EC_BLOCKS = new List<List<Integer>>{
        new List<Integer>(),                // v0 unused
        new List<Integer>{10, 1, 16},       // v1: 1×16, total=26
        new List<Integer>{16, 1, 28},       // v2: 1×28, total=44
        new List<Integer>{26, 1, 44},       // v3: 1×44, total=70
        new List<Integer>{18, 2, 32},       // v4: 2×32, total=100
        new List<Integer>{24, 2, 43},       // v5: 2×43, total=134
        new List<Integer>{16, 4, 27},       // v6: 4×27, total=172
        new List<Integer>{18, 4, 31},       // v7: 4×31, total=196
        new List<Integer>{22, 2, 38, 2, 39},// v8: 2×38 + 2×39, total=242
        new List<Integer>{22, 3, 36, 2, 37},// v9: 3×36 + 2×37, total=292
        new List<Integer>{26, 4, 43, 1, 44},// v10: 4×43 + 1×44, total=346
        new List<Integer>{30, 1, 50, 4, 51},// v11: 1×50 + 4×51, total=404
        new List<Integer>{22, 6, 36, 2, 37},// v12: 6×36 + 2×37, total=466
        new List<Integer>{22, 8, 37, 1, 38},// v13: 8×37 + 1×38, total=532
        new List<Integer>{24, 4, 40, 5, 41} // v14: 4×40 + 5×41, total=581
    };
    // Alignment pattern center positions per version (0 = none)
    private static final List<List<Integer>> QR_ALIGN_POS = new List<List<Integer>>{
        new List<Integer>(),              // v0 (unused)
        new List<Integer>(),              // v1: none
        new List<Integer>{6,18},          // v2
        new List<Integer>{6,22},          // v3
        new List<Integer>{6,26},          // v4
        new List<Integer>{6,30},          // v5
        new List<Integer>{6,34},          // v6
        new List<Integer>{6,22,38},       // v7
        new List<Integer>{6,24,42},       // v8
        new List<Integer>{6,26,46},       // v9
        new List<Integer>{6,28,50},       // v10
        new List<Integer>{6,30,54},       // v11
        new List<Integer>{6,32,58},       // v12
        new List<Integer>{6,34,62},       // v13
        new List<Integer>{6,26,46,66}     // v14
    };

    private static String buildQrPattern(String value) {
        // Convert to byte mode data
        List<Integer> dataBytes = new List<Integer>();
        for (Integer i = 0; i < value.length(); i++) {
            Integer c = value.charAt(i);
            if (c > 255) c = 63; // '?' for non-ASCII
            dataBytes.add(c);
        }

        // Select smallest version that fits
        Integer version = 0;
        for (Integer v = 1; v <= 14; v++) {
            // Byte mode: 4 (mode) + 8 or 16 (count) + 8*len bits → codewords
            Integer countBits = v <= 9 ? 8 : 16;
            Integer totalBits = 4 + countBits + dataBytes.size() * 8;
            Integer needed = (totalBits + 7) / 8;
            if (needed <= QR_DATA_CAPACITY[v]) {
                version = v;
                break;
            }
        }
        if (version == 0) return null; // Data too long

        Integer size = 4 * version + 17;
        Integer totalDataCW = QR_DATA_CAPACITY[version];
        List<Integer> blockInfo = QR_EC_BLOCKS[version];
        Integer ecPerBlock = blockInfo[0];

        // Build data bit stream: mode(4) + count(8) + data(8*n) + terminator + padding
        List<Integer> bits = new List<Integer>();
        // Mode indicator: 0100 (byte mode)
        addBits(bits, 4, 4);
        // Character count (8 bits for v1-9, 16 bits for v10+)
        Integer countBitLen = version <= 9 ? 8 : 16;
        addBits(bits, dataBytes.size(), countBitLen);
        // Data
        for (Integer b : dataBytes) {
            addBits(bits, b, 8);
        }
        // Terminator (up to 4 zeros)
        Integer targetBits = totalDataCW * 8;
        for (Integer i = 0; i < 4 && bits.size() < targetBits; i++) {
            bits.add(0);
        }
        // Pad to byte boundary
        while (Math.mod(bits.size(), 8) != 0 && bits.size() < targetBits) {
            bits.add(0);
        }
        // Pad codewords: alternating 11101100 and 00010001
        Integer padIdx = 0;
        List<Integer> padBytes = new List<Integer>{ 236, 17 };
        while (bits.size() < targetBits) {
            addBits(bits, padBytes[Math.mod(padIdx++, 2)], 8);
        }

        // Convert bits to codewords
        List<Integer> dataCodewords = new List<Integer>();
        for (Integer i = 0; i < bits.size(); i += 8) {
            Integer cw = 0;
            for (Integer b = 0; b < 8 && (i + b) < bits.size(); b++) {
                cw = cw * 2 + bits[i + b];
            }
            dataCodewords.add(cw);
        }

        // Split data into blocks and generate EC per block (ISO 18004 interleaving)
        List<List<Integer>> dataBlocks = new List<List<Integer>>();
        List<List<Integer>> ecBlocks = new List<List<Integer>>();
        Integer cwIdx = 0;

        // blockInfo format: {ecPerBlock, grp1Count, grp1DataCW [, grp2Count, grp2DataCW]}
        Integer numGroups = blockInfo.size() > 3 ? 2 : 1;
        for (Integer g = 0; g < numGroups; g++) {
            Integer bCount = blockInfo[1 + g * 2];
            Integer bDataCW = blockInfo[2 + g * 2];
            for (Integer b = 0; b < bCount; b++) {
                List<Integer> block = new List<Integer>();
                for (Integer i = 0; i < bDataCW && cwIdx < dataCodewords.size(); i++) {
                    block.add(dataCodewords[cwIdx++]);
                }
                dataBlocks.add(block);
                ecBlocks.add(generateReedSolomon(block, ecPerBlock));
            }
        }

        // Interleave data codewords: round-robin across blocks
        Integer maxDataLen = 0;
        for (List<Integer> db : dataBlocks) {
            if (db.size() > maxDataLen) maxDataLen = db.size();
        }
        List<Integer> finalBits = new List<Integer>();
        for (Integer i = 0; i < maxDataLen; i++) {
            for (List<Integer> db : dataBlocks) {
                if (i < db.size()) addBits(finalBits, db[i], 8);
            }
        }
        // Interleave EC codewords
        for (Integer i = 0; i < ecPerBlock; i++) {
            for (List<Integer> eb : ecBlocks) {
                if (i < eb.size()) addBits(finalBits, eb[i], 8);
            }
        }

        // Create the QR matrix
        List<List<Integer>> matrix = new List<List<Integer>>();
        List<List<Boolean>> reserved = new List<List<Boolean>>();
        for (Integer r = 0; r < size; r++) {
            List<Integer> row = new List<Integer>();
            List<Boolean> resRow = new List<Boolean>();
            for (Integer c = 0; c < size; c++) {
                row.add(0);
                resRow.add(false);
            }
            matrix.add(row);
            reserved.add(resRow);
        }

        // Place finder patterns (3 corners)
        placeFinderPattern(matrix, reserved, 0, 0, size);
        placeFinderPattern(matrix, reserved, size - 7, 0, size);
        placeFinderPattern(matrix, reserved, 0, size - 7, size);

        // Place timing patterns
        for (Integer i = 8; i < size - 8; i++) {
            Integer val = Math.mod(i, 2) == 0 ? 1 : 0;
            matrix[6][i] = val; reserved[6][i] = true;
            matrix[i][6] = val; reserved[i][6] = true;
        }

        // Reserve format info areas
        for (Integer i = 0; i < 8; i++) {
            // First copy: row 8 cols 0-7, col 8 rows 0-7
            if (!reserved[8][i]) reserved[8][i] = true;
            if (!reserved[i][8]) reserved[i][8] = true;
            // Second copy vertical: col 8, rows size-1 to size-7 (bits 0-6)
            if (i < 7) {
                if (!reserved[size - 1 - i][8]) reserved[size - 1 - i][8] = true;
            }
            // Second copy horizontal: row 8, cols size-1 to size-8 (bits 7-14)
            if (!reserved[8][size - 1 - i]) reserved[8][size - 1 - i] = true;
        }
        reserved[8][8] = true;
        // Dark module
        matrix[size - 8][8] = 1;
        reserved[size - 8][8] = true;

        // Alignment patterns for version >= 2
        if (version >= 2) {
            List<Integer> alignPos = QR_ALIGN_POS[version];
            for (Integer aRow : alignPos) {
                for (Integer aCol : alignPos) {
                    placeAlignmentPattern(matrix, reserved, aRow, aCol);
                }
            }
        }

        // Place data bits (bottom-right, going up, zigzag)
        Integer bitIdx = 0;
        for (Integer right = size - 1; right >= 1; right -= 2) {
            if (right == 6) right = 5; // Skip timing column
            for (Integer vert = 0; vert < size; vert++) {
                for (Integer j = 0; j < 2; j++) {
                    Integer col = right - j;
                    Boolean upward = Math.mod((size - 1 - right) / 2, 2) == 0;
                    Integer row = upward ? size - 1 - vert : vert;
                    if (col >= 0 && col < size && row >= 0 && row < size && !reserved[row][col]) {
                        if (bitIdx < finalBits.size()) {
                            matrix[row][col] = finalBits[bitIdx++];
                        }
                    }
                }
            }
        }

        // Apply mask pattern 0 (checkerboard: (row + col) % 2 == 0)
        for (Integer r = 0; r < size; r++) {
            for (Integer c = 0; c < size; c++) {
                if (!reserved[r][c] && Math.mod(r + c, 2) == 0) {
                    matrix[r][c] = matrix[r][c] == 1 ? 0 : 1;
                }
            }
        }

        // Write format information (ECL M = 00, mask 0 = 000 → format bits with BCH)
        // Pre-computed: ECL M (00) + mask 0 (000) → 15-bit format = 101010000010010
        List<Integer> formatBits = new List<Integer>{ 1,0,1,0,1,0,0,0,0,0,1,0,0,1,0 };
        // Horizontal: bits 0-7 along row 8, bits 8-14 along column 8
        for (Integer i = 0; i < 15; i++) {
            Integer fb = formatBits[i];
            // Around top-left finder
            if (i < 6) { matrix[8][i] = fb; }
            else if (i == 6) { matrix[8][7] = fb; }
            else if (i == 7) { matrix[8][8] = fb; }
            else if (i == 8) { matrix[7][8] = fb; }
            else { matrix[14 - i][8] = fb; }
            // Around other finders: bits 0-6 vertical, bits 7-14 horizontal
            if (i < 7) { matrix[size - 1 - i][8] = fb; }
            else { matrix[8][size - 15 + i] = fb; }
        }

        // Serialize to string (rows separated by newlines)
        String result = '';
        for (Integer r = 0; r < size; r++) {
            if (r > 0) result += '\n';
            for (Integer c = 0; c < size; c++) {
                result += String.valueOf(matrix[r][c]);
            }
        }
        return result;
    }

    private static void placeFinderPattern(List<List<Integer>> matrix, List<List<Boolean>> reserved, Integer row, Integer col, Integer size) {
        // 7x7 finder pattern
        List<List<Integer>> pattern = new List<List<Integer>>{
            new List<Integer>{1,1,1,1,1,1,1},
            new List<Integer>{1,0,0,0,0,0,1},
            new List<Integer>{1,0,1,1,1,0,1},
            new List<Integer>{1,0,1,1,1,0,1},
            new List<Integer>{1,0,1,1,1,0,1},
            new List<Integer>{1,0,0,0,0,0,1},
            new List<Integer>{1,1,1,1,1,1,1}
        };
        for (Integer r = -1; r <= 7; r++) {
            for (Integer c = -1; c <= 7; c++) {
                Integer mr = row + r;
                Integer mc = col + c;
                if (mr < 0 || mr >= size || mc < 0 || mc >= size) continue;
                if (r >= 0 && r < 7 && c >= 0 && c < 7) {
                    matrix[mr][mc] = pattern[r][c];
                } else {
                    matrix[mr][mc] = 0; // Separator
                }
                reserved[mr][mc] = true;
            }
        }
    }

    private static void placeAlignmentPattern(List<List<Integer>> matrix, List<List<Boolean>> reserved, Integer centerRow, Integer centerCol) {
        for (Integer r = -2; r <= 2; r++) {
            for (Integer c = -2; c <= 2; c++) {
                Integer mr = centerRow + r;
                Integer mc = centerCol + c;
                if (reserved[mr][mc]) return; // Overlaps finder — skip entirely
            }
        }
        for (Integer r = -2; r <= 2; r++) {
            for (Integer c = -2; c <= 2; c++) {
                Integer mr = centerRow + r;
                Integer mc = centerCol + c;
                Integer absR = Math.abs(r);
                Integer absC = Math.abs(c);
                matrix[mr][mc] = (absR == 2 || absC == 2 || (absR == 0 && absC == 0)) ? 1 : 0;
                reserved[mr][mc] = true;
            }
        }
    }

    private static void addBits(List<Integer> bits, Integer value, Integer count) {
        for (Integer i = count - 1; i >= 0; i--) {
            bits.add(Math.mod(value / (Integer) Math.pow(2, i), 2));
        }
    }

    // Reed-Solomon error correction over GF(256)
    private static final Integer QR_GF_POLY = 285; // x^8 + x^4 + x^3 + x^2 + 1

    private static List<Integer> generateReedSolomon(List<Integer> data, Integer ecCount) {
        // Build log/antilog tables for GF(256)
        List<Integer> gfExp = new List<Integer>();
        List<Integer> gfLog = new List<Integer>();
        for (Integer i = 0; i < 256; i++) { gfExp.add(0); gfLog.add(0); }
        Integer x = 1;
        for (Integer i = 0; i < 255; i++) {
            gfExp[i] = x;
            gfLog[x] = i;
            x *= 2;
            if (x >= 256) x = Math.mod(x, 256) ^ (QR_GF_POLY - 256);
        }

        // Build generator polynomial
        List<Integer> gen = new List<Integer>{ 1 };
        for (Integer i = 0; i < ecCount; i++) {
            List<Integer> newGen = new List<Integer>();
            for (Integer j = 0; j <= gen.size(); j++) newGen.add(0);
            for (Integer j = 0; j < gen.size(); j++) {
                newGen[j] = newGen[j] ^ gfMultiply(gen[j], gfExp[i], gfExp, gfLog);
                newGen[j + 1] = newGen[j + 1] ^ gen[j];
            }
            gen = newGen;
        }

        // Reverse gen to descending degree order for polynomial long division
        // gen was built ascending (gen[0]=constant, gen[n]=leading=1),
        // but division needs gen[0]=leading coefficient first
        List<Integer> genDesc = new List<Integer>();
        for (Integer i = gen.size() - 1; i >= 0; i--) {
            genDesc.add(gen[i]);
        }

        // Polynomial division
        List<Integer> result = new List<Integer>();
        for (Integer d : data) result.add(d);
        for (Integer i = 0; i < ecCount; i++) result.add(0);

        for (Integer i = 0; i < data.size(); i++) {
            Integer coef = result[i];
            if (coef != 0) {
                for (Integer j = 0; j < genDesc.size(); j++) {
                    result[i + j] = result[i + j] ^ gfMultiply(genDesc[j], coef, gfExp, gfLog);
                }
            }
        }

        // Return EC codewords (last ecCount entries)
        List<Integer> ec = new List<Integer>();
        for (Integer i = data.size(); i < result.size(); i++) {
            ec.add(result[i]);
        }
        return ec;
    }

    private static Integer gfMultiply(Integer a, Integer b, List<Integer> gfExp, List<Integer> gfLog) {
        if (a == 0 || b == 0) return 0;
        return gfExp[Math.mod(gfLog[a] + gfLog[b], 255)];
    }

    /** Builds the Code 128B bar pattern string for a given value. */
    private static String buildCode128Pattern(String value) {
        String pattern = START_B;
        Integer checksum = 104;

        for (Integer i = 0; i < value.length(); i++) {
            Integer charVal = value.charAt(i) - 32;
            if (charVal < 0 || charVal >= CODE128B.size()) charVal = 0;
            pattern += CODE128B[charVal];
            checksum += charVal * (i + 1);
        }

        Integer checkVal = Math.mod(checksum, 103);
        if (checkVal < CODE128B.size()) {
            pattern += CODE128B[checkVal];
        }
        pattern += STOP;
        return pattern;
    }

    /**
     * Generates a Code 128B barcode as a 1-bit BMP image.
     */
    private static Blob generateCode128(String value) {
        String pattern = buildCode128Pattern(value);

        // Render to BMP
        return renderBarcodeBmp(pattern, 2, 60, 10);
    }

    /**
     * Renders a bar pattern string ('1' = black, '0' = white) to a BMP image.
     * @param pattern The bar pattern (e.g., '110100100...')
     * @param moduleWidth Width of each module in pixels
     * @param height Height of the barcode in pixels
     * @param quietZone Width of quiet zone on each side in pixels
     */
    private static Blob renderBarcodeBmp(String pattern, Integer moduleWidth, Integer height, Integer quietZone) {
        Integer barcodeWidth = pattern.length() * moduleWidth;
        Integer width = barcodeWidth + (quietZone * 2);

        // BMP rows must be padded to 4-byte boundaries (1 bit per pixel)
        Integer rowBytes = (width + 7) / 8;
        Integer paddedRowBytes = ((rowBytes + 3) / 4) * 4;
        Integer pixelDataSize = paddedRowBytes * height;

        // BMP file: 14-byte file header + 40-byte info header + 8-byte color table + pixel data
        Integer headerSize = 14 + 40 + 8;
        Integer fileSize = headerSize + pixelDataSize;

        List<Integer> bmpBytes = new List<Integer>();

        // --- File Header (14 bytes) ---
        bmpBytes.add(66); bmpBytes.add(77); // 'BM'
        addLE32(bmpBytes, fileSize);
        addLE16(bmpBytes, 0); // Reserved
        addLE16(bmpBytes, 0); // Reserved
        addLE32(bmpBytes, headerSize); // Pixel data offset

        // --- Info Header (40 bytes) ---
        addLE32(bmpBytes, 40); // Header size
        addLE32(bmpBytes, width);
        addLE32(bmpBytes, height);
        addLE16(bmpBytes, 1); // Planes
        addLE16(bmpBytes, 1); // Bits per pixel (1-bit)
        addLE32(bmpBytes, 0); // Compression (none)
        addLE32(bmpBytes, pixelDataSize);
        addLE32(bmpBytes, 2835); // H resolution (72 DPI)
        addLE32(bmpBytes, 2835); // V resolution
        addLE32(bmpBytes, 2); // Colors used
        addLE32(bmpBytes, 0); // Important colors

        // --- Color Table (8 bytes: 2 entries x 4 bytes) ---
        // Color 0 = white (background)
        bmpBytes.add(255); bmpBytes.add(255); bmpBytes.add(255); bmpBytes.add(0);
        // Color 1 = black (bars)
        bmpBytes.add(0); bmpBytes.add(0); bmpBytes.add(0); bmpBytes.add(0);

        // --- Pixel Data (bottom-up, 1-bit per pixel) ---
        // Build one row
        List<Integer> rowBits = new List<Integer>();
        // Quiet zone (white)
        for (Integer i = 0; i < quietZone; i++) rowBits.add(0);
        // Barcode modules
        for (Integer i = 0; i < pattern.length(); i++) {
            Integer bit = pattern.charAt(i) == 49 ? 1 : 0; // '1' = black
            for (Integer w = 0; w < moduleWidth; w++) rowBits.add(bit);
        }
        // Quiet zone (white)
        for (Integer i = 0; i < quietZone; i++) rowBits.add(0);

        // Pack bits into bytes
        List<Integer> bitWeights = new List<Integer>{ 128, 64, 32, 16, 8, 4, 2, 1 };
        List<Integer> rowData = new List<Integer>();
        for (Integer i = 0; i < paddedRowBytes; i++) {
            Integer b = 0;
            for (Integer bit = 0; bit < 8; bit++) {
                Integer idx = i * 8 + bit;
                if (idx < rowBits.size() && rowBits[idx] == 1) {
                    b += bitWeights[bit];
                }
            }
            rowData.add(b);
        }

        // Repeat row for full height (BMP is bottom-up, but barcode is uniform)
        for (Integer y = 0; y < height; y++) {
            bmpBytes.addAll(rowData);
        }

        // Convert integer list to hex string → Blob
        String hex = '';
        String hexChars = '0123456789abcdef';
        for (Integer b : bmpBytes) {
            hex += hexChars.substring(b / 16, b / 16 + 1);
            hex += hexChars.substring(Math.mod(b, 16), Math.mod(b, 16) + 1);
        }
        return EncodingUtil.convertFromHex(hex);
    }

    private static void addLE32(List<Integer> bytes, Integer value) {
        bytes.add(Math.mod(value, 256));
        bytes.add(Math.mod(value / 256, 256));
        bytes.add(Math.mod(value / 65536, 256));
        bytes.add(Math.mod(value / 16777216, 256));
    }

    private static void addLE16(List<Integer> bytes, Integer value) {
        bytes.add(Math.mod(value, 256));
        bytes.add(Math.mod(value / 256, 256));
    }
}

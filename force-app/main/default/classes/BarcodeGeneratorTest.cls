@IsTest
private class BarcodeGeneratorTest {

    @IsTest
    static void testGetPatternCode128() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String pattern = BarcodeGenerator.getPattern('TEST-123', 'code128');
            System.assertNotEquals(null, pattern, 'Pattern should not be null');
            // Code 128: Start B (11) + 8 chars * 11 modules + checksum (11) + stop (13) = 123 modules
            System.assert(pattern.length() > 0, 'Pattern should have length');
            // Every character in pattern should be 0 or 1
            for (Integer i = 0; i < pattern.length(); i++) {
                String c = pattern.substring(i, i + 1);
                System.assert(c == '0' || c == '1', 'Pattern should only contain 0s and 1s: ' + c);
            }
        }
    }

    @IsTest
    static void testGetPatternNullAndBlank() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            System.assertEquals(null, BarcodeGenerator.getPattern(null, 'code128'), 'Null input should return null pattern');
            System.assertEquals(null, BarcodeGenerator.getPattern('', 'code128'), 'Blank input should return null pattern');
            System.assertEquals(null, BarcodeGenerator.getPattern('test', 'unsupported'), 'Unsupported type should return null pattern');
        }
    }

    @IsTest
    static void testGetPatternDefaultType() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String pattern = BarcodeGenerator.getPattern('ABC', null);
            System.assertNotEquals(null, pattern, 'Null type should default to code128');
        }
    }

    @IsTest
    static void testGenerateBmp() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Blob bmp = BarcodeGenerator.generate('HELLO', 'code128');
            System.assertNotEquals(null, bmp, 'BMP blob should not be null');
            System.assert(bmp.size() > 62, 'BMP should be larger than the header (62 bytes)');
            // Verify BMP magic bytes: 0x42 0x4D = 'BM'
            String hex = EncodingUtil.convertToHex(bmp);
            System.assertEquals('424d', hex.substring(0, 4).toLowerCase(), 'Should start with BM magic bytes');
        }
    }

    @IsTest
    static void testGenerateNullAndBlank() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            System.assertEquals(null, BarcodeGenerator.generate(null, 'code128'), 'Null input should return null BMP');
            System.assertEquals(null, BarcodeGenerator.generate('', 'code128'), 'Blank input should return null BMP');
            System.assertEquals(null, BarcodeGenerator.generate(null, 'qr'), 'Null QR input should return null BMP');
            System.assertEquals(null, BarcodeGenerator.generate('', 'qr'), 'Blank QR input should return null BMP');
            String tooLong = '';
            for (Integer i=0; i<3000; i++) { tooLong += 'A'; }
            System.assertEquals(null, BarcodeGenerator.generate(tooLong, 'qr'), 'Too long QR input should return null BMP');
        }
    }

    @IsTest
    static void testSpecialCharacters() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Should handle all printable ASCII without error
            String pattern = BarcodeGenerator.getPattern('!@#$%^&*()_+-=[]{}|;:,.<>?', 'code128');
            System.assertNotEquals(null, pattern, 'Special characters should produce a valid pattern');
            Blob bmp = BarcodeGenerator.generate('Special: 100% Done!', 'code128');
            System.assertNotEquals(null, bmp, 'Special characters should produce a valid BMP');
        }
    }

    @IsTest
    static void testConsistentOutput() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String p1 = BarcodeGenerator.getPattern('SAME', 'code128');
            String p2 = BarcodeGenerator.getPattern('SAME', 'code128');
            System.assertEquals(p1, p2, 'Same input should produce same pattern');
        }
    }

    // --- QR Code Tests ---

    @IsTest
    static void testGenerateQrBasic() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Blob bmp = BarcodeGenerator.generate('Hello', 'qr');
            System.assertNotEquals(null, bmp, 'BMP blob should not be null');
            String hex = EncodingUtil.convertToHex(bmp);
            System.assertEquals('424d', hex.substring(0, 4).toLowerCase(), 'Should start with BM magic bytes');
        }
    }

    @IsTest
    static void testQrBasic() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String qr = BarcodeGenerator.getPattern('Hello', 'qr');
            System.assertNotEquals(null, qr, 'QR pattern should not be null');
            List<String> rows = qr.split('\n');
            // Version 1 = 21x21
            System.assertEquals(21, rows.size(), 'QR should be 21 rows for short text');
            System.assertEquals(21, rows[0].length(), 'QR should be 21 cols');
        }
    }

    @IsTest
    static void testQrUrl() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String qr = BarcodeGenerator.getPattern('https://salesforce.com/test', 'qr');
            System.assertNotEquals(null, qr, 'QR pattern for URL should not be null');
            List<String> rows = qr.split('\n');
            // URL needs version 2+ (25x25)
            System.assert(rows.size() >= 25, 'URL should need at least version 2');
        }
    }

    @IsTest
    static void testQr255Chars() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Standard text field max — should fit in version 14 or below
            String longText = '';
                        for (Integer i = 0; i < 255; i++) { longText += 'A'; }
            String qr = BarcodeGenerator.getPattern(longText, 'qr');
            System.assertNotEquals(null, qr, '255 chars should fit in QR');
        }
    }

    @IsTest
    static void testQrNullAndBlank() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            System.assertEquals(null, BarcodeGenerator.getPattern(null, 'qr'), 'Null input should return null QR pattern');
            System.assertEquals(null, BarcodeGenerator.getPattern('', 'qr'), 'Blank input should return null QR pattern');
        }
    }

    @IsTest
    static void testQrConsistent() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String q1 = BarcodeGenerator.getPattern('TEST', 'qr');
            String q2 = BarcodeGenerator.getPattern('TEST', 'qr');
            System.assertEquals(q1, q2, 'Same input should produce same QR');
        }
    }

    @IsTest
    static void testQrFinderPatterns() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String qr = BarcodeGenerator.getPattern('A', 'qr');
            List<String> rows = qr.split('\n');
            // Top-left corner should start with 1111111 (finder pattern)
            System.assert(rows[0].startsWith('1111111'), 'Top-left finder pattern missing');
            // Top-right corner
            System.assert(rows[0].endsWith('1111111'), 'Top-right finder pattern missing');
            // Bottom-left corner
            System.assert(rows[rows.size() - 1].startsWith('1111111'), 'Bottom-left finder pattern missing');
        }
    }
}

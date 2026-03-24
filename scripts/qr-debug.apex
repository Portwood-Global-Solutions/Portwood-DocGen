// QR Code Debug Script — prints pattern matrices for verification
// Run: sf apex run --target-org docgen-fresh -f scripts/qr-debug.apex
//
// Outputs rows of 0s and 1s between markers. Feed the output into:
//   node scripts/qr-verify.js --value "HELLO" --file <logfile>

String val1 = 'HELLO';
String p1 = BarcodeGenerator.getPattern(val1, 'qr');
System.debug('===QR_START:HELLO===');
for (String row : p1.split('\n')) {
    System.debug(row);
}
System.debug('===QR_END:HELLO===');

String val2 = 'Aemail00DB0000000KIV9Aemail';
String p2 = BarcodeGenerator.getPattern(val2, 'qr');
System.debug('===QR_START:Aemail00DB0000000KIV9Aemail===');
for (String row : p2.split('\n')) {
    System.debug(row);
}
System.debug('===QR_END:Aemail00DB0000000KIV9Aemail===');

String val3 = 'https://power-data-4330-dev-ed.scratch.lightning.force.com/lightning/r/DocGen_Job__c/a00000000000000/view';
String p3 = BarcodeGenerator.getPattern(val3, 'qr');
System.debug('===QR_START:URL===');
if (p3 != null) {
    System.debug('SIZE:' + p3.split('\n').size());
    for (String row : p3.split('\n')) {
        System.debug(row);
    }
} else {
    System.debug('NULL_PATTERN');
}
System.debug('===QR_END:URL===');

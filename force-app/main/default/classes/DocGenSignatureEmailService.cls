public with sharing class DocGenSignatureEmailService {

    /**
     * Data wrapper for each signer email to send.
     */
    public class SignerEmail {
        public String signerName;
        public String signerEmail;
        public String roleName;
        public String signatureUrl;
        public Id contactId;

        public SignerEmail(String signerName, String signerEmail, String roleName, String signatureUrl, Id contactId) {
            this.signerName = signerName;
            this.signerEmail = signerEmail;
            this.roleName = roleName;
            this.signatureUrl = signatureUrl;
            this.contactId = contactId;
        }
    }

    /**
     * Sends branded signature request emails to all signers.
     * Reads branding from DocGen_Settings__c org defaults.
     */
    public static void sendSignatureRequestEmails(List<SignerEmail> signers, String documentTitle) {
        if (signers == null || signers.isEmpty()) return;

        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        String senderName = UserInfo.getName();
        String brandColor = String.isNotBlank(settings.Signature_Email_Brand_Color__c)
            ? settings.Signature_Email_Brand_Color__c : '#0176D3';
        String logoUrl = settings.Signature_Email_Logo_Url__c;
        String companyName = settings.Company_Name__c;
        String footerText = settings.Signature_Email_Footer_Text__c;
        String messageTemplate = settings.Signature_Email_Message__c;
        String subjectTemplate = String.isNotBlank(settings.Signature_Email_Subject__c)
            ? settings.Signature_Email_Subject__c : 'Action Required: Please Sign {DocumentTitle}';
        String owaId = settings.Signature_OWA_Id__c;

        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();

        for (SignerEmail signer : signers) {
            String subject = mergeFields(subjectTemplate, signer.signerName, documentTitle, senderName);
            String htmlBody = buildEmailHtml(signer, documentTitle, senderName, brandColor, logoUrl, companyName, footerText, messageTemplate);

            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setSubject(subject);
            email.setHtmlBody(htmlBody);
            email.setSaveAsActivity(false);

            // Use Org-Wide Email Address if configured
            if (String.isNotBlank(owaId)) {
                email.setOrgWideEmailAddressId(owaId);
            }

            // Use Contact as recipient if available (enables activity tracking)
            if (signer.contactId != null) {
                email.setTargetObjectId(signer.contactId);
                email.setTreatTargetObjectAsRecipient(true);
            } else {
                email.setToAddresses(new List<String>{ signer.signerEmail });
            }

            emails.add(email);
        }

        if (!emails.isEmpty()) {
            Messaging.sendEmail(emails, false);
        }
    }

    /**
     * Replaces merge field tokens in a string.
     */
    private static String mergeFields(String template, String signerName, String documentTitle, String senderName) {
        if (String.isBlank(template)) return template;
        return template
            .replace('{SignerName}', signerName != null ? signerName : '')
            .replace('{DocumentTitle}', documentTitle != null ? documentTitle : 'Document')
            .replace('{SenderName}', senderName != null ? senderName : '');
    }

    /**
     * Builds the branded HTML email body.
     */
    private static String buildEmailHtml(
        SignerEmail signer, String documentTitle, String senderName,
        String brandColor, String logoUrl, String companyName, String footerText, String messageTemplate
    ) {
        String safeSignerName = escapeHtml(signer.signerName != null ? signer.signerName : 'there');
        String safeDocTitle = escapeHtml(documentTitle != null ? documentTitle : 'Document');
        String safeSenderName = escapeHtml(senderName != null ? senderName : 'Your contact');
        String safeCompanyName = escapeHtml(companyName != null ? companyName : '');
        String safeBrandColor = escapeHtml(brandColor);
        String safeSignatureUrl = escapeHtml(signer.signatureUrl);
        String safeRoleName = signer.roleName != null ? escapeHtml(signer.roleName) : '';

        String html = '';
        html += '<!DOCTYPE html>';
        html += '<html lang="en"><head><meta charset="utf-8"/>';
        html += '<meta name="viewport" content="width=device-width, initial-scale=1.0"/>';
        html += '</head>';
        html += '<body style="margin:0;padding:0;background-color:#f4f4f4;font-family:Arial,Helvetica,sans-serif;">';

        // Outer wrapper table
        html += '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#f4f4f4;">';
        html += '<tr><td align="center" style="padding:24px 16px;">';

        // Inner card
        html += '<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background-color:#ffffff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08);">';

        // Header bar with brand color
        html += '<tr><td style="background-color:' + safeBrandColor + ';padding:24px 32px;text-align:center;">';
        if (String.isNotBlank(logoUrl)) {
            html += '<img src="' + escapeHtml(logoUrl) + '" alt="' + safeCompanyName + '" style="max-height:48px;max-width:200px;display:inline-block;" />';
        } else if (String.isNotBlank(safeCompanyName)) {
            html += '<span style="color:#ffffff;font-size:20px;font-weight:bold;">' + safeCompanyName + '</span>';
        }
        html += '</td></tr>';

        // Body content
        html += '<tr><td style="padding:32px;">';

        // Greeting
        html += '<p style="font-size:16px;color:#333333;margin:0 0 16px 0;">Hi ' + safeSignerName + ',</p>';

        // Main message (customizable via settings)
        String message;
        if (String.isNotBlank(messageTemplate)) {
            message = mergeFields(messageTemplate, signer.signerName, documentTitle, senderName);
        } else {
            message = safeSenderName + ' has sent you a document that requires your signature:';
        }
        html += '<p style="font-size:15px;color:#555555;margin:0 0 16px 0;line-height:1.5;">';
        html += escapeHtml(message) + '</p>';

        // Document info box
        html += '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px 0;">';
        html += '<tr><td style="background-color:#f8f9fa;border-left:4px solid ' + safeBrandColor + ';padding:16px 20px;border-radius:0 4px 4px 0;">';
        html += '<p style="font-size:14px;color:#706e6b;margin:0 0 4px 0;">Document</p>';
        html += '<p style="font-size:16px;color:#181818;font-weight:bold;margin:0;">' + safeDocTitle + '</p>';
        if (String.isNotBlank(safeRoleName)) {
            html += '<p style="font-size:13px;color:#706e6b;margin:8px 0 0 0;">Your role: <strong>' + safeRoleName + '</strong></p>';
        }
        html += '</td></tr></table>';

        // CTA button
        html += '<table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 auto 24px auto;">';
        html += '<tr><td align="center" style="border-radius:6px;background-color:' + safeBrandColor + ';">';
        html += '<a href="' + safeSignatureUrl + '" target="_blank" style="display:inline-block;padding:14px 32px;color:#ffffff;font-size:16px;font-weight:bold;text-decoration:none;border-radius:6px;">Review &amp; Sign Document</a>';
        html += '</td></tr></table>';

        // Security note
        html += '<p style="font-size:13px;color:#706e6b;margin:0 0 8px 0;line-height:1.5;">';
        html += 'This link is unique to you and will expire in 48 hours. You will need to verify your email before signing.</p>';

        // Fallback URL
        html += '<p style="font-size:12px;color:#999999;margin:0;word-break:break-all;">';
        html += 'If the button above doesn\'t work, copy and paste this URL into your browser:<br/>';
        html += '<a href="' + safeSignatureUrl + '" style="color:' + safeBrandColor + ';">' + safeSignatureUrl + '</a></p>';

        html += '</td></tr>';

        // Footer
        html += '<tr><td style="background-color:#f8f9fa;padding:20px 32px;border-top:1px solid #e5e5e5;text-align:center;">';
        if (String.isNotBlank(footerText)) {
            html += '<p style="font-size:12px;color:#999999;margin:0;line-height:1.4;">' + escapeHtml(footerText) + '</p>';
        } else {
            html += '<p style="font-size:12px;color:#999999;margin:0;">Powered by DocGen &mdash; Open-Source Document Generation for Salesforce</p>';
        }
        html += '</td></tr>';

        html += '</table>';
        html += '</td></tr></table>';
        html += '</body></html>';

        return html;
    }

    private static String escapeHtml(String input) {
        if (input == null) return '';
        return input.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;');
    }
}

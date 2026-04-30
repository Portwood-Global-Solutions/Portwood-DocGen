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
        sendSignatureRequestEmails(signers, documentTitle, null);
    }

    public static void sendSignatureRequestEmails(List<SignerEmail> signers, String documentTitle, Id requestId) {
        if (signers == null || signers.isEmpty())
            return;

        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        String senderName = UserInfo.getName();
        String senderEmail = UserInfo.getUserEmail();
        String brandColor = safeBrandColor(settings.Signature_Email_Brand_Color__c);
        String logoUrl = settings.Signature_Email_Logo_Url__c;
        String companyName = settings.Company_Name__c;
        String footerText = settings.Signature_Email_Footer_Text__c;
        String messageTemplate = settings.Signature_Email_Message__c;
        String subjectTemplate = String.isNotBlank(settings.Signature_Email_Subject__c)
            ? settings.Signature_Email_Subject__c
            : 'Action Required: Please Sign {DocumentTitle}';
        String owaId = settings.Signature_OWA_Id__c;

        // OWA is required for signature emails — guest users cannot send without one,
        // and consistent branding requires all emails come from the same address.
        if (String.isBlank(owaId)) {
            String errMsg = 'Emails not sent — no Org-Wide Email Address configured. Set one in DocGen > Signatures settings.';
            System.debug(LoggingLevel.ERROR, 'DocGen: ' + errMsg);
            updateEmailStatus(requestId, errMsg);
            return;
        }

        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();

        for (SignerEmail signer : signers) {
            String subject = mergeFields(subjectTemplate, signer.signerName, documentTitle, senderName);
            String htmlBody = buildEmailHtml(
                signer,
                documentTitle,
                senderName,
                brandColor,
                logoUrl,
                companyName,
                footerText,
                messageTemplate
            );

            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setSubject(subject);
            email.setHtmlBody(htmlBody);
            email.setSaveAsActivity(false);
            if (String.isNotBlank(owaId)) {
                email.setOrgWideEmailAddressId(owaId);
            }

            // Set reply-to as the user who created the signature request
            // so signer replies go to the actual sender, not the OWA
            if (String.isNotBlank(senderEmail)) {
                email.setReplyTo(senderEmail);
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
            List<Messaging.SendEmailResult> results = Messaging.sendEmail(emails, false);
            List<String> statusParts = new List<String>();
            Boolean anyFailed = false;
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    statusParts.add(signers[i].signerEmail + ': Sent');
                } else {
                    anyFailed = true;
                    for (Messaging.SendEmailError err : results[i].getErrors()) {
                        String errDetail = err.getMessage() + ' (code: ' + err.getStatusCode() + ')';
                        statusParts.add(signers[i].signerEmail + ': FAILED — ' + errDetail);
                        System.debug(
                            LoggingLevel.ERROR,
                            'DocGen: Signature email failed for ' + signers[i].signerEmail + ': ' + errDetail
                        );
                    }
                }
            }
            String statusMsg = String.join(statusParts, '\n');
            if (anyFailed) {
                statusMsg =
                    'EMAIL DELIVERY ERRORS\n' +
                    statusMsg +
                    '\n\nCheck: (1) Org-Wide Email Address is set to "All Profiles" (2) Email Deliverability is "All Email" (3) Daily email limit not exceeded';
            }
            updateEmailStatus(requestId, statusMsg);
        }
    }

    /**
     * Replaces merge field tokens in a string.
     */
    private static String mergeFields(String template, String signerName, String documentTitle, String senderName) {
        if (String.isBlank(template))
            return template;
        return template
            .replace('{SignerName}', signerName != null ? signerName : '')
            .replace('{DocumentTitle}', documentTitle != null ? documentTitle : 'Document')
            .replace('{SenderName}', senderName != null ? senderName : '');
    }

    /**
     * Builds the branded HTML email body.
     */
    private static String buildEmailHtml(
        SignerEmail signer,
        String documentTitle,
        String senderName,
        String brandColor,
        String logoUrl,
        String companyName,
        String footerText,
        String messageTemplate
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
            html +=
                '<img src="' +
                escapeHtml(logoUrl) +
                '" alt="' +
                safeCompanyName +
                '" style="max-height:48px;max-width:200px;display:inline-block;" />';
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
        html +=
            '<tr><td style="background-color:#f8f9fa;border-left:4px solid ' +
            safeBrandColor +
            ';padding:16px 20px;border-radius:0 4px 4px 0;">';
        html += '<p style="font-size:14px;color:#706e6b;margin:0 0 4px 0;">Document</p>';
        html += '<p style="font-size:16px;color:#181818;font-weight:bold;margin:0;">' + safeDocTitle + '</p>';
        if (String.isNotBlank(safeRoleName)) {
            html +=
                '<p style="font-size:13px;color:#706e6b;margin:8px 0 0 0;">Your role: <strong>' +
                safeRoleName +
                '</strong></p>';
        }
        html += '</td></tr></table>';

        // CTA button
        html += '<table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 auto 24px auto;">';
        html += '<tr><td align="center" style="border-radius:6px;background-color:' + safeBrandColor + ';">';
        html +=
            '<a href="' +
            safeSignatureUrl +
            '" target="_blank" style="display:inline-block;padding:14px 32px;color:#ffffff;font-size:16px;font-weight:bold;text-decoration:none;border-radius:6px;">Review &amp; Sign Document</a>';
        html += '</td></tr></table>';

        // Security note
        html += '<p style="font-size:13px;color:#706e6b;margin:0 0 8px 0;line-height:1.5;">';
        html += 'This link is unique to you and will expire in 48 hours. You will need to verify your email before signing.</p>';

        // Fallback URL
        html += '<p style="font-size:12px;color:#999999;margin:0;word-break:break-all;">';
        html += 'If the button above doesn\'t work, copy and paste this URL into your browser:<br/>';
        html +=
            '<a href="' +
            safeSignatureUrl +
            '" style="color:' +
            safeBrandColor +
            ';">' +
            safeSignatureUrl +
            '</a></p>';

        html += '</td></tr>';

        // Footer
        html += '<tr><td style="background-color:#f8f9fa;padding:20px 32px;border-top:1px solid #e5e5e5;text-align:center;">';
        if (String.isNotBlank(footerText)) {
            html +=
                '<p style="font-size:12px;color:#999999;margin:0;line-height:1.4;">' +
                escapeHtml(footerText) +
                '</p>';
        } else {
            html += '<p style="font-size:12px;color:#999999;margin:0;">Powered by DocGen &mdash; Open-Source Document Generation for Salesforce</p>';
        }
        html += '</td></tr>';

        html += '</table>';
        html += '</td></tr></table>';
        html += '</body></html>';

        return html;
    }

    // =========================================================================
    // Sender Notifications
    // =========================================================================

    /**
     * Notifies the sender that a signer has completed their signature.
     */
    public static void sendSignerCompletedNotification(Id requestId, DocGen_Signer__c signer) {
        sendSenderNotification(
            requestId,
            'Signature Update: ' + signer.Signer_Name__c + ' has signed',
            '<p>' +
                escapeHtml(signer.Signer_Name__c) +
                ' (' +
                escapeHtml(signer.Role_Name__c) +
                ') has completed their signature.</p>'
        );
    }

    /**
     * Notifies the sender that all signers have completed — signed PDF is attached.
     */
    public static void sendAllSignedNotification(Id requestId) {
        sendSenderNotification(
            requestId,
            'All Signatures Complete',
            '<p>All signers have completed their signatures. The signed PDF has been generated and attached to the record.</p>'
        );
    }

    /**
     * Notifies the sender that a signer has declined.
     */
    public static void sendDeclineNotification(Id requestId, DocGen_Signer__c signer, String reason) {
        String body = '<p><strong>' + escapeHtml(signer.Signer_Name__c) + '</strong>';
        if (String.isNotBlank(signer.Role_Name__c)) {
            body += ' (' + escapeHtml(signer.Role_Name__c) + ')';
        }
        body += ' has <span style="color:#ea001e;font-weight:bold;">declined</span> to sign.</p>';
        if (String.isNotBlank(reason)) {
            body += '<p><strong>Reason:</strong> ' + escapeHtml(reason) + '</p>';
        }
        sendSenderNotification(requestId, 'Signature Declined: ' + signer.Signer_Name__c, body);
    }

    /**
     * Sends a notification email to the user who created the signature request.
     */
    private static void sendSenderNotification(Id requestId, String subject, String bodyHtml) {
        try {
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            DocGen_Signature_Request__c req = [
                SELECT CreatedById
                FROM DocGen_Signature_Request__c
                WHERE Id = :requestId
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD

            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            User sender = [SELECT Email FROM User WHERE Id = :req.CreatedById WITH SYSTEM_MODE LIMIT 1]; // NOPMD
            if (String.isBlank(sender.Email))
                return;

            DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
            String brandColor = safeBrandColor(settings.Signature_Email_Brand_Color__c);
            String companyName = settings.Company_Name__c;

            String html = '<!DOCTYPE html><html><head><meta charset="utf-8"/></head>';
            html += '<body style="margin:0;padding:0;background:#f4f4f4;font-family:Arial,Helvetica,sans-serif;">';
            html += '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f4;">';
            html += '<tr><td align="center" style="padding:24px 16px;">';
            html += '<table role="presentation" width="520" cellpadding="0" cellspacing="0" style="max-width:520px;width:100%;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08);">';
            html += '<tr><td style="background:' + escapeHtml(brandColor) + ';padding:16px 32px;text-align:center;">';
            if (String.isNotBlank(companyName)) {
                html +=
                    '<span style="color:#fff;font-size:18px;font-weight:bold;">' +
                    escapeHtml(companyName) +
                    '</span>';
            }
            html += '</td></tr>';
            html += '<tr><td style="padding:24px 32px;">' + bodyHtml;
            html +=
                '<p style="font-size:13px;color:#706e6b;margin-top:16px;">Request ID: ' +
                escapeHtml(String.valueOf(requestId)) +
                '</p>';
            html += '</td></tr></table></td></tr></table></body></html>';

            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setToAddresses(new List<String>{ sender.Email });
            email.setSubject('DocGen Signatures: ' + subject);
            email.setHtmlBody(html);
            email.setSaveAsActivity(false);

            String owaId = settings.Signature_OWA_Id__c;
            if (String.isNotBlank(owaId)) {
                email.setOrgWideEmailAddressId(owaId);
            }

            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email }, false);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: Sender notification failed: ' + e.getMessage());
        }
    }

    /**
     * Updates the Email_Status__c field on a signature request with delivery status.
     * Helps admins diagnose email delivery issues without checking debug logs.
     */
    private static void updateEmailStatus(Id requestId, String status) {
        if (requestId == null || String.isBlank(status))
            return;
        try {
            DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(Id = requestId);
            req.Email_Status__c = status.left(1000);
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(req, false, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'DocGen: Could not update email status: ' + e.getMessage());
        }
    }

    private static String escapeHtml(String input) {
        if (input == null)
            return '';
        return input.replace('&', '&amp;')
            .replace('<', '&lt;')
            .replace('>', '&gt;')
            .replace('"', '&quot;')
            .replace('\'', '&#39;');
    }

    /**
     * Validates a brand color string against the strict 6-digit hex format (#RRGGBB).
     * Returns the input if valid, or a safe default if not. Used to prevent
     * inline-style injection when the value is interpolated into style="" attributes.
     */
    private static String safeBrandColor(String input) {
        if (String.isNotBlank(input) && Pattern.matches('^#[0-9a-fA-F]{6}$', input)) {
            return input;
        }
        return '#1589EE';
    }
}

import { LightningElement, track, wire } from 'lwc';
import getSettingsFresh from '@salesforce/apex/DocGenSetupController.getSettingsFresh';
import saveSettings from '@salesforce/apex/DocGenSetupController.saveSettings';
import saveSignatureSettings from '@salesforce/apex/DocGenSetupController.saveSignatureSettings';
import getOrgWideEmailAddresses from '@salesforce/apex/DocGenSetupController.getOrgWideEmailAddresses';
import validateSignatureSetup from '@salesforce/apex/DocGenSetupController.validateSignatureSetup';
import saveReminderSettings from '@salesforce/apex/DocGenSetupController.saveReminderSettings';

export default class DocGenSignatureSettings extends LightningElement {
    @track isLoaded = false;
    @track isSaving = false;
    @track saveMessage = '';
    @track saveSuccess = false;

    @track siteUrl = '';
    @track companyName = '';
    @track brandColor = '#0176D3';
    @track logoUrl = '';
    @track emailSubject = '';
    @track emailMessage = '';
    @track footerText = '';
    @track owaId = '';
    @track owaOptions = [];

    // Reminders
    @track reminderEnabled = false;
    @track reminderHours = 24;

    // Setup checks
    @track setupChecks = [];
    @track setupChecksLoaded = false;

    connectedCallback() {
        this._loadSettings();
        this._loadSetupChecks();
    }

    async _loadSettings() {
        try {
            const data = await getSettingsFresh();
            this.siteUrl = data.Experience_Site_Url__c || '';
            this.companyName = data.Company_Name__c || '';
            this.brandColor = data.Signature_Email_Brand_Color__c || '#0176D3';
            this.logoUrl = data.Signature_Email_Logo_Url__c || '';
            this.emailSubject = data.Signature_Email_Subject__c || '';
            this.emailMessage = data.Signature_Email_Message__c || '';
            this.footerText = data.Signature_Email_Footer_Text__c || '';
            this.owaId = data.Signature_OWA_Id__c || '';
            this.reminderEnabled = data.Signature_Reminder_Enabled__c === true;
            this.reminderHours = data.Signature_Reminder_Hours__c || 24;
        } catch (_err) {
            // Settings not yet created — use defaults
        }
        this.isLoaded = true;
    }

    async _loadSetupChecks() {
        this.setupChecksLoaded = false;
        try {
            this.setupChecks = await validateSignatureSetup();
        } catch (_err) {
            this.setupChecks = [];
        }
        this.setupChecksLoaded = true;
    }

    @wire(getOrgWideEmailAddresses)
    wiredOwas({ data }) {
        if (data) {
            this.owaOptions = data;
        }
    }

    handleSiteUrlChange(e) {
        this.siteUrl = e.target.value;
    }
    handleCompanyNameChange(e) {
        this.companyName = e.target.value;
    }
    handleBrandColorChange(e) {
        this.brandColor = e.target.value;
    }
    handleLogoUrlChange(e) {
        this.logoUrl = e.target.value;
    }
    handleOwaChange(e) {
        this.owaId = e.detail.value;
    }
    handleEmailSubjectChange(e) {
        this.emailSubject = e.target.value;
    }
    handleEmailMessageChange(e) {
        this.emailMessage = e.target.value;
    }
    handleFooterTextChange(e) {
        this.footerText = e.target.value;
    }
    handleReminderEnabledChange(e) {
        this.reminderEnabled = e.target.checked;
    }
    handleReminderHoursChange(e) {
        this.reminderHours = e.target.value;
    }

    handleRefreshChecks() {
        this._loadSetupChecks();
    }

    get allChecksPassed() {
        return this.setupChecks.length > 0 && this.setupChecks.every((c) => c.passed);
    }

    get saveLabel() {
        return this.isSaving ? 'Saving...' : 'Save Settings';
    }

    get headerStyle() {
        return `background-color:${this.brandColor};padding:12px 20px;text-align:center;border-radius:6px 6px 0 0;`;
    }

    get docBoxStyle() {
        return `border-left:3px solid ${this.brandColor};background:#f8f9fa;padding:8px 12px;border-radius:0 4px 4px 0;margin:0.75rem 0;`;
    }

    get btnStyle() {
        return `display:inline-block;background:${this.brandColor};color:#fff;padding:8px 20px;border-radius:4px;font-weight:bold;font-size:0.8125rem;`;
    }

    get companyNameDisplay() {
        return this.companyName || 'Your Company';
    }

    get emailMessageDisplay() {
        return this.emailMessage || 'You have a document that requires your signature.';
    }

    get footerTextDisplay() {
        return this.footerText || 'Powered by DocGen';
    }

    get saveMessageClass() {
        return (
            'slds-m-top_small slds-p-around_small slds-text-align_center ' +
            (this.saveSuccess ? 'slds-theme_success' : 'slds-theme_error')
        );
    }

    async handleSave() {
        this.isSaving = true;
        this.saveMessage = '';
        try {
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            await saveSettings({ experienceSiteUrl: this.siteUrl });
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            await saveSignatureSettings({
                brandColor: this.brandColor,
                logoUrl: this.logoUrl,
                emailSubject: this.emailSubject,
                emailMessage: this.emailMessage,
                footerText: this.footerText,
                companyName: this.companyName,
                owaId: this.owaId
            });
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            await saveReminderSettings({
                enabled: this.reminderEnabled,
                hours: parseInt(this.reminderHours, 10) || 24
            });
            this.saveSuccess = true;
            this.saveMessage =
                'Settings saved successfully.' + (this.reminderEnabled ? ' Reminders scheduled hourly.' : '');
            // Re-validate setup after save
            this._loadSetupChecks();
        } catch (err) {
            this.saveSuccess = false;
            this.saveMessage = err.body ? err.body.message : 'Failed to save settings.';
        } finally {
            this.isSaving = false;
        }
    }
}

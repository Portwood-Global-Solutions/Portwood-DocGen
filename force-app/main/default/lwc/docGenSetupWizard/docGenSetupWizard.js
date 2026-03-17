import { LightningElement, track, wire } from 'lwc';
import getSettings from '@salesforce/apex/DocGenSetupController.getSettings';
import saveSettings from '@salesforce/apex/DocGenSetupController.saveSettings';
import saveEmailBrandingSettings from '@salesforce/apex/DocGenSetupController.saveEmailBrandingSettings';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class DocGenSetupWizard extends LightningElement {
    @track experienceSiteUrl = '';
    @track isLoaded = false;
    @track currentStep = '1';

    // Email branding state
    @track companyName = '';
    @track emailLogoUrl = '';
    @track emailBrandColor = '#0176D3';
    @track emailSubject = 'Action Required: Please Sign {DocumentTitle}';
    @track emailFooterText = '';
    @track isSavingBranding = false;

    @wire(getSettings)
    wiredSettings({ error, data }) {
        if (data) {
            this.experienceSiteUrl = data.Experience_Site_Url__c || '';
            this.companyName = data.Company_Name__c || '';
            this.emailLogoUrl = data.Signature_Email_Logo_Url__c || '';
            this.emailBrandColor = data.Signature_Email_Brand_Color__c || '#0176D3';
            this.emailSubject = data.Signature_Email_Subject__c || 'Action Required: Please Sign {DocumentTitle}';
            this.emailFooterText = data.Signature_Email_Footer_Text__c || '';
            this.isLoaded = true;
        } else if (error) {
            this.isLoaded = true;
        }
    }

    handleStepClick(event) {
        this.currentStep = event.target.value;
    }

    get isStep1() { return this.currentStep === '1'; }
    get isStep2() { return this.currentStep === '2'; }
    get isStep3() { return this.currentStep === '3'; }

    nextStep() {
        let stepNum = parseInt(this.currentStep, 10);
        if (stepNum < 3) {
            this.currentStep = String(stepNum + 1);
        }
    }

    prevStep() {
        let stepNum = parseInt(this.currentStep, 10);
        if (stepNum > 1) {
            this.currentStep = String(stepNum - 1);
        }
    }

    handleUrlChange(event) {
        this.experienceSiteUrl = event.target.value;
    }

    handleCompanyNameChange(event) { this.companyName = event.target.value; }
    handleLogoUrlChange(event) { this.emailLogoUrl = event.target.value; }
    handleBrandColorChange(event) { this.emailBrandColor = event.target.value; }
    handleEmailSubjectChange(event) { this.emailSubject = event.target.value; }
    handleFooterTextChange(event) { this.emailFooterText = event.target.value; }

    handleSaveEmailBranding() {
        this.isSavingBranding = true;
        saveEmailBrandingSettings({
            companyName: this.companyName,
            logoUrl: this.emailLogoUrl,
            brandColor: this.emailBrandColor,
            emailSubject: this.emailSubject,
            footerText: this.emailFooterText
        })
            .then(() => {
                this.isSavingBranding = false;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Success',
                        message: 'Email branding settings saved successfully',
                        variant: 'success'
                    })
                );
            })
            .catch(error => {
                this.isSavingBranding = false;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Error',
                        message: error.body ? error.body.message : error.message,
                        variant: 'error'
                    })
                );
            });
    }

    handleSaveSettings() {
        this.isLoaded = false;
        saveSettings({ experienceSiteUrl: this.experienceSiteUrl })
            .then(() => {
                this.isLoaded = true;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Success',
                        message: 'Settings saved successfully',
                        variant: 'success'
                    })
                );
            })
            .catch(error => {
                this.isLoaded = true;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Error',
                        message: error.body ? error.body.message : error.message,
                        variant: 'error'
                    })
                );
            });
    }
}

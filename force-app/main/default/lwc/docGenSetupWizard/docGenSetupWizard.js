import { LightningElement, track, wire } from 'lwc';
import getOrgUrl from '@salesforce/apex/DocGenSetupController.getOrgUrl';
import getSettings from '@salesforce/apex/DocGenSetupController.getSettings';
import saveSettings from '@salesforce/apex/DocGenSetupController.saveSettings';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class DocGenSetupWizard extends LightningElement {
    @track orgUrl = '';
    @track experienceSiteUrl = '';
    @track isLoaded = false;
    @track currentStep = '1';

    get callbackUrl() {
        return this.orgUrl + '/services/authcallback/DocGen_Auth_Provider';
    }

    @wire(getOrgUrl)
    wiredOrgUrl({ error, data }) {
        if (data) {
            this.orgUrl = data;
        } else if (error) {
        }
    }

    @wire(getSettings)
    wiredSettings({ error, data }) {
        if (data) {
            this.experienceSiteUrl = data.Experience_Site_Url__c || '';
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
    get isStep4() { return this.currentStep === '4'; }
    
    nextStep() {
        let stepNum = parseInt(this.currentStep, 10);
        if (stepNum < 4) {
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
            });
    }
}
import { LightningElement, track, wire } from 'lwc';
import getSettings from '@salesforce/apex/DocGenSetupController.getSettings';

export default class DocGenSetupWizard extends LightningElement {
    @track isLoaded = false;

    @wire(getSettings)
    wiredSettings({ error, data }) {
        if (data || error) {
            this.isLoaded = true;
        }
    }
}

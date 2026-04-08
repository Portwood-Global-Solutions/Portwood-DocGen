import { LightningElement, track } from 'lwc';
import verifyDocument from '@salesforce/apex/DocGenAuthenticatorController.verifyDocument';
import verifyByRequestId from '@salesforce/apex/DocGenAuthenticatorController.verifyByRequestId';

export default class DocGenAuthenticator extends LightningElement {
    @track isProcessing = false;
    @track result;
    @track requestResults;
    @track hasRequestId = false;

    connectedCallback() {
        // Check URL for request ID parameter
        const params = new URLSearchParams(window.location.search);
        const reqId = params.get('id');
        if (reqId) {
            this.hasRequestId = true;
            this.loadRequestAudit(reqId);
        }
    }

    async loadRequestAudit(requestId) {
        this.isProcessing = true;
        try {
            this.requestResults = await verifyByRequestId({ requestId });
        } catch (error) {
            this.requestResults = [];
            this.result = {
                isValid: false,
                message: 'Could not load signature details: ' + (error.body ? error.body.message : error.message)
            };
        } finally {
            this.isProcessing = false;
        }
    }

    get hasResults() {
        return this.requestResults && this.requestResults.length > 0;
    }

    get resultContainerClass() {
        if (!this.result) return '';
        return this.result.isValid
            ? 'slds-box slds-theme_success slds-var-m-top_medium'
            : 'slds-box slds-theme_error slds-var-m-top_medium';
    }

    get resultIcon() {
        return this.result && this.result.isValid ? 'utility:success' : 'utility:error';
    }

    handleDragOver(event) {
        event.preventDefault();
        event.dataTransfer.dropEffect = 'copy';
    }

    handleDrop(event) {
        event.preventDefault();
        if (event.dataTransfer.files && event.dataTransfer.files.length > 0) {
            this.processFile(event.dataTransfer.files[0]);
        }
    }

    handleFileSelect(event) {
        if (event.target.files && event.target.files.length > 0) {
            this.processFile(event.target.files[0]);
        }
    }

    async processFile(file) {
        this.result = undefined;
        this.isProcessing = true;

        try {
            const arrayBuffer = await file.arrayBuffer();
            const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
            const hashArray = Array.from(new Uint8Array(hashBuffer));
            const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

            this.result = await verifyDocument({ fileHash: hashHex });
        } catch (error) {
            this.result = {
                isValid: false,
                message: 'Error processing file: ' + (error.body ? error.body.message : error.message)
            };
        } finally {
            this.isProcessing = false;
        }
    }
}

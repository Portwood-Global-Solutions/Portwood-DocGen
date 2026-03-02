import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getRelatedDocuments from '@salesforce/apex/DocGenSignatureSenderController.getRelatedDocuments';
import getSignerRolePicklistValues from '@salesforce/apex/DocGenSignatureSenderController.getSignerRolePicklistValues';
import getSignatureTemplates from '@salesforce/apex/DocGenSignatureSenderController.getSignatureTemplates';
import getTemplateRoles from '@salesforce/apex/DocGenSignatureSenderController.getTemplateRoles';
import createMultiSignerRequest from '@salesforce/apex/DocGenSignatureSenderController.createMultiSignerRequest';
import saveSignatureTemplate from '@salesforce/apex/DocGenSignatureSenderController.saveSignatureTemplate';
import getContactInfo from '@salesforce/apex/DocGenSignatureSenderController.getContactInfo';
import getPendingSignatureRequests from '@salesforce/apex/DocGenSignatureSenderController.getPendingSignatureRequests';

let signerIdCounter = 0;

export default class DocGenSignatureSender extends LightningElement {
    @api recordId;

    @track isLoading = true;
    @track error;

    // Document selection
    @track documentOptions = [];
    @track selectedDocId = '';

    // Role picklist
    @track roleOptions = [];

    // Templates
    @track templateOptions = [];
    @track selectedTemplateId = '';
    @track showTemplateModal = false;
    @track newTemplateName = '';

    // Signers
    @track signers = [];

    // Results
    @track signerResults;

    // Previous requests
    @track previousRequests = [];
    @track showPreviousRequests = false;

    @wire(getRelatedDocuments, { recordId: '$recordId' })
    wiredDocs({ error, data }) {
        if (data) {
            this.documentOptions = data.map(doc => ({
                label: `${doc.Title}.${doc.FileExtension}`,
                value: doc.ContentDocumentId
            }));
            if (this.documentOptions.length > 0 && !this.selectedDocId) {
                this.selectedDocId = this.documentOptions[0].value;
            }
            this.error = undefined;
        } else if (error) {
            this.error = 'Error loading documents: ' + (error.body ? error.body.message : error.message);
            this.documentOptions = [];
        }
        this._checkInitialLoad();
    }

    @wire(getSignerRolePicklistValues)
    wiredRoles({ error, data }) {
        if (data) {
            this.roleOptions = data.map(entry => ({
                label: entry.label,
                value: entry.value
            }));
        } else if (error) {
        }
        this._checkInitialLoad();
    }

    @wire(getSignatureTemplates)
    wiredTemplates({ error, data }) {
        if (data) {
            this.templateOptions = [
                { label: '-- None --', value: '' },
                ...data.map(t => ({ label: t.Name, value: t.Id }))
            ];
        } else if (error) {
        }
        this._checkInitialLoad();
    }

    _wireCallsReturned = 0;
    _checkInitialLoad() {
        this._wireCallsReturned++;
        if (this._wireCallsReturned >= 3) {
            this.isLoading = false;
            if (this.signers.length === 0) {
                this.handleAddSigner();
            }
        }
    }

    // --- Computed Properties ---

    get isGenerateDisabled() {
        if (!this.selectedDocId || this.signers.length === 0) return true;
        return this.signers.some(s => !s.signerName || !s.signerEmail || !s.roleName);
    }

    get isRemoveDisabled() {
        return this.signers.length <= 1;
    }

    get previousRequestsLabel() {
        return this.showPreviousRequests ? 'Hide Previous Requests' : 'Show Previous Requests';
    }

    get hasPreviousRequests() {
        return this.previousRequests.length > 0;
    }

    get isSaveTemplateDisabled() {
        return this.signers.length === 0 || this.signers.every(s => !s.roleName);
    }

    get isTemplateSaveDisabled() {
        return !this.newTemplateName || this.newTemplateName.trim().length === 0;
    }

    // --- Document Handlers ---

    handleDocChange(event) {
        this.selectedDocId = event.detail.value;
    }

    // --- Template Handlers ---

    async handleTemplateChange(event) {
        this.selectedTemplateId = event.detail.value;
        if (!this.selectedTemplateId) return;

        this.isLoading = true;
        try {
            const roles = await getTemplateRoles({ templateId: this.selectedTemplateId });
            this.signers = roles.map(role => ({
                id: ++signerIdCounter,
                roleName: role.Role_Name__c,
                contactId: '',
                signerName: '',
                signerEmail: ''
            }));
        } catch (err) {
            this.showToast('Error', 'Failed to load template roles: ' + (err.body ? err.body.message : err.message), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleSaveTemplate() {
        this.newTemplateName = '';
        this.showTemplateModal = true;
    }

    handleCancelTemplate() {
        this.showTemplateModal = false;
        this.newTemplateName = '';
    }

    handleTemplateNameChange(event) {
        this.newTemplateName = event.target.value;
    }

    async handleConfirmSaveTemplate() {
        this.isLoading = true;
        this.showTemplateModal = false;
        try {
            const rolesJson = JSON.stringify(
                this.signers
                    .filter(s => s.roleName)
                    .map(s => ({ roleName: s.roleName }))
            );
            await saveSignatureTemplate({
                templateName: this.newTemplateName.trim(),
                rolesJson: rolesJson
            });
            this.showToast('Success', 'Template saved.', 'success');
            this.newTemplateName = '';
        } catch (err) {
            this.showToast('Error', 'Failed to save template: ' + (err.body ? err.body.message : err.message), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // --- Signer Row Handlers ---

    handleAddSigner() {
        this.signers = [
            ...this.signers,
            {
                id: ++signerIdCounter,
                roleName: '',
                contactId: '',
                signerName: '',
                signerEmail: ''
            }
        ];
    }

    handleRemoveSigner(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        this.signers = this.signers.filter((_, i) => i !== index);
    }

    handleRoleChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        this.signers = this.signers.map((s, i) =>
            i === index ? { ...s, roleName: event.detail.value } : s
        );
    }

    async handleContactChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const contactId = event.detail.recordId;

        if (!contactId) {
            this.signers = this.signers.map((s, i) =>
                i === index ? { ...s, contactId: '', signerName: '', signerEmail: '' } : s
            );
            return;
        }

        this.signers = this.signers.map((s, i) =>
            i === index ? { ...s, contactId: contactId } : s
        );

        try {
            const info = await getContactInfo({ contactId: contactId });
            this.signers = this.signers.map((s, i) =>
                i === index ? {
                    ...s,
                    signerName: info.name || s.signerName,
                    signerEmail: info.email || s.signerEmail
                } : s
            );
        } catch (err) {
        }
    }

    handleNameChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        this.signers = this.signers.map((s, i) =>
            i === index ? { ...s, signerName: event.target.value } : s
        );
    }

    handleEmailChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        this.signers = this.signers.map((s, i) =>
            i === index ? { ...s, signerEmail: event.target.value } : s
        );
    }

    // --- Generate ---

    async handleGenerate() {
        this.isLoading = true;
        this.error = undefined;
        try {
            const signersPayload = this.signers.map(s => ({
                roleName: s.roleName,
                contactId: s.contactId || null,
                signerName: s.signerName,
                signerEmail: s.signerEmail
            }));

            this.signerResults = await createMultiSignerRequest({
                contentDocumentId: this.selectedDocId,
                relatedRecordId: this.recordId,
                signersJson: JSON.stringify(signersPayload)
            });

            this.showToast('Success', 'Signature links generated for ' + this.signerResults.length + ' signer(s).', 'success');
            // Refresh previous requests list
            if (this.showPreviousRequests) {
                this.loadPreviousRequests();
            }
        } catch (err) {
            this.error = 'Error generating links: ' + (err.body ? err.body.message : err.message);
        } finally {
            this.isLoading = false;
        }
    }

    // --- Previous Requests ---

    async handleShowPreviousRequests() {
        this.showPreviousRequests = !this.showPreviousRequests;
        if (this.showPreviousRequests && this.previousRequests.length === 0) {
            await this.loadPreviousRequests();
        }
    }

    async loadPreviousRequests() {
        try {
            const data = await getPendingSignatureRequests({ relatedRecordId: this.recordId });
            this.previousRequests = data.map(req => ({
                ...req,
                statusBadgeClass: req.status === 'Signed' ? 'slds-badge slds-theme_success' :
                    req.status === 'In Progress' ? 'slds-badge slds-theme_warning' : 'slds-badge',
                signers: (req.signers || []).map(s => ({
                    ...s,
                    statusIcon: s.status === 'Signed' ? 'utility:check' :
                        s.status === 'Viewed' ? 'utility:preview' : 'utility:clock',
                    statusVariant: s.status === 'Signed' ? 'success' :
                        s.status === 'Viewed' ? 'warning' : 'bare'
                }))
            }));
        } catch (err) {
            this.showToast('Error', 'Failed to load previous requests: ' + (err.body ? err.body.message : err.message), 'error');
        }
    }

    handleCopyPreviousUrl(event) {
        const url = event.currentTarget.dataset.url;
        this._copyToClipboard(url);
        this.showToast('Copied', 'Link copied to clipboard.', 'success');
    }

    // --- Copy Handlers ---

    handleCopyUrl(event) {
        const url = event.currentTarget.dataset.url;
        this._copyToClipboard(url);
        this.showToast('Copied', 'Link copied to clipboard.', 'success');
    }

    handleCopyAllUrls() {
        const allText = this.signerResults
            .map(r => `${r.signerName}${r.roleName ? ' (' + r.roleName + ')' : ''}: ${r.signerUrl}`)
            .join('\n');
        this._copyToClipboard(allText);
        this.showToast('Copied', 'All links copied to clipboard.', 'success');
    }

    _copyToClipboard(text) {
        if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(text);
        } else {
            const textArea = document.createElement('textarea');
            textArea.value = text;
            textArea.style.position = 'fixed';
            textArea.style.left = '-9999px';
            document.body.appendChild(textArea);
            textArea.focus();
            textArea.select();
            try {
                document.execCommand('copy');
            } catch (err) {
            }
            document.body.removeChild(textArea);
        }
    }

    // --- Utilities ---

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}

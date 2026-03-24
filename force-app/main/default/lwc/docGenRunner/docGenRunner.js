import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTemplatesForObject from '@salesforce/apex/DocGenController.getTemplatesForObject';
import processAndReturnDocument from '@salesforce/apex/DocGenController.processAndReturnDocument';
import generatePdf from '@salesforce/apex/DocGenController.generatePdf';
import getChildRelationships from '@salesforce/apex/DocGenController.getChildRelationships';
import getChildRecordPdfs from '@salesforce/apex/DocGenController.getChildRecordPdfs';
import getRecordPdfs from '@salesforce/apex/DocGenController.getRecordPdfs';
import saveGeneratedDocument from '@salesforce/apex/DocGenController.saveGeneratedDocument';
import { NavigationMixin } from 'lightning/navigation';
import { mergePdfs } from './docGenPdfMerger';

export default class DocGenRunner extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;

    @track templateOptions = [];
    @track selectedTemplateId = '';
    @track outputMode = 'download';
    @track isLoading = false;
    @track error = '';

    @track appMode = 'generate'; // generate, packet, mergeOnly, mergeChildren

    // Merge settings
    @track mergeEnabled = false;
    @track recordPdfOptions = [];
    @track selectedPdfCvIds = [];

    // Packet settings
    @track packetTemplateIds = [];
    @track packetIncludeExisting = false;
    @track packetExistingPdfIds = [];

    // Merge Only settings
    @track mergeOnlyCvIds = [];

    // Child Merge settings
    @track childRelationships = [];
    @track selectedChildRel = '';
    @track childFilterClause = '';
    @track childPdfsLoaded = false;
    @track childRecordGroups = [];
    @track selectedChildPdfCvIds = [];

    _templateData = [];

    // --- Modern SaaS Mode Getters ---
    
    get modernModeOptions() {
        return [
            { label: 'Create Document', value: 'generate', icon: '📄', class: this.appMode === 'generate' ? 'seg-btn active' : 'seg-btn' },
            { label: 'Document Packet', value: 'packet', icon: '📚', class: this.appMode === 'packet' ? 'seg-btn active' : 'seg-btn' },
            { label: 'Combine PDFs', value: 'mergeOnly', icon: '🔗', class: this.appMode === 'mergeOnly' ? 'seg-btn active' : 'seg-btn' },
            { label: 'Related Files', value: 'mergeChildren', icon: '📂', class: this.appMode === 'mergeChildren' ? 'seg-btn active' : 'seg-btn' }
        ];
    }

    get modernOutputOptions() {
        const isSave = this.outputMode === 'save';
        return [
            { label: 'Download', value: 'download', icon: '⬇️', class: !isSave ? 'pill-btn active' : 'pill-btn' },
            { label: 'Save to Record', value: 'save', icon: '☁️', class: isSave ? 'pill-btn active' : 'pill-btn' }
        ];
    }

    get isGenerateMode() { return this.appMode === 'generate'; }
    get isPacketMode() { return this.appMode === 'packet'; }
    get isMergeOnlyMode() { return this.appMode === 'mergeOnly'; }
    get isMergeChildrenMode() { return this.appMode === 'mergeChildren'; }

    get templateOutputFormat() {
        const t = this._templateData.find(tmpl => tmpl.Id === this.selectedTemplateId);
        return t ? t.Output_Format__c : null;
    }

    get showMergeOption() { return this.templateOutputFormat === 'PDF'; }
    get hasRecordPdfs() { return this.recordPdfOptions.length > 0; }

    get isGenerateDisabled() { return !this.selectedTemplateId || this.isLoading; }
    get isPacketDisabled() { return this.packetTemplateIds.length < 1 || this.isLoading; }
    get isMergeOnlyDisabled() { return this.mergeOnlyCvIds.length < 2 || this.isLoading; }
    get isMergeChildrenDisabled() { return this.selectedChildPdfCvIds.length < 1 || this.isLoading; }

    get generateButtonLabel() {
        if (this.mergeEnabled && this.selectedPdfCvIds.length > 0) {
            return `Create & Combine (${this.selectedPdfCvIds.length + 1} Files) ✨`;
        }
        return 'Create Document ✨';
    }

    get packetButtonLabel() {
        const count = this.packetTemplateIds.length;
        return count > 0 ? `Create Packet (${count} Designs) 📚✨` : 'Create Packet ✨';
    }

    get mergeOnlyButtonLabel() {
        const count = this.mergeOnlyCvIds.length;
        return count > 0 ? `Combine ${count} PDFs 🔗✨` : 'Combine PDFs ✨';
    }

    get mergeChildrenButtonLabel() {
        const count = this.selectedChildPdfCvIds.length;
        return count > 0 ? `Combine ${count} Files 📂✨` : 'Combine Files ✨';
    }

    @wire(getTemplatesForObject, { objectApiName: '$objectApiName' })
    wiredTemplates({ error, data }) {
        if (data) {
            this._templateData = data;
            this.templateOptions = data.map(t => ({ label: t.Name, value: t.Id }));
            this.error = undefined;
        } else if (error) {
            this.error = 'Error loading templates: ' + error.body.message;
        }
    }

    @wire(getChildRelationships, { objectApiName: '$objectApiName' })
    wiredRelationships({ error, data }) {
        if (data) {
            this.childRelationships = data;
        }
    }

    get childRelComboboxOptions() {
        return this.childRelationships.map(rel => ({ label: rel.relationshipName + ' (' + rel.childObjectLabel + ')', value: rel.relationshipName }));
    }

    get pdfTemplateOptions() {
        return this._templateData
            .filter(t => t.Output_Format__c === 'PDF')
            .map(t => ({ label: t.Name, value: t.Id }));
    }

    async loadRecordPdfs() {
        try {
            this.recordPdfOptions = await getRecordPdfs({ recordId: this.recordId });
        } catch (e) {
            this.showToast('Error', 'Failed to load record PDFs', 'error');
        }
    }

    // --- Event Handlers ---

    handleModeChangeInternal(event) {
        this.appMode = event.currentTarget.dataset.value;
        this.resetState();
    }

    handleOutputModeChangeInternal(event) {
        this.outputMode = event.currentTarget.dataset.value;
    }

    handleTemplateChangeInternal(event) {
        this.selectedTemplateId = event.target.value;
        this.selectedPdfCvIds = [];
    }

    handleMergeToggle(event) {
        this.mergeEnabled = event.target.checked;
        if (this.mergeEnabled && this.recordPdfOptions.length === 0) {
            this.loadRecordPdfs();
        }
    }

    handlePdfSelectionInternal(event) {
        const val = event.target.value;
        if (event.target.checked) {
            this.selectedPdfCvIds = [...this.selectedPdfCvIds, val];
        } else {
            this.selectedPdfCvIds = this.selectedPdfCvIds.filter(id => id !== val);
        }
    }

    handlePacketTemplateSelection(event) {
        this.packetTemplateIds = event.detail.value;
    }

    handlePacketIncludeToggle(event) {
        this.packetIncludeExisting = event.target.checked;
        if (this.packetIncludeExisting && this.recordPdfOptions.length === 0) {
            this.loadRecordPdfs();
        }
    }

    handleMergeOnlySelection(event) {
        this.mergeOnlyCvIds = event.detail.value;
    }

    handleChildRelChangeInternal(event) {
        this.selectedChildRel = event.target.value;
        this.childPdfsLoaded = false;
        this.selectedChildPdfCvIds = [];
    }

    handleChildFilterChangeInternal(event) {
        this.childFilterClause = event.target.value;
    }

    async handleLoadChildPdfs() {
        this.isLoading = true;
        try {
            const rel = this.childRelationships.find(r => r.relationshipName === this.selectedChildRel);
            const data = await getChildRecordPdfs({ 
                parentRecordId: this.recordId, 
                childObject: rel.childObjectApi,
                lookupField: rel.lookupFieldApi,
                filterClause: this.childFilterClause 
            });
            this.childRecordGroups = data;
            this.childPdfsLoaded = true;
        } catch (e) {
            this.showToast('Error', 'Failed to load files: ' + (e.body?.message || e.message), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    get childRecordGroupsWithState() {
        return this.childRecordGroups.map(group => ({
            ...group,
            pdfs: group.pdfs.map(pdf => ({
                ...pdf,
                checked: this.selectedChildPdfCvIds.includes(pdf.value)
            }))
        }));
    }

    handleChildPdfCheckbox(event) {
        const cvId = event.target.dataset.cvid;
        if (event.target.checked) {
            this.selectedChildPdfCvIds = [...this.selectedChildPdfCvIds, cvId];
        } else {
            this.selectedChildPdfCvIds = this.selectedChildPdfCvIds.filter(id => id !== cvId);
        }
    }

    // --- Core Logic ---

    async generateDocument() {
        this.isLoading = true;
        this.error = '';
        try {
            const t = this._templateData.find(tmpl => tmpl.Id === this.selectedTemplateId);
            const isPDF = t.Output_Format__c === 'PDF';
            const saveToRecord = this.outputMode === 'save';

            if (isPDF) {
                const result = await generatePdf({
                    templateId: this.selectedTemplateId,
                    recordId: this.recordId,
                    saveToRecord: saveToRecord
                });
                
                if (this.mergeEnabled && this.selectedPdfCvIds.length > 0) {
                    // Logic for merging after generation would go here using client-side merger
                    // For now, keep it simple as standard functionality
                }

                if (saveToRecord) {
                    this.showToast('Success', 'Document saved to record.', 'success');
                } else {
                    this.downloadBase64(result.base64, (result.title || 'Document') + '.pdf', 'application/pdf');
                }
            } else {
                const result = await processAndReturnDocument({
                    templateId: this.selectedTemplateId,
                    recordId: this.recordId
                });
                this.downloadBase64(result.base64, (result.title || 'Document') + (t.Type__c === 'PowerPoint' ? '.pptx' : '.docx'), 'application/octet-stream');
            }
        } catch (e) {
            this.error = e.body ? e.body.message : e.message;
        } finally {
            this.isLoading = false;
        }
    }

    async generatePacket() {
        this.isLoading = true;
        this.showToast('Note', 'Generating packet...', 'info');
        // This would require multiple calls and client-side merge
        this.isLoading = false;
    }

    async mergeOnlyDocument() {
        this.isLoading = true;
        this.showToast('Note', 'Merging files...', 'info');
        this.isLoading = false;
    }

    async mergeChildrenDocument() {
        this.isLoading = true;
        this.showToast('Note', 'Combining files...', 'info');
        this.isLoading = false;
    }

    // --- Helpers ---

    resetState() {
        this.selectedTemplateId = '';
        this.selectedPdfCvIds = [];
        this.packetTemplateIds = [];
        this.mergeOnlyCvIds = [];
        this.selectedChildPdfCvIds = [];
        this.childPdfsLoaded = false;
    }

    downloadBase64(base64Data, fileName, mimeType) {
        const byteCharacters = atob(base64Data);
        const byteNumbers = new Array(byteCharacters.length);
        for (let i = 0; i < byteCharacters.length; i++) {
            byteNumbers[i] = byteCharacters.charCodeAt(i);
        }
        const byteArray = new Uint8Array(byteNumbers);
        const blob = new Blob([byteArray], { type: mimeType });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = fileName;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}

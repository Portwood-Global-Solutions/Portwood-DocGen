import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTemplatesForObject from '@salesforce/apex/DocGenController.getTemplatesForObject';
import processAndReturnDocument from '@salesforce/apex/DocGenController.processAndReturnDocument';
import generateDocumentParts from '@salesforce/apex/DocGenController.generateDocumentParts';
import getContentVersionBase64 from '@salesforce/apex/DocGenController.getContentVersionBase64';
import generatePdf from '@salesforce/apex/DocGenController.generatePdf';
import saveGeneratedDocument from '@salesforce/apex/DocGenController.saveGeneratedDocument';
import getChildRelationships from '@salesforce/apex/DocGenController.getChildRelationships';
import getChildRecordPdfs from '@salesforce/apex/DocGenController.getChildRecordPdfs';
import getRecordPdfs from '@salesforce/apex/DocGenController.getRecordPdfs';
import generateDocumentGiantQuery from '@salesforce/apex/DocGenController.generateDocumentGiantQuery';
import getGiantQueryJobStatus from '@salesforce/apex/DocGenController.getGiantQueryJobStatus';
import getGiantQueryFragments from '@salesforce/apex/DocGenController.getGiantQueryFragments';
import generateDocumentPartsGiantQuery from '@salesforce/apex/DocGenController.generateDocumentPartsGiantQuery';
import cleanupGiantQueryFragments from '@salesforce/apex/DocGenController.cleanupGiantQueryFragments';
import { NavigationMixin } from 'lightning/navigation';
import { downloadBase64 as downloadBase64Util } from 'c/docGenUtils';
import { buildDocx } from './docGenZipWriter';
import { mergePdfs } from './docGenPdfMerger';
import OUT_FMT_FIELD from '@salesforce/schema/DocGen_Template__c.Output_Format__c';
import TYPE_FIELD from '@salesforce/schema/DocGen_Template__c.Type__c';
import IS_DEFAULT_FIELD from '@salesforce/schema/DocGen_Template__c.Is_Default__c';

export default class DocGenRunner extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;

    @track templateOptions = [];
    @track selectedTemplateId = '';
    @track outputMode = 'download';
    @track isLoading = false;
    @track error = '';
    @track loadingMessage = '';

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
            { label: 'Combine PDFs', value: 'mergeOnly', icon: '🔗', class: this.appMode === 'mergeOnly' ? 'seg-btn active' : 'seg-btn' }
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
        return t ? t[OUT_FMT_FIELD.fieldApiName] : null;
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
            // Auto-select the default template (query returns Is_Default__c DESC, so first match is the default)
            const defaultTemplate = data.find(t => t[IS_DEFAULT_FIELD.fieldApiName]);
            this.templateOptions = data.map(t => ({
                label: t.Name,
                value: t.Id,
                selected: defaultTemplate ? t.Id === defaultTemplate.Id : false
            }));
            if (defaultTemplate) {
                this.selectedTemplateId = defaultTemplate.Id;
            }
            this.error = undefined;
            // Preload record PDFs for merge option
            this.loadRecordPdfs();
        } else if (error) {
            this.error = 'Error loading templates: ' + error.body.message;
        }
    }

    @wire(getChildRelationships, { objectApiName: '$objectApiName' })
    wiredRelationships({ data }) {
        if (data) {
            this.childRelationships = data;
        }
    }

    get childRelComboboxOptions() {
        return this.childRelationships.map(rel => ({ label: rel.label, value: rel.value }));
    }

    get pdfTemplateOptions() {
        return this._templateData
            .filter(t => t[OUT_FMT_FIELD.fieldApiName] === 'PDF')
            .map(t => ({ label: t.Name, value: t.Id }));
    }

    async loadRecordPdfs() {
        try {
            this.recordPdfOptions = await getRecordPdfs({ recordId: this.recordId });
        } catch {
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
            const rel = this.childRelationships.find(r => r.value === this.selectedChildRel);
            const data = await getChildRecordPdfs({
                parentRecordId: this.recordId,
                childObject: rel.childObjectApiName,
                lookupField: rel.lookupField,
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

    /**
     * Main entry point for the Generate button. Auto-detects whether the dataset
     * qualifies as a Giant Query (>2000 child records) and routes accordingly.
     * For PDF output, launches async pipeline server-side.
     * For DOCX output, launches harvest batch then assembles client-side.
     * If not giant, falls through to normal generation.
     */
    async handleGenerate() {
        const selected = this._templateData.find(t => t.Id === this.selectedTemplateId);
        const templateType = selected ? selected[TYPE_FIELD.fieldApiName] : 'Word';
        const isPPT = templateType === 'PowerPoint';
        const isExcel = templateType === 'Excel';
        const isPDF = this.templateOutputFormat === 'PDF' && !isPPT && !isExcel;
        const isWord = templateType === 'Word' && !isPPT && !isExcel;

        // Giant Query auto-detect for PDF (non-merge) and DOCX Word output
        if ((isPDF || isWord) && !this.mergeEnabled) {
            this.isLoading = true;
            this.loadingMessage = 'Analyzing template...';
            this.error = null;
            try {
                const result = await generateDocumentGiantQuery({
                    templateId: this.selectedTemplateId,
                    recordId: this.recordId
                });
                if (result.isGiantQuery) {
                    if (isPDF) {
                        // PDF: async pipeline launched server-side — show toast and stop
                        const count = result.childCounts ? Object.values(result.childCounts).find(c => c > 2000) : null;
                        const countMsg = count ? count.toLocaleString() + ' records' : 'large dataset';
                        this.showToast('Success', `${countMsg} detected — generating asynchronously. Check Job History for progress.`, 'success');
                        return;
                    }
                    // DOCX: harvest batch launched — poll and assemble client-side
                    await this._assembleGiantQueryDocx(result.jobId, result.giantRelationship);
                    return;
                }
                // Not a giant query — document was already generated and saved by the Apex method.
                if (isPDF) {
                    const saveToRecord = this.outputMode === 'save';
                    const docTitle = result.title || 'Document';
                    if (saveToRecord) {
                        this.showToast('Success', 'PDF saved to record.', 'success');
                    } else if (result.contentVersionId) {
                        this.loadingMessage = 'Preparing download...';
                        const b64 = await getContentVersionBase64({ contentVersionId: result.contentVersionId });
                        if (b64) {
                            this.downloadBase64(b64, docTitle + '.pdf', 'application/pdf');
                            this.showToast('Success', 'PDF downloaded.', 'success');
                        } else {
                            this.showToast('Success', 'PDF saved to record (download unavailable).', 'success');
                        }
                    }
                    return;
                }
                // Not giant DOCX — fall through to normal generation
            } catch (e) {
                // If scouting fails, fall through to normal generation
                console.warn('DocGen: Giant Query scout failed, falling back to normal generation', e);
            } finally {
                this.isLoading = false;
                this.loadingMessage = '';
            }
        }

        // Normal generation path (non-PDF, merge-enabled PDF, or giant query scout fallback)
        await this.generateDocument();
    }

    async generateDocument() {
        this.isLoading = true;
        this.error = null;
        try {
            const selected = this._templateData.find(t => t.Id === this.selectedTemplateId);
            const templateType = selected ? selected[TYPE_FIELD.fieldApiName] : 'Word';
            const isPPT = templateType === 'PowerPoint';
            const isExcel = templateType === 'Excel';
            const isPDF = this.templateOutputFormat === 'PDF' && !isPPT && !isExcel;
            const saveToRecord = this.outputMode === 'save';
            const shouldMerge = isPDF && this.mergeEnabled && this.selectedPdfCvIds.length > 0;

            if (isPDF) {
                if (shouldMerge) {
                    await this._generateMergedPdf(saveToRecord);
                } else {
                    this.showToast('Info', 'Generating PDF...', 'info');
                    const result = await generatePdf({
                        templateId: this.selectedTemplateId,
                        recordId: this.recordId,
                        saveToRecord: saveToRecord
                    });
                    if (saveToRecord) {
                        this.showToast('Success', 'PDF saved to record.', 'success');
                    } else if (result.base64) {
                        this.downloadBase64(result.base64, (result.title || 'Document') + '.pdf', 'application/pdf');
                    }
                }
            } else if (!isPPT) {
                // Word DOCX / Excel XLSX — client-side assembly
                const ext = isExcel ? 'xlsx' : 'docx';
                this.showToast('Info', 'Generating document...', 'info');
                await this._generateOfficeClientSide(saveToRecord, ext, 'application/octet-stream');
            } else {
                // PowerPoint — server-side
                const result = await processAndReturnDocument({
                    templateId: this.selectedTemplateId,
                    recordId: this.recordId
                });
                if (!result || !result.base64) { throw new Error('Document generation returned empty result.'); }
                const docTitle = result.title || 'Document';
                if (saveToRecord) {
                    await saveGeneratedDocument({ recordId: this.recordId, fileName: docTitle, base64Data: result.base64, extension: 'pptx' });
                    this.showToast('Success', 'PPTX saved to record.', 'success');
                } else {
                    this.downloadBase64(result.base64, docTitle + '.pptx', 'application/octet-stream');
                }
            }
        } catch (e) {
            this.error = 'Generation Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
            this.loadingMessage = '';
        }
    }

    async handleGiantQuery() {
        this.isLoading = true;
        this.error = null;
        try {
            this.showToast('Info', 'Checking dataset size...', 'info');
            const result = await generateDocumentGiantQuery({
                templateId: this.selectedTemplateId,
                recordId: this.recordId
            });
            if (result.isGiantQuery) {
                this.showToast('Success', 'Large dataset detected \u2014 generating asynchronously. Check Job History for progress.', 'success');
            } else if (result.base64) {
                const saveToRecord = this.outputMode === 'save';
                const docTitle = result.title || 'Document';
                if (saveToRecord) {
                    await saveGeneratedDocument({ recordId: this.recordId, fileName: docTitle, base64Data: result.base64, extension: 'pdf' });
                    this.showToast('Success', 'PDF saved to record.', 'success');
                } else {
                    this.downloadBase64(result.base64, docTitle + '.pdf', 'application/pdf');
                    this.showToast('Success', 'Document downloaded.', 'success');
                }
            }
        } catch (e) {
            this.error = 'Giant Query Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
        }
    }

    async _generateMergedPdf(saveToRecord) {
        const totalPdfs = this.selectedPdfCvIds.length + 1;
        this.showToast('Info', `Generating and merging ${totalPdfs} PDFs...`, 'info');
        const result = await generatePdf({ templateId: this.selectedTemplateId, recordId: this.recordId, saveToRecord: false });
        if (!result || !result.base64) { throw new Error('Template PDF generation returned empty result.'); }
        const docTitle = result.title || 'Document';
        const pdfBytesArray = [this._base64ToUint8Array(result.base64)];
        for (const cvId of this.selectedPdfCvIds) {
            const b64 = await getContentVersionBase64({ contentVersionId: cvId });
            if (b64) { pdfBytesArray.push(this._base64ToUint8Array(b64)); }
        }
        const mergedBytes = mergePdfs(pdfBytesArray);
        const mergedBase64 = this._uint8ArrayToBase64(mergedBytes);
        if (saveToRecord) {
            await saveGeneratedDocument({ recordId: this.recordId, fileName: docTitle, base64Data: mergedBase64, extension: 'pdf' });
            this.showToast('Success', 'Merged PDF saved to record.', 'success');
        } else {
            this.downloadBase64(mergedBase64, docTitle + '.pdf', 'application/pdf');
            this.showToast('Success', 'Merged PDF downloaded.', 'success');
        }
    }

    async generatePacket() {
        this.isLoading = true;
        this.error = null;
        try {
            const templateCount = this.packetTemplateIds.length;
            const existingCount = this.packetIncludeExisting ? this.packetExistingPdfIds.length : 0;
            this.showToast('Info', `Generating packet (${templateCount + existingCount} documents)...`, 'info');
            const pdfBytesArray = [];
            for (const templateId of this.packetTemplateIds) {
                const result = await generatePdf({ templateId, recordId: this.recordId, saveToRecord: false });
                if (result && result.base64) { pdfBytesArray.push(this._base64ToUint8Array(result.base64)); }
            }
            if (this.packetIncludeExisting && this.packetExistingPdfIds.length > 0) {
                for (const cvId of this.packetExistingPdfIds) {
                    const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                    if (b64) { pdfBytesArray.push(this._base64ToUint8Array(b64)); }
                }
            }
            if (pdfBytesArray.length === 0) { throw new Error('No documents were generated.'); }
            let finalBase64;
            if (pdfBytesArray.length === 1) {
                finalBase64 = this._uint8ArrayToBase64(pdfBytesArray[0]);
            } else {
                finalBase64 = this._uint8ArrayToBase64(mergePdfs(pdfBytesArray));
            }
            const saveToRecord = this.outputMode === 'save';
            if (saveToRecord) {
                await saveGeneratedDocument({ recordId: this.recordId, fileName: 'Document Packet', base64Data: finalBase64, extension: 'pdf' });
                this.showToast('Success', 'Document packet saved to record.', 'success');
            } else {
                this.downloadBase64(finalBase64, 'Document Packet.pdf', 'application/pdf');
                this.showToast('Success', 'Document packet downloaded.', 'success');
            }
        } catch (e) {
            this.error = 'Packet Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
        }
    }

    async mergeOnlyDocument() {
        this.isLoading = true;
        this.error = null;
        try {
            const count = this.mergeOnlyCvIds.length;
            this.showToast('Info', `Merging ${count} PDFs...`, 'info');
            const pdfBytesArray = [];
            for (const cvId of this.mergeOnlyCvIds) {
                const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                if (b64) { pdfBytesArray.push(this._base64ToUint8Array(b64)); }
            }
            if (pdfBytesArray.length < 2) { throw new Error('Need at least 2 PDFs to merge.'); }
            const mergedBytes = mergePdfs(pdfBytesArray);
            const mergedBase64 = this._uint8ArrayToBase64(mergedBytes);
            const saveToRecord = this.outputMode === 'save';
            if (saveToRecord) {
                await saveGeneratedDocument({ recordId: this.recordId, fileName: 'Merged Document', base64Data: mergedBase64, extension: 'pdf' });
                this.showToast('Success', 'Merged PDF saved to record.', 'success');
            } else {
                this.downloadBase64(mergedBase64, 'Merged Document.pdf', 'application/pdf');
                this.showToast('Success', 'Merged PDF downloaded.', 'success');
            }
        } catch (e) {
            this.error = 'Merge Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
        }
    }

    async mergeChildrenDocument() {
        this.isLoading = true;
        this.error = null;
        try {
            const count = this.selectedChildPdfCvIds.length;
            this.showToast('Info', `Merging ${count} PDFs from child records...`, 'info');
            const pdfBytesArray = [];
            for (const cvId of this.selectedChildPdfCvIds) {
                const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                if (b64) { pdfBytesArray.push(this._base64ToUint8Array(b64)); }
            }
            if (pdfBytesArray.length < 1) { throw new Error('No PDFs could be loaded.'); }
            let finalBytes;
            if (pdfBytesArray.length === 1) { finalBytes = pdfBytesArray[0]; }
            else { finalBytes = mergePdfs(pdfBytesArray); }
            const finalBase64 = this._uint8ArrayToBase64(finalBytes);
            const saveToRecord = this.outputMode === 'save';
            if (saveToRecord) {
                await saveGeneratedDocument({ recordId: this.recordId, fileName: 'Merged Child PDFs', base64Data: finalBase64, extension: 'pdf' });
                this.showToast('Success', 'Merged PDF saved to record.', 'success');
            } else {
                this.downloadBase64(finalBase64, 'Merged Child PDFs.pdf', 'application/pdf');
                this.showToast('Success', 'Merged PDF downloaded.', 'success');
            }
        } catch (e) {
            this.error = 'Merge Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
        }
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

    /**
     * Client-side Office document assembly (DOCX or XLSX).
     * Server merges XML, client fetches images, assembles ZIP.
     * Note: Rich text images from rtaImage servlet URLs render in PDF only.
     * For DOCX images, use {%FieldName} tags with ContentVersion IDs.
     */
    async _generateOfficeClientSide(saveToRecord, extension, mimeType) {
        const parts = await generateDocumentParts({
            templateId: this.selectedTemplateId,
            recordId: this.recordId
        });
        if (!parts || !parts.allXmlParts) { throw new Error('Document generation returned empty result.'); }
        const docTitle = parts.title || 'Document';

        const allImages = { ...(parts.imageBase64Map || {}) };
        if (parts.imageCvIdMap) {
            const uniqueCvIds = new Map();
            for (const [mediaPath, cvId] of Object.entries(parts.imageCvIdMap)) {
                if (!uniqueCvIds.has(cvId)) { uniqueCvIds.set(cvId, []); }
                uniqueCvIds.get(cvId).push(mediaPath);
            }
            for (const [cvId, mediaPaths] of uniqueCvIds) {
                try {
                    const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                    if (b64) { for (const mp of mediaPaths) { allImages[mp] = b64; } }
                } catch (imgErr) { console.warn('DocGen: Failed to fetch image CV ' + cvId, imgErr); }
            }
        }

        const fileBytes = buildDocx(parts.allXmlParts, allImages);
        const fileBase64 = this._uint8ArrayToBase64(fileBytes);
        if (saveToRecord) {
            await saveGeneratedDocument({ recordId: this.recordId, fileName: docTitle, base64Data: fileBase64, extension });
            this.showToast('Success', extension.toUpperCase() + ' saved to record.', 'success');
        } else {
            this.downloadBase64(fileBase64, docTitle + '.' + extension, mimeType);
            this.showToast('Success', extension.toUpperCase() + ' downloaded.', 'success');
        }
    }

    /**
     * Polls a Giant Query harvest batch, fetches fragments, injects into the template
     * shell, and builds a DOCX ZIP entirely client-side. No heap limit.
     * @param {string} jobId - The DocGen_Job__c record ID
     * @param {string} giantRelationship - The child relationship name being harvested
     */
    async _assembleGiantQueryDocx(jobId, giantRelationship) {
        this.isLoading = true;
        this.error = null;
        try {
            // 1. Poll harvest batch until completed
            this.loadingMessage = 'Processing records...';
            let status = 'Harvesting';
            while (status !== 'Completed' && status !== 'Failed') {
                // eslint-disable-next-line no-await-in-loop
                await new Promise(resolve => { setTimeout(resolve, 3000); }); // NOSONAR — intentional poll delay
                // eslint-disable-next-line no-await-in-loop
                const jobStatus = await getGiantQueryJobStatus({ jobId });
                status = jobStatus.status;
                if (status === 'Failed') {
                    throw new Error('Giant Query harvest failed: ' + (jobStatus.label || 'Unknown error'));
                }
                const done = jobStatus.successCount || 0;
                const total = jobStatus.totalRecords || 0;
                if (total > 0) {
                    const batchesDone = done;
                    const totalBatches = Math.ceil(total / 50);
                    this.loadingMessage = `Processing ${total.toLocaleString()} records (batch ${batchesDone}/${totalBatches})...`;
                }
            }

            // 2. Get template shell with placeholder where giant loop goes
            this.loadingMessage = 'Preparing template...';
            const parts = await generateDocumentPartsGiantQuery({
                templateId: this.selectedTemplateId,
                recordId: this.recordId,
                giantRelationshipName: giantRelationship
            });
            if (!parts || !parts.allXmlParts) {
                throw new Error('Template parts generation returned empty result.');
            }
            const docTitle = parts.title || 'Document';
            const placeholder = parts.placeholder || '<!--DOCGEN_GIANT_LOOP_PLACEHOLDER-->';

            // 3. Fetch fragment CV IDs
            this.loadingMessage = 'Fetching fragments...';
            const fragResult = await getGiantQueryFragments({ jobId });
            const fragmentIds = fragResult.fragmentIds || [];

            // 4. Fetch each fragment and concatenate XML
            let allFragmentXml = '';
            for (let i = 0; i < fragmentIds.length; i++) {
                this.loadingMessage = `Assembling document (fragment ${i + 1}/${fragmentIds.length})...`;
                // eslint-disable-next-line no-await-in-loop
                const fragB64 = await getContentVersionBase64({ contentVersionId: fragmentIds[i] });
                if (fragB64) {
                    // Decode base64 to string (fragment is UTF-8 XML text)
                    allFragmentXml += atob(fragB64);
                }
            }

            // 5. Inject fragment XML into the template at the placeholder position
            const docXmlKey = 'word/document.xml';
            if (parts.allXmlParts[docXmlKey]) {
                parts.allXmlParts[docXmlKey] = parts.allXmlParts[docXmlKey].replace(placeholder, allFragmentXml);
            }

            // 6. Fetch images (same logic as _generateOfficeClientSide)
            this.loadingMessage = 'Fetching images...';
            const allImages = { ...(parts.imageBase64Map || {}) };
            if (parts.imageCvIdMap) {
                const uniqueCvIds = new Map();
                for (const [mediaPath, cvId] of Object.entries(parts.imageCvIdMap)) {
                    if (!uniqueCvIds.has(cvId)) { uniqueCvIds.set(cvId, []); }
                    uniqueCvIds.get(cvId).push(mediaPath);
                }
                for (const [cvId, mediaPaths] of uniqueCvIds) {
                    try {
                        // eslint-disable-next-line no-await-in-loop
                        const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                        if (b64) { for (const mp of mediaPaths) { allImages[mp] = b64; } }
                    } catch (imgErr) { console.warn('DocGen: Failed to fetch image CV ' + cvId, imgErr); }
                }
            }

            // 7. Build DOCX ZIP
            this.loadingMessage = 'Building DOCX...';
            const fileBytes = buildDocx(parts.allXmlParts, allImages);
            const fileBase64 = this._uint8ArrayToBase64(fileBytes);

            // 8. Download or save
            const saveToRecord = this.outputMode === 'save';
            if (saveToRecord) {
                await saveGeneratedDocument({ recordId: this.recordId, fileName: docTitle, base64Data: fileBase64, extension: 'docx' });
                this.showToast('Success', 'DOCX saved to record.', 'success');
            } else {
                this.downloadBase64(fileBase64, docTitle + '.docx', 'application/octet-stream');
                this.showToast('Success', 'DOCX downloaded.', 'success');
            }

            // 9. Clean up fragment CVs server-side
            try {
                await cleanupGiantQueryFragments({ jobId });
            } catch (cleanupErr) {
                console.warn('DocGen: Fragment cleanup failed (non-fatal)', cleanupErr);
            }
        } catch (e) {
            this.error = 'Giant Query DOCX Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
            this.loadingMessage = '';
        }
    }

    _base64ToUint8Array(base64) {
        const binaryStr = atob(base64);
        const bytes = new Uint8Array(binaryStr.length);
        for (let i = 0; i < binaryStr.length; i++) { bytes[i] = binaryStr.charCodeAt(i); }
        return bytes;
    }

    _uint8ArrayToBase64(bytes) {
        let binary = '';
        for (let i = 0; i < bytes.length; i++) { binary += String.fromCharCode(bytes[i]); }
        return btoa(binary);
    }

    downloadBase64(base64Data, fileName, mimeType) {
        downloadBase64Util(base64Data, fileName, mimeType);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
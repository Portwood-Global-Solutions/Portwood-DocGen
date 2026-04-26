import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTemplatesForObject from '@salesforce/apex/DocGenController.getTemplatesForObjectAndRecord';
import processAndReturnDocument from '@salesforce/apex/DocGenController.processAndReturnDocument';
import processAndReturnDocumentWithOverride from '@salesforce/apex/DocGenController.processAndReturnDocumentWithOverride';
import generateDocumentParts from '@salesforce/apex/DocGenController.generateDocumentParts';
import getContentVersionBase64 from '@salesforce/apex/DocGenController.getContentVersionBase64';
import generatePdf from '@salesforce/apex/DocGenController.generatePdf';
import saveGeneratedDocument from '@salesforce/apex/DocGenController.saveGeneratedDocument';
import generatePdfAsync from '@salesforce/apex/DocGenController.generatePdfAsync';
import scoutAttachedImageSize from '@salesforce/apex/DocGenController.scoutAttachedImageSize';
import getChildRelationships from '@salesforce/apex/DocGenController.getChildRelationships';
import getChildRecordPdfs from '@salesforce/apex/DocGenController.getChildRecordPdfs';
import getRecordPdfs from '@salesforce/apex/DocGenController.getRecordPdfs';
import generateDocumentGiantQuery from '@salesforce/apex/DocGenController.generateDocumentGiantQuery';
import getGiantQueryJobStatus from '@salesforce/apex/DocGenController.getGiantQueryJobStatus';
import getGiantQueryFragments from '@salesforce/apex/DocGenController.getGiantQueryFragments';
import generateDocumentPartsGiantQuery from '@salesforce/apex/DocGenController.generateDocumentPartsGiantQuery';
import cleanupGiantQueryFragments from '@salesforce/apex/DocGenController.cleanupGiantQueryFragments';
import getChildRecordPage from '@salesforce/apex/DocGenController.getChildRecordPage';
import scoutChildCounts from '@salesforce/apex/DocGenController.scoutChildCounts';
import launchGiantQueryPdfBatch from '@salesforce/apex/DocGenController.launchGiantQueryPdfBatch';
import getSortedChildIds from '@salesforce/apex/DocGenController.getSortedChildIds';
import getChildRecordsByIds from '@salesforce/apex/DocGenController.getChildRecordsByIds';
import { NavigationMixin } from 'lightning/navigation';
import { downloadBase64 as downloadBase64Util } from 'c/docGenUtils';
import { buildDocx } from './docGenZipWriter';
import { mergePdfs } from './docGenPdfMerger';
import { extractFirstImageFromPdfBase64 } from './docGenPdfImageExtractor';
import renderImageAsPdfBase64 from '@salesforce/apex/DocGenController.renderImageAsPdfBase64';
import OUT_FMT_FIELD from '@salesforce/schema/DocGen_Template__c.Output_Format__c';
import TYPE_FIELD from '@salesforce/schema/DocGen_Template__c.Type__c';
import IS_DEFAULT_FIELD from '@salesforce/schema/DocGen_Template__c.Is_Default__c';
import CATEGORY_FIELD from '@salesforce/schema/DocGen_Template__c.Category__c';
import LOCK_OUTPUT_FORMAT_FIELD from '@salesforce/schema/DocGen_Template__c.Lock_Output_Format__c';

export default class DocGenRunner extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;

    @track templateOptions = [];
    @track selectedTemplateId = '';
    @track selectedCategory = '__ALL__'; // 1.47 — category filter
    @track outputFormatOverride = ''; // 1.47 — runtime output format override
    @track outputMode = 'download';
    @track isLoading = false;
    @track error = '';
    @track loadingMessage = '';
    @track isGiantQueryMode = false;
    @track progressPercent = 0;
    @track showProgressBar = false;

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

    get _isMobile() {
        return /Mobi|Android|iPhone|iPad/i.test(navigator.userAgent);
    }

    get modernOutputOptions() {
        // Mobile can only save to record — no browser download capability
        if (this._isMobile) {
            if (this.outputMode !== 'save') { this.outputMode = 'save'; }
            return [
                { label: 'Save to Record', value: 'save', icon: '☁️', class: 'pill-btn active' }
            ];
        }
        const isPdfOutput = this.templateOutputFormat === 'PDF';
        if (!isPdfOutput || this.isGiantQueryMode) {
            return [
                { label: 'Download', value: 'download', icon: '⬇️', class: 'pill-btn active' }
            ];
        }
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
    get progressBarStyle() { return `width: ${this.progressPercent}%`; }
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

    @wire(getTemplatesForObject, { objectApiName: '$objectApiName', recordId: '$recordId' })
    wiredTemplates({ error, data }) {
        if (data) {
            this._templateData = data;
            this._rebuildTemplateOptions();
            this.error = undefined;
            // Preload record PDFs for merge option
            this.loadRecordPdfs();
        } else if (error) {
            this.error = 'Error loading templates: ' + error.body.message;
        }
    }

    /**
     * Rebuilds templateOptions from _templateData applying the current category filter,
     * decorating default templates with a star prefix, and auto-selecting the default
     * (or the first option if no default).
     */
    _rebuildTemplateOptions() {
        const data = this._templateData || [];
        const filtered = (this.selectedCategory && this.selectedCategory !== '__ALL__')
            ? data.filter(t => (t[CATEGORY_FIELD.fieldApiName] || '__UNCATEGORIZED__') === this.selectedCategory)
            : data;
        const defaultTemplate = filtered.find(t => t[IS_DEFAULT_FIELD.fieldApiName]);
        this.templateOptions = filtered.map(t => {
            const isDefault = !!t[IS_DEFAULT_FIELD.fieldApiName];
            const catVal = t[CATEGORY_FIELD.fieldApiName];
            const cat = catVal ? `[${catVal}] ` : '';
            return {
                label: `${isDefault ? '★ ' : ''}${cat}${t.Name}`,
                value: t.Id,
                selected: defaultTemplate ? t.Id === defaultTemplate.Id : false
            };
        });
        // If the previously-selected template is no longer in the filtered list,
        // fall back to the new default (or first option, or empty).
        const stillSelected = this.templateOptions.some(o => o.value === this.selectedTemplateId);
        if (!stillSelected) {
            this.selectedTemplateId = defaultTemplate ? defaultTemplate.Id
                : (this.templateOptions[0] ? this.templateOptions[0].value : '');
        }
        // Reset override when template list changes — the new selection may be a different type
        this.outputFormatOverride = '';
    }

    /**
     * Distinct categories present in the loaded template list, plus an "All" sentinel.
     * Hidden when there's only one category (no point showing a filter with one option).
     */
    get categoryOptions() {
        const data = this._templateData || [];
        const distinct = new Set();
        for (const t of data) {
            const v = t[CATEGORY_FIELD.fieldApiName];
            distinct.add(v ? v : '__UNCATEGORIZED__');
        }
        if (distinct.size <= 1) return [];
        const opts = [{ label: 'All Categories', value: '__ALL__' }];
        const sorted = Array.from(distinct).sort();
        for (const c of sorted) {
            opts.push({ label: c === '__UNCATEGORIZED__' ? '(Uncategorized)' : c, value: c });
        }
        return opts;
    }

    get showCategoryFilter() { return this.categoryOptions.length > 0; }

    get selectedTemplate() {
        return this._templateData.find(t => t.Id === this.selectedTemplateId);
    }

    /**
     * Output format picker options derived from the selected template's Type__c.
     * Word templates: PDF + Word. PowerPoint templates: PPTX only (picker hidden).
     * Hidden entirely when the template has Lock_Output_Format__c = true.
     */
    get outputFormatPickerOptions() {
        const t = this.selectedTemplate;
        if (!t) return [];
        if (t[LOCK_OUTPUT_FORMAT_FIELD.fieldApiName]) return [];
        const tplType = t[TYPE_FIELD.fieldApiName];
        if (tplType === 'PowerPoint') return []; // PPTX only — no choice
        if (tplType === 'Word') {
            return [
                { label: 'PDF', value: 'PDF' },
                { label: 'Word (DOCX)', value: 'Word' }
            ];
        }
        return [];
    }

    get showOutputFormatPicker() { return this.outputFormatPickerOptions.length > 0; }

    /**
     * Effective Output_Format__c value for THIS run — 'PDF' or 'Native'.
     * Maps the override (PDF / Word / PowerPoint, matching template TYPE) onto the
     * Output_Format__c vocabulary the runner branches on.
     */
    get effectiveOutputFormat() {
        if (this.outputFormatOverride === 'PDF') return 'PDF';
        if (this.outputFormatOverride === 'Word' || this.outputFormatOverride === 'PowerPoint') return 'Native';
        return this.templateOutputFormat;
    }

    get showEmptyState() {
        return this._templateData && this._templateData.length === 0;
    }

    get emptyStateMessage() {
        return 'No templates available for this record. Check the template\'s Specific Record Ids and Required Permission Sets, or ask an admin to create a template for ' + (this.objectApiName || 'this object') + '.';
    }

    handleCategoryChange(event) {
        this.selectedCategory = event.target.value;
        this._rebuildTemplateOptions();
    }

    handleOutputFormatOverrideChange(event) {
        this.outputFormatOverride = event.target.value || '';
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
        // Keep templateOptions.selected in sync so the <select> re-renders
        // correctly when the Generate section is destroyed/recreated by lwc:if
        this.templateOptions = this.templateOptions.map(t => ({
            ...t,
            selected: t.value === this.selectedTemplateId
        }));
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
        const isWord = templateType === 'Word' && !isPPT && !isExcel;

        // Giant Query auto-detect: ALWAYS scout first before any generation
        this.isLoading = true;
        this.loadingMessage = 'Analyzing...';
        this.error = null;
        try {
            const scoutResult = await scoutChildCounts({
                recordId: this.recordId,
                templateId: this.selectedTemplateId
            });
            const counts = scoutResult.counts || {};
            const childNodes = scoutResult.childNodes || {};
            const useGiantPath = scoutResult.useGiantPath || {};

            // Heap-aware routing (v1.54.0+): server estimates peak sync-path heap per
            // relationship and flags useGiantPath[rel]=true if the estimate exceeds
            // the safe ratio of the 6MB sync heap limit. No hardcoded record threshold.
            const giantRel = Object.entries(counts).find(([rel]) => useGiantPath[rel]);
            if (giantRel) {
                this.isGiantQueryMode = true;
                this.outputMode = 'download';
                const isPdf = this.templateOutputFormat === 'PDF';
                if (isPdf) {
                    await this._assembleGiantQueryPdf(giantRel[0], counts, childNodes[giantRel[0]]);
                    return;
                }
                if (isWord) {
                    await this._assembleGiantQueryDocxClientSide(giantRel[0], counts, childNodes[giantRel[0]]);
                    return;
                }
                this.isLoading = false;
                this.loadingMessage = '';
                this.error = `This record has ${giantRel[1].toLocaleString()} ${giantRel[0]} records — ` +
                    'too large for sync PowerPoint/Excel output. Please generate as DOCX (Word) or PDF.';
                return;
            }
            // Stash scout data so the sync fallback branch can auto-retry if processXml
            // detects heap pressure mid-flight and returns the heapPressure signal.
            this._scoutCache = { counts, childNodes };
        } catch (e) {
            // Scout failed — fall through to normal generation
            console.error('DocGen: SCOUT FAILED:', e.body ? e.body.message : e.message, e);
        } finally {
            this.isLoading = false;
            this.loadingMessage = '';
        }

        // Normal generation — scout confirmed <2000 children (or scout unavailable)
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
            // Use effectiveOutputFormat so a runtime PDF/Word override re-routes the path.
            const isPDF = this.effectiveOutputFormat === 'PDF' && !isPPT && !isExcel;
            const saveToRecord = this.outputMode === 'save';
            const shouldMerge = isPDF && this.mergeEnabled && this.selectedPdfCvIds.length > 0;
            const hasOverride = !!this.outputFormatOverride;

            if (isPDF) {
                if (shouldMerge) {
                    await this._generateMergedPdf(saveToRecord);
                } else if (hasOverride) {
                    // Override path — runs through processAndReturnDocumentWithOverride so
                    // the template's Lock_Output_Format__c + PowerPoint→PDF guards fire.
                    this.showToast('Info', 'Generating PDF...', 'info');
                    const result = await processAndReturnDocumentWithOverride({
                        templateId: this.selectedTemplateId,
                        recordId: this.recordId,
                        resolvedImages: null,
                        outputFormatOverride: this.outputFormatOverride
                    });
                    if (await this._handledHeapPressure(result)) { return; }
                    if (saveToRecord) {
                        await saveGeneratedDocument({ recordId: this.recordId, fileName: (result.title || 'Document'), base64Data: result.base64, extension: 'pdf' });
                        this.showToast('Success', 'PDF saved to record.', 'success');
                    } else {
                        this.downloadBase64(result.base64, (result.title || 'Document') + '.pdf', 'application/pdf');
                    }
                } else if (saveToRecord) {
                    // Pre-flight size check: attached images >30MB will fail the
                    // Save-to-Record ContentVersion insert. Warn up front instead
                    // of letting the Queueable fail silently.
                    const imgBytes = await scoutAttachedImageSize({ recordId: this.recordId });
                    const LIMIT_BYTES = 30 * 1024 * 1024;
                    if (imgBytes > LIMIT_BYTES) {
                        const mb = (imgBytes / 1024 / 1024).toFixed(1);
                        this.showToast(
                            'Cannot Save to Record',
                            `This record has ${mb} MB of attached images — above the 30 MB Save-to-Record limit. Use Download instead (no size limit), or remove some images and try again.`,
                            'error',
                            'sticky'
                        );
                        return;
                    }
                    // Save-to-record runs fully server-side via a Queueable so the full
                    // render + big-file DML never holds the Aura request open long enough
                    // to trip Salesforce's CSRF timeout (which returns an "Illegal Request"
                    // HTML page instead of the expected JSON). LWC gets back immediately.
                    this.showToast('Info', 'Generating and saving PDF in the background...', 'info');
                    await generatePdfAsync({
                        templateId: this.selectedTemplateId,
                        recordId: this.recordId
                    });
                    this.showToast('Success', 'PDF is being generated. It will appear on the record in a moment — refresh the page to see it.', 'success');
                } else {
                    this.showToast('Info', 'Generating PDF...', 'info');
                    const result = await generatePdf({
                        templateId: this.selectedTemplateId,
                        recordId: this.recordId,
                        saveToRecord: false
                    });
                    if (await this._handledHeapPressure(result)) { return; }
                    if (result.base64) {
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
                    // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
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

    /**
     * In-flight heap-pressure fallback (v1.54.0+). When sync PDF generation returns
     * { heapPressure: true, giantRelationship: 'OpportunityLineItems' }, transparently
     * re-route to the giant-query batch path using scout data cached during handleGenerate.
     * Returns true if we handled the signal, false otherwise.
     */
    async _handledHeapPressure(result) {
        if (!result || !result.heapPressure) { return false; }
        if (!this._scoutCache) {
            this.error = 'Dataset exceeds sync heap limit — open the Command Hub and generate via the bulk pipeline.';
            return true;
        }
        const { counts, childNodes } = this._scoutCache;
        // If the server couldn't identify the giant relationship (e.g. Blob.toPdf
        // heap OOM — thrown from deep in the PDF engine, not our typed exception),
        // pick the relationship with the most records. It's almost always the one
        // blowing heap.
        let rel = result.giantRelationship;
        if (!rel) {
            let maxCount = 0;
            for (const [name, count] of Object.entries(counts || {})) {
                if (count > maxCount) { maxCount = count; rel = name; }
            }
        }
        if (!rel || !childNodes[rel]) {
            this.error = 'Dataset exceeds sync heap limit — open the Command Hub and generate via the bulk pipeline.';
            return true;
        }
        this.showToast('Info', `Large dataset — switching to giant-query mode for ${rel}.`, 'info');
        this.isGiantQueryMode = true;
        this.outputMode = 'download';
        await this._assembleGiantQueryPdf(rel, counts, childNodes[rel]);
        return true;
    }

    async handleGiantQuery() {
        this.isLoading = true;
        this.error = null;
        try {
            this.showToast('Info', 'Checking dataset size...', 'info');
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
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
                    // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
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
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
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
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
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
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
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
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
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
        // Keep selectedTemplateId so it persists when switching back to generate mode
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
        // Lightning rich text inline images (0EM ContentReference) — only path:
        // server renders single-image PDF via Blob.toPdf (privileged URL resolver),
        // client extracts the embedded JPEG XObject. PDF is in-memory only.
        if (parts.imageUrlMap) {
            for (const [mediaPath, url] of Object.entries(parts.imageUrlMap)) {
                if (!/rtaImage/i.test(url)) continue;
                try {
                    // eslint-disable-next-line no-await-in-loop
                    const pdfB64 = await renderImageAsPdfBase64({ imageUrl: url });
                    if (!pdfB64) continue;
                    // eslint-disable-next-line no-await-in-loop
                    const extracted = await extractFirstImageFromPdfBase64(pdfB64);
                    if (extracted && extracted.base64) {
                        allImages[mediaPath] = extracted.base64;
                        if (extracted.width && extracted.height) {
                            this._updateDocxImageSizeIfNotExplicit(parts, mediaPath, extracted.width, extracted.height);
                        }
                    }
                } catch (urlErr) { console.warn('DocGen: rich text image extract failed for ' + url, urlErr); }
            }
        }

        const fileBytes = buildDocx(parts.allXmlParts, allImages);
        const fileBase64 = this._uint8ArrayToBase64(fileBytes);
        if (saveToRecord) {
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
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
            if (parts.imageUrlMap) {
                for (const [mediaPath, url] of Object.entries(parts.imageUrlMap)) {
                    if (!/rtaImage/i.test(url)) continue;
                    try {
                        // eslint-disable-next-line no-await-in-loop
                        const pdfB64 = await renderImageAsPdfBase64({ imageUrl: url });
                        if (!pdfB64) continue;
                        // eslint-disable-next-line no-await-in-loop
                        const extracted = await extractFirstImageFromPdfBase64(pdfB64);
                        if (extracted && extracted.base64) {
                            allImages[mediaPath] = extracted.base64;
                            // wp:extent rewrite temporarily disabled — was breaking
                            // image rendering in Word. Re-enable once root cause known.
                            // if (extracted.width && extracted.height) {
                            //     this._updateDocxImageSizeIfNotExplicit(parts, mediaPath, extracted.width, extracted.height);
                            // }
                        }
                    } catch (urlErr) { console.warn('DocGen: rich text image extract failed for ' + url, urlErr); }
                }
            }

            // 7. Build DOCX ZIP
            this.loadingMessage = 'Building DOCX...';
            const fileBytes = buildDocx(parts.allXmlParts, allImages);
            const fileBase64 = this._uint8ArrayToBase64(fileBytes);

            // 8. Download or save
            const saveToRecord = this.outputMode === 'save';
            if (saveToRecord) {
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
                await saveGeneratedDocument({ recordId: this.recordId, fileName: docTitle, base64Data: fileBase64, extension: 'docx' });
                this.showToast('Success', 'DOCX saved to record.', 'success');
            } else {
                this.downloadBase64(fileBase64, docTitle + '.docx', 'application/octet-stream');
                this.showToast('Success', 'DOCX downloaded.', 'success');
            }

            // 9. Clean up fragment CVs server-side
            try {
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
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

    /**
     * Pure client-side Giant Query DOCX assembly.
     * No server-side batch, no fragment CVs — queries child records page by page
     * via getChildRecordPage (2,000 rows per call), renders XML in JS, builds DOCX.
     */
    async _assembleGiantQueryDocxClientSide(giantRelationship, childCounts, serverChildNode) {
        this.isLoading = true;
        this.error = null;
        try {
            const totalRecords = childCounts ? childCounts[giantRelationship] || 0 : 0;

            // 1. Get template shell with placeholder
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

            // 2. Use server-resolved child node metadata (works for V1, V2, V3)
            if (!serverChildNode) {
                throw new Error('Could not find child node configuration for ' + giantRelationship);
            }

            const childObject = serverChildNode.object;
            const lookupField = serverChildNode.lookupField;
            const childFields = serverChildNode.fields || [];
            const parentFields = serverChildNode.parentFields || [];
            const allFields = ['Id', ...childFields.filter(f => f !== 'Id'), ...parentFields].join(', ');

            // 3. Get the loop body XML from the template (extracted by generateDocumentPartsGiantQuery)
            const innerXml = parts.giantLoopBodyXml || '';
            if (!innerXml) {
                throw new Error('Could not extract loop body XML from template for ' + giantRelationship);
            }

            // 4. Page through child records and render XML client-side
            const orderBy = serverChildNode.orderBy || '';
            const whereClause = serverChildNode.where || '';
            let allRenderedXml = '';
            let fetched = 0;
            const pageSize = 500;

            if (orderBy) {
                // Sorted path: pre-query all IDs in sort order, then fetch by chunk
                this.loadingMessage = 'Sorting records...';
                const sortedIds = await getSortedChildIds({
                    childObject,
                    lookupField,
                    parentId: this.recordId,
                    orderByClause: orderBy,
                    whereClause: whereClause || null
                });

                for (let i = 0; i < sortedIds.length; i += pageSize) {
                    const chunk = sortedIds.slice(i, i + pageSize);
                    this.loadingMessage = `Loading records (${fetched.toLocaleString()} / ${totalRecords.toLocaleString()})...`;

                    // eslint-disable-next-line no-await-in-loop
                    const records = await getChildRecordsByIds({
                        childObject,
                        fields: allFields,
                        recordIds: chunk
                    });

                    fetched += records.length;
                    this._renderGiantDocxRows(records, innerXml, childFields, parentFields, (xml) => { allRenderedXml += xml; });

                    this.progressPercent = Math.round((fetched / totalRecords) * 80);
                }
            } else {
                // Unsorted cursor path (original behavior)
                let lastCursorId = null;
                let hasMore = true;

                while (hasMore) {
                    this.loadingMessage = `Loading records (${fetched.toLocaleString()} / ${totalRecords.toLocaleString()})...`;

                    // eslint-disable-next-line no-await-in-loop
                    const page = await getChildRecordPage({
                        childObject,
                        lookupField,
                        parentId: this.recordId,
                        lastCursorId,
                        fields: allFields,
                        pageSize
                    });

                    const records = page.records || [];
                    lastCursorId = page.lastId;
                    hasMore = page.hasMore;
                    fetched += records.length;

                    this._renderGiantDocxRows(records, innerXml, childFields, parentFields, (xml) => { allRenderedXml += xml; });

                    this.progressPercent = Math.round((fetched / totalRecords) * 80);
                }
            }

            this.loadingMessage = `Loaded ${fetched.toLocaleString()} records. Building document...`;

            // 5. Inject rendered XML into template at placeholder
            const docXmlKey = 'word/document.xml';
            if (parts.allXmlParts[docXmlKey]) {
                parts.allXmlParts[docXmlKey] = parts.allXmlParts[docXmlKey].replace(placeholder, allRenderedXml);
            }
            allRenderedXml = null; // free memory

            // 6. Fetch images
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
            if (parts.imageUrlMap) {
                for (const [mediaPath, url] of Object.entries(parts.imageUrlMap)) {
                    if (!/rtaImage/i.test(url)) continue;
                    try {
                        // eslint-disable-next-line no-await-in-loop
                        const pdfB64 = await renderImageAsPdfBase64({ imageUrl: url });
                        if (!pdfB64) continue;
                        // eslint-disable-next-line no-await-in-loop
                        const extracted = await extractFirstImageFromPdfBase64(pdfB64);
                        if (extracted && extracted.base64) {
                            allImages[mediaPath] = extracted.base64;
                            // wp:extent rewrite temporarily disabled — was breaking
                            // image rendering in Word. Re-enable once root cause known.
                            // if (extracted.width && extracted.height) {
                            //     this._updateDocxImageSizeIfNotExplicit(parts, mediaPath, extracted.width, extracted.height);
                            // }
                        }
                    } catch (urlErr) { console.warn('DocGen: rich text image extract failed for ' + url, urlErr); }
                }
            }

            // 7. Build DOCX ZIP
            this.loadingMessage = 'Building DOCX...';
            const fileBytes = buildDocx(parts.allXmlParts, allImages);
            const fileBase64 = this._uint8ArrayToBase64(fileBytes);

            // 8. Giant Query always downloads — file size exceeds Aura 4MB payload limit
            const fileSizeMB = (fileBase64.length * 0.75 / 1048576).toFixed(1);
            this.downloadBase64(fileBase64, docTitle + '.docx', 'application/octet-stream');
            this.showToast('Success', `DOCX downloaded (${fileSizeMB}MB) — ${fetched.toLocaleString()} ${giantRelationship} rows.`, 'success');
        } catch (e) {
            this.error = 'Giant Query Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
            this.loadingMessage = '';
            this.isGiantQueryMode = false;
        }
    }

    /**
     * Giant Query PDF: launches server batch that renders XML fragments, then
     * assembles into a single PDF server-side via Blob.toPdf() in finish().
     * Client just polls, fetches the final PDF, and downloads.
     * @param {string} giantRelationship - The child relationship name
     * @param {Object} childCounts - Map of relationship name to record count
     * @param {Object} childNodeConfig - Child node config from scout
     */
    /**
     * Renders DOCX XML rows for a batch of records. Used by both sorted and
     * cursor-based Giant Query DOCX assembly paths.
     */
    _renderGiantDocxRows(records, innerXml, childFields, parentFields, appendFn) {
        for (const rec of records) {
            let rowXml = innerXml;
            for (const field of [...childFields, ...parentFields]) {
                let value = '';
                if (field.includes('.')) {
                    const fieldParts = field.split('.');
                    let current = rec;
                    for (let i = 0; i < fieldParts.length && current; i++) {
                        current = current[fieldParts[i]];
                    }
                    value = current != null ? String(current) : '';
                } else {
                    value = rec[field] != null ? String(rec[field]) : '';
                }
                const escaped = value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
                rowXml = rowXml.split('{' + field + '}').join(escaped);
                rowXml = rowXml.split('{*' + field + '}').join(escaped);
                rowXml = rowXml.split('{%QR:' + field + '}').join(escaped);
                rowXml = rowXml.split('{%BARCODE:' + field + '}').join(escaped);
                rowXml = rowXml.split('{%' + field + '}').join(escaped);
            }
            rowXml = rowXml.replace(/\{(\w[\w.]*?)(?::([^}]+))?\}/g, (match, fieldName, format) => {
                let val = rec[fieldName];
                if (fieldName.includes('.')) {
                    const parts = fieldName.split('.');
                    let cur = rec;
                    for (let i = 0; i < parts.length && cur; i++) { cur = cur[parts[i]]; }
                    val = cur;
                }
                if (val == null) return '';
                if (format === 'currency' && typeof val === 'number') {
                    return val.toLocaleString('en-US', { style: 'currency', currency: 'USD' });
                }
                if (format === 'number' && typeof val === 'number') {
                    return val.toLocaleString();
                }
                return String(val).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
            });
            appendFn(rowXml);
        }
    }

    async _assembleGiantQueryPdf(giantRelationship, childCounts, childNodeConfig) {
        this.isLoading = true;
        this.error = null;
        try {
            const totalRecords = childCounts ? childCounts[giantRelationship] || 0 : 0;

            if (!childNodeConfig) {
                throw new Error('Child node configuration not available for ' + giantRelationship);
            }

            // 1. Launch batch
            this.showProgressBar = true;
            this.progressPercent = 0;
            this.loadingMessage = 'Starting PDF generation...';
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            const giantResult = await launchGiantQueryPdfBatch({
                templateId: this.selectedTemplateId,
                recordId: this.recordId,
                giantRelationship,
                childNodeConfigJson: JSON.stringify(childNodeConfig)
            });
            if (!giantResult.isGiantQuery || !giantResult.jobId) {
                throw new Error('Giant Query batch failed to launch.');
            }
            const jobId = giantResult.jobId;

            // 2. Poll until completed — server assembles the final PDF in finish()
            this.loadingMessage = `Processing ${totalRecords.toLocaleString()} records... Do not leave this page.`;
            let status = 'Harvesting';
            while (status !== 'Completed' && status !== 'Failed') {
                // eslint-disable-next-line no-await-in-loop
                await new Promise(resolve => { setTimeout(resolve, 3000); }); // NOSONAR — intentional poll delay
                // eslint-disable-next-line no-await-in-loop
                const jobStatus = await getGiantQueryJobStatus({ jobId });
                status = jobStatus.status;
                if (status === 'Failed') {
                    throw new Error('PDF generation failed: ' + (jobStatus.label || 'Unknown error'));
                }
                const done = jobStatus.successCount || 0;
                const total = jobStatus.totalRecords || 0;
                if (total > 0) {
                    const totalBatches = Math.ceil(total / 50);
                    this.progressPercent = Math.min(95, Math.round((done / totalBatches) * 95));
                    this.loadingMessage = `Generating PDF (batch ${done}/${totalBatches})... Do not leave this page.`;
                }
            }

            // 3. Fetch result — single part is saved to record, multiple parts need client merge
            this.progressPercent = 97;
            this.loadingMessage = 'Finalizing PDF... Do not leave this page.';
            const fragResult = await getGiantQueryFragments({ jobId });
            const finalCvId = fragResult.finalPdfCvId;
            const partIds = fragResult.partPdfCvIds || [];

            if (finalCvId) {
                // Single PDF — already saved to record
                this.progressPercent = 100;
                this.showToast('Success', `PDF saved to record — ${totalRecords.toLocaleString()} ${giantRelationship} rows.`, 'success');
            } else if (partIds.length > 0) {
                // Multiple parts — fetch and merge client-side
                const pdfParts = [];
                for (let i = 0; i < partIds.length; i++) {
                    this.loadingMessage = `Merging PDF parts (${i + 1}/${partIds.length})... Do not leave this page.`;
                    // eslint-disable-next-line no-await-in-loop
                    const partB64 = await getContentVersionBase64({ contentVersionId: partIds[i] });
                    if (partB64) { pdfParts.push(this._base64ToUint8Array(partB64)); }
                }
                this.loadingMessage = 'Assembling final PDF...';
                const mergedPdf = mergePdfs(pdfParts);
                const mergedBase64 = this._uint8ArrayToBase64(mergedPdf);
                const fileSizeMB = (mergedBase64.length * 0.75 / 1048576).toFixed(1);
                this.downloadBase64(mergedBase64, 'Document.pdf', 'application/pdf');
                this.progressPercent = 100;
                this.showToast('Success', `PDF downloaded (${fileSizeMB}MB) — ${totalRecords.toLocaleString()} ${giantRelationship} rows.`, 'success');
                // Clean up parts
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
                try { await cleanupGiantQueryFragments({ jobId }); } catch (cleanupErr) { console.warn('Cleanup:', cleanupErr); }
            } else {
                throw new Error('PDF generation completed but no output found.');
            }
        } catch (e) {
            this.error = 'Giant Query PDF Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
            this.loadingMessage = '';
            this.isGiantQueryMode = false;
            this.showProgressBar = false;
            this.progressPercent = 0;
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

    /**
     * Updates the wp:extent values in document.xml for an image whose native
     * dimensions weren't known at server-merge time. Only applies when the
     * server didn't mark the drawing with descr="DOCGEN_EXPLICIT_SIZE" — i.e.
     * the user didn't set width/height in the rich text. We derive the relId
     * from the rels XML by media filename, then find the matching <a:blip
     * r:embed="..."/> in document.xml and rewrite its enclosing <wp:extent>
     * (and the inner <a:ext> on <pic:spPr>) to native pixel dimensions in EMU.
     */
    _updateDocxImageSizeIfNotExplicit(parts, mediaPath, widthPx, heightPx) {
        if (!parts || !parts.allXmlParts) return;
        const docXml = parts.allXmlParts['word/document.xml'];
        const relsXml = parts.allXmlParts['word/_rels/document.xml.rels'];
        if (!docXml || !relsXml) return;

        // mediaPath like "word/media/docgen_image_1.png" → look up rels Target
        const targetName = mediaPath.replace(/^word\//, ''); // "media/docgen_image_1.png"
        const relMatch = relsXml.match(new RegExp('<Relationship\\s+Id="([^"]+)"[^>]*?Target="' + targetName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '"', 'i'));
        if (!relMatch) return;
        const relId = relMatch[1];

        // Find <a:blip r:embed="relId"/> in doc XML, then walk back to enclosing <w:drawing>
        const blipIdx = docXml.indexOf('r:embed="' + relId + '"');
        if (blipIdx === -1) return;
        const drawStart = docXml.lastIndexOf('<w:drawing', blipIdx);
        const drawEnd = docXml.indexOf('</w:drawing>', blipIdx);
        if (drawStart === -1 || drawEnd === -1) return;

        const drawingXml = docXml.substring(drawStart, drawEnd + '</w:drawing>'.length);
        // If server marked this as explicit-size, leave it alone
        if (drawingXml.indexOf('DOCGEN_EXPLICIT_SIZE') !== -1) return;

        const cxEmu = widthPx * 9525;
        const cyEmu = heightPx * 9525;
        let updated = drawingXml.replace(
            /<wp:extent\s+cx="\d+"\s+cy="\d+"\s*\/>/,
            '<wp:extent cx="' + cxEmu + '" cy="' + cyEmu + '"/>'
        );
        updated = updated.replace(
            /<a:ext\s+cx="\d+"\s+cy="\d+"\s*\/>/,
            '<a:ext cx="' + cxEmu + '" cy="' + cyEmu + '"/>'
        );
        if (updated !== drawingXml) {
            parts.allXmlParts['word/document.xml'] =
                docXml.substring(0, drawStart) + updated + docXml.substring(drawEnd + '</w:drawing>'.length);
        }
    }

    downloadBase64(base64Data, fileName, mimeType) {
        downloadBase64Util(base64Data, fileName, mimeType);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
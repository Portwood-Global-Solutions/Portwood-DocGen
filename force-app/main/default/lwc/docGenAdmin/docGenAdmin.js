import { LightningElement, track, wire } from 'lwc';
import { createRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { downloadBase64 as downloadBase64Util, parseSOQLFields, stripOuterSelectFrom } from 'c/docGenUtils';

// Apex
import getAllTemplates from '@salesforce/apex/DocGenController.getAllTemplates';
import deleteTemplate from '@salesforce/apex/DocGenController.deleteTemplate';
import saveTemplate from '@salesforce/apex/DocGenController.saveTemplate';
import getTemplateVersions from '@salesforce/apex/DocGenController.getTemplateVersions';
import processAndReturnDocument from '@salesforce/apex/DocGenController.processAndReturnDocument';
import generatePdf from '@salesforce/apex/DocGenController.generatePdf';
import activateVersion from '@salesforce/apex/DocGenController.activateVersion';
import createSampleTemplates from '@salesforce/apex/DocGenController.createSampleTemplates';
import exportTemplate from '@salesforce/apex/DocGenController.exportTemplate';
import importTemplate from '@salesforce/apex/DocGenController.importTemplate';
import getObjectFields from '@salesforce/apex/DocGenController.getObjectFields';
import getObjectOptions from '@salesforce/apex/DocGenController.getObjectOptions';
import getChildRelationships from '@salesforce/apex/DocGenController.getChildRelationships';
import getParentRelationships from '@salesforce/apex/DocGenController.getParentRelationships';
import previewRecordData from '@salesforce/apex/DocGenController.previewRecordData';

// Schema
import DOCGEN_TEMPLATE_OBJECT from '@salesforce/schema/DocGen_Template__c';
import NAME_FIELD from '@salesforce/schema/DocGen_Template__c.Name';
import CATEGORY_FIELD from '@salesforce/schema/DocGen_Template__c.Category__c';
import TYPE_FIELD from '@salesforce/schema/DocGen_Template__c.Type__c';
import BASE_OBJECT_FIELD from '@salesforce/schema/DocGen_Template__c.Base_Object_API__c';
import QUERY_CONFIG_FIELD from '@salesforce/schema/DocGen_Template__c.Query_Config__c';
import DESC_FIELD from '@salesforce/schema/DocGen_Template__c.Description__c';
import OUTPUT_FORMAT_FIELD from '@salesforce/schema/DocGen_Template__c.Output_Format__c';
import TEST_RECORD_FIELD from '@salesforce/schema/DocGen_Template__c.Test_Record_Id__c';
import DOC_TITLE_FIELD from '@salesforce/schema/DocGen_Template__c.Document_Title_Format__c';
import IS_DEFAULT_FIELD from '@salesforce/schema/DocGen_Template__c.Is_Default__c';
// 1.47 — runner visibility & sort
import SORT_ORDER_FIELD from '@salesforce/schema/DocGen_Template__c.Sort_Order__c';
import LOCK_OUTPUT_FORMAT_FIELD from '@salesforce/schema/DocGen_Template__c.Lock_Output_Format__c';
import SPECIFIC_RECORD_IDS_FIELD from '@salesforce/schema/DocGen_Template__c.Specific_Record_Ids__c';
import REQUIRED_PERM_SETS_FIELD from '@salesforce/schema/DocGen_Template__c.Required_Permission_Sets__c';
import RECORD_FILTER_FIELD from '@salesforce/schema/DocGen_Template__c.Record_Filter__c';
import testRecordFilter from '@salesforce/apex/DocGenController.testRecordFilter';
// Version fields (DocGen_Template_Version__c)
import VER_IS_ACTIVE_FIELD from '@salesforce/schema/DocGen_Template_Version__c.Is_Active__c';
import VER_CV_ID_FIELD from '@salesforce/schema/DocGen_Template_Version__c.Content_Version_Id__c';

// Field API name map — resolves namespace automatically
const F = {
    Name: 'Name',
    Category: CATEGORY_FIELD.fieldApiName,
    Type: TYPE_FIELD.fieldApiName,
    OutputFormat: OUTPUT_FORMAT_FIELD.fieldApiName,
    BaseObject: BASE_OBJECT_FIELD.fieldApiName,
    QueryConfig: QUERY_CONFIG_FIELD.fieldApiName,
    Desc: DESC_FIELD.fieldApiName,
    TestRecordId: TEST_RECORD_FIELD.fieldApiName,
    DocTitleFormat: DOC_TITLE_FIELD.fieldApiName,
    IsDefault: IS_DEFAULT_FIELD.fieldApiName,
    // 1.47 — runner visibility & sort
    SortOrder: SORT_ORDER_FIELD.fieldApiName,
    LockOutputFormat: LOCK_OUTPUT_FORMAT_FIELD.fieldApiName,
    SpecificRecordIds: SPECIFIC_RECORD_IDS_FIELD.fieldApiName,
    RequiredPermSets: REQUIRED_PERM_SETS_FIELD.fieldApiName,
    RecordFilter: RECORD_FILTER_FIELD.fieldApiName,
    // Version fields
    VerIsActive: VER_IS_ACTIVE_FIELD.fieldApiName,
    VerCvId: VER_CV_ID_FIELD.fieldApiName
};

const COLUMNS = [
    { label: 'Category', fieldName: F.Category, initialWidth: 150 },
    { label: 'Name', fieldName: 'Name' },
    { label: 'Type', fieldName: F.Type, initialWidth: 100 },
    { label: 'Output Format', fieldName: F.OutputFormat, initialWidth: 120 },
    { label: 'Base Object', fieldName: F.BaseObject },
    { label: 'Default', fieldName: 'defaultLabel', initialWidth: 80, cellAttributes: { class: { fieldName: 'defaultClass' } } },
    { label: 'Description', fieldName: F.Desc },
    { type: 'action', typeAttributes: { rowActions: [
        { label: 'View', name: 'view' },
        { label: 'Edit', name: 'edit' },
        { label: 'Export', name: 'export' },
        { label: 'Delete', name: 'delete' }
    ] } }
];

const VERSION_COLUMNS = [
    { label: 'Ver', fieldName: 'VersionNumber', initialWidth: 70 },
    { label: 'Active', fieldName: 'isActiveLabel', initialWidth: 70, cellAttributes: {
        class: { fieldName: 'activeClass' }
    }},
    { label: 'Created Date', fieldName: 'CreatedDate', type: 'date', typeAttributes: {
        year: 'numeric', month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit'
    }},
    { label: 'Created By', fieldName: 'CreatedByName' },
    { type: 'button', initialWidth: 100, typeAttributes: {
        label: 'Preview', name: 'preview', variant: 'neutral', iconName: 'utility:preview'
    }},
    { type: 'button', typeAttributes: {
        label: 'Activate', name: 'restore', title: 'Restore and Activate this version', variant: 'brand',
        disabled: { fieldName: 'Is_Active__c' }
    }}
];

    export default class DocGenAdmin extends NavigationMixin(LightningElement) {
    @track templates = [];
    columns = COLUMNS;
    versionColumns = VERSION_COLUMNS;
    wiredTemplatesResult;

    @track versions = [];

    // Form/Wizard State
    @track activeMainTab = 'new_template';
    @track currentWizardStep = '1';

    // Create State
    newTemplateName = '';
    newTemplateCategory = '';
    @track newTemplateType = 'Word';
    @track newTemplateOutputFormat = 'PDF';
    newTemplateObject = 'Account';
    newTemplateDesc = '';
    newTemplateQuery = '';
    @track newTemplateSampleRecordId = '';
    @track sampleRecordData = null;
    isCreating = true;
    createdTemplateId;

    // Edit State
    @track isEditModalOpen = false;
    @track activeEditTab = 'details';
    editTemplateId;
    editTemplateName;
    editTemplateCategory;
    @track editTemplateType;
    editTemplateObject;
    @track editTemplateOutputFormat;
    editTemplateDesc;
    @track editTemplateQuery;
    editTemplateTestRecordId;
    editTemplateTitleFormat;
    editTemplateIsDefault = false;
    // 1.47 — runner visibility & sort
    editTemplateSortOrder;
    editTemplateLockOutputFormat = false;
    editTemplateSpecificRecordIds;
    editTemplateRequiredPermissionSets;
    editTemplateRecordFilter;
    @track editTemplateRecordFilterResult = '';
    @track editTemplateRecordFilterResultMessage = '';
    @track editTemplateRecordFilterTesting = false;

    @track currentFileId;
    @track uploadedFileName = '';
    @track uploadedContentVersionId;

    // Preview/Restore State
    @track isPreviewModalOpen = false;
    @track previewVersion = {};
    isLoadingVersions = false;

    // Visual builder toggle (wizard + edit modal)
    @track useVisualBuilder = false;
    @track editUseVisualBuilder = false;

    // Edit modal manual query toggle (for backward compat with existing V3 configs)
    @track isManualQuery = false;
    // Context flag: true when editing in modal, false when in wizard
    _editContext = false;

    get _activeQuery() { return this._editContext ? this.editTemplateQuery : this.newTemplateQuery; }
    set _activeQuery(v) { if (this._editContext) { this.editTemplateQuery = v; } else { this.newTemplateQuery = v; } }
    get _activeObject() { return this._editContext ? this.editTemplateObject : this.newTemplateObject; }
    get _activeSampleId() { return this._editContext ? this.editTemplateTestRecordId : this.newTemplateSampleRecordId; }
    // Builder 2.0 state
    @track objectOptions = [];
    @track filteredObjectOptions = [];
    @track showObjectSuggestions = false;
    @track queryTreeNodes = [];
    @track queryWarnings = null;
    @track builderTab = 'fields';
    @track builderSearchTerm = '';
    @track _allFields = [];
    @track _allChildren = [];
    @track _allParents = [];

    get builderFieldsTabClass() { return this.builderTab === 'fields' ? 'builder-tab-active' : ''; }
    get builderRelatedTabClass() { return this.builderTab === 'related' ? 'builder-tab-active' : ''; }
    get builderParentsTabClass() { return this.builderTab === 'parents' ? 'builder-tab-active' : ''; }
    get builderPanelItems() {
        const s = (this.builderSearchTerm || '').toLowerCase();
        if (this.builderTab === 'fields') {
            return (this._allFields || [])
                .filter(f => !s || f.label.toLowerCase().includes(s) || f.value.toLowerCase().includes(s))
                .slice(0, 150)
                .map(f => ({ value: f.value, label: f.label, extra: f.type || '' }));
        } else if (this.builderTab === 'related') {
            return (this._allChildren || [])
                .filter(c => !s || c.label.toLowerCase().includes(s) || c.value.toLowerCase().includes(s))
                .slice(0, 80)
                .map(c => ({ value: c.value, label: c.label, extra: c.childObjectApiName || '' }));
        } else if (this.builderTab === 'parents') {
            return (this._allParents || [])
                .filter(p => !s || p.label.toLowerCase().includes(s) || p.value.toLowerCase().includes(s))
                .slice(0, 80)
                .map(p => ({ value: p.value, label: p.label, extra: p.targetObject || '' }));
        }
        return [];
    }

    handleBuilderTabClick(event) {
        this.builderTab = event.currentTarget.dataset.tab;
        this.builderSearchTerm = '';
    }

    handleBuilderSearch(event) {
        this.builderSearchTerm = event.target.value;
    }

    handleBuilderItemClick(event) {
        const val = event.currentTarget.dataset.value;
        const q = (this.newTemplateQuery || '').trim();
        const sep = q && !q.endsWith(',') ? ', ' : '';

        let insert = '';
        if (this.builderTab === 'fields') {
            insert = sep + val;
        } else if (this.builderTab === 'related') {
            insert = (q ? ',\n' : '') + '(SELECT Id FROM ' + val + ')';
        } else if (this.builderTab === 'parents') {
            insert = sep + val + '.Name';
        }

        this.newTemplateQuery = q + insert;
        this._updateQueryTree();
    }

    @track suggestions = [];
    @track showSuggestions = false;

    handleDirectQueryEdit(event) {
        this.newTemplateQuery = event.target.value;
        this._updateQueryTree();
        this._updateSuggestions(event.target);
        // Debounced sample data refresh
        clearTimeout(this._sampleDebounce);
        this._sampleDebounce = setTimeout(() => { this._loadSampleData(); }, 800);
    }

    _findUnmatchedParen(str) {
        let depth = 0;
        for (let i = str.length - 1; i >= 0; i--) {
            if (str[i] === ')') depth++;
            if (str[i] === '(') { if (depth === 0) return i; depth--; }
        }
        return -1;
    }

    _getToken(before) {
        // Token = text after the last comma, open-paren, or newline
        let sepIdx = -1;
        for (let i = before.length - 1; i >= 0; i--) {
            const ch = before[i];
            if (ch === ',' || ch === '(' || ch === '\n') { sepIdx = i; break; }
        }
        return { token: before.substring(sepIdx + 1).trim(), sepChar: sepIdx >= 0 ? before[sepIdx] : '', start: sepIdx + 1 };
    }

    _updateSuggestions(textarea) {
        const text = textarea.value;
        const cursor = textarea.selectionStart || text.length;
        const before = text.substring(0, cursor);
        this._suggestCursor = cursor;

        const { token, sepChar, start } = this._getToken(before);
        this._tokenReplaceStart = start;

        // Skip SOQL keywords
        const upper = token.toUpperCase();
        if (['SELECT', 'FROM', 'WHERE', 'AND', 'OR', 'ORDER', 'BY', 'LIMIT', 'ASC', 'DESC', 'LIKE', 'IN', 'NOT', 'NULL', '=', '!=', '>', '<', '>=', '<='].includes(upper)) {
            this.showSuggestions = false;
            return;
        }

        // 1) Just typed "(" — show child relationships
        if (sepChar === '(' && token === '') {
            this._suggestMode = 'related-scaffold';
            this.suggestions = (this._allChildren || []).slice(0, 15)
                .map(c => ({ value: c.value, label: c.label, extra: c.childObjectApiName || '' }));
            this.showSuggestions = this.suggestions.length > 0;
            return;
        }

        // 2) Are we inside an unmatched paren? (subquery context)
        const parenIdx = this._findUnmatchedParen(before);
        if (parenIdx !== -1) {
            const insideParen = before.substring(parenIdx + 1).trim();
            const upperInside = insideParen.toUpperCase();

            // 2a) After FROM with no space after relationship name yet — suggest child relationships
            const fromAtEnd = upperInside.match(/FROM\s*(\S*)$/);
            if (fromAtEnd) {
                this._suggestMode = 'related';
                const s = (fromAtEnd[1] || '').toLowerCase();
                this.suggestions = (this._allChildren || [])
                    .filter(c => !s || c.value.toLowerCase().includes(s) || c.label.toLowerCase().includes(s))
                    .slice(0, 15)
                    .map(c => ({ value: c.value, label: c.label, extra: c.childObjectApiName || '' }));
                this.showSuggestions = this.suggestions.length > 0;
                return;
            }

            // 2b) We know the FROM object — suggest that child object's fields
            const fromMatch = insideParen.match(/FROM\s+(\w+)/i);
            if (fromMatch && token.length >= 1) {
                const relName = fromMatch[1];
                const childRel = (this._allChildren || []).find(c => c.value.toLowerCase() === relName.toLowerCase());
                if (childRel) {
                    this._suggestMode = 'child-field';
                    const cacheKey = '_cache_' + childRel.childObjectApiName;
                    const s = token.toLowerCase();
                    if (this[cacheKey]) {
                        this._showSimpleSuggestions(this[cacheKey], s);
                    } else {
                        getObjectFields({ objectName: childRel.childObjectApiName }).then(data => {
                            this[cacheKey] = data || [];
                            this._showSimpleSuggestions(data || [], s);
                        }).catch(() => { this.showSuggestions = false; });
                    }
                    return;
                }
            }

            // 2c) Inside paren but no FROM yet and token has text — could be typing SELECT fields or relationship name
            if (token.length >= 1 && !upperInside.includes('FROM')) {
                this._suggestMode = 'related';
                const s = token.toLowerCase();
                this.suggestions = (this._allChildren || [])
                    .filter(c => c.value.toLowerCase().includes(s) || c.label.toLowerCase().includes(s))
                    .slice(0, 15)
                    .map(c => ({ value: c.value, label: c.label, extra: c.childObjectApiName || '' }));
                this.showSuggestions = this.suggestions.length > 0;
                return;
            }
        }

        // 3) After a dot — parent field lookup
        if (token.includes('.')) {
            const dot = token.lastIndexOf('.');
            const parentName = token.substring(0, dot);
            const fieldSearch = token.substring(dot + 1).toLowerCase();
            const parentRel = (this._allParents || []).find(p => p.value.toLowerCase() === parentName.toLowerCase());
            if (parentRel) {
                this._suggestMode = 'parent-field';
                this._suggestParent = parentName;
                const cacheKey = '_cache_' + parentRel.targetObject;
                if (this[cacheKey]) {
                    this._showParentFieldSuggestions(this[cacheKey], fieldSearch, parentName);
                } else {
                    getObjectFields({ objectName: parentRel.targetObject }).then(data => {
                        this[cacheKey] = data || [];
                        this._showParentFieldSuggestions(data || [], fieldSearch, parentName);
                    }).catch(() => { this.showSuggestions = false; });
                }
                return;
            }
        }

        // 4) Default — base object fields + parent relationship names
        if (token.length >= 1) {
            this._suggestMode = 'field';
            const s = token.toLowerCase();
            const fieldResults = (this._allFields || [])
                .filter(f => f.value.toLowerCase().includes(s) || f.label.toLowerCase().includes(s))
                .slice(0, 8)
                .map(f => ({ value: f.value, label: f.label, extra: f.type || '' }));
            const parentResults = (this._allParents || [])
                .filter(p => p.value.toLowerCase().includes(s) || p.label.toLowerCase().includes(s))
                .slice(0, 4)
                .map(p => ({ value: p.value + '.', label: p.label, extra: '→ ' + (p.targetObject || '') }));
            this.suggestions = [...fieldResults, ...parentResults];
            this.showSuggestions = this.suggestions.length > 0;
        } else {
            this.showSuggestions = false;
        }
    }

    _showSimpleSuggestions(fields, search) {
        this.suggestions = (fields || [])
            .filter(f => !search || f.value.toLowerCase().includes(search) || f.label.toLowerCase().includes(search))
            .slice(0, 10)
            .map(f => ({ value: f.value, label: f.label, extra: f.type || '' }));
        this.showSuggestions = this.suggestions.length > 0;
    }

    _showParentFieldSuggestions(fields, search, parentName) {
        this.suggestions = (fields || [])
            .filter(f => !search || f.value.toLowerCase().includes(search) || f.label.toLowerCase().includes(search))
            .slice(0, 10)
            .map(f => ({ value: parentName + '.' + f.value, label: f.label, extra: f.type || '' }));
        this.showSuggestions = this.suggestions.length > 0;
    }

    handleSuggestionClick(event) {
        const val = event.currentTarget.dataset.value;
        const text = this._activeQuery || '';
        const cursor = this._suggestCursor || text.length;

        // Find the token boundaries fresh — don't rely on cached values
        const before = text.substring(0, cursor);
        let sepIdx = -1;
        for (let i = before.length - 1; i >= 0; i--) {
            const ch = before[i];
            if (ch === ',' || ch === '(' || ch === '\n') { sepIdx = i; break; }
        }
        // prefix = everything up to and including the separator
        // after = everything after cursor
        const prefix = text.substring(0, sepIdx + 1);
        const after = text.substring(cursor);
        // Add a space after separator if needed
        const needSpace = prefix.length > 0 && !prefix.endsWith(' ') && !prefix.endsWith('(') && !prefix.endsWith('\n');

        let result;
        if (this._suggestMode === 'related-scaffold') {
            // Typed "(" — scaffold full subquery, prefix already ends with "("
            result = prefix + 'SELECT Id FROM ' + val + ')' + after;
        } else if (this._suggestMode === 'related') {
            // Replacing relationship name (after FROM)
            result = prefix + (needSpace ? ' ' : '') + val + after;
        } else if (val.endsWith('.')) {
            // Parent relationship — "Owner." — no comma, they pick a field next
            result = prefix + (needSpace ? ' ' : '') + val + after;
        } else {
            // Regular field — replace token, add trailing comma
            result = prefix + (needSpace ? ' ' : '') + val + ', ' + after;
        }

        this._activeQuery = result;
        // Native textarea doesn't re-render from tracked property after user input — set DOM directly
        const taSelector = this._editContext ? '.edit-query-textarea' : '.wizard-query-textarea';
        const ta = this.template.querySelector(taSelector);
        if (ta) { ta.value = result; }
        this.showSuggestions = false;
        this._updateQueryTree();

        // If parent with dot, re-trigger to show that parent's fields
        if (val.endsWith('.')) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                const ta = this.template.querySelector(taSelector);
                if (ta) {
                    const newPos = prefix.length + (needSpace ? 1 : 0) + val.length;
                    ta.setSelectionRange(newPos, newPos);
                    ta.focus();
                    this._updateSuggestions(ta);
                }
            }, 50);
        }
    }

    handleSuggestionMouseDown(event) {
        // Prevent textarea blur from firing before onclick
        event.preventDefault();
    }

    handleQueryKeyDown(event) {
        if (event.key === 'Escape' && this.showSuggestions) {
            this.showSuggestions = false;
            event.stopPropagation();
        }
    }

    // Filter State
    searchKey = '';

    @track isInstallingSamples = false;
    _samplesChecked = false;

    @wire(getAllTemplates)
    wiredTemplates(result) {
        this.wiredTemplatesResult = result;
        if (result.data) {
            this.templates = result.data.map(t => ({
                ...t,
                defaultLabel: t[F.IsDefault] ? '★' : '',
                defaultClass: t[F.IsDefault] ? 'slds-text-color_success slds-text-title_bold' : ''
            }));
            this._samplesChecked = true;
        } else if (result.error) {
           this.showToast('Error', 'Error loading templates', 'error');
        }
    }

    get filteredTemplates() {
        if (!this.searchKey) return this.templates;
        const lowerKey = this.searchKey.toLowerCase();
        return this.templates.filter(t =>
            (t.Name && t.Name.toLowerCase().includes(lowerKey)) ||
            (t[F.Category] && t[F.Category].toLowerCase().includes(lowerKey)) ||
            (t[F.BaseObject] && t[F.BaseObject].toLowerCase().includes(lowerKey)) ||
            (t[F.Type] && t[F.Type].toLowerCase().includes(lowerKey)) ||
            (t[F.OutputFormat] && t[F.OutputFormat].toLowerCase().includes(lowerKey)) ||
            (t[F.Desc] && t[F.Desc].toLowerCase().includes(lowerKey)) ||
            (t.Id && t.Id.toLowerCase().includes(lowerKey))
        );
    }

    handleRefresh() {
        return refreshApex(this.wiredTemplatesResult);
    }

    handleSearch(event) {
        this.searchKey = event.detail.value;
    }

    async installSampleTemplates() {
        this.isInstallingSamples = true;
        try {
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            const count = await createSampleTemplates();
            this.showToast('Welcome to DocGen!', count + ' sample templates installed. Open any template to see how merge tags work.', 'success');
            await refreshApex(this.wiredTemplatesResult);
            this.activeMainTab = 'list';
        } catch (error) {
            const msg = error.body ? error.body.message : error.message;
            this.showToast('Error', 'Failed to create sample templates: ' + msg, 'error');
        } finally {
            this.isInstallingSamples = false;
        }
    }

    // --- Wizard Logic ---

    renderedCallback() {
        // Sync native textarea DOM value with tracked property after re-render
        if (this.currentWizardStep === '2' && this.newTemplateQuery) {
            const ta = this.template.querySelector('.wizard-query-textarea');
            if (ta && ta.value !== this.newTemplateQuery) {
                ta.value = this.newTemplateQuery;
            }
        }
        if (this._editContext && this.isEditModalOpen && this.editTemplateQuery) {
            const ta = this.template.querySelector('.edit-query-textarea');
            if (ta && ta.value !== this.editTemplateQuery) {
                ta.value = this.editTemplateQuery;
            }
        }
    }

    get isStep1() { return this.currentWizardStep === '1'; }
    get isStep2() { return this.currentWizardStep === '2'; }
    get isStep3() { return this.currentWizardStep === '3'; }
    get isBackDisabled() { return this.currentWizardStep === '1'; }

    handleNextStep() {
        if (this.currentWizardStep === '1') {
            if (!this.newTemplateName || !this.newTemplateType) {
                this.showToast('Error', 'Please fill in the template name and type.', 'error');
                return;
            }
            if (!this.newTemplateObject) {
                this.showToast('Error', 'Please select a base object.', 'error');
                return;
            }
            // Load metadata for step 2 before transitioning
            this._loadObjectMetadata(this.newTemplateObject);
            this.currentWizardStep = '2';
        } else if (this.currentWizardStep === '2') {
             // Clean up trailing commas/whitespace
             let q = (this.newTemplateQuery || '').replace(/[\s,]+$/, '').replace(/^[\s,]+/, '');
             this.newTemplateQuery = q;
             const ta = this.template.querySelector('.wizard-query-textarea');
             if (ta) { ta.value = q; }

             if (!q) {
                this.showToast('Error', 'Please add at least one field to the query.', 'error');
                return;
             }
             this.currentWizardStep = '3';
        }
    }

    handlePrevStep() {
        if (this.currentWizardStep === '3') this.currentWizardStep = '2';
        else if (this.currentWizardStep === '2') this.currentWizardStep = '1';
    }

    handleWizardTabActive() {
        this.activeMainTab = 'new_template';
        this.resetForm();
    }

    handleTabActive(event) {
        this.activeMainTab = event.target.value;
    }

    // --- Create Handlers ---
    handleNameChange(event) { this.newTemplateName = event.detail.value; }
    handleCategoryChange(event) { this.newTemplateCategory = event.detail.value; }
    handleTypeChange(event) {
        this.newTemplateType = event.detail.value;
        // Excel only supports Native output — auto-switch from PDF
        if (event.detail.value === 'Excel' && this.newTemplateOutputFormat === 'PDF') {
            this.newTemplateOutputFormat = 'Native';
        }
    }
    handleOutputFormatChange(event) { this.newTemplateOutputFormat = event.detail.value; }
    handleDescChange(event) { this.newTemplateDesc = event.detail.value; }

    handleConfigChange(event) {
        this.newTemplateObject = event.detail.objectName;
        this.newTemplateQuery = event.detail.queryConfig;
        this._updateQueryTree();
    }

    toggleVisualBuilder() {
        this.useVisualBuilder = !this.useVisualBuilder;
    }

    toggleEditVisualBuilder() {
        this.editUseVisualBuilder = !this.editUseVisualBuilder;
    }

    handleEditConfigChange(event) {
        this.editTemplateObject = event.detail.objectName;
        this.editTemplateQuery = event.detail.queryConfig;
    }

    get visualBuilderToggleIcon() {
        return this.useVisualBuilder ? 'utility:edit' : 'utility:builder';
    }

    get editVisualBuilderToggleIcon() {
        return this.editUseVisualBuilder ? 'utility:edit' : 'utility:builder';
    }

    get readableQueryConfig() {
        return this._formatQueryConfig(this.newTemplateQuery);
    }

    get readableEditQueryConfig() {
        return this._formatQueryConfig(this.editTemplateQuery);
    }

    get isV3Query() {
        const q = this.newTemplateQuery;
        return q && q.trim().startsWith('{') && q.includes('"v":3');
    }

    get isEditV3Query() {
        const q = this.editTemplateQuery;
        return q && q.trim().startsWith('{') && q.includes('"v":3');
    }

    _formatQueryConfig(configStr) {
        if (!configStr) { return ''; }
        try {
            const cfg = JSON.parse(configStr);
            if (cfg.v !== 3 || !cfg.nodes) { return configStr; }

            const root = cfg.nodes.find(n => !n.parentNode);
            if (!root) { return configStr; }

            // Recursively build subqueries — supports any depth
            const buildSubqueries = (parentId) => {
                const children = cfg.nodes.filter(n => n.parentNode === parentId);
                const subs = [];
                for (const child of children) {
                    const subFields = [
                        ...(child.fields || []),
                        ...(child.parentFields || [])
                    ];
                    // Recurse: grandchildren become nested subqueries
                    const nestedSubs = buildSubqueries(child.id);
                    subFields.push(...nestedSubs);
                    if (subFields.length === 0) { subFields.push('Id'); }
                    let sq = '(SELECT ' + subFields.join(', ') + ' FROM ' + child.relationshipName;
                    if (child.where) { sq += ' WHERE ' + child.where; }
                    if (child.orderBy) { sq += ' ORDER BY ' + child.orderBy; }
                    if (child.limit) { sq += ' LIMIT ' + child.limit; }
                    sq += ')';
                    subs.push(sq);
                }
                return subs;
            };

            const parts = [
                ...(root.fields || []),
                ...(root.parentFields || []),
                ...buildSubqueries(root.id)
            ];

            return parts.join(', ');
        } catch {
            return configStr;
        }
    }

    handleNewQueryStringChange(event) {
        this.newTemplateQuery = event.detail ? event.detail.value : event.target.value;
    }

    handleSampleRecordChange(event) {
        this.newTemplateSampleRecordId = event.detail.recordId || '';
        this._loadSampleData();
    }

    _loadSampleData() {
        const recordId = this._activeSampleId;
        const objectName = this._activeObject;
        const query = this._activeQuery;
        if (!recordId || !objectName || !query) {
            this.sampleRecordData = null;
            return;
        }
        previewRecordData({
            recordId: recordId,
            baseObject: objectName,
            queryConfig: query
        }).then(data => {
            this.sampleRecordData = data;
            this._updateQueryTree();
        }).catch(() => {
            this.sampleRecordData = null;
        });
    }

    handleObjectSearchInput(event) {
        const term = (event.detail ? event.detail.value : event.target.value) || '';
        this.newTemplateObject = term;
        if (term.length >= 2) {
            if (this.objectOptions.length === 0) {
                getObjectOptions().then(data => {
                    this.objectOptions = data;
                    this._filterObjects(term);
                });
            } else {
                this._filterObjects(term);
            }
        } else {
            this.showObjectSuggestions = false;
        }
    }

    _filterObjects(term) {
        const t = term.toLowerCase();
        this.filteredObjectOptions = this.objectOptions
            .filter(o => o.label.toLowerCase().includes(t) || o.value.toLowerCase().includes(t))
            .slice(0, 12);
        this.showObjectSuggestions = this.filteredObjectOptions.length > 0;
    }

    handleObjectSuggestionClick(event) {
        const apiName = event.currentTarget.dataset.value;
        this.newTemplateObject = apiName;
        this.showObjectSuggestions = false;
        this._loadObjectMetadata(apiName);
    }

    _loadObjectMetadata(objectName) {
        // Load fields, children, and parents in parallel for slash commands
        getObjectFields({ objectName }).then(data => { this._allFields = data || []; }).catch(() => { this._allFields = []; });
        getChildRelationships({ objectName }).then(data => { this._allChildren = data || []; }).catch(() => { this._allChildren = []; });
        getParentRelationships({ objectName }).then(data => { this._allParents = data || []; }).catch(() => { this._allParents = []; });
    }


    // --- Live Query Tree ---
    _updateQueryTree() {
        const q = (this._activeQuery || '').trim();
        if (!q || !this._activeObject) { this.queryTreeNodes = []; return; }
        try {
            const nodes = [];
            const data = this.sampleRecordData || {};
            // Parse using nesting-aware SOQL parser
            const parsed = parseSOQLFields(q);
            this.queryWarnings = parsed.warnings.length > 0 ? parsed.warnings : null;
            const directFields = parsed.baseFields;
            const parentFields = parsed.parentFields;

            // Build field display with sample values
            const fieldPills = directFields.map(f => {
                const val = data[f];
                return { key: f, name: f, sample: val != null ? String(val) : '' };
            });
            const parentPills = parentFields.map(f => {
                // Resolve dot notation: "Owner.Name" → data.Owner.Name
                const parts = f.split('.');
                let val = data;
                for (const p of parts) { val = val && typeof val === 'object' ? val[p] : undefined; }
                return { key: f, name: f, sample: val != null ? String(val) : '' };
            });

            // Flatten child subqueries recursively into a single list with depth
            // so the template can render any nesting level with one for:each
            const flatChildren = [];
            const flattenChildren = (subqueries, depth) => {
                for (let i = 0; i < subqueries.length; i++) {
                    const sq = subqueries[i];
                    const directF = sq.fields.filter(f => !f.includes('.'));
                    const parentF = sq.fields.filter(f => f.includes('.'));
                    flatChildren.push({
                        id: 'child_' + flatChildren.length,
                        label: sq.relationshipName,
                        fields: directF,
                        parentFields: parentF,
                        hasParentFields: parentF.length > 0,
                        fieldCount: sq.fields.length,
                        where: sq.whereClause || '',
                        depth,
                        indentStyle: 'margin-left: ' + (depth * 20) + 'px; margin-bottom: 6px; padding: 8px 10px; background: #fff; border: 1px solid #e5e5e5; border-radius: 6px;'
                    });
                    if (sq.children && sq.children.length > 0) {
                        flattenChildren(sq.children, depth + 1);
                    }
                }
            };
            flattenChildren(parsed.subqueries, 0);

            nodes.push({
                id: 'root',
                label: this._activeObject,
                icon: 'standard:account',
                isRoot: true,
                fields: directFields,
                parentFields: parentFields,
                fieldPills: fieldPills,
                parentPills: parentPills,
                flatChildren: flatChildren,
                hasFields: fieldPills.length > 0,
                hasParentFields: parentPills.length > 0,
                hasFlatChildren: flatChildren.length > 0
            });
            this.queryTreeNodes = nodes;
        } catch (err) { // eslint-disable-line no-unused-vars
            this.queryTreeNodes = [];
        }
    }

    // --- Edit Handlers ---
    handleEditNameChange(event) { this.editTemplateName = event.detail.value; }
    handleEditCategoryChange(event) { this.editTemplateCategory = event.detail.value; }
    handleEditTypeChange(event) {
        this.editTemplateType = event.detail.value;
        if (event.detail.value === 'Excel' && this.editTemplateOutputFormat === 'PDF') {
            this.editTemplateOutputFormat = 'Native';
        }
    }
    handleEditOutputFormatChange(event) { this.editTemplateOutputFormat = event.detail.value; }
    handleEditDescChange(event) { this.editTemplateDesc = event.detail.value; }
    handleEditDefaultChange(event) { this.editTemplateIsDefault = event.target.checked; }
    // 1.47 — runner visibility & sort handlers
    handleEditSortOrderChange(event) { this.editTemplateSortOrder = event.detail.value; }
    handleEditLockOutputChange(event) { this.editTemplateLockOutputFormat = event.target.checked; }
    handleEditSpecificRecordIdsChange(event) { this.editTemplateSpecificRecordIds = event.detail.value; }
    handleEditRequiredPermSetsChange(event) { this.editTemplateRequiredPermissionSets = event.detail.value; }
    handleEditRecordFilterChange(event) {
        this.editTemplateRecordFilter = event.detail.value;
        this.editTemplateRecordFilterResult = '';
        this.editTemplateRecordFilterResultMessage = '';
    }

    async handleTestRecordFilter() {
        if (!this.editTemplateRecordFilter || !this.editTemplateTestRecordId || !this.editTemplateObject) {
            this.editTemplateRecordFilterResult = 'error';
            this.editTemplateRecordFilterResultMessage = 'Need Base Object, Sample Test Record Id (set on the template), and a Record Filter clause to test.';
            return;
        }
        this.editTemplateRecordFilterTesting = true;
        this.editTemplateRecordFilterResult = '';
        this.editTemplateRecordFilterResultMessage = '';
        try {
            const res = await testRecordFilter({
                baseObjectApiName: this.editTemplateObject,
                sampleRecordId: this.editTemplateTestRecordId,
                whereClause: this.editTemplateRecordFilter
            });
            if (res.error) {
                this.editTemplateRecordFilterResult = 'error';
                this.editTemplateRecordFilterResultMessage = res.error;
            } else if (res.matched) {
                this.editTemplateRecordFilterResult = 'matched';
                this.editTemplateRecordFilterResultMessage = '✓ Match — this template would appear for the test record.';
            } else {
                this.editTemplateRecordFilterResult = 'nomatch';
                this.editTemplateRecordFilterResultMessage = '✗ No match — the test record does not satisfy this filter.';
            }
        } catch (e) {
            this.editTemplateRecordFilterResult = 'error';
            this.editTemplateRecordFilterResultMessage = (e.body && e.body.message) ? e.body.message : e.message;
        } finally {
            this.editTemplateRecordFilterTesting = false;
        }
    }

    get recordFilterResultClass() {
        if (this.editTemplateRecordFilterResult === 'matched') return 'slds-text-color_success slds-var-m-top_x-small';
        if (this.editTemplateRecordFilterResult === 'nomatch') return 'slds-text-color_weak slds-var-m-top_x-small';
        if (this.editTemplateRecordFilterResult === 'error') return 'slds-text-color_error slds-var-m-top_x-small';
        return 'slds-hide';
    }

    handleQueryTabActive() {
        // lightning-tab lazy-renders content — sync textarea when query tab first activates
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const ta = this.template.querySelector('.edit-query-textarea');
            if (ta && this.editTemplateQuery && ta.value !== this.editTemplateQuery) {
                ta.value = this.editTemplateQuery;
            }
            this._updateQueryTree();
        }, 50);
    }

    handleManualQueryToggle(event) {
        this.isManualQuery = event.target.checked;
        // Convert V3 JSON to V1 flat string when switching to manual mode (toggle OFF)
        if (!this.isManualQuery && this.isEditV3Query) {
            const v1 = this._formatQueryConfig(this.editTemplateQuery);
            if (v1 && v1 !== this.editTemplateQuery) {
                this.editTemplateQuery = v1;
            }
        }
    }

    handleQueryStringChange(event) {
        this.editTemplateQuery = event.target.value;
    }

    handleEditDirectQueryEdit(event) {
        this.editTemplateQuery = event.target.value;
        this._updateQueryTree();
        this._updateSuggestions(event.target);
        clearTimeout(this._sampleDebounce);
        this._sampleDebounce = setTimeout(() => { this._loadSampleData(); }, 800);
    }

    handleEditConfigChange(event) {
        this.editTemplateObject = event.detail.objectName;
        this.editTemplateQuery = event.detail.queryConfig;
    }

    /**
     * Strips outer SELECT and FROM clauses from a query config string.
     * Delegates to the shared stripOuterSelectFrom utility in docGenUtils.
     */
    _sanitizeQueryConfig(queryConfig) {
        if (!queryConfig) return queryConfig;
        const cleaned = queryConfig.trim();
        if (cleaned.startsWith('{')) return cleaned;
        return stripOuterSelectFrom(cleaned);
    }

    handleEditTestRecordChange(event) {
        this.editTemplateTestRecordId = event.detail.recordId;
        this._loadSampleData();
    }

    // Generate a flat tag list from the query config for the tags view
    get editTemplateTags() {
        const qc = this.editTemplateQuery;
        if (!qc) return null;

        try {
            // Try JSON v3
            if (qc.trim().startsWith('{')) {
                const config = JSON.parse(qc);
                if (config.v >= 3 && config.nodes) {
                    const sections = [];
                    for (const node of config.nodes) {
                        const tags = [];
                        if (node.fields) {
                            for (const f of node.fields) {
                                tags.push({ code: '{' + f + '}' });
                            }
                        }
                        if (node.parentFields) {
                            for (const pf of node.parentFields) {
                                tags.push({ code: '{' + pf + '}' });
                            }
                        }
                        const isLoop = !!node.parentNode;
                        sections.push({
                            name: node.object + (isLoop ? ' (loop)' : ''),
                            isLoop,
                            loopStart: isLoop ? '{#' + node.relationshipName + '}' : '',
                            loopEnd: isLoop ? '{/' + node.relationshipName + '}' : '',
                            tags
                        });
                    }
                    return sections.length > 0 ? sections : null;
                }
            }

            // V1 / full SOQL: parse using shared nesting-aware parser
            const parsed = parseSOQLFields(qc);
            const sections = [];

            const buildTagSections = (subqueries) => {
                for (const sq of subqueries) {
                    sections.push({
                        name: sq.relationshipName,
                        isLoop: true,
                        loopStart: '{#' + sq.relationshipName + '}',
                        loopEnd: '{/' + sq.relationshipName + '}',
                        tags: sq.fields.filter(f => f).map(f => ({ code: '{' + f + '}' }))
                    });
                    if (sq.children && sq.children.length > 0) {
                        buildTagSections(sq.children);
                    }
                }
            };

            const baseFields = [...parsed.baseFields, ...parsed.parentFields];
            buildTagSections(parsed.subqueries);

            if (baseFields.length > 0) {
                sections.unshift({
                    name: this.editTemplateObject || 'Base Fields',
                    isLoop: false,
                    tags: baseFields.map(f => ({ code: '{' + f + '}' }))
                });
            }

            return sections.length > 0 ? sections : null;
        } catch {
            return null;
        }
    }

    async handleCopyEditTag(event) {
        const tag = event.currentTarget.dataset.tag;
        if (!tag) { return; }
        try {
            await this._copyToClipboard(tag);
            this.dispatchEvent(new ShowToastEvent({ title: 'Copied', message: tag, variant: 'success' }));
        } catch {
            this.dispatchEvent(new ShowToastEvent({ title: 'Copy Failed', message: 'Unable to copy to clipboard.', variant: 'error' }));
        }
    }

    // Split a string on commas, but only at parentheses depth 0
    _splitTopLevel(str) {
        const tokens = [];
        let depth = 0;
        let current = '';
        for (let i = 0; i < str.length; i++) {
            const ch = str[i];
            if (ch === '(') { depth++; current += ch; }
            else if (ch === ')') { depth--; current += ch; }
            else if (ch === ',' && depth === 0) {
                tokens.push(current.trim());
                current = '';
            } else {
                current += ch;
            }
        }
        if (current.trim()) { tokens.push(current.trim()); }
        return tokens;
    }

    _copyToClipboard(text) {
        if (navigator.clipboard && window.isSecureContext) {
            return navigator.clipboard.writeText(text);
        }
        const textArea = document.createElement('textarea');
        textArea.value = text;
        textArea.style.position = 'fixed';
        textArea.style.left = '-9999px';
        document.body.appendChild(textArea);
        textArea.focus();
        textArea.select();
        try {
            document.execCommand('copy');
        } finally {
            document.body.removeChild(textArea);
        }
        return Promise.resolve();
    }

    handleTitleFormatChange(event) {
        this.editTemplateTitleFormat = event.detail.value;
    }

    get isBuilderDisabled() {
        return this.isManualQuery;
    }

    // --- Options ---
    get typeOptions() {
        return [
            { label: 'Word', value: 'Word' },
            { label: 'PowerPoint', value: 'PowerPoint' },
            { label: 'Excel', value: 'Excel' }
        ];
    }

    get outputFormatOptions() {
        const type = this.isCreating ? this.newTemplateType : this.editTemplateType;
        if (type === 'Excel') {
            return [
                { label: 'Native (.xlsx)', value: 'Native' }
            ];
        }
        return [
            { label: type === 'PowerPoint' ? 'Native (.pptx)' : 'Native (.docx)', value: 'Native' },
            { label: 'PDF', value: 'PDF' }
        ];
    }

    get acceptedFormats() {
        const type = this.isCreating ? this.newTemplateType : this.editTemplateType;
        if (type === 'PowerPoint') return ['.pptx'];
        if (type === 'Excel') return ['.xlsx'];
        return ['.docx'];
    }

    // --- Create Logic ---
    async createTemplate() {
        const fields = {};
        fields[NAME_FIELD.fieldApiName] = this.newTemplateName;
        fields[CATEGORY_FIELD.fieldApiName] = this.newTemplateCategory;
        fields[TYPE_FIELD.fieldApiName] = this.newTemplateType;
        fields[OUTPUT_FORMAT_FIELD.fieldApiName] = this.newTemplateOutputFormat;
        fields[BASE_OBJECT_FIELD.fieldApiName] = this.newTemplateObject;
        fields[QUERY_CONFIG_FIELD.fieldApiName] = this._sanitizeQueryConfig(this.newTemplateQuery);
        fields[DESC_FIELD.fieldApiName] = this.newTemplateDesc;
        if (this.newTemplateSampleRecordId) {
            fields[TEST_RECORD_FIELD.fieldApiName] = this.newTemplateSampleRecordId;
        }

        try {
            const record = await createRecord({ apiName: DOCGEN_TEMPLATE_OBJECT.objectApiName, fields });
            this.createdTemplateId = record.id;
            this.isCreating = false;
            this.showToast('Success', 'Template Record created. Please upload your document.', 'success');

            const newRow = {
                Id: record.id,
                Name: this.newTemplateName,
                [F.Category]: this.newTemplateCategory,
                [F.Type]: this.newTemplateType,
                [F.OutputFormat]: this.newTemplateOutputFormat,
                [F.BaseObject]: this.newTemplateObject,
                [F.Desc]: this.newTemplateDesc,
                [F.QueryConfig]: this.newTemplateQuery,
                [F.TestRecordId]: this.newTemplateSampleRecordId || null,
                [F.DocTitleFormat]: null,
                ContentDocumentLinks: []
            };

            this.resetForm();
            await refreshApex(this.wiredTemplatesResult);

            this.activeMainTab = 'list';
            this.activeEditTab = 'document';
            this.openEditModal(newRow, 'document');

        } catch (error) {
            this.showToast('Error creating record', error.body ? error.body.message : error.message, 'error');
        }
    }

    // --- Row Action ---
    async handleRowAction(event) {
        const actionName = event.detail.action.name;
        const row = event.detail.row;

        if (actionName === 'delete') {
            try {
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
                await deleteTemplate({ templateId: row.Id });
                this.showToast('Success', 'Template deleted', 'success');
                return refreshApex(this.wiredTemplatesResult);
            } catch (error) {
                this.showToast('Error deleting template', error.body ? error.body.message : error.message, 'error');
            }
        } else if (actionName === 'edit') {
            this.openEditModal(row, 'details');
        } else if (actionName === 'view') {
            this.openEditModal(row, 'tags');
        } else if (actionName === 'export') {
            this.handleExportTemplate(row);
        }
    }

    async handleExportTemplate(row) {
        try {
            this.showToast('Exporting', 'Preparing ' + row.Name + '...', 'info');
            const jsonStr = await exportTemplate({ templateId: row.Id });
            const blob = new Blob([jsonStr], { type: 'application/json' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = (row.Name || 'template').replace(/[^a-zA-Z0-9_-]/g, '_') + '.docgen.json';
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
            this.showToast('Exported', row.Name + ' exported successfully', 'success');
        } catch (error) {
            this.showToast('Export Error', error.body ? error.body.message : error.message, 'error');
        }
    }

    handleImportClick() {
        this.template.querySelector('input[data-id="importFileInput"]').click();
    }

    async handleImportFile(event) {
        const file = event.target.files[0];
        if (!file) return;
        // Reset the input so the same file can be re-imported
        event.target.value = '';

        if (!file.name.endsWith('.json') && !file.name.endsWith('.docgen.json')) {
            this.showToast('Invalid File', 'Please select a .docgen.json file', 'error');
            return;
        }

        try {
            this.showToast('Importing', 'Importing ' + file.name + '...', 'info');
            const jsonStr = await file.text();
            // Basic validation
            const parsed = JSON.parse(jsonStr);
            if (!parsed.template || !parsed.docgenExportVersion) {
                this.showToast('Invalid File', 'This file is not a valid DocGen export.', 'error');
                return;
            }
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            await importTemplate({ jsonData: jsonStr });
            this.showToast('Imported', (parsed.template.Name || 'Template') + ' imported successfully', 'success');
            return refreshApex(this.wiredTemplatesResult);
        } catch (error) {
            this.showToast('Import Error', error.body ? error.body.message : error.message, 'error');
        }
    }

    // --- Edit Modal ---
    openEditModal(row, activeTab) {
        try {
            this.editTemplateId = row.Id;
            this.editTemplateName = row.Name;
            this.editTemplateCategory = row[F.Category];
            this.editTemplateType = row[F.Type];
            this.editTemplateObject = row[F.BaseObject];
            this.editTemplateOutputFormat = row[F.OutputFormat] || 'Native';
            this.editTemplateDesc = row[F.Desc];
            this.editTemplateQuery = this._formatQueryConfig(row[F.QueryConfig]);
            this.editTemplateTestRecordId = row[F.TestRecordId];
            this.editTemplateTitleFormat = row[F.DocTitleFormat];
            this.editTemplateIsDefault = row[F.IsDefault] || false;
            this.editTemplateSortOrder = row[F.SortOrder];
            this.editTemplateLockOutputFormat = row[F.LockOutputFormat] || false;
            this.editTemplateSpecificRecordIds = row[F.SpecificRecordIds];
            this.editTemplateRequiredPermissionSets = row[F.RequiredPermSets];
            this.editTemplateRecordFilter = row[F.RecordFilter];
            this.editTemplateRecordFilterResult = '';
            this.editTemplateRecordFilterResultMessage = '';

            let cdLinks = [];
            if (row.ContentDocumentLinks) {
                if (Array.isArray(row.ContentDocumentLinks)) {
                    cdLinks = row.ContentDocumentLinks;
                } else if (row.ContentDocumentLinks.records) {
                    cdLinks = row.ContentDocumentLinks.records;
                }
            }

            if (cdLinks && cdLinks.length > 0) {
                this.currentFileId = cdLinks[0].ContentDocumentId;
            } else {
                this.currentFileId = null;
            }

            if (!this.currentFileId) {
                this.activeEditTab = 'document';
            } else {
                this.activeEditTab = activeTab || 'details';
            }

            this.loadVersions(row.Id);
            this.isCreating = false;
            this.isEditModalOpen = true;
            this._editContext = true;
            this._loadObjectMetadata(this.editTemplateObject);
            // Initialize query tree + sync textarea after DOM renders
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                this._updateQueryTree();
                this._loadSampleData();
                // Native textarea doesn't reliably pick up value from LWC reactivity — set DOM directly
                const ta = this.template.querySelector('.edit-query-textarea');
                if (ta && this.editTemplateQuery) { ta.value = this.editTemplateQuery; }
            }, 300);
        } catch (e) {
            this.showToast('Error', 'Failed to open modal: ' + e.message, 'error');
        }
    }

    closeEditModal() {
        this.isEditModalOpen = false;
        this._editContext = false;
        this.queryTreeNodes = [];
        this.sampleRecordData = null;
        this.showSuggestions = false;
    }

    // --- Versions Logic ---
    get hasVersions() {
        return this.versions && this.versions.length > 0;
    }

    get currentVersionLabel() {
        if (this.hasVersions) {
            return this.versions[0].VersionNumber;
        }
        return '';
    }

    loadVersions(templateId) {
        getTemplateVersions({ templateId })
            .then(data => {
                if (!data) {
                    this.versions = [];
                    return;
                }
                const total = data.length;
                this.versions = data.map((v, index) => {
                    const isActive = v[F.VerIsActive];
                    return {
                        ...v,
                        VersionNumber: 'v' + (total - index),
                        CreatedByName: v.CreatedBy ? v.CreatedBy.Name : '',
                        isActiveLabel: isActive ? '✓' : '',
                        activeClass: isActive ? 'slds-text-color_success slds-text-title_bold' : '',
                        activateVariant: isActive ? 'neutral' : 'brand'
                    };
                });
            })
            .catch(() => {
                this.versions = [];
            });
    }

    async handleRestoreVersion(event) {
        const action = event.detail.action.name;
        const row = event.detail.row;
        if (action === 'restore') {
            try {
                this.isLoadingVersions = true;
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
                await activateVersion({ versionId: row.Id });

                this.showToast('Success', 'Version activated.', 'success');

                this.editTemplateQuery = this._formatQueryConfig(row[F.QueryConfig]);
                this.editTemplateCategory = row[F.Category];
                this.editTemplateDesc = row[F.Desc];
                this.editTemplateType = row[F.Type];

                this.loadVersions(this.editTemplateId);
                refreshApex(this.wiredTemplatesResult);
            } catch (error) {
                this.showToast('Error activating version', error.body ? error.body.message : error.message, 'error');
            } finally {
                this.isLoadingVersions = false;
            }
        } else if (action === 'preview') {
            this.handlePreviewVersion(row);
        }
    }

    handlePreviewVersion(row) {
        this.previewVersion = row;
        this.isGeneratingPreview = false;
        this.isPreviewModalOpen = true;
    }

    closePreviewModal() {
        this.isPreviewModalOpen = false;
        this.isGeneratingPreview = false;
    }

    handleRestoreFromPreview() {
        const event = {
            detail: {
                action: { name: 'restore' },
                row: this.previewVersion
            }
        };
        this.handleRestoreVersion(event);
        this.closePreviewModal();
    }

    // --- Version Preview Helpers ---

    @track isGeneratingPreview = false;

    get isPreviewVersionActive() {
        return this.previewVersion?.[F.VerIsActive] || false;
    }

    get previewVersionQueryFormatted() {
        const raw = this.previewVersion?.[F.QueryConfig];
        if (!raw) return '';
        // Format: split on commas that are NOT inside parentheses (subqueries)
        let depth = 0;
        let formatted = '';
        for (let i = 0; i < raw.length; i++) {
            const ch = raw[i];
            if (ch === '(') {
                depth++;
                formatted += '\n  (';
            } else if (ch === ')') {
                depth--;
                formatted += ')';
            } else if (ch === ',' && depth === 0) {
                formatted += ',\n';
            } else {
                formatted += ch;
            }
        }
        return formatted.trim();
    }

    get previewGenerateDisabled() {
        return !this.previewVersion?.[F.VerCvId] || !this.editTemplateTestRecordId || this.isGeneratingPreview;
    }

    handlePreviewDownload() {
        const cvId = this.previewVersion?.[F.VerCvId];
        if (cvId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__webPage',
                attributes: {
                    url: `/sfc/servlet.shepherd/version/download/${cvId}`
                }
            }, false);
        }
    }

    async handlePreviewGenerate() {
        if (!this.previewVersion?.[F.VerCvId] || !this.editTemplateTestRecordId) {
            this.showToast('Warning', 'Template file and test record are required.', 'warning');
            return;
        }

        this.isGeneratingPreview = true;

        try {
            // Activate this version first so generation uses its file and config
            if (!this.previewVersion[F.VerIsActive]) {
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
                await activateVersion({ versionId: this.previewVersion.Id });
                // Sync version config to local edit state
                this.editTemplateQuery = this._formatQueryConfig(this.previewVersion[F.QueryConfig]);
                this.editTemplateCategory = this.previewVersion[F.Category];
                this.editTemplateDesc = this.previewVersion[F.Desc];
                this.editTemplateType = this.previewVersion[F.Type];
                this.loadVersions(this.editTemplateId);
                refreshApex(this.wiredTemplatesResult);
            }

            const isPPT = ['PowerPoint', 'PPT', 'PPTX'].includes(this.previewVersion[F.Type]);

            if (isPPT || this.editTemplateOutputFormat === 'Native') {
                const result = await processAndReturnDocument({
                    templateId: this.editTemplateId,
                    recordId: this.editTemplateTestRecordId
                });
                if (!result || !result.base64) {
                    throw new Error('Document generation returned empty result.');
                }
                const docTitle = 'Preview_' + this.previewVersion.VersionNumber + '_' + (result.title || 'Document');
                const ext = isPPT ? '.pptx' : '.docx';
                this.downloadBase64(result.base64, docTitle + ext, 'application/octet-stream');
                this.showToast('Success', 'Sample document generated for ' + this.previewVersion.VersionNumber, 'success');
            } else {
                this.showToast('Info', 'Generating PDF sample for ' + this.previewVersion.VersionNumber + '...', 'info');
                const pdfResult = await generatePdf({
                    templateId: this.editTemplateId,
                    recordId: this.editTemplateTestRecordId,
                    saveToRecord: false
                });
                if (!pdfResult || !pdfResult.base64) {
                    throw new Error('PDF generation returned empty result.');
                }
                const pdfTitle = 'Preview_' + this.previewVersion.VersionNumber + '_' + (pdfResult.title || 'Document');
                this.downloadBase64(pdfResult.base64, pdfTitle + '.pdf', 'application/pdf');
                this.showToast('Success', 'PDF sample generated for ' + this.previewVersion.VersionNumber, 'success');
            }
        } catch (error) {
            let msg = 'Unknown error';
            if (error.body && error.body.message) msg = error.body.message;
            else if (error.message) msg = error.message;
            this.showToast('Generation Failed', msg, 'error');
        } finally {
            this.isGeneratingPreview = false;
        }
    }

    // --- Save Logic ---
    async handleSaveOnly() {
         if (!this.editTemplateName || !this.editTemplateType) {
            this.showToast('Error', 'Name and Type are required.', 'error');
            return;
        }

        const fields = {
            Id: this.editTemplateId,
            Name: this.editTemplateName,
            'Category__c': this.editTemplateCategory,
            'Type__c': this.editTemplateType,
            'Output_Format__c': this.editTemplateOutputFormat,
            'Base_Object_API__c': this.editTemplateObject,
            'Description__c': this.editTemplateDesc,
            'Query_Config__c': this._sanitizeQueryConfig(this.editTemplateQuery),
            'Test_Record_Id__c': this.editTemplateTestRecordId,
            'Document_Title_Format__c': this.editTemplateTitleFormat,
            'Is_Default__c': this.editTemplateIsDefault,
            'Sort_Order__c': this.editTemplateSortOrder,
            'Lock_Output_Format__c': this.editTemplateLockOutputFormat,
            'Specific_Record_Ids__c': this.editTemplateSpecificRecordIds,
            'Required_Permission_Sets__c': this.editTemplateRequiredPermissionSets,
            'Record_Filter__c': this.editTemplateRecordFilter
        };
        this.editTemplateQuery = fields['Query_Config__c'];

        try {
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            await saveTemplate({ fields: fields, createVersion: false, contentVersionId: null });
            this.showToast('Success', 'Template Details saved.', 'success');
            return refreshApex(this.wiredTemplatesResult);
        } catch (error) {
            this.showToast('Error saving template', error.body ? error.body.message : error.message, 'error');
        }
    }

    async handleSaveAndClose() {
        if (!this.editTemplateName || !this.editTemplateType) {
            this.showToast('Error', 'Name and Type are required.', 'error');
            return;
        }

        const fields = {
            Id: this.editTemplateId,
            Name: this.editTemplateName,
            'Category__c': this.editTemplateCategory,
            'Type__c': this.editTemplateType,
            'Output_Format__c': this.editTemplateOutputFormat,
            'Base_Object_API__c': this.editTemplateObject,
            'Description__c': this.editTemplateDesc,
            'Query_Config__c': this._sanitizeQueryConfig(this.editTemplateQuery),
            'Test_Record_Id__c': this.editTemplateTestRecordId,
            'Document_Title_Format__c': this.editTemplateTitleFormat,
            'Is_Default__c': this.editTemplateIsDefault,
            'Sort_Order__c': this.editTemplateSortOrder,
            'Lock_Output_Format__c': this.editTemplateLockOutputFormat,
            'Specific_Record_Ids__c': this.editTemplateSpecificRecordIds,
            'Required_Permission_Sets__c': this.editTemplateRequiredPermissionSets,
            'Record_Filter__c': this.editTemplateRecordFilter
        };
        this.editTemplateQuery = fields['Query_Config__c'];

        try {
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            await saveTemplate({ fields: fields, createVersion: true, contentVersionId: this.uploadedContentVersionId });
            this.showToast('Success', 'Template and Version saved.', 'success');
            this.closeEditModal();
            return refreshApex(this.wiredTemplatesResult);
        } catch (error) {
            this.showToast('Error saving template', error.body ? error.body.message : error.message, 'error');
        }
    }

    // --- Document Generation & Test Logic ---
    get editTemplateTestRecordIdEmpty() {
        return !this.editTemplateTestRecordId;
    }

    get isRealObject() {
        return this.editTemplateObject && this.editTemplateObject !== 'ApexProvider';
    }

    async handleTestGenerate() {
        if (!this.editTemplateTestRecordId) {
            this.showToast('Warning', 'Please select a Test Record ID first.', 'warning');
            return;
        }

        // Auto-heal sample query config
        if (this.editTemplateName === 'Sample Quote Template' && this.editTemplateQuery && !this.editTemplateQuery.toLowerCase().includes('quotelineitems')) {
            this.editTemplateQuery += ', (SELECT Product2.Name, Description, Quantity, UnitPrice, TotalPrice FROM QuoteLineItems)';
        }

        // Save first
        await this.handleSaveOnly();

        this.isLoadingVersions = true;

        try {
            const isPPT = ['PowerPoint', 'PPT', 'PPTX'].includes(this.editTemplateType);

            if (isPPT || this.editTemplateOutputFormat === 'Native') {
                // Native DOCX/PPTX download
                const result = await processAndReturnDocument({
                    templateId: this.editTemplateId,
                    recordId: this.editTemplateTestRecordId
                });

                if (!result || !result.base64) {
                    throw new Error('Document generation returned empty result.');
                }

                const docTitle = 'Sample_' + (result.title || 'Document');
                const ext = isPPT ? '.pptx' : '.docx';
                this.downloadBase64(result.base64, docTitle + ext, 'application/octet-stream');
                this.showToast('Success', 'Sample Document Downloaded', 'success');
            } else {
                // PDF generation — same path as bulk
                this.showToast('Info', 'Generating PDF Sample...', 'info');
                const pdfResult = await generatePdf({
                    templateId: this.editTemplateId,
                    recordId: this.editTemplateTestRecordId,
                    saveToRecord: false
                });

                if (!pdfResult || !pdfResult.base64) {
                    throw new Error('PDF generation returned empty result.');
                }
                const pdfTitle = 'Sample_' + (pdfResult.title || 'Document');
                this.downloadBase64(pdfResult.base64, pdfTitle + '.pdf', 'application/pdf');
                this.showToast('Success', 'PDF Sample Generated', 'success');
            }
        } catch (error) {
            let msg = 'Unknown error';
            if (error.body && error.body.message) {
                msg = error.body.message;
            } else if (error.message) {
                msg = error.message;
            }
            this.showToast('Generation Failed', 'Generation Failed. ' + msg, 'error');
        } finally {
            this.isLoadingVersions = false;
        }
    }

    /**
     * Downloads a base64-encoded file via an anchor element.
     */
    downloadBase64(base64Data, fileName, mimeType) {
        downloadBase64Util(base64Data, fileName, mimeType);
    }

    // --- File Upload ---
    handleEditUploadFinished(event) {
        const uploadedFiles = event.detail.files;
        if (uploadedFiles && uploadedFiles.length > 0) {
            const file = uploadedFiles[0];
            this.showToast('Success', 'File Uploaded: ' + file.name, 'success');
            this.currentFileId = file.documentId;
            this.uploadedContentVersionId = file.contentVersionId;
            this.uploadedFileName = file.name;
        }
    }

    downloadTemplate() {
        if (this.currentFileId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__webPage',
                attributes: {
                    url: `/sfc/servlet.shepherd/document/download/${this.currentFileId}`
                }
            }, false);
        }
    }

    resetForm() {
        this.uploadedFileName = '';
        this.uploadedContentVersionId = null;
        this.currentWizardStep = '1';
        this.newTemplateName = '';
        this.newTemplateCategory = '';
        this.newTemplateDesc = '';
        this.newTemplateQuery = '';
        this.newTemplateOutputFormat = 'PDF';
        this.newTemplateObject = 'Account';
        this.createdTemplateId = null;
        this.isCreating = true;
        this.queryTreeNodes = [];
        this.builderTab = 'fields';
        this.builderSearchTerm = '';
        this.newTemplateSampleRecordId = '';
        this.sampleRecordData = null;
        this._allFields = [];
        this._allChildren = [];
        this._allParents = [];
        return refreshApex(this.wiredTemplatesResult);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant
            })
        );
    }
}

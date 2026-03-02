import { LightningElement, track, wire } from 'lwc';
import { createRecord, updateRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { loadScript } from 'lightning/platformResourceLoader';
import { refreshApex } from '@salesforce/apex';

// Apex
import getAllTemplates from '@salesforce/apex/DocGenController.getAllTemplates';
import deleteTemplate from '@salesforce/apex/DocGenController.deleteTemplate';
import saveTemplate from '@salesforce/apex/DocGenController.saveTemplate';
import getTemplateVersions from '@salesforce/apex/DocGenController.getTemplateVersions';
import processAndReturnDocument from '@salesforce/apex/DocGenController.processAndReturnDocument';
import activateVersion from '@salesforce/apex/DocGenController.activateVersion';

// Schema
import DOCGEN_TEMPLATE_OBJECT from '@salesforce/schema/DocGen_Template__c';
import ID_FIELD from '@salesforce/schema/DocGen_Template__c.Id';
import NAME_FIELD from '@salesforce/schema/DocGen_Template__c.Name';
import CATEGORY_FIELD from '@salesforce/schema/DocGen_Template__c.Category__c';
import TYPE_FIELD from '@salesforce/schema/DocGen_Template__c.Type__c';
import BASE_OBJECT_FIELD from '@salesforce/schema/DocGen_Template__c.Base_Object_API__c';
import QUERY_CONFIG_FIELD from '@salesforce/schema/DocGen_Template__c.Query_Config__c';
import DESC_FIELD from '@salesforce/schema/DocGen_Template__c.Description__c';

// Static Resources
import FILESAVER_JS from '@salesforce/resourceUrl/filesaver';

const COLUMNS = [
    { label: 'Category', fieldName: 'Category__c', initialWidth: 150 },
    { label: 'Name', fieldName: 'Name' },
    { label: 'Type', fieldName: 'Type__c', initialWidth: 100 },
    { label: 'Output Format', fieldName: 'Output_Format__c', initialWidth: 120 },
    { label: 'Base Object', fieldName: 'Base_Object_API__c' },
    { label: 'Description', fieldName: 'Description__c' },
    { type: 'action', typeAttributes: { rowActions: [
        { label: 'View', name: 'view' },
        { label: 'Edit', name: 'edit' },
        { label: 'Share', name: 'share' },
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

    librariesLoaded = false;
    @track versions = [];

    // Form/Wizard State
    @track activeMainTab = 'list';
    @track currentWizardStep = '1';

    // Create State
    newTemplateName = '';
    newTemplateCategory = '';
    newTemplateType = 'Word';
    newTemplateOutputFormat = 'PDF';
    newTemplateObject = 'Account';
    newTemplateDesc = '';
    newTemplateQuery = '';
    isCreating = true;
    createdTemplateId;

    // Edit State
    @track isEditModalOpen = false;
    @track activeEditTab = 'details';
    editTemplateId;
    editTemplateName;
    editTemplateCategory;
    editTemplateType;
    editTemplateObject;
    editTemplateOutputFormat;
    editTemplateDesc;
    editTemplateQuery;
    editTemplateTestRecordId;
    editTemplateTitleFormat; // New Field

    @track currentFileId;
    @track uploadedFileName = '';
    
    // Preview/Restore State
    @track isPreviewModalOpen = false;
    @track previewVersion = {};
    isLoadingVersions = false;

    // Manual Query Toggle
    @track isManualQuery = false;

    // Filter State
    searchKey = '';

    @wire(getAllTemplates)
    wiredTemplates(result) {
        this.wiredTemplatesResult = result;
        if (result.data) {
            this.templates = result.data;
        } else if (result.error) {
           this.showToast('Error', 'Error loading templates', 'error');
        }
    }

    get filteredTemplates() {
        if (!this.searchKey) return this.templates;
        const lowerKey = this.searchKey.toLowerCase();
        return this.templates.filter(t =>
            (t.Name && t.Name.toLowerCase().includes(lowerKey)) ||
            (t.Category__c && t.Category__c.toLowerCase().includes(lowerKey)) ||
            (t.Base_Object_API__c && t.Base_Object_API__c.toLowerCase().includes(lowerKey)) ||
            (t.Type__c && t.Type__c.toLowerCase().includes(lowerKey)) ||
            (t.Output_Format__c && t.Output_Format__c.toLowerCase().includes(lowerKey)) ||
            (t.Description__c && t.Description__c.toLowerCase().includes(lowerKey)) ||
            (t.Id && t.Id.toLowerCase().includes(lowerKey))
        );
    }
    
    handleRefresh() {
        return refreshApex(this.wiredTemplatesResult);
    }

    handleSearch(event) {
        this.searchKey = event.detail.value;
    }

    get showInstallSample() {
        return false; // Disabled per cleanup
    }

    /*
    handleInstallSample() {
        // Removed per cleanup
    }
    */

    renderedCallback() {
        if (this.librariesLoaded) return;
        this.librariesLoaded = true;

        loadScript(this, FILESAVER_JS)
            .then(() => {
                this.librariesReady = true;
            })
            .catch(() => {
                this.showToast('Error', 'Error loading download library', 'error');
            });
    }

    // --- Wizard Logic ---

    get isStep1() { return this.currentWizardStep === '1'; }
    get isStep2() { return this.currentWizardStep === '2'; }
    get isStep3() { return this.currentWizardStep === '3'; }
    get isBackDisabled() { return this.currentWizardStep === '1'; }

    handleNextStep() {
        if (this.currentWizardStep === '1') {
            if (!this.newTemplateName || !this.newTemplateType) {
                this.showToast('Error', 'Please fill required fields.', 'error');
                return;
            }
            this.currentWizardStep = '2';
        } else if (this.currentWizardStep === '2') {
             if (!this.newTemplateObject || !this.newTemplateQuery) {
                this.showToast('Error', 'Please configure the query.', 'error');
                return;
             }
             this.currentWizardStep = '3';
        }
    }

    handlePrevStep() {
        if (this.currentWizardStep === '3') this.currentWizardStep = '2';
        else if (this.currentWizardStep === '2') this.currentWizardStep = '1';
    }

    handleWizardTabActive(event) {
        this.activeMainTab = 'new_template';
        this.resetForm();
    }

    handleTabActive(event) {
        this.activeMainTab = event.target.value;
    }

    // --- Create Handlers ---
    handleNameChange(event) { this.newTemplateName = event.detail.value; }
    handleCategoryChange(event) { this.newTemplateCategory = event.detail.value; }
    handleTypeChange(event) { this.newTemplateType = event.detail.value; }
    handleOutputFormatChange(event) { this.newTemplateOutputFormat = event.detail.value; }
    handleDescChange(event) { this.newTemplateDesc = event.detail.value; }
    
    handleConfigChange(event) {
        this.newTemplateObject = event.detail.objectName;
        this.newTemplateQuery = event.detail.queryConfig;
    }
    
    // --- Edit Handlers ---
    handleEditNameChange(event) { this.editTemplateName = event.detail.value; }
    handleEditCategoryChange(event) { this.editTemplateCategory = event.detail.value; }
    handleEditTypeChange(event) { this.editTemplateType = event.detail.value; }
    handleEditOutputFormatChange(event) { this.editTemplateOutputFormat = event.detail.value; }
    handleEditDescChange(event) { this.editTemplateDesc = event.detail.value; }
    
    handleManualQueryToggle(event) {
        this.isManualQuery = event.target.checked;
    }
    
    handleQueryStringChange(event) {
        this.editTemplateQuery = event.target.value;
    }

    handleEditConfigChange(event) {
        this.editTemplateObject = event.detail.objectName;
        this.editTemplateQuery = event.detail.queryConfig;
    }
    
    handleEditTestRecordChange(event) { 
        this.editTemplateTestRecordId = event.detail.recordId; 
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
            { label: 'PowerPoint', value: 'PowerPoint' }
        ];
    }
    
    get outputFormatOptions() {
        return [
            { label: 'Native (.docx / .pptx)', value: 'Native' },
            { label: 'PDF', value: 'PDF' }
        ];
    }
    
    get acceptedFormats() {
        return this.editTemplateType === 'PowerPoint' ? ['.pptx'] : ['.docx'];
    }

    // --- Create Logic ---
    async createTemplate() {
        const fields = {};
        fields[NAME_FIELD.fieldApiName] = this.newTemplateName;
        fields[CATEGORY_FIELD.fieldApiName] = this.newTemplateCategory;
        fields[TYPE_FIELD.fieldApiName] = this.newTemplateType;
        fields['Output_Format__c'] = this.newTemplateOutputFormat;
        fields[BASE_OBJECT_FIELD.fieldApiName] = this.newTemplateObject;
        fields[QUERY_CONFIG_FIELD.fieldApiName] = this.newTemplateQuery;
        fields[DESC_FIELD.fieldApiName] = this.newTemplateDesc;

        try {
            const record = await createRecord({ apiName: DOCGEN_TEMPLATE_OBJECT.objectApiName, fields });
            this.createdTemplateId = record.id;
            this.isCreating = false;
            this.showToast('Success', 'Template Record created. Please upload your document.', 'success');
            
            // Construct row object for edit modal
            const newRow = {
                Id: record.id,
                Name: this.newTemplateName,
                Category__c: this.newTemplateCategory,
                Type__c: this.newTemplateType,
                Base_Object_API__c: this.newTemplateObject,
                Description__c: this.newTemplateDesc,
                Query_Config__c: this.newTemplateQuery,
                Test_Record_Id__c: null,
                Document_Title_Format__c: null,
                ContentDocumentLinks: []
            };

            this.resetForm();
            await refreshApex(this.wiredTemplatesResult);
            
            // Switch to List Tab and Open Modal
            this.activeMainTab = 'list';
            this.activeEditTab = 'document'; // Explicitly go to document upload for new templates
            this.openEditModal(newRow, 'document');  
            
        } catch (error) {
            this.showToast('Error creating record', error.body ? error.body.message : error.message, 'error');
        }
    }

    // --- Sharing Logic ---
    @track isSharingModalOpen = false;
    sharingTemplateId;

    handleCloseSharing() {
        this.isSharingModalOpen = false;
    }

    // --- Row Action ---
    async handleRowAction(event) {
        // Row action handler
        const actionName = event.detail.action.name;
        const row = event.detail.row;
        
        if (actionName === 'delete') {
            try {
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
        } else if (actionName === 'share') {
            this.sharingTemplateId = row.Id;
            this.isSharingModalOpen = true;
        }
    }

    // --- Edit Modal ---
    openEditModal(row, activeTab) {
        try {
            this.editTemplateId = row.Id;
            this.editTemplateName = row.Name;
            this.editTemplateCategory = row.Category__c;
            this.editTemplateType = row.Type__c;
            this.editTemplateObject = row.Base_Object_API__c;
            this.editTemplateOutputFormat = row.Output_Format__c || 'Native';
            this.editTemplateDesc = row.Description__c;
            this.editTemplateQuery = row.Query_Config__c;
            this.editTemplateTestRecordId = row.Test_Record_Id__c; 
            this.editTemplateTitleFormat = row.Document_Title_Format__c; 
            
            // Extract ContentDocumentId safely
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
            
            // Default to "Document & History" if no file exists to prompt upload
            if (!this.currentFileId) {
                this.activeEditTab = 'document';
            } else {
                this.activeEditTab = activeTab || 'details';
            }
            
            this.loadVersions(row.Id);
            this.isCreating = false;
            this.isEditModalOpen = true;
        } catch (e) {
            this.showToast('Error', 'Failed to open modal: ' + e.message, 'error');
        }
    }

    closeEditModal() {
        this.isEditModalOpen = false;
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
                    const isActive = v.Is_Active__c;
                    return {
                        ...v,
                        VersionNumber: 'v' + (total - index),
                        CreatedByName: v.CreatedBy ? v.CreatedBy.Name : '',
                        isActiveLabel: isActive ? '✓' : '',
                        activeClass: isActive ? 'slds-text-color_success slds-text-title_bold' : '',
                        activateVariant: isActive ? 'neutral' : 'brand' // Brand (Blue) for Inactive, Neutral for Active
                    };
                });
            })
            .catch(error => {
                this.versions = [];
            });
    }

    async handleRestoreVersion(event) {
        const action = event.detail.action.name;
        const row = event.detail.row;
        if (action === 'restore') {
            try {
                this.isLoadingVersions = true;
                await activateVersion({ versionId: row.Id });
                
                this.showToast('Success', 'Version activated.', 'success');
                
                // Update local state to match restored version
                this.editTemplateQuery = row.Query_Config__c;
                this.editTemplateCategory = row.Category__c;
                this.editTemplateDesc = row.Description__c;
                this.editTemplateType = row.Type__c;
                
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
        this.isPreviewModalOpen = true;
    }

    closePreviewModal() {
        this.isPreviewModalOpen = false;
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

    // --- Save Logic ---
    async handleSaveOnly() {
         // Validate
         if (!this.editTemplateName || !this.editTemplateType) {
            this.showToast('Error', 'Name and Type are required.', 'error');
            return;
        }

        const fields = {
            Id: this.editTemplateId,
            Name: this.editTemplateName,
            Category__c: this.editTemplateCategory,
            Type__c: this.editTemplateType,
            Output_Format__c: this.editTemplateOutputFormat,
            Base_Object_API__c: this.editTemplateObject,
            Description__c: this.editTemplateDesc,
            Query_Config__c: this.editTemplateQuery,
            Test_Record_Id__c: this.editTemplateTestRecordId,
            Document_Title_Format__c: this.editTemplateTitleFormat
        };

        try {
            await saveTemplate({ fields: fields, createVersion: false });
            this.showToast('Success', 'Template Details saved.', 'success');
            return refreshApex(this.wiredTemplatesResult);
        } catch (error) {
            this.showToast('Error saving template', error.body ? error.body.message : error.message, 'error');
        }
    }

    async handleSaveAndClose() {
        // Validate
        if (!this.editTemplateName || !this.editTemplateType) {
            this.showToast('Error', 'Name and Type are required.', 'error');
            return;
        }

        const fields = {
            Id: this.editTemplateId,
            Name: this.editTemplateName,
            Category__c: this.editTemplateCategory,
            Type__c: this.editTemplateType,
            Output_Format__c: this.editTemplateOutputFormat,
            Base_Object_API__c: this.editTemplateObject,
            Description__c: this.editTemplateDesc,
            Query_Config__c: this.editTemplateQuery,
            Test_Record_Id__c: this.editTemplateTestRecordId,
            Document_Title_Format__c: this.editTemplateTitleFormat
        };
        
        const createVersion = true; 

        try {
            await saveTemplate({ fields: fields, createVersion: createVersion });
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

        if (!this.librariesReady) {
            this.showToast('Error', 'Download library not loaded yet. Please wait.', 'error');
            return;
        }

        this.isLoadingVersions = true;

        try {
            // Server-side document processing
            const result = await processAndReturnDocument({
                templateId: this.editTemplateId,
                recordId: this.editTemplateTestRecordId
            });

            if (!result || !result.base64) {
                throw new Error('Document generation returned empty result.');
            }

            const base64Data = result.base64;
            const docTitle = result.title || 'Sample_Document';
            const templateType = this.editTemplateType;
            const isPPT = ['PowerPoint', 'PPT', 'PPTX'].includes(templateType);
            const baseName = 'Sample_' + docTitle;

            // Decode base64 to binary
            const binaryString = atob(base64Data);
            const bytes = new Uint8Array(binaryString.length);
            for (let i = 0; i < binaryString.length; i++) {
                bytes[i] = binaryString.charCodeAt(i);
            }

            if (isPPT || this.editTemplateOutputFormat === 'Native') {
                const out = new Blob([bytes], { type: 'application/octet-stream' });
                window.saveAs(out, baseName + (isPPT ? '.pptx' : '.docx'));
                this.showToast('Success', 'Sample Document Downloaded', 'success');
            } else {
                // PDF
                this.showToast('Info', 'Generating PDF Sample...', 'info');
                const iframe = this.template.querySelector('iframe');
                if (!iframe) {
                    this.showToast('Error', 'PDF Engine not found in DOM.', 'error');
                    return;
                }

                iframe.contentWindow.postMessage({
                    type: 'generate',
                    blob: bytes.buffer,
                    fileName: baseName
                }, new URL('/apex/DocGenPDFEngine', window.location.origin).origin);
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

    // --- File Upload ---
    handleEditUploadFinished(event) {
        const uploadedFiles = event.detail.files;
        if (uploadedFiles && uploadedFiles.length > 0) {
            const file = uploadedFiles[0];
            this.showToast('Success', 'File Uploaded: ' + file.name, 'success');
            this.currentFileId = file.documentId;
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

    // --- Messaging ---
    connectedCallback() {
        window.addEventListener('message', this.handlePdfMessage);
    }
    
    disconnectedCallback() {
        window.removeEventListener('message', this.handlePdfMessage);
    }

    handlePdfMessage = (event) => {
        if (!event.data || !event.data.type) return;
        if (event.data.type === 'docgen_success') {
            this.showToast('Success', 'PDF Sample Generated', 'success');
        } else if (event.data.type === 'docgen_error') {
            this.showToast('Error', 'PDF Engine: ' + event.data.message, 'error');
        }
    }

    resetForm() {
        this.uploadedFileName = '';
        this.currentWizardStep = '1';
        this.newTemplateName = '';
        this.newTemplateCategory = '';
        this.newTemplateDesc = '';
        this.newTemplateQuery = '';
        this.newTemplateOutputFormat = 'PDF';
        this.newTemplateObject = 'Account';
        this.createdTemplateId = null;
        this.isCreating = true;
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
import { LightningElement, wire, track, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getObjectOptions from '@salesforce/apex/DocGenController.getObjectOptions';
import previewRecordData from '@salesforce/apex/DocGenController.previewRecordData';
import { refreshApex } from '@salesforce/apex';

export default class DocGenQueryBuilder extends LightningElement {
    @track objectOptions = [];
    @track filteredObjectOptions = [];

    @api selectedObject;
    @track selectedObjectLabel = '';
    @track showObjectDropdown = false;

    // --- New Hierarchy State ---
    @track rootNodeConfig = null;
    @api queryMetadata = ''; // Stores the JSON

    @api showTagsOnly = false;
    @api templateType = 'HTML'; // 'HTML', 'Word', 'PowerPoint'
    @track showSelectedOnly = false;
    @track showRawData = false;

    // --- Search State ---
    @track tagsSearchKey = '';

    get mainColumnClass() {
        return this.showTagsOnly ? 'slds-hide' : 'slds-col slds-size_2-of-3';
    }

    get tagsColumnClass() {
        return this.showTagsOnly ? 'slds-col slds-size_1-of-1' : 'slds-col slds-size_1-of-3';
    }

    // --- Wiring ---
    @api
    get queryConfig() {
        return this._queryConfig;
    }
    set queryConfig(value) {
        this._queryConfig = value;
    }
    _queryConfig = '';

    @wire(getObjectOptions)
    wiredOptions({ error, data }) {
        if (data) {
            this.objectOptions = data;
            this.filteredObjectOptions = data;
            if (this.selectedObject) {
                const found = this.objectOptions.find(o => o.value === this.selectedObject);
                if (found) this.selectedObjectLabel = found.label;

                // Init Root Node if loading existing
                if (!this.rootNodeConfig && this.queryMetadata) {
                    try {
                        this.rootNodeConfig = JSON.parse(this.queryMetadata);
                    } catch (e) {
                        console.error('Error parsing Query_Metadata__c', e);
                        // Fallback to init blank
                        this.initRootNode();
                    }
                } else if (!this.rootNodeConfig) {
                    this.initRootNode();
                }
            }
        } else if (error) {
            console.error(error);
        }
    }

    // --- Object Search Handling ---
    handleObjectSearch(event) {
        const searchKey = event.target.value.toLowerCase();
        this.selectedObjectLabel = event.target.value;
        this.showObjectDropdown = true;

        if (searchKey) {
            this.filteredObjectOptions = this.objectOptions.filter(opt =>
                opt.label.toLowerCase().includes(searchKey)
            );
        } else {
            this.filteredObjectOptions = this.objectOptions;
        }
    }

    handleObjectFocus() {
        this.showObjectDropdown = true;
        this.filteredObjectOptions = this.objectOptions.filter(opt =>
            opt.label.toLowerCase().includes((this.selectedObjectLabel || '').toLowerCase())
        );
    }

    handleObjectSelect(event) {
        const value = event.currentTarget.dataset.value;
        const label = event.currentTarget.dataset.label;

        this.selectedObject = value;
        this.selectedObjectLabel = label;
        this.showObjectDropdown = false;

        this.initRootNode();
        this.notifyChange();
    }

    initRootNode() {
        this.rootNodeConfig = {
            type: 'root',
            objectApiName: this.selectedObject,
            relationshipName: '',
            selectedFields: [],
            childConfigs: [],
            parentConfigs: [],
            whereFilters: [],
            orderBy: '',
            limitAmount: '',
            isExpanded: true
        };
    }

    // Global filter toggle passed down
    get globalState() {
        return { showSelectedOnly: this.showSelectedOnly };
    }

    handleToggleSelectedOnly(event) {
        this.showSelectedOnly = event.target.checked;
        const rootNode = this.template.querySelector('c-doc-gen-query-node');
        if (rootNode) {
            rootNode.refreshFieldsFilter(this.globalState);
        }
    }

    // --- Root Node Event ---
    handleRootConfigChange(event) {
        this.rootNodeConfig = event.detail.config;
        this.notifyChange();
    }

    // --- SOQL Generator Engine ---

    get generatedQuery() {
        if (!this.rootNodeConfig) return '';
        try {
            return this.buildNodeSOQL(this.rootNodeConfig, true);
        } catch (e) {
            console.error('SOQL Generation Error:', e);
            return 'ERROR: Could not generate SOQL. Check configuration.';
        }
    }

    // Recursive SOQL Builder
    buildNodeSOQL(node, isRoot) {
        let selectItems = [];

        // 1. Direct Fields
        if (node.selectedFields && node.selectedFields.length > 0) {
            selectItems.push(...node.selectedFields);
        }

        // 2. Parent Lookups (Flat paths e.g. CreatedBy.Name)
        if (node.parentConfigs && node.parentConfigs.length > 0) {
            node.parentConfigs.forEach(parent => {
                const parentPaths = this.buildParentPaths(parent, parent.relationshipName);
                selectItems.push(...parentPaths);
            });
        }

        // 3. Child Relationships (Nested SELECTs)
        if (node.childConfigs && node.childConfigs.length > 0) {
            node.childConfigs.forEach(child => {
                const childSOQL = this.buildNodeSOQL(child, false);
                if (childSOQL) {
                    selectItems.push(`(${childSOQL})`);
                }
            });
        }

        // Must have at least Id if nothing selected
        if (selectItems.length === 0) {
            selectItems.push('Id');
        }

        // Deduplicate simple fields
        selectItems = [...new Set(selectItems)];

        let soql = `SELECT ${selectItems.join(', ')} FROM ${isRoot ? node.objectApiName : node.relationshipName}`;

        // 4. Filters (WHERE)
        if (node.whereFilters && node.whereFilters.length > 0) {
            const clauses = node.whereFilters.map(f => f.clause);
            soql += ` WHERE ${clauses.join(' AND ')}`;
        }

        // 5. Order & Limit
        if (node.orderBy) soql += ` ORDER BY ${node.orderBy}`;
        if (node.limitAmount) soql += ` LIMIT ${node.limitAmount}`;

        return soql;
    }

    // Recursive Lookup Field Flattener
    buildParentPaths(parentNode, currentPrefix) {
        let paths = [];

        // Direct fields on this parent
        if (parentNode.selectedFields && parentNode.selectedFields.length > 0) {
            parentNode.selectedFields.forEach(f => {
                paths.push(`${currentPrefix}.${f}`);
            });
        }

        // Nested parents
        if (parentNode.parentConfigs && parentNode.parentConfigs.length > 0) {
            parentNode.parentConfigs.forEach(nestedParent => {
                const nestedPrefix = `${currentPrefix}.${nestedParent.relationshipName}`;
                paths.push(...this.buildParentPaths(nestedParent, nestedPrefix));
            });
        }

        return paths;
    }


    // --- State Management ---
    notifyChange() {
        const soql = this.generatedQuery;
        const metadata = this.rootNodeConfig ? JSON.stringify(this.rootNodeConfig) : '';

        if (soql.length > 20000) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Warning', message: 'SOQL query exceeds 20,000 characters. It may fail to execute.', variant: 'warning' }));
        }

        const event = new CustomEvent('configchange', {
            detail: {
                objectName: this.selectedObject,
                queryConfig: soql,
                queryMetadata: metadata,
                titleFormat: this.titleFormat
            }
        });
        this.dispatchEvent(event);
    }

    @api
    getQueryConfig() {
        return this.generatedQuery;
    }

    @api
    getQueryMetadata() {
        return this.rootNodeConfig ? JSON.stringify(this.rootNodeConfig) : '';
    }

    @api
    refreshFromConfig() {
        if (this.queryMetadata) {
            try {
                this.rootNodeConfig = JSON.parse(this.queryMetadata);
                // Also parse titleFormat if we had it, but that comes from wrapper.
            } catch (e) {
                console.error('refreshFromConfig parse error', e);
            }
        }
    }

    // --- Complex Preview & Tags logic ---
    // (We will implement a recursive tag generator)
    @api testRecordId;
    @track previewData = null;
    @track previewError = null;

    @wire(previewRecordData, {
        recordId: '$testRecordId',
        baseObject: '$selectedObject',
        queryConfig: '$queryConfig' // Relies on SOQL string
    })
    wiredPreview(result) {
        this.previewResult = result;
        const { error, data } = result;

        if (data) {
            this.previewData = this.flattenPreview(data);
            this.previewError = null;
        } else if (error) {
            this.previewData = null;
            this.previewError = error.body ? error.body.message : error.message;
        }
    }

    @api
    refreshPreview() {
        if (this.previewResult) return refreshApex(this.previewResult);
    }

    get rawPreviewJson() {
        if (this.previewError) return 'Error: ' + this.previewError;
        if (!this.previewData) return 'No data loaded. Select a test record.';
        return JSON.stringify(this.previewData, null, 2);
    }

    handleToggleRawData() {
        this.showRawData = !this.showRawData;
    }

    flattenPreview(data) {
        if (!data) return {};
        let flat = {};
        for (let key in data) {
            let val = data[key];
            if (val && typeof val === 'object' && val.records) {
                flat[key] = val.records; // Keep array
            } else if (val && typeof val === 'object' && !Array.isArray(val)) {
                flat[key] = val; // Nested object (Parent)
            } else {
                flat[key] = val;
            }
        }
        return flat;
    }

    handleTagsSearch(event) {
        window.clearTimeout(this.tagsDelayTimeout);
        const searchKey = event.target.value.toLowerCase();
        this.tagsDelayTimeout = window.setTimeout(() => {
            this.tagsSearchKey = searchKey;
        }, 300);
    }


    handleCopyTag(event) {
        event.preventDefault();
        const tag = event.currentTarget.dataset.tag;
        if (!tag) return;

        // navigator.clipboard is not available in LWC sandboxed iframes.
        // Use the legacy execCommand approach with a temporary textarea instead.
        const textarea = document.createElement('textarea');
        textarea.value = tag;
        textarea.style.position = 'fixed';
        textarea.style.opacity = '0';
        document.body.appendChild(textarea);
        textarea.focus();
        textarea.select();

        let success = false;
        try {
            success = document.execCommand('copy');
        } catch (err) {
            console.error('Failed to copy tag', err);
        }
        document.body.removeChild(textarea);

        if (success) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Copied!', message: `${tag}`, variant: 'success' }));
        } else {
            this.dispatchEvent(new ShowToastEvent({ title: 'Copy failed', message: 'Could not copy to clipboard.', variant: 'error' }));
        }
    }


    // Tag format helpers based on template type
    get isHtmlTemplate() {
        return this.templateType === 'HTML';
    }

    // For HTML: {{field}}, for Word/PPT: {field}
    makeTag(fieldPath) {
        return this.isHtmlTemplate ? `{{${fieldPath}}}` : `{${fieldPath}}`;
    }

    // Loop helpers (docxtemplater syntax used for both — HTML is handlebars-flavored)
    makeLoopStart(relation) {
        return this.isHtmlTemplate ? `{{#${relation}}}` : `{#${relation}}`;
    }

    makeLoopEnd(relation) {
        return this.isHtmlTemplate ? `{{/${relation}}}` : `{/${relation}}`;
    }

    get generatedTags() {
        if (!this.rootNodeConfig) return null;
        const search = this.tagsSearchKey;
        const data = this.previewData || {};
        return this.buildTagsForNode(this.rootNodeConfig, data, search, '');
    }
    @api
    convertSOQLToMetadata(soqlString, baseObject) {
        if (!soqlString) return null;
        try {
            const rootNode = this.parseSOQLNode(soqlString, 'root', baseObject, '');
            return JSON.stringify(rootNode);
        } catch (e) {
            console.error('SOQL Parse Error', e);
            return null;
        }
    }

    parseSOQLNode(soqlSegment, type, objectApiName, relationshipName) {
        let node = {
            type: type,
            objectApiName: objectApiName,
            relationshipName: relationshipName,
            selectedFields: [],
            childConfigs: [],
            parentConfigs: [],
            whereFilters: [],
            orderBy: '',
            limitAmount: '',
            isExpanded: true
        };

        if (!soqlSegment) return node;
        let s = soqlSegment.trim();
        let selectMatch = s.match(/^SELECT\s/i);
        if (!selectMatch) return node;

        let fromIndex = -1;
        let parenCount = 0;
        for (let i = 0; i < s.length; i++) {
            const char = s[i];
            if (char === '(') parenCount++;
            else if (char === ')') parenCount--;
            else if (parenCount === 0 && s.substring(i, i + 5).toUpperCase() === 'FROM ') {
                fromIndex = i;
                break;
            }
        }

        if (fromIndex === -1) return node;

        let fieldString = s.substring(selectMatch[0].length, fromIndex).trim();
        let postFromStr = s.substring(fromIndex + 5).trim();
        let mainObjNameMatch = postFromStr.match(/^([a-zA-Z0-9__c]+)/);
        let parsedObjName = mainObjNameMatch ? mainObjNameMatch[1] : objectApiName;
        node.objectApiName = parsedObjName;
        if (type === 'root' && !objectApiName) node.objectApiName = parsedObjName;

        let remainder = postFromStr.substring(parsedObjName.length).trim();

        let whereMatch = remainder.match(/WHERE\s+(((?!ORDER\s+BY|LIMIT).)*)/i);
        if (whereMatch) {
            let whereStr = whereMatch[1].trim();
            let filterParts = whereStr.split(/\s+AND\s+/i);
            filterParts.forEach(fp => {
                let parts = fp.match(/([a-zA-Z0-9_\.]+)\s*(=|!=|<|>|<=|>=|LIKE|IN|NOT\s+IN|INCLUDES|EXCLUDES)\s*(.*)/i);
                if (parts) {
                    node.whereFilters.push({
                        id: Date.now().toString() + Math.random(),
                        field: parts[1],
                        operator: parts[2].toUpperCase(),
                        value: parts[3].replace(/^'|'$/g, '')
                    });
                }
            });
        }

        let orderMatch = remainder.match(/ORDER\s+BY\s+(((?!LIMIT).)*)/i);
        if (orderMatch) node.orderBy = orderMatch[1].trim();

        let limitMatch = remainder.match(/LIMIT\s+(\d+)/i);
        if (limitMatch) node.limitAmount = limitMatch[1].trim();

        let currentPart = '';
        parenCount = 0;
        let tokens = [];
        for (let i = 0; i < fieldString.length; i++) {
            let char = fieldString[i];
            if (char === '(') parenCount++;
            else if (char === ')') parenCount--;

            if (char === ',' && parenCount === 0) {
                if (currentPart.trim()) tokens.push(currentPart.trim());
                currentPart = '';
            } else {
                currentPart += char;
            }
        }
        if (currentPart.trim()) tokens.push(currentPart.trim());

        let parentMap = {};

        tokens.forEach(tok => {
            if (tok.startsWith('(') && tok.endsWith(')')) {
                let subStr = tok.substring(1, tok.length - 1).trim();
                let subNode = this.parseSOQLNode(subStr, 'child', '', '');
                subNode.relationshipName = subNode.objectApiName;
                node.childConfigs.push(subNode);
            } else {
                if (tok.includes('.')) {
                    let parts = tok.split('.');
                    let fieldName = parts.pop();
                    let relPath = parts.join('.');
                    if (!parentMap[relPath]) {
                        parentMap[relPath] = {
                            type: 'parent',
                            relationshipName: relPath,
                            objectApiName: relPath,
                            selectedFields: [],
                            parentConfigs: [],
                            whereFilters: [],
                            isExpanded: false
                        };
                    }
                    parentMap[relPath].selectedFields.push(fieldName);
                } else {
                    if (tok !== '') node.selectedFields.push(tok);
                }
            }
        });

        Object.values(parentMap).forEach(p => node.parentConfigs.push(p));
        return node;
    }
    buildTagsForNode(node, dataScope, search, prefixContext) {
        let tags = {
            hasBase: false, baseFields: [], baseCopyAll: '',
            hasParent: false, parentSections: [],
            hasChildren: false, children: []
        };

        // 1. Base Fields
        if (node.selectedFields && node.selectedFields.length > 0) {
            let fields = node.selectedFields.map(f => {
                let sampleVal = dataScope ? dataScope[f] : '';
                if (typeof sampleVal === 'object') sampleVal = JSON.stringify(sampleVal);
                const code = this.makeTag(`${prefixContext}${f}`);
                return { label: f, code, sample: sampleVal };
            });
            if (search) fields = fields.filter(t => t.label.toLowerCase().includes(search) || t.code.toLowerCase().includes(search));
            tags.baseFields = fields;
            tags.hasBase = fields.length > 0;
            tags.baseCopyAll = fields.map(f => f.code).join('\n');
        }

        // 2. Parent (lookup) fields — can be nested within parents
        if (node.parentConfigs && node.parentConfigs.length > 0) {
            node.parentConfigs.forEach(p => {
                let pFields = this.buildParentPaths(p, p.relationshipName).map(f => {
                    let sampleVal = '';
                    if (dataScope) {
                        const parts = f.split('.');
                        let curScope = dataScope;
                        for (let part of parts) { if (curScope) curScope = curScope[part]; }
                        sampleVal = curScope;
                    }
                    return { label: f, code: this.makeTag(`${prefixContext}${f}`), sample: sampleVal };
                });
                if (search) pFields = pFields.filter(t => t.label.toLowerCase().includes(search) || t.code.toLowerCase().includes(search));
                if (pFields.length > 0) {
                    tags.parentSections.push({
                        name: p.relationshipName,
                        fields: pFields,
                        copyAllText: pFields.map(f => f.code).join('\n'),
                        isVisible: true
                    });
                }
            });
            tags.hasParent = tags.parentSections.length > 0;
        }

        // 3. Children — recurse deeply so nested children at all levels are shown
        if (node.childConfigs && node.childConfigs.length > 0) {
            node.childConfigs.forEach(c => {
                const rel = `${prefixContext}${c.relationshipName}`;
                const loopStart = this.makeLoopStart(rel);
                const loopEnd = this.makeLoopEnd(rel);

                const childRecords = dataScope ? dataScope[c.relationshipName] : null;
                const firstRecord = (childRecords && Array.isArray(childRecords) && childRecords.length > 0) ? childRecords[0] : null;

                // Direct fields of this child (inside the loop, no prefix)
                let fields = c.selectedFields.map(f => {
                    const sampleVal = firstRecord ? firstRecord[f] : '';
                    return { label: f, code: this.makeTag(f), sample: sampleVal };
                });

                // Parent lookups inside this child
                if (c.parentConfigs) {
                    c.parentConfigs.forEach(nestedP => {
                        let nestedFields = this.buildParentPaths(nestedP, nestedP.relationshipName).map(nestedF => {
                            let sampleVal = '';
                            if (firstRecord) {
                                const parts = nestedF.split('.');
                                let curScope = firstRecord;
                                for (let part of parts) if (curScope) curScope = curScope[part];
                                sampleVal = curScope;
                            }
                            return { label: nestedF, code: this.makeTag(nestedF), sample: sampleVal };
                        });
                        fields.push(...nestedFields);
                    });
                }

                if (search) fields = fields.filter(f => f.label.toLowerCase().includes(search) || f.code.toLowerCase().includes(search));

                const isSectionMatch = c.relationshipName.toLowerCase().includes(search || '');
                const hasVisibleFields = fields.length > 0;

                // Recurse into nested children of this child
                const nestedChildScope = firstRecord || {};
                const nestedTags = this.buildTagsForNode(c, nestedChildScope, search, '');

                if (!search || isSectionMatch || hasVisibleFields || nestedTags.hasChildren) {
                    tags.children.push({
                        name: c.relationshipName,
                        loopStart,
                        loopEnd,
                        fields,
                        nestedChildren: nestedTags.children,
                        hasNestedChildren: nestedTags.hasChildren,
                        copyAllText: [loopStart, ...fields.map(f => f.code), loopEnd].join('\n'),
                        isVisible: true
                    });
                }
            });
            tags.hasChildren = tags.children.length > 0;
        }

        return tags;
    }

    // Warnings
    get complexityWarning() {
        if (!this.rootNodeConfig) return null;
        let warnings = [];
        let soqlLen = this.generatedQuery.length;
        if (soqlLen > 15000) {
            warnings.push(`Approaching SOQL 20,000 char limit (Current: ${soqlLen}).`);
        }
        if (warnings.length > 0) return { title: 'Limit Status', messages: warnings };
        return null;
    }

    @api titleFormat = '';
    handleTitleChange(event) {
        this.titleFormat = event.target.value;
        this.notifyChange();
    }
}

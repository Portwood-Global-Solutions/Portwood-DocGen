import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getObjectFields from '@salesforce/apex/DocGenController.getObjectFields';
import getChildRelationships from '@salesforce/apex/DocGenController.getChildRelationships';
import getParentRelationships from '@salesforce/apex/DocGenController.getParentRelationships';

export default class DocGenQueryNode extends LightningElement {
    _nodeConfig;
    _initialized = false;
    @api
    get nodeConfig() {
        return this._nodeConfig;
    }
    set nodeConfig(value) {
        this._nodeConfig = value;
        if (!this._initialized) {
            this._initialized = true;
            this.localConfig = JSON.parse(JSON.stringify(value));
        } else {
            // If parent corrected the objectApiName, adopt it and re-trigger wire
            if (value && value.objectApiName && value.objectApiName !== this.localConfig.objectApiName) {
                this.localConfig = { ...this.localConfig, objectApiName: value.objectApiName };
                this.isLoadingFields = true;
                this.isLoadingParents = true;
                this.isLoadingChildren = true;
            }
        }
    }
    @api level = 1;
    @api subqueryDepth = 0;  // How many levels of subqueries (child-to-child) deep (max 5)
    @api lookupDepth = 0;    // How deep in the current lookup chain we are (max 5, resets per subquery)
    @api showTagsOnly = false;
    @api globals = { showSelectedOnly: false };

    @track localConfig = {};

    @track _fieldOptions = [];
    @track filteredFieldOptions = [];

    @track childOptions = [];
    @track parentOptions = [];
    @track filteredChildOptions = [];
    @track filteredParentOptions = [];

    // Search Strings
    fieldSearchKey = '';
    @track selectedChildLabel = '';
    @track showChildDropdown = false;
    @track selectedParentLabel = '';
    @track showParentDropdown = false;

    @track isLoadingFields = true;
    @track isLoadingChildren = true;
    @track isLoadingParents = true;
    @track fieldLoadError = false;
    @track childLoadError = false;
    @track parentLoadError = false;
    @track isExpanded = true;

    // Filter Modal State
    @track showFilterModal = false;
    @track filterField = '';
    @track filterOp = '=';
    @track filterValue = '';

    get operators() {
        return [
            { label: 'Equals (=)', value: '=' },
            { label: 'Not Equals (!=)', value: '!=' },
            { label: 'Greater Than (>)', value: '>' },
            { label: 'Less Than (<)', value: '<' },
            { label: 'Greater/Equal (>=)', value: '>=' },
            { label: 'Less/Equal (<=)', value: '<=' },
            { label: 'LIKE', value: 'LIKE' },
            { label: 'INCLUDES', value: 'INCLUDES' },
            { label: 'EXCLUDES', value: 'EXCLUDES' }
        ];
    }

    connectedCallback() {
        // localConfig should already be set by the setter, but guard just in case
        if (!this._initialized && this._nodeConfig) {
            this._initialized = true;
            this.localConfig = JSON.parse(JSON.stringify(this._nodeConfig));
        }

        if (!this.localConfig.selectedFields) this.localConfig.selectedFields = [];
        if (!this.localConfig.childConfigs) this.localConfig.childConfigs = [];
        if (!this.localConfig.parentConfigs) this.localConfig.parentConfigs = [];
        if (!this.localConfig.whereFilters) this.localConfig.whereFilters = [];

        // Base/Root always expanded by default. Children default to expanded too if they exist.
        if (this.level > 1 && !this.localConfig.isExpanded) {
            this.isExpanded = false;
        } else {
            this.isExpanded = true;
            this.localConfig.isExpanded = true;
        }
    }

    get nodeTitle() {
        if (this.level === 1) return `Base Object: ${this.localConfig.objectApiName}`;
        if (this.localConfig.type === 'child') return `Child: ${this.localConfig.relationshipName} (${this.localConfig.objectApiName})`;
        if (this.localConfig.type === 'parent') return `Lookup: ${this.localConfig.relationshipName} (${this.localConfig.objectApiName})`;
        return this.localConfig.objectApiName;
    }

    get iconName() {
        if (this.level === 1) return 'standard:custom';
        if (this.localConfig.type === 'parent') return 'standard:hierarchy';
        return 'standard:related_list';
    }

    get isPillMode() {
        return this.showTagsOnly;
    }

    get hasFilters() {
        return this.localConfig.whereFilters && this.localConfig.whereFilters.length > 0;
    }

    get hasOrderLimit() {
        return this.localConfig.orderBy || this.localConfig.limitAmount;
    }

    get isFilterable() {
        // Base object might have filters, children too. Prents usually don't have filters in SELECT Lookups,
        // (You can't filter a parent lookup, you filter the base).
        return this.localConfig.type !== 'parent';
    }

    get isRemovable() {
        // Root (level 1) cannot be removed; all children and lookups can
        return parseInt(this.level, 10) > 1;
    }

    // Max 5 levels of child subquery nesting
    get maxChildLevelReached() {
        return parseInt(this.subqueryDepth, 10) >= 5;
    }

    // Max 5 levels of parent lookup dot-notation per subquery level
    get maxParentLevelReached() {
        return parseInt(this.lookupDepth, 10) >= 5;
    }

    // Keep maxLevelReached for display in existing template
    get maxLevelReached() {
        return this.maxChildLevelReached && this.maxParentLevelReached;
    }

    get nextLevel() {
        return parseInt(this.level, 10) + 1;
    }

    // For child nodes: subqueryDepth+1, lookupDepth resets to 0
    get nextChildSubqueryDepth() {
        return parseInt(this.subqueryDepth, 10) + 1;
    }

    // For parent lookup nodes: same subqueryDepth, lookupDepth+1
    get nextLookupDepth() {
        return parseInt(this.lookupDepth, 10) + 1;
    }

    get levelTitle() {
        return `Level ${this.level}`;
    }

    get expandIcon() {
        return this.isExpanded ? 'utility:chevrondown' : 'utility:chevronright';
    }

    get filterButtonVariant() {
        return this.hasFilters ? 'brand' : 'border-filled';
    }

    toggleExpand() {
        this.isExpanded = !this.isExpanded;
        this.localConfig.isExpanded = this.isExpanded;
        this.dispatchChange();
    }

    // --- Wire Methods ---

    @wire(getObjectFields, { objectName: '$localConfig.objectApiName' })
    wiredFields({ error, data }) {
        if (data) {
            this._fieldOptions = data;
            this.filterFields();
            this.fieldLoadError = false;
            this.isLoadingFields = false;
        } else if (error) {
            const msg = error.body ? error.body.message : JSON.stringify(error);
            console.error('docGenQueryNode: Failed to load fields for', this.localConfig.objectApiName, msg);
            this.dispatchEvent(new ShowToastEvent({ title: 'Error Loading Fields', message: `Could not load fields for "${this.localConfig.objectApiName}": ${msg}`, variant: 'error' }));
            this._fieldOptions = [];
            this.filteredFieldOptions = [];
            this.fieldLoadError = true;
            this.isLoadingFields = false;
        }
    }

    @wire(getChildRelationships, { objectName: '$localConfig.objectApiName' })
    wiredChildren({ error, data }) {
        if (data) {
            this.childOptions = data;
            this.filteredChildOptions = data;
            this.childLoadError = false;

            // Auto-correct child node objectApiNames from manual SOQL parsing
            let configChanged = false;
            const correctedChildConfigs = this.localConfig.childConfigs.map(childConf => {
                const match = data.find(opt => opt.value === childConf.relationshipName);
                if (match && childConf.objectApiName !== match.childObjectApiName) {
                    configChanged = true;
                    return { ...childConf, objectApiName: match.childObjectApiName };
                }
                return childConf;
            });
            if (configChanged) {
                this.localConfig = { ...this.localConfig, childConfigs: correctedChildConfigs };
                this.dispatchChange();
            }

            this.isLoadingChildren = false;
        } else if (error) {
            const msg = error.body ? error.body.message : JSON.stringify(error);
            console.error('docGenQueryNode: Failed to load child relationships for', this.localConfig.objectApiName, msg);
            this.dispatchEvent(new ShowToastEvent({ title: 'Error Loading Related Lists', message: `Could not load related lists for "${this.localConfig.objectApiName}": ${msg}`, variant: 'error' }));
            this.childOptions = [];
            this.filteredChildOptions = [];
            this.childLoadError = true;
            this.isLoadingChildren = false;
        }
    }

    @wire(getParentRelationships, { objectName: '$localConfig.objectApiName' })
    wiredParents({ error, data }) {
        if (data) {
            this.parentOptions = data;
            this.filteredParentOptions = data;
            this.parentLoadError = false;

            // Auto-correct lookup node objectApiNames from manual SOQL parsing
            let configChanged = false;
            const correctedParentConfigs = this.localConfig.parentConfigs.map(pConf => {
                const match = data.find(opt => opt.value === pConf.relationshipName);
                if (match && pConf.objectApiName !== match.childObjectApiName) {
                    configChanged = true;
                    return { ...pConf, objectApiName: match.childObjectApiName };
                }
                return pConf;
            });
            if (configChanged) {
                this.localConfig = { ...this.localConfig, parentConfigs: correctedParentConfigs };
                this.dispatchChange();
            }

            this.isLoadingParents = false;
        } else if (error) {
            const msg = error.body ? error.body.message : JSON.stringify(error);
            console.error('docGenQueryNode: Failed to load parent lookups for', this.localConfig.objectApiName, msg);
            this.dispatchEvent(new ShowToastEvent({ title: 'Error Loading Lookups', message: `Could not load lookups for "${this.localConfig.objectApiName}": ${msg}`, variant: 'error' }));
            this.parentOptions = [];
            this.filteredParentOptions = [];
            this.parentLoadError = true;
            this.isLoadingParents = false;
        }
    }

    // --- Logic ---

    handleFieldSearch(event) {
        window.clearTimeout(this.delayTimeout);
        const searchKey = event.target.value;
        this.delayTimeout = window.setTimeout(() => {
            this.fieldSearchKey = searchKey;
            this.filterFields();
        }, 300);
    }

    @api
    refreshFieldsFilter(globalState) {
        if (globalState) {
            this.globals = globalState;
        }
        this.filterFields();
        // Propagate down
        const childNodes = this.template.querySelectorAll('c-doc-gen-query-node');
        if (childNodes) {
            childNodes.forEach(node => node.refreshFieldsFilter(this.globals));
        }
    }

    filterFields() {
        let optionsToShow = [];
        let sourceOptions = this._fieldOptions;

        if (this.globals.showSelectedOnly) {
            sourceOptions = sourceOptions.filter(opt => this.localConfig.selectedFields.includes(opt.value));
        }

        if (!this.fieldSearchKey) {
            optionsToShow = sourceOptions.slice(0, 200);
        } else {
            const key = this.fieldSearchKey.toLowerCase();
            optionsToShow = sourceOptions.filter(opt =>
                opt.label.toLowerCase().includes(key) ||
                opt.value.toLowerCase().includes(key)
            );
            optionsToShow = optionsToShow.slice(0, 500);
        }

        if (this.localConfig.selectedFields && this.localConfig.selectedFields.length > 0) {
            const selectedSet = new Set(this.localConfig.selectedFields);
            const visibleSet = new Set(optionsToShow.map(o => o.value));

            const missingOptions = this._fieldOptions.filter(o =>
                selectedSet.has(o.value) && !visibleSet.has(o.value)
            );

            if (!this.globals.showSelectedOnly && missingOptions.length > 0) {
                optionsToShow = [...optionsToShow, ...missingOptions];
            }
        }
        this.filteredFieldOptions = optionsToShow;
    }

    handleFieldChange(event) {
        this.localConfig.selectedFields = event.detail.value;
        this.dispatchChange();
    }

    handleSelectAll() {
        if (!this._fieldOptions) return;
        this.localConfig.selectedFields = this._fieldOptions.map(opt => opt.value);
        this.filterFields();
        this.dispatchChange();
    }

    // --- Search Children ---

    handleChildSearch(event) {
        const key = event.target.value.toLowerCase();
        this.selectedChildLabel = event.target.value;
        this.showChildDropdown = true;
        this.filteredChildOptions = key ?
            this.childOptions.filter(o => o.label.toLowerCase().includes(key)) :
            this.childOptions;
    }

    handleChildFocus() {
        this.showChildDropdown = true;
        this.filteredChildOptions = this.childOptions.filter(o =>
            o.label.toLowerCase().includes((this.selectedChildLabel || '').toLowerCase())
        );
    }

    handleChildBlur() {
        // setTimeout allows the click event on the dropdown item to fire first before hiding
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        window.setTimeout(() => {
            this.showChildDropdown = false;
        }, 150);
    }

    handleChildSelect(event) {
        const val = event.currentTarget.dataset.value;
        const targetObj = event.currentTarget.dataset.target;
        this.showChildDropdown = false;
        this.selectedChildLabel = '';

        // Add
        if (!this.localConfig.childConfigs) this.localConfig.childConfigs = [];

        // Prevent dupes
        if (this.localConfig.childConfigs.find(c => c.relationshipName === val)) return;

        this.localConfig.childConfigs.push({
            type: 'child',
            relationshipName: val,
            objectApiName: targetObj,
            selectedFields: [],
            childConfigs: [],
            parentConfigs: [],
            whereFilters: [],
            orderBy: '',
            limitAmount: '',
            isExpanded: true
        });
        this.dispatchChange();
    }

    handleRemoveNode() {
        this.dispatchEvent(new CustomEvent('remove'));
    }

    handleRemoveChild(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const updated = [...this.localConfig.childConfigs];
        updated.splice(index, 1);
        this.localConfig = { ...this.localConfig, childConfigs: updated };
        this.dispatchChange();
    }

    // --- Search Parents ---

    handleParentSearch(event) {
        const key = event.target.value.toLowerCase();
        this.selectedParentLabel = event.target.value;
        this.showParentDropdown = true;
        this.filteredParentOptions = key ?
            this.parentOptions.filter(o => o.label.toLowerCase().includes(key)) :
            this.parentOptions;
    }

    handleParentFocus() {
        this.showParentDropdown = true;
        this.filteredParentOptions = this.parentOptions.filter(o =>
            o.label.toLowerCase().includes((this.selectedParentLabel || '').toLowerCase())
        );
    }

    handleParentBlur() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        window.setTimeout(() => {
            this.showParentDropdown = false;
        }, 150);
    }

    handleParentSelect(event) {
        const val = event.currentTarget.dataset.value;
        const targetObj = event.currentTarget.dataset.target;
        this.showParentDropdown = false;
        this.selectedParentLabel = '';

        if (!this.localConfig.parentConfigs) this.localConfig.parentConfigs = [];
        if (this.localConfig.parentConfigs.find(c => c.relationshipName === val)) return;

        this.localConfig.parentConfigs.push({
            type: 'parent',
            relationshipName: val,
            objectApiName: targetObj,
            selectedFields: [],
            childConfigs: [],
            parentConfigs: [],
            isExpanded: true
        });
        this.dispatchChange();
    }

    handleRemoveParent(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const updated = [...this.localConfig.parentConfigs];
        updated.splice(index, 1);
        this.localConfig = { ...this.localConfig, parentConfigs: updated };
        this.dispatchChange();
    }

    // --- Upward Events ---

    handleChildChange(event) {
        const index = event.currentTarget.dataset.index;
        this.localConfig.childConfigs[index] = event.detail.config;
        this.dispatchChange();
    }

    handleParentChange(event) {
        const index = event.currentTarget.dataset.index;
        this.localConfig.parentConfigs[index] = event.detail.config;
        this.dispatchChange();
    }

    dispatchChange() {
        // Deep copy out
        const safeConfig = JSON.parse(JSON.stringify(this.localConfig));
        this.dispatchEvent(new CustomEvent('configchange', {
            detail: { config: safeConfig }
        }));
    }

    // --- Filtering ---

    openFilterModal() {
        this.showFilterModal = true;
    }

    closeFilterModal() {
        this.showFilterModal = false;
    }

    handleFilterFieldChange(event) { this.filterField = event.detail.value; }
    handleFilterOpChange(event) { this.filterOp = event.detail.value; }
    handleFilterValChange(event) { this.filterValue = event.detail.value; }

    addFilter() {
        if (!this.filterField || !this.filterOp) return;
        if (!this.localConfig.whereFilters) this.localConfig.whereFilters = [];

        let valStr = this.filterValue;
        // Auto format string
        if (this.filterOp === 'LIKE') {
            if (!valStr.startsWith("'") && !valStr.endsWith("'")) {
                valStr = `'${valStr}'`; // Quotes for like
            }
        } else if (valStr && isNaN(valStr) && valStr !== 'null' && valStr !== 'true' && valStr !== 'false' && !valStr.startsWith("'")) {
            valStr = `'${valStr}'`;
        }

        this.localConfig.whereFilters.push({
            field: this.filterField,
            op: this.filterOp,
            val: valStr,
            clause: `${this.filterField} ${this.filterOp} ${valStr}`
        });

        this.filterField = '';
        this.filterOp = '=';
        this.filterValue = '';
        this.dispatchChange();
    }

    removeFilter(event) {
        const index = event.currentTarget.dataset.index;
        this.localConfig.whereFilters.splice(index, 1);
        this.dispatchChange();
    }

    handleOrderChange(event) {
        this.localConfig.orderBy = event.target.value;
        this.dispatchChange();
    }

    handleLimitChange(event) {
        this.localConfig.limitAmount = event.target.value;
        this.dispatchChange();
    }

    get nextLevel() {
        return parseInt(this.level, 10) + 1;
    }

    get filterCountText() {
        return this.localConfig.whereFilters ? this.localConfig.whereFilters.length : 0;
    }

    // Auto-close dropdowns
    handleOutsideClick() {
        const activeElement = this.template.activeElement;
        // Basic close if clicking outside dropdown
    }
}
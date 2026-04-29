import { LightningElement, api, track } from 'lwc';

/**
 * Recursive tree node for the visual query builder.
 * Renders: selected field pills, field picker dropdown,
 * parent lookup folders, child relationship folders.
 * Same component used at every depth level.
 */
export default class DocGenTreeNode extends LightningElement {
    @api nodeData; // { path, objectLabel, objectName, fields[], parentRels[], childRels[], isChild, whereClause, orderBy, limitAmount }
    @api depth = 0;
    @api globalSearch = '';

    @track _pickerOpen = false;
    @track _pickerSearch = '';

    // ── Field picker ────────────────────────────────────────────
    togglePicker() {
        this._pickerOpen = !this._pickerOpen;
        this._pickerSearch = '';
    }

    handlePickerSearch(event) {
        this._pickerSearch = (event.target.value || '').toLowerCase();
    }

    get showPicker() {
        // Auto-open picker when global search matches fields in this node
        if (this._pickerOpen) return true;
        if (this.globalSearch && this.nodeData && this.nodeData.fields) {
            const gs = this.globalSearch;
            return this.nodeData.fields.some(
                (f) => f.displayLabel.toLowerCase().includes(gs) || f.apiName.toLowerCase().includes(gs)
            );
        }
        return false;
    }

    get pickerFields() {
        if (!this.nodeData || !this.nodeData.fields) return [];
        const s = this._pickerSearch || this.globalSearch || '';
        return this.nodeData.fields
            .filter((f) => !s || f.displayLabel.toLowerCase().includes(s) || f.apiName.toLowerCase().includes(s))
            .slice(0, 100);
    }

    handlePickerToggleField(event) {
        const apiName = event.currentTarget.dataset.api;
        this.dispatchEvent(
            new CustomEvent('fieldtoggle', {
                bubbles: true,
                composed: true, // NOPMD — composed required for recursive tree node events
                detail: { path: this.nodeData.path, fieldName: apiName }
            })
        );
    }

    // ── Remove pill ─────────────────────────────────────────────
    handleRemoveField(event) {
        const apiName = event.currentTarget.dataset.api;
        this.dispatchEvent(
            new CustomEvent('fieldtoggle', {
                bubbles: true,
                composed: true, // NOPMD — composed required for recursive tree node events
                detail: { path: this.nodeData.path, fieldName: apiName }
            })
        );
    }

    // ── Parent lookup expand ────────────────────────────────────
    handleExpandParent(event) {
        const relName = event.currentTarget.dataset.rel;
        this.dispatchEvent(
            new CustomEvent('expandparent', {
                bubbles: true,
                composed: true, // NOPMD — composed required for recursive tree node events
                detail: { path: this.nodeData.path, relName }
            })
        );
    }

    handleParentFieldToggle(event) {
        // Bubbles up from nested picker
        const apiName = event.currentTarget.dataset.api;
        const relName = event.currentTarget.dataset.rel;
        this.dispatchEvent(
            new CustomEvent('parentfieldtoggle', {
                bubbles: true,
                composed: true, // NOPMD — composed required for recursive tree node events
                detail: { path: this.nodeData.path, relName, fieldName: apiName }
            })
        );
    }

    handleRemoveParentField(event) {
        const apiName = event.currentTarget.dataset.api;
        const relName = event.currentTarget.dataset.rel;
        this.dispatchEvent(
            new CustomEvent('parentfieldtoggle', {
                bubbles: true,
                composed: true, // NOPMD — composed required for recursive tree node events
                detail: { path: this.nodeData.path, relName, fieldName: apiName }
            })
        );
    }

    // ── Remove relationship ─────────────────────────────────────
    handleRemoveChild(event) {
        event.preventDefault();
        event.stopPropagation();
        const relName = event.currentTarget.dataset.rel;
        this.dispatchEvent(
            new CustomEvent('removechild', {
                bubbles: true,
                composed: true, // NOPMD — composed required for recursive tree node events
                detail: { path: this.nodeData.path, relName }
            })
        );
    }

    handleRemoveParent(event) {
        event.preventDefault();
        event.stopPropagation();
        const relName = event.currentTarget.dataset.rel;
        this.dispatchEvent(
            new CustomEvent('removeparent', {
                bubbles: true,
                composed: true, // NOPMD — composed required for recursive tree node events
                detail: { path: this.nodeData.path, relName }
            })
        );
    }

    // ── Child expand ────────────────────────────────────────────
    handleExpandChild(event) {
        const relName = event.currentTarget.dataset.rel;
        this.dispatchEvent(
            new CustomEvent('expandchild', {
                bubbles: true,
                composed: true, // NOPMD — composed required for recursive tree node events
                detail: { path: this.nodeData.path, relName }
            })
        );
    }

    // ── Clause changes ──────────────────────────────────────────
    handleAliasChange(event) {
        // Strip non-identifier chars to keep merge tags valid ([A-Za-z0-9_]+)
        const cleaned = (event.target.value || '').trim().replace(/[^A-Za-z0-9_]/g, '');
        this.dispatchEvent(
            new CustomEvent('clausechange', {
                bubbles: true,
                composed: true, // NOPMD — composed required for recursive tree node events
                detail: { path: this.nodeData.path, field: 'alias', value: cleaned }
            })
        );
    }
    handleWhereChange(event) {
        this.dispatchEvent(
            new CustomEvent('clausechange', {
                bubbles: true,
                composed: true, // NOPMD — composed required for recursive tree node events
                detail: { path: this.nodeData.path, field: 'whereClause', value: event.target.value }
            })
        );
    }
    handleOrderByChange(event) {
        this.dispatchEvent(
            new CustomEvent('clausechange', {
                bubbles: true,
                composed: true, // NOPMD — composed required for recursive tree node events
                detail: { path: this.nodeData.path, field: 'orderBy', value: event.target.value }
            })
        );
    }
    handleLimitChange(event) {
        this.dispatchEvent(
            new CustomEvent('clausechange', {
                bubbles: true,
                composed: true, // NOPMD — composed required for recursive tree node events
                detail: { path: this.nodeData.path, field: 'limitAmount', value: event.target.value }
            })
        );
    }

    // ── Template getters ────────────────────────────────────────
    get selectedFields() {
        if (!this.nodeData || !this.nodeData.fields) return [];
        return this.nodeData.fields.filter((f) => f.checked);
    }

    get hasSelectedFields() {
        return this.selectedFields.length > 0;
    }

    get selectedFieldCount() {
        return this.selectedFields.length;
    }

    get parentRels() {
        if (!this.nodeData || !this.nodeData.parentRels) return [];
        return this.nodeData.parentRels;
    }

    get childRels() {
        if (!this.nodeData || !this.nodeData.childRels) return [];
        return this.nodeData.childRels;
    }

    get isChild() {
        return this.nodeData && this.nodeData.isChild;
    }

    get indentStyle() {
        const px = this.depth > 0 ? 16 : 0;
        return 'padding-left: ' + px + 'px;';
    }

    get nodeAlias() {
        return this.nodeData ? this.nodeData.alias || '' : '';
    }
    get nodeWhereClause() {
        return this.nodeData ? this.nodeData.whereClause || '' : '';
    }
    get nodeOrderBy() {
        return this.nodeData ? this.nodeData.orderBy || '' : '';
    }
    get nodeLimitAmount() {
        return this.nodeData ? this.nodeData.limitAmount || '' : '';
    }

    // Parent rel data for template — filtered by global search
    get parentRelsList() {
        if (!this.nodeData || !this.nodeData.parentRels) return [];
        const gs = this.globalSearch;
        return this.nodeData.parentRels
            .filter(
                (pr) =>
                    !gs || pr.expanded || this._matchesSearch(pr, gs) || (pr.fields && pr.fields.some((f) => f.checked))
            )
            .map((pr) => {
                const selFields = pr.fields ? pr.fields.filter((f) => f.checked) : [];
                return {
                    ...pr,
                    selectedFields: selFields,
                    hasSelectedFields: selFields.length > 0,
                    selectedFieldCount: selFields.length,
                    pickerFields: pr.fields ? pr.fields.slice(0, 100) : []
                };
            });
    }

    // ── Relationship pickers ───────────────────────────────────
    @track _relPickerOpen = false;
    @track _relPickerSearch = '';
    @track _parentRelPickerOpen = false;
    @track _parentRelPickerSearch = '';

    toggleRelPicker() {
        this._relPickerOpen = !this._relPickerOpen;
        this._relPickerSearch = '';
        this._parentRelPickerOpen = false;
    }

    toggleParentPicker() {
        this._parentRelPickerOpen = !this._parentRelPickerOpen;
        this._parentRelPickerSearch = '';
        this._relPickerOpen = false;
    }

    handleRelPickerSearch(event) {
        this._relPickerSearch = (event.target.value || '').toLowerCase();
    }

    handleParentRelPickerSearch(event) {
        this._parentRelPickerSearch = (event.target.value || '').toLowerCase();
    }

    get showRelPicker() {
        return this._relPickerOpen;
    }
    get showParentPicker() {
        return this._parentRelPickerOpen;
    }

    get filteredChildRels() {
        if (!this.nodeData || !this.nodeData.childRels) return [];
        const s = this._relPickerSearch;
        // Dedupe by relationship value so each appears once in the picker.
        // We always show every relationship (even ones already expanded) —
        // clicking again creates a filtered-subset slot rather than toggling
        // the existing one.
        const seen = new Set();
        return this.nodeData.childRels
            .filter((cr) => {
                if (seen.has(cr.value)) return false;
                seen.add(cr.value);
                return true;
            })
            .filter((cr) => !s || cr.displayLabel.toLowerCase().includes(s) || cr.value.toLowerCase().includes(s))
            .slice(0, 50);
    }

    get filteredParentRels() {
        if (!this.nodeData || !this.nodeData.parentRels) return [];
        const s = this._parentRelPickerSearch;
        return this.nodeData.parentRels
            .filter((pr) => !pr.expanded)
            .filter((pr) => !s || pr.displayLabel.toLowerCase().includes(s) || pr.value.toLowerCase().includes(s))
            .slice(0, 50);
    }

    handleExpandChildFromPicker(event) {
        this._relPickerOpen = false;
        this.handleExpandChild(event);
    }

    handleExpandParentFromPicker(event) {
        this._parentRelPickerOpen = false;
        this.handleExpandParent(event);
    }

    // Active rels (expanded ones only — shown above the pickers)
    get activeParentRels() {
        return this.parentRelsList.filter((pr) => pr.expanded || pr.hasSelectedFields);
    }

    get activeChildRels() {
        if (!this.nodeData || !this.nodeData.childRels) return [];
        return this.nodeData.childRels.filter((cr) => cr.expanded);
    }

    _matchesSearch(rel, search) {
        return (
            (rel.displayLabel && rel.displayLabel.toLowerCase().includes(search)) ||
            (rel.value && rel.value.toLowerCase().includes(search)) ||
            (rel.label && rel.label.toLowerCase().includes(search))
        );
    }

    // Child rel data for template — filtered by global search.
    // Each rendered entry gets a unique `slotKey` (= _slotKey for filtered
    // subsets, else cr.value) used as the LWC list key and as the data-rel
    // discriminator for slot-aware operations like remove.
    get childRels() {
        if (!this.nodeData || !this.nodeData.childRels) return [];
        const gs = this.globalSearch;
        return this.nodeData.childRels
            .filter((cr) => !gs || cr.expanded || this._matchesSearch(cr, gs))
            .map((cr) => {
                const count = cr.nodeData ? this._countNodeFields(cr.nodeData) : 0;
                return {
                    ...cr,
                    slotKey: cr._slotKey || cr.value,
                    hasSelectedCount: count > 0,
                    selectedCount: count,
                    nextDepth: parseInt(this.depth, 10) + 1,
                    icon: cr.expanded ? 'utility:chevrondown' : 'utility:chevronright'
                };
            });
    }

    _countNodeFields(nd) {
        if (!nd) return 0;
        let c = 0;
        if (nd.fields) {
            for (const f of nd.fields) {
                if (f.checked) c++;
            }
        }
        if (nd.parentRels) {
            for (const pr of nd.parentRels) {
                if (pr.fields) {
                    for (const f of pr.fields) {
                        if (f.checked) c++;
                    }
                }
            }
        }
        return c;
    }

    // Bubble handlers (events from nested child nodes just pass through via composed)
    handleChildFieldBubble() {}
    handleChildParentFieldBubble() {}
    handleChildExpandBubble() {}
    handleChildParentExpandBubble() {}
    handleChildClauseBubble() {}
    handleChildRemoveChildBubble() {}
    handleChildRemoveParentBubble() {}

    // Hover effect
    _hoverIn(event) {
        event.currentTarget.style.backgroundColor = '#f5f5f5';
    }
    _hoverOut(event) {
        event.currentTarget.style.backgroundColor = '';
    }
}

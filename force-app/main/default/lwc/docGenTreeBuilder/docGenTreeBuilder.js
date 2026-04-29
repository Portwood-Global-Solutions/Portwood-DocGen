import { LightningElement, track, api } from 'lwc';
import getObjectFields from '@salesforce/apex/DocGenController.getObjectFields';
import getChildRelationships from '@salesforce/apex/DocGenController.getChildRelationships';
import getParentRelationships from '@salesforce/apex/DocGenController.getParentRelationships';
import { parseSOQLFields } from 'c/docGenUtils';

/**
 * Tree-based visual query builder. Renders a recursive tree of nodes —
 * each node shows selected field pills, a compact field picker, parent
 * lookup folders, and child relationship folders. Same component pattern
 * at every level. Outputs a flat SOQL-style field string.
 */
export default class DocGenTreeBuilder extends LightningElement {
    // ── API ──────────────────────────────────────────────────────
    @api
    get selectedObject() {
        return this._selectedObject;
    }
    set selectedObject(val) {
        if (val && val !== this._selectedObject) {
            this._selectedObject = val;
            this._initRoot();
        }
    }
    _selectedObject;

    @api
    get queryConfig() {
        return this._buildQueryString();
    }
    set queryConfig(val) {
        // Round-trip / interaction guard: skip parsing when (a) the parent is
        // re-binding the same string we just emitted, or (b) the user is
        // actively typing/clicking inside the builder. Without this, every
        // keystroke triggers a parent re-bind that wipes _root and re-creates
        // the input, blowing away cursor position.
        if (val === this._lastEmittedConfig) {
            return;
        }
        if (this._userInteracting) {
            return;
        }
        this._pendingConfig = val;
        if (this._rootLoaded) {
            this._parseIncoming(val);
        }
    }

    // ── Internal state ──────────────────────────────────────────
    @track _root = null; // root node data
    @track _globalSearch = '';
    _rootLoaded = false;
    _pendingConfig = null;
    _suppressNotify = false;
    _schemaCache = {};

    handleGlobalSearch(event) {
        this._globalSearch = (event.target.value || '').toLowerCase();
    }

    get globalSearch() {
        return this._globalSearch;
    }

    // ── Root init ───────────────────────────────────────────────
    async _initRoot() {
        const obj = this._selectedObject;
        if (!obj) return;
        const schema = await this._loadSchema(obj);
        this._root = this._makeNode('root', obj, obj, schema, false);
        this._rootLoaded = true;
        if (this._pendingConfig) {
            await this._parseIncoming(this._pendingConfig);
            this._pendingConfig = null;
        }
        this._refresh();
    }

    _makeNode(path, objectName, objectLabel, schema, isChild) {
        return {
            path,
            objectName,
            objectLabel,
            isChild,
            fields: schema.fields.map((f) => ({
                apiName: f.value,
                displayLabel: this._extractLabel(f.label),
                type: f.type,
                label: f.label,
                checked: false
            })),
            parentRels: schema.parents.map((p) => ({
                value: p.value,
                displayLabel: this._extractLabel(p.label),
                label: p.label,
                targetObject: p.targetObject,
                icon: 'utility:chevronright',
                expanded: false,
                fields: null // lazy
            })),
            childRels: schema.children.map((c) => ({
                value: c.value,
                displayLabel: this._extractRelLabel(c.label),
                label: c.label,
                childObjectApiName: c.childObjectApiName,
                lookupField: c.lookupField,
                icon: 'utility:chevronright',
                expanded: false,
                nodeData: null, // lazy
                hasNode: false
            })),
            alias: '', // optional override for the merge-tag name on this loop ({#Alias}…{/Alias})
            whereClause: '',
            orderBy: '',
            limitAmount: ''
        };
    }

    // ── Schema cache ────────────────────────────────────────────
    async _loadSchema(objectName) {
        if (this._schemaCache[objectName]) return this._schemaCache[objectName];
        const [fields, children, parents] = await Promise.all([
            getObjectFields({ objectName }),
            getChildRelationships({ objectName }),
            getParentRelationships({ objectName })
        ]);
        const schema = { fields, children, parents };
        this._schemaCache[objectName] = schema;
        return schema;
    }

    // ── Event handlers (from tree nodes) ────────────────────────
    handleNodeFieldToggle(event) {
        event.stopPropagation();
        const { path, fieldName } = event.detail;
        const node = this._resolveNode(path);
        if (!node) return;
        const field = node.fields.find((f) => f.apiName === fieldName);
        if (field) {
            field.checked = !field.checked;
        }
        this._refresh();
        this._notifyChange();
    }

    handleNodeParentFieldToggle(event) {
        event.stopPropagation();
        const { path, relName, fieldName } = event.detail;
        const node = this._resolveNode(path);
        if (!node) return;
        const pr = node.parentRels.find((p) => p.value === relName);
        if (!pr || !pr.fields) return;
        const field = pr.fields.find((f) => f.apiName === fieldName);
        if (field) {
            field.checked = !field.checked;
        }
        this._refresh();
        this._notifyChange();
    }

    async handleNodeExpandChild(event) {
        event.stopPropagation();
        const { path, relName } = event.detail;
        const node = this._resolveNode(path);
        if (!node) return;

        // If any slot for this relationship is already expanded, picking it
        // again from the picker spawns a NEW filtered-subset slot instead of
        // toggling the existing one. The new slot inherits schema from the
        // primary cr, gets a unique _slotKey, and is pre-expanded so the
        // user lands directly in the editor for the new loop.
        const alreadyExpanded = node.childRels.some((c) => c.value === relName && c.expanded);
        if (alreadyExpanded) {
            const sourceCr = node.childRels.find((c) => c.value === relName);
            if (!sourceCr) return;
            const existingCount = node.childRels.filter((c) => c.value === relName).length;
            const dupIdx = existingCount + 1;
            const slotKey = relName + '#' + dupIdx;
            const schema = await this._loadSchema(sourceCr.childObjectApiName);
            const childPath = path + '.child:' + slotKey;
            const newNodeData = this._makeNode(
                childPath,
                sourceCr.childObjectApiName,
                sourceCr.displayLabel,
                schema,
                true
            );
            newNodeData.alias = relName + dupIdx; // suggested alias — user overwrites in Tag name input
            node.childRels.push({
                value: relName,
                _slotKey: slotKey, // unique within sibling set; primary slot has no _slotKey
                displayLabel: sourceCr.displayLabel + ' (filtered #' + dupIdx + ')',
                label: sourceCr.label,
                childObjectApiName: sourceCr.childObjectApiName,
                lookupField: sourceCr.lookupField,
                icon: 'utility:chevrondown',
                expanded: true,
                nodeData: newNodeData,
                hasNode: true
            });
            this._refresh();
            this._notifyChange();
            return;
        }

        // Primary expansion (or collapse) of an unexpanded slot.
        const cr = node.childRels.find((c) => c.value === relName);
        if (!cr) return;
        if (cr.expanded) {
            cr.expanded = false;
            cr.icon = 'utility:chevronright';
        } else {
            if (!cr.nodeData) {
                const schema = await this._loadSchema(cr.childObjectApiName);
                const childPath = path + '.child:' + relName;
                cr.nodeData = this._makeNode(childPath, cr.childObjectApiName, cr.displayLabel, schema, true);
                cr.hasNode = true;
            }
            cr.expanded = true;
            cr.icon = 'utility:chevrondown';
        }
        this._refresh();
    }

    async handleNodeExpandParent(event) {
        event.stopPropagation();
        const { path, relName } = event.detail;
        const node = this._resolveNode(path);
        if (!node) return;
        const pr = node.parentRels.find((p) => p.value === relName);
        if (!pr) return;

        if (pr.expanded) {
            pr.expanded = false;
            pr.icon = 'utility:chevronright';
        } else {
            if (!pr.fields) {
                const schema = await this._loadSchema(pr.targetObject);
                pr.fields = schema.fields.map((f) => ({
                    apiName: f.value,
                    displayLabel: this._extractLabel(f.label),
                    label: f.label,
                    type: f.type,
                    checked: false
                }));
            }
            pr.expanded = true;
            pr.icon = 'utility:chevrondown';
        }
        this._refresh();
    }

    handleNodeRemoveChild(event) {
        event.stopPropagation();
        const { path, relName } = event.detail;
        const node = this._resolveNode(path);
        if (!node) return;
        // relName here is actually the slotKey from the rendered cr
        // (= _slotKey for duplicates, cr.value for primary).
        const cr = node.childRels.find((c) => (c._slotKey || c.value) === relName);
        if (!cr) return;
        if (cr._slotKey) {
            // Filtered-subset slot: pop entirely so the relationship can be
            // re-duplicated without conflicting with the popped slotKey.
            node.childRels = node.childRels.filter((c) => c !== cr);
        } else {
            // Primary slot: collapse + clear (existing behavior — preserves the
            // schema-derived entry so the relationship can be re-expanded).
            cr.expanded = false;
            cr.icon = 'utility:chevronright';
            cr.nodeData = null;
            cr.hasNode = false;
        }
        this._refresh();
        this._notifyChange();
    }

    handleNodeRemoveParent(event) {
        event.stopPropagation();
        const { path, relName } = event.detail;
        const node = this._resolveNode(path);
        if (!node) return;
        const pr = node.parentRels.find((p) => p.value === relName);
        if (!pr) return;
        // Collapse and uncheck all fields
        pr.expanded = false;
        pr.icon = 'utility:chevronright';
        if (pr.fields) {
            for (const f of pr.fields) {
                f.checked = false;
            }
        }
        this._refresh();
        this._notifyChange();
    }

    handleNodeClauseChange(event) {
        event.stopPropagation();
        const { path, field, value } = event.detail;
        const node = this._resolveNode(path);
        if (node) {
            node[field] = value;
        }
        this._markInteracting();
        this._notifyChange();
    }

    // Set when the user is actively editing inside the builder. Cleared after
    // a short idle window. While set, the @api queryConfig setter ignores
    // round-trip rebinds from the parent — preserving input focus.
    _markInteracting() {
        this._userInteracting = true;
        if (this._interactionTimer) {
            clearTimeout(this._interactionTimer);
        }
        this._interactionTimer = setTimeout(() => {
            this._userInteracting = false;
        }, 600);
    }

    // ── Node resolution ─────────────────────────────────────────
    _resolveNode(pathStr) {
        if (!this._root || !pathStr) return null;
        const parts = pathStr.split('.');
        let node = this._root;
        for (let i = 1; i < parts.length; i++) {
            const part = parts[i];
            if (part.startsWith('child:')) {
                const seg = part.substring(6);
                // seg is either RelName (primary slot) or RelName#N (filtered subset).
                // Match _slotKey first, then fall back to value for primaries.
                const cr = node.childRels.find((c) => (c._slotKey || c.value) === seg);
                if (cr && cr.nodeData) {
                    node = cr.nodeData;
                } else return null;
            }
        }
        return node;
    }

    // ── Build query string ──────────────────────────────────────
    // Emits V1 flat SOQL by default. When ANY child node has an alias set
    // (i.e. the user wants a custom merge-tag name for a loop), switches
    // to V3 JSON since V1 SOQL has no place to store an alias.
    _buildQueryString() {
        if (!this._root) return '';
        if (this._anyNodeHasAlias(this._root)) {
            return this._buildV3Json();
        }
        const parts = [];
        this._collectFields(this._root, parts);
        return parts.join(', ');
    }

    _anyNodeHasAlias(node) {
        if (node.alias && node.alias.trim()) return true;
        // Duplicate-slot relationships (filtered subsets) can't be expressed
        // in V1 SOQL — flag them so emit switches to V3 JSON.
        const seen = new Set();
        for (const cr of node.childRels) {
            if (!cr.nodeData) continue;
            if (seen.has(cr.value)) return true;
            seen.add(cr.value);
            if (this._anyNodeHasAlias(cr.nodeData)) return true;
        }
        return false;
    }

    _buildV3Json() {
        const nodes = [];
        let nextId = 0;
        const walk = (node, parentNodeId) => {
            const myId = 'n' + nextId++;
            const fields = node.fields.filter((f) => f.checked).map((f) => f.apiName);
            const parentFields = [];
            for (const pr of node.parentRels) {
                if (!pr.fields) continue;
                for (const f of pr.fields) {
                    if (f.checked) parentFields.push(pr.value + '.' + f.apiName);
                }
            }
            const n = {
                id: myId,
                object: node.objectName,
                fields,
                parentFields,
                parentNode: parentNodeId,
                lookupField: null,
                relationshipName: null
            };
            if (parentNodeId !== null) {
                // Child node — derive relationship name from path. Path's last
                // segment is "child:RelName" or "child:RelName#N" — strip the
                // "#N" filtered-subset discriminator to get the actual rel name.
                const lastSeg = node.path.split('.').pop();
                const slotKey = lastSeg.startsWith('child:') ? lastSeg.substring(6) : lastSeg;
                const relName = slotKey.split('#')[0];
                n.relationshipName = relName;
                // lookupField stored on the parent's childRels entry (primary or duplicate)
                const parentNode = this._findParentByChildPath(this._root, node.path);
                if (parentNode) {
                    const cr = parentNode.childRels.find((c) => (c._slotKey || c.value) === slotKey);
                    if (cr && cr.lookupField) n.lookupField = cr.lookupField;
                }
                if (node.alias && node.alias.trim()) n.alias = node.alias.trim();
                if (node.whereClause) n.where = node.whereClause;
                if (node.orderBy) n.orderBy = node.orderBy;
                if (node.limitAmount) n.limit = String(node.limitAmount);
            }
            nodes.push(n);
            for (const cr of node.childRels) {
                if (cr.nodeData) walk(cr.nodeData, myId);
            }
        };
        walk(this._root, null);
        return JSON.stringify({ v: 3, root: this._root.objectName, nodes });
    }

    _findParentByChildPath(searchNode, childPath) {
        for (const cr of searchNode.childRels) {
            if (cr.nodeData && cr.nodeData.path === childPath) return searchNode;
            if (cr.nodeData) {
                const found = this._findParentByChildPath(cr.nodeData, childPath);
                if (found) return found;
            }
        }
        return null;
    }

    _collectFields(node, parts) {
        // Base fields
        for (const f of node.fields) {
            if (f.checked) parts.push(f.apiName);
        }
        // Parent fields
        for (const pr of node.parentRels) {
            if (!pr.fields) continue;
            for (const f of pr.fields) {
                if (f.checked) parts.push(pr.value + '.' + f.apiName);
            }
        }
        // Child subqueries
        for (const cr of node.childRels) {
            if (!cr.nodeData) continue;
            const sub = this._buildSubquery(cr.nodeData);
            if (sub) parts.push(sub);
        }
    }

    _buildSubquery(node) {
        const fieldParts = [];
        this._collectFields(node, fieldParts);
        if (fieldParts.length === 0) return null;

        // Strip "child:" prefix and any "#N" filtered-subset suffix to get the
        // actual relationship name. Filtered-subset slots can't be expressed in
        // V1 SOQL, so duplicates rely on _anyNodeHasAlias triggering V3 emit upstream.
        const pathParts = node.path.split('.');
        const lastPart = pathParts[pathParts.length - 1];
        const slotKey = lastPart.startsWith('child:') ? lastPart.substring(6) : lastPart;
        const relName = slotKey.split('#')[0];
        let sq = '(SELECT ' + fieldParts.join(', ') + ' FROM ' + relName;
        if (node.whereClause) sq += ' WHERE ' + node.whereClause;
        if (node.orderBy) sq += ' ORDER BY ' + node.orderBy;
        if (node.limitAmount) sq += ' LIMIT ' + node.limitAmount;
        sq += ')';
        return sq;
    }

    // ── Parse incoming config ───────────────────────────────────
    async _parseIncoming(configStr) {
        if (!configStr || !this._root) return;
        this._suppressNotify = true;

        // V3 JSON: tree-shaped config. Walk nodes, expand each child's path,
        // restore alias + WHERE + ORDER + LIMIT.
        const trimmed = configStr.trim();
        if (trimmed.startsWith('{') && trimmed.includes('"v":3')) {
            try {
                const cfg = JSON.parse(trimmed);
                // Reset tree state so re-parsing the same config (e.g. when the
                // parent round-trips queryConfig after our configchange event)
                // doesn't keep spawning duplicate filtered-subset slots.
                const resetTree = (node) => {
                    if (!node) return;
                    // Drop filtered-subset slots; collapse primaries so the
                    // V3 walker re-claims them fresh.
                    node.childRels = node.childRels.filter((cr) => !cr._slotKey);
                    for (const cr of node.childRels) {
                        if (cr.nodeData) resetTree(cr.nodeData);
                        cr.expanded = false;
                        cr.icon = 'utility:chevronright';
                        cr.nodeData = null;
                        cr.hasNode = false;
                    }
                    node.alias = '';
                };
                resetTree(this._root);
                this._uncheckAll(this._root);
                const nodesById = {};
                for (const n of cfg.nodes || []) nodesById[n.id] = n;
                // Find root (parentNode null)
                const rootNode = (cfg.nodes || []).find((n) => !n.parentNode);
                if (rootNode) {
                    for (const fname of rootNode.fields || []) {
                        const f = this._root.fields.find((ff) => ff.apiName === fname);
                        if (f) f.checked = true;
                    }
                    for (const pf of rootNode.parentFields || []) {
                        const dotIdx = pf.indexOf('.');
                        if (dotIdx === -1) continue;
                        const relName = pf.substring(0, dotIdx);
                        const fName = pf.substring(dotIdx + 1);
                        const pr = this._root.parentRels.find((p) => p.value === relName);
                        if (pr) await this._expandAndCheckParentField(pr, fName);
                    }
                }
                // Expand children depth-first
                const expandChildren = async (parentJsonNode, parentTreeNode) => {
                    const kids = (cfg.nodes || []).filter((n) => n.parentNode === parentJsonNode.id);
                    for (const kid of kids) {
                        // Find an unclaimed slot for this relationship. Multiple kids
                        // with the same relationshipName (filtered subsets) land in
                        // separate slots — first claims primary, subsequent claim
                        // freshly-spawned filtered-subset slots.
                        let cr = parentTreeNode.childRels.find((c) => c.value === kid.relationshipName && !c.expanded);
                        if (!cr) {
                            const baseRels = parentTreeNode.childRels.filter((c) => c.value === kid.relationshipName);
                            if (baseRels.length === 0) continue; // schema doesn't expose this relationship
                            const tpl = baseRels[0];
                            const dupIdx = baseRels.length + 1;
                            cr = {
                                value: kid.relationshipName,
                                _slotKey: kid.relationshipName + '#' + dupIdx,
                                displayLabel: tpl.displayLabel + ' (filtered #' + dupIdx + ')',
                                label: tpl.label,
                                childObjectApiName: tpl.childObjectApiName,
                                lookupField: tpl.lookupField,
                                icon: 'utility:chevronright',
                                expanded: false,
                                nodeData: null,
                                hasNode: false
                            };
                            parentTreeNode.childRels.push(cr);
                        }
                        if (!cr.nodeData) {
                            const schema = await this._loadSchema(cr.childObjectApiName);
                            const slotKey = cr._slotKey || kid.relationshipName;
                            const childPath = parentTreeNode.path + '.child:' + slotKey;
                            cr.nodeData = this._makeNode(
                                childPath,
                                cr.childObjectApiName,
                                cr.displayLabel,
                                schema,
                                true
                            );
                            cr.hasNode = true;
                        }
                        cr.expanded = true;
                        cr.icon = 'utility:chevrondown';
                        cr.nodeData.alias = kid.alias || '';
                        cr.nodeData.whereClause = kid.where || '';
                        cr.nodeData.orderBy = kid.orderBy || '';
                        cr.nodeData.limitAmount = kid.limit || '';
                        for (const fname of kid.fields || []) {
                            const f = cr.nodeData.fields.find((ff) => ff.apiName === fname);
                            if (f) f.checked = true;
                        }
                        for (const pf of kid.parentFields || []) {
                            const dotIdx = pf.indexOf('.');
                            if (dotIdx === -1) continue;
                            const relName = pf.substring(0, dotIdx);
                            const fName = pf.substring(dotIdx + 1);
                            const pr = cr.nodeData.parentRels.find((p) => p.value === relName);
                            if (pr) await this._expandAndCheckParentField(pr, fName);
                        }
                        await expandChildren(kid, cr.nodeData);
                    }
                };
                await expandChildren(rootNode, this._root);
                this._suppressNotify = false;
                this._refresh();
                return;
            } catch (err) {
                // Fall through to V1 parsing on JSON error
            }
        }

        const parsed = parseSOQLFields(configStr);

        // Reset
        this._uncheckAll(this._root);

        // Check root base fields
        for (const fname of parsed.baseFields) {
            const f = this._root.fields.find((ff) => ff.apiName === fname);
            if (f) f.checked = true;
        }

        // Check root parent fields
        for (const pf of parsed.parentFields) {
            const dotIdx = pf.indexOf('.');
            if (dotIdx === -1) continue;
            const relName = pf.substring(0, dotIdx);
            const fieldName = pf.substring(dotIdx + 1);
            const pr = this._root.parentRels.find((p) => p.value === relName);
            if (pr) {
                await this._expandAndCheckParentField(pr, fieldName);
            }
        }

        // Expand child relationships
        for (const sq of parsed.subqueries) {
            await this._expandAndCheckChild(this._root, sq);
        }

        this._suppressNotify = false;
        this._refresh();
    }

    _uncheckAll(node) {
        for (const f of node.fields) {
            f.checked = false;
        }
        for (const pr of node.parentRels) {
            if (pr.fields) {
                for (const f of pr.fields) {
                    f.checked = false;
                }
            }
        }
        for (const cr of node.childRels) {
            if (cr.nodeData) {
                this._uncheckAll(cr.nodeData);
            }
        }
    }

    async _expandAndCheckParentField(parentRel, fieldName) {
        if (!parentRel.fields) {
            const schema = await this._loadSchema(parentRel.targetObject);
            parentRel.fields = schema.fields.map((f) => ({
                apiName: f.value,
                displayLabel: this._extractLabel(f.label),
                label: f.label,
                type: f.type,
                checked: false
            }));
        }
        parentRel.expanded = true;
        parentRel.icon = 'utility:chevrondown';
        const field = parentRel.fields.find((f) => f.apiName === fieldName);
        if (field) field.checked = true;
    }

    async _expandAndCheckChild(parentNode, subquery) {
        const cr = parentNode.childRels.find((c) => c.value === subquery.relationshipName);
        if (!cr) return;

        if (!cr.nodeData) {
            const schema = await this._loadSchema(cr.childObjectApiName);
            const childPath = parentNode.path + '.child:' + subquery.relationshipName;
            cr.nodeData = this._makeNode(childPath, cr.childObjectApiName, cr.displayLabel, schema, true);
            cr.hasNode = true;
        }
        cr.expanded = true;
        cr.icon = 'utility:chevrondown';

        cr.nodeData.whereClause = subquery.whereClause || '';
        cr.nodeData.orderBy = subquery.orderBy || '';
        cr.nodeData.limitAmount = subquery.limitAmount || '';

        for (const fieldName of subquery.fields) {
            if (fieldName.includes('.')) {
                const dotIdx = fieldName.indexOf('.');
                const relName = fieldName.substring(0, dotIdx);
                const fName = fieldName.substring(dotIdx + 1);
                const pr = cr.nodeData.parentRels.find((p) => p.value === relName);
                if (pr) {
                    await this._expandAndCheckParentField(pr, fName);
                }
            } else {
                const f = cr.nodeData.fields.find((ff) => ff.apiName === fieldName);
                if (f) f.checked = true;
            }
        }

        if (subquery.children) {
            for (const nested of subquery.children) {
                await this._expandAndCheckChild(cr.nodeData, nested);
            }
        }
    }

    // ── Helpers ──────────────────────────────────────────────────
    _extractLabel(rawLabel) {
        if (!rawLabel) return '';
        const idx = rawLabel.lastIndexOf('(');
        return idx > 0 ? rawLabel.substring(0, idx).trim() : rawLabel;
    }

    _extractRelLabel(rawLabel) {
        if (!rawLabel) return '';
        const idx = rawLabel.lastIndexOf('(');
        return idx > 0
            ? rawLabel
                  .substring(idx + 1)
                  .replace(')', '')
                  .trim()
            : rawLabel;
    }

    _refresh() {
        // Deep clone to force LWC reactivity at all nesting depths.
        // Node data is plain objects (no functions/circular refs) so JSON round-trip is safe.
        this._root = this._root ? JSON.parse(JSON.stringify(this._root)) : null;
    }

    _notifyChange() {
        if (this._suppressNotify) return;
        const cfg = this._buildQueryString();
        // Record what we just emitted so the @api queryConfig setter can
        // recognize a same-value round-trip from the parent and skip re-parsing.
        this._lastEmittedConfig = cfg;
        this.dispatchEvent(
            new CustomEvent('configchange', {
                detail: {
                    objectName: this._selectedObject,
                    queryConfig: cfg
                }
            })
        );
    }

    // ── Template getters ────────────────────────────────────────
    get hasRoot() {
        return !!this._root;
    }

    get rootNodeData() {
        return this._root;
    }

    get selectedCount() {
        if (!this._root) return 0;
        return this._countAll(this._root);
    }

    _countAll(node) {
        let c = 0;
        for (const f of node.fields) {
            if (f.checked) c++;
        }
        for (const pr of node.parentRels) {
            if (pr.fields) {
                for (const f of pr.fields) {
                    if (f.checked) c++;
                }
            }
        }
        for (const cr of node.childRels) {
            if (cr.nodeData) c += this._countAll(cr.nodeData);
        }
        return c;
    }
}

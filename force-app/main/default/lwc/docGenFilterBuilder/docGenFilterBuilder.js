import { LightningElement, api, track, wire } from 'lwc';
import getObjectFields from '@salesforce/apex/DocGenController.getObjectFields';

export default class DocGenFilterBuilder extends LightningElement {
    @api objectName;
    @api value = ''; // Initial SOQL string

    @track rows = [];
    @track fieldOptions = [];
    @track isLoading = false;

    logicOptions = [
        { label: 'AND', value: 'AND' },
        { label: 'OR', value: 'OR' }
    ];

    operatorOptions = [
        { label: 'Equals (=)', value: '=' },
        { label: 'Not Equals (!=)', value: '!=' },
        { label: 'Starts With', value: 'LIKE_START' }, // Maps to LIKE 'Val%'
        { label: 'Includes', value: 'LIKE' }, // Maps to LIKE '%Val%'
        { label: 'Greater Than (>)', value: '>' },
        { label: 'Less Than (<)', value: '<' },
        { label: 'In List (IN)', value: 'IN' }
    ];

    @wire(getObjectFields, { objectName: '$objectName' })
    wiredFields({ error, data }) {
        this.isLoading = true;
        if (data) {
            this.fieldOptions = data;
            // Initialize if empty?
            if (this.rows.length === 0 && !this.value) {
                this.handleAddRow();
            }
        } else if (error) {
            // Field loading error handled silently; fieldOptions stays empty
        }
        this.isLoading = false;
    }

    connectedCallback() {
        // Parse initial value (Basic parsing)
        // If complex, dumping to manual mode might be safer or just showing it in Text Area.
        // For now, start with 1 row if empty.
        if (this.rows.length === 0 && !this.value) {
            this.handleAddRow();
        }
    }

    handleAddRow() {
        this.rows.push({
            id: Date.now() + Math.random(),
            logic: 'AND',
            field: '',
            operator: '=',
            value: ''
        });
    }

    handleRemoveRow(event) {
        const index = event.target.dataset.index;
        this.rows.splice(index, 1);
        this.generateSoql();
    }

    handleFieldChange(event) {
        const index = event.target.dataset.index;
        this.rows[index].field = event.detail.value;
        this.generateSoql();
    }

    handleOperatorChange(event) {
        const index = event.target.dataset.index;
        this.rows[index].operator = event.detail.value;
        this.generateSoql();
    }

    handleLogicChange(event) {
        const index = event.target.dataset.index;
        this.rows[index].logic = event.detail.value;
        this.generateSoql();
    }

    handleValueChange(event) {
        const index = event.target.dataset.index;
        this.rows[index].value = event.detail.value;
        this.generateSoql();
    }

    // --- Generation ---
    _generatedSoql = '';

    get generatedSoql() {
        return this._generatedSoql;
    }
    set generatedSoql(val) {
        // Allow manual override
        this._generatedSoql = val;
    }

    generateSoql() {
        if (!this.rows || this.rows.length === 0) {
            this._generatedSoql = '';
            this.notifyChange();
            return;
        }

        // Build field type lookup from field options
        const fieldTypeMap = {};
        (this.fieldOptions || []).forEach((f) => {
            if (f.value && f.type) fieldTypeMap[f.value] = f.type;
        });

        const dateLiterals = [
            'TODAY',
            'YESTERDAY',
            'TOMORROW',
            'LAST_WEEK',
            'THIS_WEEK',
            'NEXT_WEEK',
            'LAST_MONTH',
            'THIS_MONTH',
            'NEXT_MONTH',
            'LAST_QUARTER',
            'THIS_QUARTER',
            'NEXT_QUARTER',
            'LAST_YEAR',
            'THIS_YEAR',
            'NEXT_YEAR',
            'LAST_90_DAYS',
            'NEXT_90_DAYS',
            'LAST_N_DAYS',
            'NEXT_N_DAYS'
        ];

        let soql = '';
        this.rows.forEach((row, index) => {
            if (!row.field) return; // Skip incomplete

            if (index > 0) {
                soql += ` ${row.logic} `;
            }

            let val = row.value;
            let op = row.operator;
            const fieldType = fieldTypeMap[row.field] || '';

            // Handle LIKE helpers
            if (op === 'LIKE_START') {
                op = 'LIKE';
                if (val && !val.includes('%')) val = `${val}%`;
                if (val && !val.startsWith("'")) val = `'${val}'`;
            } else if (op === 'LIKE') {
                if (val && !val.includes('%')) val = `%${val}%`;
                if (val && !val.startsWith("'")) val = `'${val}'`;
            } else if (op === 'IN') {
                if (val && !val.startsWith('(')) val = `(${val})`;
            } else {
                // Type-aware value formatting
                const upper = (val || '').toUpperCase();
                const isDateLiteral = dateLiterals.some((d) => upper === d || upper.startsWith(d + ':'));
                const isNLiteral = upper.startsWith('LAST_N_') || upper.startsWith('NEXT_N_');
                const isDateFormat = /^\d{4}-\d{2}-\d{2}$/.test(val);
                const isDateTimeFormat = /^\d{4}-\d{2}-\d{2}T/.test(val);

                if (isDateLiteral || isNLiteral) {
                    // Date literals: unquoted (TODAY, LAST_N_DAYS:30, etc.)
                } else if (fieldType === 'DATETIME' && isDateFormat) {
                    // Datetime field with date-only value: append time component
                    val = val + 'T00:00:00Z';
                } else if (fieldType === 'DATE' && isDateFormat) {
                    // Date field with date value: use as-is, unquoted
                } else if (isDateTimeFormat) {
                    // Already has time component: use as-is, unquoted
                } else if (
                    val &&
                    !val.startsWith("'") &&
                    !val.endsWith("'") &&
                    isNaN(val) &&
                    val !== 'true' &&
                    val !== 'false' &&
                    val !== 'null'
                ) {
                    val = `'${val}'`;
                }
            }

            soql += `${row.field} ${op} ${val}`;
        });

        this._generatedSoql = soql;
        this.notifyChange();
    }

    handleManualSoqlChange(event) {
        this._generatedSoql = event.detail.value;
        this.notifyChange();
    }

    notifyChange() {
        this.dispatchEvent(
            new CustomEvent('change', {
                detail: { value: this._generatedSoql }
            })
        );
    }
}

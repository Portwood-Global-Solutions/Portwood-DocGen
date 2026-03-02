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

        let soql = '';
        this.rows.forEach((row, index) => {
            if (!row.field) return; // Skip incomplete
            
            if (index > 0) {
                soql += ` ${row.logic} `;
            }
            
            let val = row.value;
            let op = row.operator;
            
            // Handle LIKE helpers
            if (op === 'LIKE_START') {
                 op = 'LIKE';
                 if (val && !val.includes('%')) val = `${val}%`;
                 if (val && !val.startsWith("'")) val = `'${val}'`; // Quote check
            } else if (op === 'LIKE') {
                 // Check if it's strictly the "Includes" helper or raw LIKE
                 // If value has %, assume raw. If not, wrap.
                 if (val && !val.includes('%')) val = `%${val}%`;
                 if (val && !val.startsWith("'")) val = `'${val}'`;
            } else if (op === 'IN') {
                 if (val && !val.startsWith('(')) val = `(${val})`;
            } else {
                 // Standard quoting heuristic
                 // Numeric? Boolean? String? 
                 // Simple check: if not quoted and likely string
                 if (val && !val.startsWith("'") && !val.endsWith("'") && isNaN(val) && val !== 'true' && val !== 'false' && val !== 'null') {
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
        this.dispatchEvent(new CustomEvent('change', {
            detail: { value: this._generatedSoql }
        }));
    }
}
import { LightningElement, api, track } from 'lwc';

export default class DocGenTitleEditor extends LightningElement {
    @api
    get value() {
        return this._value;
    }
    set value(val) {
        this._value = val;
    }
    @track _value = '';

    @api queryConfig = '';

    @track showSuggestions = false;
    @track suggestions = [];

    // Internal state for tokenizer
    cursorPos = 0;

    handleInput(event) {
        this._value = event.detail.value;
        this.notifyChange();

        // Simple Logic: check if the last token being typed starts with {
        // We find the last '{' before cursor.
        // Actually, lightning-input doesn't give cursor position easily in onchange event detail,
        // but we can try to guess or use basic substring.
        // Better: Use the Input Element to get cursor.

        // Note: LWC lightning-input doesn't expose selectionStart directly easily in all versions,
        // but usually we can check value logic.
        // Let's assume user is typing at end or we check the whole string for an open brace without close brace at the end?

        // Robust strategy: Check if value ends with `{` or `{partial`.
        // We will regex search for `\{[a-zA-Z0-9_\.]*$`

        const text = this._value;
        const match = text.match(/\{([a-zA-Z0-9_.]*$)/);

        if (match) {
            const keys = this.parseFields();
            const term = match[1].toLowerCase();

            this.suggestions = keys.filter((k) => k.toLowerCase().includes(term));
            this.showSuggestions = true;
        } else {
            this.showSuggestions = false;
        }
    }

    handleFocus() {
        // Optional: show suggestions if cursor at end of { ?
    }

    handleBlur() {
        // Delay hide to allow click
        // But mousedown on dropdown prevents blur usually if we handle it right.
        // We'll use a timeout or check relatedTarget.
        setTimeout(() => {
            this.showSuggestions = false;
        }, 200);
    }

    handleDropdownMouseDown(event) {
        // Prevent blur
        event.preventDefault();
    }

    handleSelectSuggestion(event) {
        const fieldName = event.currentTarget.dataset.value;

        // Replace the last match
        // We know it ends with `{partial`
        const text = this._value;
        const lastBraceIndex = text.lastIndexOf('{');
        if (lastBraceIndex >= 0) {
            const prefix = text.substring(0, lastBraceIndex);
            // We replace everything after last brace
            this._value = prefix + '{' + fieldName + '}';
            this.notifyChange();
        }

        this.showSuggestions = false;

        // Refocus (though we might have lost it)
        // this.template.querySelector('lightning-input').focus();
        // focus() might fail if not rendered or timing.
    }

    notifyChange() {
        this.dispatchEvent(
            new CustomEvent('change', {
                detail: { value: this._value }
            })
        );
    }

    parseFields() {
        if (!this.queryConfig) return [];

        // Basic parser: Split by comma, ignore subqueries `(SELECT ...)`
        // 1. Remove subqueries
        const clean = this.queryConfig.replace(/\(SELECT.*?\)/gi, '');

        // 2. Split
        const tokens = clean.split(',');

        // 3. Trim and Filter
        const fields = tokens.map((t) => t.trim()).filter((t) => t && !t.startsWith('(')); // Double check

        return fields;
    }

    get hasSuggestions() {
        return this.suggestions && this.suggestions.length > 0;
    }
}

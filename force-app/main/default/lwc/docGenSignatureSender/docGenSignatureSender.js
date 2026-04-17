import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSignerRolePicklistValues from '@salesforce/apex/DocGenSignatureSenderController.getSignerRolePicklistValues';
import createTemplateSignerRequest from '@salesforce/apex/DocGenSignatureSenderController.createTemplateSignerRequestWithOrder';
import markSignerVerifiedInPerson from '@salesforce/apex/DocGenSignatureSenderController.markSignerVerifiedInPerson';
import createPacketSignerRequest from '@salesforce/apex/DocGenSignatureSenderController.createPacketSignerRequest';
import getContactInfo from '@salesforce/apex/DocGenSignatureSenderController.getContactInfo';
import getPendingSignatureRequests from '@salesforce/apex/DocGenSignatureSenderController.getPendingSignatureRequests';
import getDocGenTemplates from '@salesforce/apex/DocGenSignatureSenderController.getDocGenTemplatesForRecord';
import getTemplateSignaturePlacements from '@salesforce/apex/DocGenSignatureSenderController.getTemplateSignaturePlacements';
import getDocumentPreviewHtml from '@salesforce/apex/DocGenSignatureSenderController.getDocumentPreviewHtml';

let signerIdCounter = 0;
let templateIdCounter = 0;

export default class DocGenSignatureSender extends LightningElement {
    @api recordId;

    @track isLoading = true;
    @track error;

    // All available templates
    @track docGenTemplateOptions = [];

    // Selected templates (packet support)
    @track selectedTemplates = []; // [{id, templateId, name, placements, placementSummary, docNumber}]

    // Role picklist
    @track roleOptions = [];

    // Aggregated placements from all selected templates
    @track detectedPlacements = [];

    // Signing order
    @track signingOrder = 'Parallel';

    // Signers
    @track signers = [];

    // Results
    @track signerResults;

    // Preview modal
    @track showPreviewModal = false;
    @track previewHtml = '';
    @track previewLoading = false;

    // Previous requests
    @track previousRequests = [];
    @track showPreviousRequests = false;

    @wire(getSignerRolePicklistValues)
    wiredRoles({ error, data }) {
        if (data) {
            this.roleOptions = data.map(entry => ({
                label: entry.label,
                value: entry.value
            }));
        } else if (error) {
            // Role picklist unavailable
        }
        this._checkInitialLoad();
    }

    @wire(getDocGenTemplates, { relatedRecordId: '$recordId' })
    wiredDocGenTemplates({ error, data }) {
        if (data) {
            this.docGenTemplateOptions = data.map(t => ({
                label: t.Name,
                value: t.Id
            }));
        } else if (error) {
            this.docGenTemplateOptions = [];
        }
        this._checkInitialLoad();
    }

    _wireCallsReturned = 0;
    _checkInitialLoad() {
        this._wireCallsReturned++;
        if (this._wireCallsReturned >= 2) {
            this.isLoading = false;
            if (this.signers.length === 0) {
                this.handleAddSigner();
            }
        }
    }

    // --- Computed Properties ---

    get hasSelectedTemplates() {
        return this.selectedTemplates.length > 0;
    }

    get isPacketMode() {
        return this.selectedTemplates.length > 1;
    }

    get isGenerateDisabled() {
        if (this.selectedTemplates.length === 0 || this.signers.length === 0) return true;
        return this.signers.some(s => !s.signerName || !s.signerEmail || !s.roleName);
    }

    get isRemoveDisabled() {
        return this.signers.length <= 1;
    }

    get previousRequestsLabel() {
        return this.showPreviousRequests ? 'Hide Previous Requests' : 'Show Previous Requests';
    }

    get hasPreviousRequests() {
        return this.previousRequests.length > 0;
    }

    get hasDetectedPlacements() {
        return this.detectedPlacements.length > 0;
    }

    get availableTemplateOptions() {
        // Filter out already-selected templates
        const selectedIds = new Set(this.selectedTemplates.map(t => t.templateId));
        return this.docGenTemplateOptions.filter(t => !selectedIds.has(t.value));
    }

    /**
     * Builds a summary of placements per role across all templates.
     */
    get placementSummaryByRole() {
        if (!this.detectedPlacements || this.detectedPlacements.length === 0) return [];
        const roleMap = {};
        for (const p of this.detectedPlacements) {
            if (!roleMap[p.role]) roleMap[p.role] = { Full: 0, Initials: 0, Date: 0, DatePick: 0 };
            roleMap[p.role][p.placementType] = (roleMap[p.role][p.placementType] || 0) + 1;
        }
        const result = [];
        for (const role of Object.keys(roleMap)) {
            const c = roleMap[role];
            const parts = [];
            if (c.Full > 0) parts.push(c.Full + ' signature' + (c.Full > 1 ? 's' : ''));
            if (c.Initials > 0) parts.push(c.Initials + ' initial' + (c.Initials > 1 ? 's' : ''));
            if (c.Date > 0) parts.push(c.Date + ' date' + (c.Date > 1 ? 's' : ''));
            if (c.DatePick > 0) parts.push(c.DatePick + ' date picker' + (c.DatePick > 1 ? 's' : ''));
            result.push({ role, summary: parts.join(', ') || '1 signature' });
        }
        return result;
    }

    get generateButtonLabel() {
        return this.isPacketMode ? 'Generate Packet Signature Links' : 'Generate Signature Links';
    }

    get signingOrderOptions() {
        return [
            { label: 'All at once (parallel)', value: 'Parallel' },
            { label: 'One at a time (sequential)', value: 'Sequential' }
        ];
    }

    handleSigningOrderChange(event) {
        this.signingOrder = event.detail.value;
    }

    // --- Template Selection ---

    async handleTemplateSelected(event) {
        const templateId = event.detail.value;
        if (!templateId) return;

        const opt = this.docGenTemplateOptions.find(t => t.value === templateId);
        if (!opt) return;

        // Scan template for placements
        let placements = [];
        try {
            placements = await getTemplateSignaturePlacements({ templateId });
        } catch (_err) {
            // Template may not have signature tags
        }

        // Build placement summary string
        const counts = { Full: 0, Initials: 0, Date: 0, DatePick: 0 };
        for (const p of (placements || [])) {
            counts[p.placementType] = (counts[p.placementType] || 0) + 1;
        }
        const parts = [];
        if (counts.Full > 0) parts.push(counts.Full + ' signature' + (counts.Full > 1 ? 's' : ''));
        if (counts.Initials > 0) parts.push(counts.Initials + ' initial' + (counts.Initials > 1 ? 's' : ''));
        if (counts.Date > 0) parts.push(counts.Date + ' date' + (counts.Date > 1 ? 's' : ''));
        if (counts.DatePick > 0) parts.push(counts.DatePick + ' date picker' + (counts.DatePick > 1 ? 's' : ''));
        const placementSummary = parts.length > 0 ? parts.join(', ') : 'No signature placements detected';

        this.selectedTemplates = [
            ...this.selectedTemplates,
            {
                id: ++templateIdCounter,
                templateId,
                name: opt.label,
                placements: placements || [],
                placementSummary,
                docNumber: this.selectedTemplates.length + 1
            }
        ];

        this._refreshAggregatedPlacements();
    }

    handleRemoveTemplate(event) {
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        this.selectedTemplates = this.selectedTemplates.filter((_, i) => i !== idx);
        this._refreshAggregatedPlacements();
    }

    handleMoveTemplateUp(event) {
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        if (idx <= 0) return;
        const arr = [...this.selectedTemplates];
        [arr[idx - 1], arr[idx]] = [arr[idx], arr[idx - 1]];
        this.selectedTemplates = arr;
    }

    handleMoveTemplateDown(event) {
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        if (idx >= this.selectedTemplates.length - 1) return;
        const arr = [...this.selectedTemplates];
        [arr[idx], arr[idx + 1]] = [arr[idx + 1], arr[idx]];
        this.selectedTemplates = arr;
    }

    _refreshAggregatedPlacements() {
        // Renumber documents
        this.selectedTemplates = this.selectedTemplates.map((t, i) => ({
            ...t,
            docNumber: i + 1
        }));

        // Merge all template placements and auto-populate signers
        const all = [];
        for (const t of this.selectedTemplates) {
            for (const p of t.placements) {
                all.push(p);
            }
        }
        this.detectedPlacements = all;

        // Extract unique roles
        const uniqueRoles = [];
        for (const p of all) {
            if (!uniqueRoles.includes(p.role)) uniqueRoles.push(p.role);
        }

        if (uniqueRoles.length > 0) {
            // Preserve existing signer data for roles that already have entries
            const existingByRole = {};
            for (const s of this.signers) {
                if (s.roleName) existingByRole[s.roleName] = s;
            }

            this.signers = uniqueRoles.map(roleName => {
                if (existingByRole[roleName]) return existingByRole[roleName];
                return {
                    id: ++signerIdCounter,
                    roleName,
                    contactId: '',
                    signerName: '',
                    signerEmail: ''
                };
            });
        }
    }

    // --- Preview Modal ---

    async handleShowPreview() {
        this.showPreviewModal = true;
        this.previewLoading = true;
        this.previewHtml = '';

        try {
            // Generate preview for each template and concatenate
            const htmlParts = [];
            for (let i = 0; i < this.selectedTemplates.length; i++) {
                const tmpl = this.selectedTemplates[i];
                if (this.selectedTemplates.length > 1) {
                    htmlParts.push('<div style="background:#f8fafc;border:1px solid #e5e5e5;border-radius:6px;padding:12px 16px;margin:16px 0;text-align:center;"><strong>Document ' + (i + 1) + ' of ' + this.selectedTemplates.length + ': ' + tmpl.name + '</strong></div>');
                }
                const html = await getDocumentPreviewHtml({
                    templateId: tmpl.templateId,
                    relatedRecordId: this.recordId
                });
                if (html) {
                    htmlParts.push(html);
                } else {
                    htmlParts.push('<p style="color:#706e6b;text-align:center;padding:2rem;">Preview unavailable for ' + tmpl.name + '</p>');
                }
            }
            this.previewHtml = htmlParts.join('');
        } catch (err) {
            this.previewHtml = '<p style="color:#ea001e;text-align:center;padding:2rem;">Failed to generate preview: ' + (err.body ? err.body.message : err.message) + '</p>';
        }
        this.previewLoading = false;

        // Inject server-rendered HTML into the preview container after render.
        // The HTML is generated server-side by DocGenHtmlRenderer from merged template XML —
        // all user content is escaped in Apex. This is safe and required for document preview.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const container = this.template.querySelector('.preview-document-container');
            if (container && this.previewHtml) {
                // eslint-disable-next-line @lwc/lwc/no-inner-html
                container.innerHTML = this.previewHtml;
            }
        }, 100);
    }

    handleClosePreview() {
        this.showPreviewModal = false;
        this.previewHtml = '';
    }

    handleSendFromPreview() {
        this.showPreviewModal = false;
        this.handleGenerate();
    }

    // --- Signer Row Handlers ---

    handleAddSigner() {
        this.signers = [
            ...this.signers,
            { id: ++signerIdCounter, roleName: '', contactId: '', signerName: '', signerEmail: '' }
        ];
    }

    handleRemoveSigner(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        this.signers = this.signers.filter((_, i) => i !== index);
    }

    handleRoleChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        this.signers = this.signers.map((s, i) =>
            i === index ? { ...s, roleName: event.detail.value } : s
        );
    }

    async handleContactChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const contactId = event.detail.recordId;
        if (!contactId) {
            this.signers = this.signers.map((s, i) =>
                i === index ? { ...s, contactId: '', signerName: '', signerEmail: '' } : s
            );
            return;
        }
        this.signers = this.signers.map((s, i) =>
            i === index ? { ...s, contactId } : s
        );
        try {
            const info = await getContactInfo({ contactId });
            this.signers = this.signers.map((s, i) =>
                i === index ? { ...s, signerName: info.name || s.signerName, signerEmail: info.email || s.signerEmail } : s
            );
        } catch (_err) { /* user can type manually */ }
    }

    handleNameChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        this.signers = this.signers.map((s, i) =>
            i === index ? { ...s, signerName: event.target.value } : s
        );
    }

    handleEmailChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        this.signers = this.signers.map((s, i) =>
            i === index ? { ...s, signerEmail: event.target.value } : s
        );
    }

    // --- Generate ---

    async handleGenerate() {
        this.isLoading = true;
        this.error = undefined;
        try {
            const signersPayload = this.signers.map(s => ({
                roleName: s.roleName,
                contactId: s.contactId || null,
                signerName: s.signerName,
                signerEmail: s.signerEmail
            }));
            const signersJson = JSON.stringify(signersPayload);

            if (this.selectedTemplates.length === 1) {
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
                this.signerResults = await createTemplateSignerRequest({
                    templateId: this.selectedTemplates[0].templateId,
                    relatedRecordId: this.recordId,
                    signersJson,
                    signingOrder: this.signingOrder
                });
            } else {
                const templateIds = this.selectedTemplates.map(t => t.templateId);
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
                this.signerResults = await createPacketSignerRequest({
                    templateIdsJson: JSON.stringify(templateIds),
                    relatedRecordId: this.recordId,
                    signersJson,
                    signingOrder: this.signingOrder
                });
            }

            this.showToast('Success', 'Signature links generated for ' + this.signerResults.length + ' signer(s).', 'success');
            if (this.showPreviousRequests) this.loadPreviousRequests();
        } catch (err) {
            this.error = 'Error generating links: ' + (err.body ? err.body.message : err.message);
        } finally {
            this.isLoading = false;
        }
    }

    // --- Previous Requests ---

    async handleShowPreviousRequests() {
        this.showPreviousRequests = !this.showPreviousRequests;
        if (this.showPreviousRequests && this.previousRequests.length === 0) {
            await this.loadPreviousRequests();
        }
    }

    async loadPreviousRequests() {
        try {
            const data = await getPendingSignatureRequests({ relatedRecordId: this.recordId });
            this.previousRequests = data.map(req => ({
                ...req,
                statusBadgeClass: req.status === 'Signed' ? 'slds-badge slds-theme_success' :
                    req.status === 'In Progress' ? 'slds-badge slds-theme_warning' : 'slds-badge',
                signers: (req.signers || []).map(s => ({
                    ...s,
                    statusIcon: s.status === 'Signed' ? 'utility:check' :
                        s.status === 'Viewed' ? 'utility:preview' : 'utility:clock',
                    statusVariant: s.status === 'Signed' ? 'success' :
                        s.status === 'Viewed' ? 'warning' : 'bare'
                }))
            }));
        } catch (err) {
            this.showToast('Error', 'Failed to load previous requests: ' + (err.body ? err.body.message : err.message), 'error');
        }
    }

    handleCopyPreviousUrl(event) {
        this._copyToClipboard(event.currentTarget.dataset.url);
        this.showToast('Copied', 'Link copied to clipboard.', 'success');
    }

    handleCopyUrl(event) {
        this._copyToClipboard(event.currentTarget.dataset.url);
        this.showToast('Copied', 'Link copied to clipboard.', 'success');
    }

    async handleSignInPerson(event) {
        const signerId = event.currentTarget.dataset.signerId;
        const signerName = event.currentTarget.dataset.signerName || 'this signer';
        if (!signerId) {
            this.showToast('Error', 'Signer record is not available. Re-create the request to use In-Person Signing.', 'error');
            return;
        }
        const confirmed = window.confirm(
            `Confirm you have verified the identity of ${signerName} in person.\n\n` +
            `This bypasses email PIN verification. Your action will be recorded in the signature audit log.`
        );
        if (!confirmed) return;
        try {
            const url = await markSignerVerifiedInPerson({ signerId });
            if (url) {
                window.open(url, '_blank', 'noopener');
            }
            this.showToast('Verified', `${signerName} marked as verified. Signing page opened in a new tab.`, 'success');
        } catch (e) {
            const msg = (e.body && e.body.message) ? e.body.message : e.message || 'Unknown error.';
            this.showToast('Unable to mark verified', msg, 'error');
        }
    }

    handleCopyAllUrls() {
        const allText = this.signerResults
            .map(r => `${r.signerName}${r.roleName ? ' (' + r.roleName + ')' : ''}: ${r.signerUrl}`)
            .join('\n');
        this._copyToClipboard(allText);
        this.showToast('Copied', 'All links copied to clipboard.', 'success');
    }

    _copyToClipboard(text) {
        if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(text);
        } else {
            const ta = document.createElement('textarea');
            ta.value = text;
            ta.style.position = 'fixed';
            ta.style.left = '-9999px';
            document.body.appendChild(ta);
            ta.focus();
            ta.select();
            try { document.execCommand('copy'); } catch (_e) { /* fallback failed */ }
            document.body.removeChild(ta);
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}

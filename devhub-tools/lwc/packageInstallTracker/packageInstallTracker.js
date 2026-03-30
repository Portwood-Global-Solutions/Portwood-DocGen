import { LightningElement, wire, track } from 'lwc';
import getPackages from '@salesforce/apex/PackageInstallTracker.getPackages';
import getSubscribers from '@salesforce/apex/PackageInstallTracker.getSubscribers';
import getStats from '@salesforce/apex/PackageInstallTracker.getStats';
import getVersions from '@salesforce/apex/PackageInstallTracker.getVersions';
import sendInstallNotification from '@salesforce/apex/PackageInstallTracker.sendInstallNotification';
import linkOrgToAccount from '@salesforce/apex/PackageInstallTracker.linkOrgToAccount';
import createAccountForOrg from '@salesforce/apex/PackageInstallTracker.createAccountForOrg';
import searchAccounts from '@salesforce/apex/PackageInstallTracker.searchAccounts';
import syncNow from '@salesforce/apex/DocGenSubscriberSync.syncNow';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';

const ROW_ACTIONS = [
    { label: 'Link to Account', name: 'link_account' },
    { label: 'Create Account', name: 'create_account' },
    { label: 'View Account', name: 'view_account' }
];

const COLUMNS = [
    { label: 'Org Name', fieldName: 'orgName', sortable: true },
    { label: 'Account', fieldName: 'accountName', initialWidth: 180, sortable: true,
        cellAttributes: { class: { fieldName: 'accountClass' } }
    },
    { label: 'Org Type', fieldName: 'orgType', initialWidth: 120, sortable: true,
        cellAttributes: { class: { fieldName: 'orgTypeClass' } }
    },
    { label: 'Status', fieldName: 'installedStatus', initialWidth: 110, sortable: true,
        cellAttributes: { class: { fieldName: 'statusClass' } }
    },
    { label: 'Version', fieldName: 'versionLabel', sortable: true },
    { label: 'Installed', fieldName: 'installedDateFormatted', initialWidth: 180, sortable: true },
    { label: 'Org ID', fieldName: 'orgKey', initialWidth: 200 },
    { type: 'action', typeAttributes: { rowActions: ROW_ACTIONS } }
];

const VERSION_COLUMNS = [
    { label: 'Version', fieldName: 'version', initialWidth: 120 },
    { label: 'Name', fieldName: 'name' },
    { label: 'State', fieldName: 'releaseState', initialWidth: 100,
        cellAttributes: { class: { fieldName: 'stateClass' } }
    },
    { label: 'Published', fieldName: 'publishedDateFormatted', initialWidth: 180 }
];

const POLL_MS = 60000; // Check for new installs every 60 seconds

export default class PackageInstallTracker extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    versionColumns = VERSION_COLUMNS;
    @track subscribers = [];
    @track versions = [];
    @track packages = [];
    @track stats = {};
    selectedPackageId = '';
    isLoading = true;
    sortBy = 'installedDate';
    sortDirection = 'desc';
    _pollTimer;
    _knownOrgKeys = new Set();
    _initialized = false;
    showVersions = false;

    // Link Account modal state
    @track showLinkModal = false;
    @track linkOrgKey = '';
    @track linkOrgName = '';
    @track accountSearchTerm = '';
    @track accountSearchResults = [];
    @track selectedAccountId = null;

    @wire(getPackages)
    wiredPackages({ data, error }) {
        if (data) {
            this.packages = data.map(p => ({
                label: p.name + (p.namespacePrefix ? ' (' + p.namespacePrefix + ')' : ''),
                value: p.id
            }));
            if (this.packages.length > 0 && !this.selectedPackageId) {
                this.selectedPackageId = this.packages[0].value;
            }
        }
        if (error) {
            console.error('Error loading packages:', error);
        }
    }

    @wire(getSubscribers, { metadataPackageId: '$selectedPackageId' })
    wiredSubscribers({ data, error }) {
        this.isLoading = false;
        if (data) {
            // Detect genuinely NEW orgs (not upgrades or re-syncs)
            if (this._initialized) {
                for (const s of data) {
                    if (s.orgKey && s.installedStatus === 'Installed' && !this._knownOrgKeys.has(s.orgKey)) {
                        this._sendNotification(s);
                    }
                }
            }
            // Track all known org keys
            this._knownOrgKeys = new Set(data.map(s => s.orgKey));
            this._initialized = true;

            this.subscribers = data.map(s => ({
                ...s,
                installedDateFormatted: s.installedDate ? new Date(s.installedDate).toLocaleDateString('en-US', {
                    year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'
                }) : '',
                orgTypeClass: s.orgType === 'Production' ? 'slds-text-color_success' : 'slds-text-color_weak',
                statusClass: s.installedStatus === 'Installed' ? 'slds-text-color_success' : 'slds-text-color_error',
                accountName: s.accountName || '— No Account —',
                accountClass: s.accountId ? '' : 'slds-text-color_error'
            }));
        }
        if (error) {
            console.error('Error loading subscribers:', error);
            this.subscribers = [];
        }
    }

    @wire(getStats, { metadataPackageId: '$selectedPackageId' })
    wiredStats({ data }) {
        if (data) { this.stats = data; }
    }

    @wire(getVersions, { metadataPackageId: '$selectedPackageId' })
    wiredVersions({ data }) {
        if (data) {
            this.versions = data.map(v => ({
                ...v,
                publishedDateFormatted: v.publishedDate ? new Date(v.publishedDate).toLocaleDateString('en-US', {
                    year: 'numeric', month: 'short', day: 'numeric'
                }) : '',
                stateClass: v.releaseState === 'Released' ? 'slds-text-color_success' : 'slds-text-color_weak'
            }));
        }
    }

    connectedCallback() {
        this._startPolling();
    }

    disconnectedCallback() {
        this._stopPolling();
    }

    _startPolling() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._pollTimer = setInterval(() => { this.handleRefresh(); }, POLL_MS);
    }

    _stopPolling() {
        if (this._pollTimer) {
            clearInterval(this._pollTimer);
            this._pollTimer = null;
        }
    }

    _sendNotification(subscriber) {
        sendInstallNotification({
            orgName: subscriber.orgName || 'Unknown Org',
            orgType: subscriber.orgType || 'Unknown',
            versionLabel: subscriber.versionLabel || subscriber.versionId,
            orgKey: subscriber.orgKey
        }).catch(() => {});
    }

    get packageOptions() {
        return [{ label: 'All Packages', value: '' }, ...this.packages];
    }

    get totalInstalls() { return this.stats.total || 0; }
    get productionInstalls() { return this.stats.production || 0; }
    get sandboxInstalls() { return this.stats.sandbox || 0; }
    get activeInstalls() { return this.stats.installed || 0; }
    get uninstalled() { return this.stats.uninstalled || 0; }
    get hasSubscribers() { return this.subscribers.length > 0; }
    get hasVersions() { return this.versions.length > 0; }
    get versionToggleLabel() { return this.showVersions ? 'Hide Versions' : 'Show Versions'; }
    get linkDisabled() { return !this.selectedAccountId; }

    handlePackageChange(event) {
        this.isLoading = true;
        this._knownOrgKeys = new Set();
        this._initialized = false;
        this.selectedPackageId = event.detail.value;
    }

    handleToggleVersions() {
        this.showVersions = !this.showVersions;
    }

    handleSort(event) {
        this.sortBy = event.detail.fieldName;
        this.sortDirection = event.detail.sortDirection;
        const data = [...this.subscribers];
        const key = this.sortBy;
        const dir = this.sortDirection === 'asc' ? 1 : -1;
        data.sort((a, b) => {
            const va = a[key] || '';
            const vb = b[key] || '';
            return va > vb ? dir : va < vb ? -dir : 0;
        });
        this.subscribers = data;
    }

    handleRowAction(event) {
        const action = event.detail.action;
        const row = event.detail.row;
        switch (action.name) {
            case 'view_account':
                if (row.accountId) {
                    this[NavigationMixin.Navigate]({
                        type: 'standard__recordPage',
                        attributes: { recordId: row.accountId, actionName: 'view' }
                    });
                } else {
                    this.dispatchEvent(new ShowToastEvent({ title: 'No Account', message: 'This org has no linked Account. Use "Link to Account" or "Create Account".', variant: 'warning' }));
                }
                break;
            case 'link_account':
                this.linkOrgKey = row.orgKey;
                this.linkOrgName = row.orgName;
                this.accountSearchTerm = '';
                this.accountSearchResults = [];
                this.selectedAccountId = null;
                this.showLinkModal = true;
                break;
            case 'create_account':
                this._createAccount(row.orgKey, row.orgName);
                break;
            default:
                break;
        }
    }

    _createAccount(orgKey, orgName) {
        this.isLoading = true;
        createAccountForOrg({ orgKey, accountName: orgName })
            .then(accountId => {
                this.dispatchEvent(new ShowToastEvent({ title: 'Account Created', message: orgName + ' account created and linked.', variant: 'success' }));
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: { recordId: accountId, actionName: 'view' }
                });
                this.handleRefresh();
            })
            .catch(err => {
                this.dispatchEvent(new ShowToastEvent({ title: 'Error', message: err.body ? err.body.message : err.message, variant: 'error' }));
                this.isLoading = false;
            });
    }

    handleAccountSearch(event) {
        this.accountSearchTerm = event.target.value;
        if (this.accountSearchTerm.length >= 2) {
            searchAccounts({ searchTerm: this.accountSearchTerm })
                .then(results => { this.accountSearchResults = results; })
                .catch(() => { this.accountSearchResults = []; });
        } else {
            this.accountSearchResults = [];
        }
    }

    handleSelectAccount(event) {
        this.selectedAccountId = event.currentTarget.dataset.id;
        this.accountSearchTerm = event.currentTarget.dataset.name;
        this.accountSearchResults = [];
    }

    handleLinkAccount() {
        if (!this.selectedAccountId) return;
        this.isLoading = true;
        this.showLinkModal = false;
        linkOrgToAccount({ orgKey: this.linkOrgKey, accountId: this.selectedAccountId })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({ title: 'Linked', message: this.linkOrgName + ' linked to account.', variant: 'success' }));
                this.handleRefresh();
            })
            .catch(err => {
                this.dispatchEvent(new ShowToastEvent({ title: 'Error', message: err.body ? err.body.message : err.message, variant: 'error' }));
                this.isLoading = false;
            });
    }

    handleCloseLinkModal() {
        this.showLinkModal = false;
    }

    handleSyncNow() {
        this.isLoading = true;
        syncNow()
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Sync Complete',
                    message: 'Subscriber orgs synced and Accounts created.',
                    variant: 'success'
                }));
                this.handleRefresh();
            })
            .catch(err => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Sync Failed',
                    message: err.body ? err.body.message : err.message,
                    variant: 'error'
                }));
                this.isLoading = false;
            });
    }

    handleRefresh() {
        this.isLoading = true;
        const current = this.selectedPackageId;
        this.selectedPackageId = null;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.selectedPackageId = current; }, 100);
    }
}

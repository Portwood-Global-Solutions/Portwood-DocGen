import { LightningElement, wire, track } from 'lwc';
import getPackages from '@salesforce/apex/PackageInstallTracker.getPackages';
import getSubscribers from '@salesforce/apex/PackageInstallTracker.getSubscribers';
import getStats from '@salesforce/apex/PackageInstallTracker.getStats';
import getVersions from '@salesforce/apex/PackageInstallTracker.getVersions';
import sendInstallNotification from '@salesforce/apex/PackageInstallTracker.sendInstallNotification';

const COLUMNS = [
    { label: 'Org Name', fieldName: 'orgName', sortable: true },
    { label: 'Org Type', fieldName: 'orgType', initialWidth: 120, sortable: true,
        cellAttributes: { class: { fieldName: 'orgTypeClass' } }
    },
    { label: 'Status', fieldName: 'installedStatus', initialWidth: 110, sortable: true,
        cellAttributes: { class: { fieldName: 'statusClass' } }
    },
    { label: 'Version', fieldName: 'versionLabel', sortable: true },
    { label: 'Installed', fieldName: 'installedDateFormatted', initialWidth: 180, sortable: true },
    { label: 'Org ID', fieldName: 'orgKey', initialWidth: 200 }
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

export default class PackageInstallTracker extends LightningElement {
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
    _lastSubscriberCount = 0;
    showVersions = false;

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
            const newCount = data.length;
            // Detect new installs
            if (this._lastSubscriberCount > 0 && newCount > this._lastSubscriberCount) {
                const newest = data[0]; // Sorted by SystemModstamp DESC
                this._sendNotification(newest);
            }
            this._lastSubscriberCount = newCount;

            this.subscribers = data.map(s => ({
                ...s,
                installedDateFormatted: s.installedDate ? new Date(s.installedDate).toLocaleDateString('en-US', {
                    year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'
                }) : '',
                orgTypeClass: s.orgType === 'Production' ? 'slds-text-color_success' : 'slds-text-color_weak',
                statusClass: s.installedStatus === 'Installed' ? 'slds-text-color_success' : 'slds-text-color_error'
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
            versionLabel: subscriber.versionLabel || subscriber.versionId
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

    handlePackageChange(event) {
        this.isLoading = true;
        this._lastSubscriberCount = 0;
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

    handleRefresh() {
        this.isLoading = true;
        const current = this.selectedPackageId;
        this.selectedPackageId = null;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.selectedPackageId = current; }, 100);
    }
}

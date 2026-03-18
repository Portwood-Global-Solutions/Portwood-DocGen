import { LightningElement, track } from 'lwc';

export default class DocGenAdminGuide extends LightningElement {
    @track activeSection = 'overview';

    sections = [
        { name: 'overview', label: 'Overview', icon: 'utility:home' },
        { name: 'installation', label: 'Installation & Setup', icon: 'utility:setup' },
        { name: 'templates', label: 'Creating Templates', icon: 'utility:template' },
        { name: 'tags', label: 'Merge Tags & Syntax', icon: 'utility:merge_field' },
        { name: 'generation', label: 'Generating Documents', icon: 'utility:download' },
        { name: 'bulk', label: 'Bulk Generation', icon: 'utility:multi_select_checkbox' },
        { name: 'signatures', label: 'E-Signatures', icon: 'utility:edit_form' },
        { name: 'roles', label: 'Signature Roles & Templates', icon: 'utility:people' },
        { name: 'email', label: 'Email Branding & Copy', icon: 'utility:email' },
        { name: 'logo', label: 'Logo & Images', icon: 'utility:image' },
        { name: 'sharing', label: 'Sharing & Permissions', icon: 'utility:lock' },
        { name: 'versions', label: 'Template Versioning', icon: 'utility:clock' },
        { name: 'flows', label: 'Flow & Automation', icon: 'utility:flow' },
        { name: 'troubleshooting', label: 'Troubleshooting', icon: 'utility:bug' }
    ];

    handleSectionClick(event) {
        this.activeSection = event.currentTarget.dataset.section;
    }

    get computedSections() {
        return this.sections.map(s => ({
            ...s,
            cssClass: 'slds-nav-vertical__item' + (s.name === this.activeSection ? ' slds-is-active' : ''),
            ariaCurrent: s.name === this.activeSection ? 'page' : undefined
        }));
    }

    get isOverview() { return this.activeSection === 'overview'; }
    get isInstallation() { return this.activeSection === 'installation'; }
    get isTemplates() { return this.activeSection === 'templates'; }
    get isTags() { return this.activeSection === 'tags'; }
    get isGeneration() { return this.activeSection === 'generation'; }
    get isBulk() { return this.activeSection === 'bulk'; }
    get isSignatures() { return this.activeSection === 'signatures'; }
    get isRoles() { return this.activeSection === 'roles'; }
    get isEmail() { return this.activeSection === 'email'; }
    get isLogo() { return this.activeSection === 'logo'; }
    get isSharing() { return this.activeSection === 'sharing'; }
    get isVersions() { return this.activeSection === 'versions'; }
    get isFlows() { return this.activeSection === 'flows'; }
    get isTroubleshooting() { return this.activeSection === 'troubleshooting'; }
}

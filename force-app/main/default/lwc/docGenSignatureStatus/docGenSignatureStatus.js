// Dura Composites Ltd. (new file)
// Signature Status card: every signature request on this record, with each signer's progress,
// when they opened their link and how often. Read-only; data from DocGenSignatureStatusController.
import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { NavigationMixin } from 'lightning/navigation';
import getRequests from '@salesforce/apex/DocGenSignatureStatusController.getRequests';

const REQUEST_BADGE = {
    Signed: 'slds-badge slds-theme_success',
    Declined: 'slds-badge slds-theme_error',
    Cancelled: 'slds-badge slds-badge_lightest',
    Viewed: 'slds-badge slds-theme_warning',
    'In Progress': 'slds-badge slds-theme_warning'
};
const SIGNER_BADGE = {
    Signed: 'slds-badge slds-theme_success',
    Declined: 'slds-badge slds-theme_error',
    Cancelled: 'slds-badge slds-badge_lightest',
    Viewed: 'slds-badge slds-theme_warning'
};
const DEVICE_ICON = { Phone: 'utility:phone_portrait', Tablet: 'utility:tablet_portrait', Desktop: 'utility:desktop' };

export default class DocGenSignatureStatus extends NavigationMixin(LightningElement) {
    @api recordId;

    requests = [];
    error;
    loading = true;
    expanded = new Set();
    wired;

    @wire(getRequests, { recordId: '$recordId' })
    receive(result) {
        this.wired = result;
        const { data, error } = result;
        if (data) {
            this.raw = data;
            this.requests = this.decorate(data);
            this.error = undefined;
            this.loading = false;
        } else if (error) {
            this.error = (error.body && error.body.message) || 'Could not load signature requests.';
            this.requests = [];
            this.loading = false;
        }
    }

    get hasRequests() {
        return this.requests.length > 0;
    }

    get isEmpty() {
        return !this.loading && !this.error && this.requests.length === 0;
    }

    get cardTitle() {
        return this.requests.length ? `Signature requests (${this.requests.length})` : 'Signature requests';
    }

    decorate(data) {
        return data.map((r) => ({
            ...r,
            badgeClass: REQUEST_BADGE[r.status] || 'slds-badge',
            hasExpiry: !!r.expiresAt && r.status !== 'Signed' && r.status !== 'Declined' && r.status !== 'Cancelled',
            hasSignedFile: !!r.signedFileId,
            hasAttachments: r.attachmentCount > 0,
            orderLabel: this.orderLabel(r),
            signers: (r.signers || []).map((s) => this.decorateSigner(s, r))
        }));
    }

    // Only worth saying when there's more than one signer.
    orderLabel(r) {
        if ((r.signers || []).length < 2) {
            return '';
        }
        if (r.signingOrder === 'Sequential') {
            return 'Signs in order';
        }
        return r.signingOrder === 'Parallel' ? 'Signs in any order' : '';
    }

    decorateSigner(s, r) {
        const visitCount = s.visitCount || 0;
        const signedOrDeclined = s.status === 'Signed' || s.status === 'Declined';
        return {
            ...s,
            key: s.id,
            badgeClass: SIGNER_BADGE[s.status] || 'slds-badge',
            opened: visitCount > 0,
            openedLabel: visitCount === 1 ? 'Opened once' : `Opened ${visitCount} times`,
            manyVisits: visitCount >= 3 && !signedOrDeclined,
            notOpened: visitCount === 0 && !signedOrDeclined,
            showLast: visitCount > 1,
            isSigned: s.status === 'Signed' && !!s.signedAt,
            isDeclined: s.status === 'Declined',
            hasReminders: s.remindersSent > 0,
            remindersLabel: s.remindersSent === 1 ? '1 reminder sent' : `${s.remindersSent} reminders sent`,
            showReview: r.attachmentCount > 0,
            reviewLabel:
                `Opened ${s.attachmentsOpened || 0} of ${r.attachmentCount} attached documents` +
                (s.attachmentsMarkedUp ? `, marked up ${s.attachmentsMarkedUp}` : ''),
            hasVisits: (s.visits || []).length > 0,
            showVisits: this.expanded.has(s.id),
            visitsToggleLabel: this.expanded.has(s.id) ? 'Hide visits' : 'Show visits',
            visitRows: (s.visits || []).map((v, i) => ({
                ...v,
                key: `${s.id}-${i}`,
                icon: DEVICE_ICON[v.device] || 'utility:question',
                deviceLabel: v.device || 'Unknown',
                loadsLabel: v.pageLoads > 1 ? `${v.pageLoads} page loads` : ''
            }))
        };
    }

    handleToggleVisits(event) {
        const id = event.currentTarget.dataset.id;
        if (this.expanded.has(id)) {
            this.expanded.delete(id);
        } else {
            this.expanded.add(id);
        }
        this.requests = this.decorate(this.raw || []);
    }

    handleRefresh() {
        this.loading = true;
        refreshApex(this.wired).finally(() => {
            this.loading = false;
        });
    }

    handleOpenRequest(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.id, actionName: 'view' }
        });
    }

    handleOpenSignedFile(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: event.currentTarget.dataset.id }
        });
    }
}

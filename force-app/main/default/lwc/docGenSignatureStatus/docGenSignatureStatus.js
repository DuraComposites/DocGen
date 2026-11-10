// Dura Composites Ltd. (new file)
// Signature Status card: each signature request on this record as a timeline of what happened
// (sent, opened, reminders, resends, revokes, signed or declined, expiry). On a parent record it
// can also list the requests on related records, grouped by record. Read-only; the timeline is
// built by DocGenSignatureStatusController.
import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { NavigationMixin } from 'lightning/navigation';
import getTimeline from '@salesforce/apex/DocGenSignatureStatusController.getTimeline';

const TONE = {
    success: 'pill pill-success',
    danger: 'pill pill-danger',
    accent: 'pill pill-accent',
    neutral: 'pill pill-neutral'
};
const DOT = {
    opened: 'dot dot-accent',
    signed: 'dot dot-success',
    declined: 'dot dot-danger',
    revoked: 'dot dot-warning',
    expired: 'dot dot-warning',
    'expired-open': 'dot dot-warning',
    waiting: 'dot dot-hollow'
};

export default class DocGenSignatureStatus extends NavigationMixin(LightningElement) {
    @api recordId;
    /** "ChildObject.LookupField", comma-separated: also show requests on these related records. */
    // Defaults to empty: a wire does not run while any of its parameters is undefined.
    @api relatedRecords = '';

    groups = [];
    error;
    loading = true;
    toggled = new Set();
    raw;
    wired;

    @wire(getTimeline, { recordId: '$recordId', relatedRecords: '$relatedRecords' })
    receive(result) {
        this.wired = result;
        const { data, error } = result;
        if (data) {
            this.raw = data;
            this.groups = this.decorate(data);
            this.error = undefined;
            this.loading = false;
        } else if (error) {
            this.error = (error.body && error.body.message) || 'Could not load signature requests.';
            this.groups = [];
            this.loading = false;
        }
    }

    get grouped() {
        return (this.raw || []).some((g) => !g.isThisRecord);
    }

    get requestCount() {
        return (this.raw || []).reduce((n, g) => n + g.requests.length, 0);
    }

    get cardTitle() {
        return this.requestCount ? `Signature requests (${this.requestCount})` : 'Signature requests';
    }

    get isEmpty() {
        return !this.loading && !this.error && this.requestCount === 0;
    }

    decorate(data) {
        const grouped = data.some((g) => !g.isThisRecord);
        return data
            .filter((g) => g.requests.length > 0)
            .map((g) => ({
                ...g,
                key: g.recordId,
                showHeader: grouped,
                heading: g.isThisRecord ? 'This record' : g.recordName,
                requests: g.requests.map((r, i) => {
                    // On a single record the newest request opens by default; grouped, all start closed.
                    const openByDefault = !grouped && i === 0;
                    const expanded = this.toggled.has(r.id) ? !openByDefault : openByDefault;
                    return {
                        ...r,
                        key: r.id,
                        pillClass: TONE[r.statusTone] || TONE.neutral,
                        expanded,
                        toggleLabel: expanded ? 'Hide timeline' : 'Show timeline',
                        toggleIcon: expanded ? 'utility:chevrondown' : 'utility:chevronright',
                        hasDrawings: (r.drawingLines || []).length > 0,
                        hasSignedFile: !!r.signedFileId,
                        items: (r.timeline || []).map((t, j) => ({
                            ...t,
                            key: `${r.id}-${j}`,
                            dotClass: DOT[t.kind] || 'dot',
                            hasTime: !!t.at,
                            textClass: t.kind === 'waiting' ? 'muted' : ''
                        }))
                    };
                })
            }));
    }

    handleToggle(event) {
        const id = event.currentTarget.dataset.id;
        if (this.toggled.has(id)) {
            this.toggled.delete(id);
        } else {
            this.toggled.add(id);
        }
        this.groups = this.decorate(this.raw || []);
    }

    handleRefresh() {
        this.loading = true;
        refreshApex(this.wired).finally(() => {
            this.loading = false;
        });
    }

    handleOpenRecord(event) {
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

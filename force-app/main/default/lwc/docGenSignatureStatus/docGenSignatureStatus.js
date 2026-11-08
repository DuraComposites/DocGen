// Dura Composites Ltd. (new file)
// Signature Status card: each signature request on this record as a timeline of what happened
// (sent, opened, reminders, resends, revokes, signed or declined, expiry). On a parent record it
// can also list the requests on related records, grouped by record. The timeline is built by
// DocGenSignatureStatusController. For a request that isn't finished, the user can extend the
// link or change the reminders here; each change goes on the timeline with their name.
import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTimeline from '@salesforce/apex/DocGenSignatureStatusController.getTimeline';
import changeExpiry from '@salesforce/apex/DocGenSignatureStatusController.changeExpiry';
import changeReminders from '@salesforce/apex/DocGenSignatureStatusController.changeReminders';

const TONE = {
    success: 'pill pill-success',
    danger: 'pill pill-danger',
    accent: 'pill pill-accent',
    neutral: 'pill pill-neutral'
};
const MAX_DAYS = 365;

function isoInDays(days, from) {
    const d = from ? new Date(from + 'T12:00:00') : new Date();
    d.setDate(d.getDate() + days);
    const pad = (n) => String(n).padStart(2, '0');
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
}

const DOT = {
    opened: 'dot dot-accent',
    signed: 'dot dot-success',
    declined: 'dot dot-danger',
    revoked: 'dot dot-warning',
    expired: 'dot dot-warning',
    'expired-open': 'dot dot-warning',
    'expiry-changed': 'dot dot-accent',
    'reminders-changed': 'dot',
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

    // The open editor, if any: { id, type: 'expiry' | 'reminders' }, and its values.
    editor = null;
    editExpiresOn;
    editMode;
    editEvery;
    editUntil;
    saving = false;

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
                        hasPlan: !!r.plan,
                        extendLabel: r.isOpen ? 'Extend link' : 'Reopen link',
                        isEditingExpiry: !!this.editor && this.editor.id === r.id && this.editor.type === 'expiry',
                        isEditingReminders:
                            !!this.editor && this.editor.id === r.id && this.editor.type === 'reminders',
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

    // --- changing a sent request: extend the link, change the reminders ---

    get todayIso() {
        return isoInDays(0);
    }

    get maxDateIso() {
        return isoInDays(MAX_DAYS);
    }

    get reminderModeOptions() {
        return [
            { label: 'Every few days', value: 'EVERY' },
            { label: 'Standard schedule (Signature Settings)', value: 'ORG' },
            { label: 'No more reminders', value: 'NONE' }
        ];
    }

    get editIsEvery() {
        return this.editMode === 'EVERY';
    }

    findRequest(id) {
        for (const g of this.raw || []) {
            const r = g.requests.find((x) => x.id === id);
            if (r) return r;
        }
        return null;
    }

    openEditor(id, type) {
        this.editor = { id, type };
        this.groups = this.decorate(this.raw || []);
    }

    handleStartExtend(event) {
        const r = this.findRequest(event.currentTarget.dataset.id);
        if (!r) return;
        // A week past the current expiry, or a week from today if it has lapsed.
        const base = r.expiresOn && r.expiresOn > this.todayIso ? r.expiresOn : this.todayIso;
        this.editExpiresOn = isoInDays(7, base);
        if (this.editExpiresOn > this.maxDateIso) this.editExpiresOn = this.maxDateIso;
        this.openEditor(r.id, 'expiry');
    }

    handleStartReminders(event) {
        const r = this.findRequest(event.currentTarget.dataset.id);
        if (!r) return;
        const every = r.reminderEvery;
        this.editMode = every === null || every === undefined ? 'ORG' : every > 0 ? 'EVERY' : 'NONE';
        this.editEvery = every > 0 ? every : 2;
        this.editUntil = r.remindersUntil || null;
        this.openEditor(r.id, 'reminders');
    }

    handleCancelEdit() {
        this.editor = null;
        this.groups = this.decorate(this.raw || []);
    }

    handleEditExpiresOn(event) {
        this.editExpiresOn = event.detail.value;
    }

    handleEditMode(event) {
        this.editMode = event.detail.value;
    }

    handleEditEvery(event) {
        this.editEvery = event.detail.value;
    }

    handleEditUntil(event) {
        this.editUntil = event.detail.value || null;
    }

    async handleSaveExpiry(event) {
        const requestId = event.currentTarget.dataset.id;
        if (!this.editExpiresOn || this.editExpiresOn < this.todayIso || this.editExpiresOn > this.maxDateIso) {
            this.toast('Choose a date between today and a year from now.', 'error');
            return;
        }
        await this.save(() => changeExpiry({ requestId, expiresOn: this.editExpiresOn }), 'Link expiry changed.');
    }

    async handleSaveReminders(event) {
        const requestId = event.currentTarget.dataset.id;
        const every = parseInt(this.editEvery, 10);
        if (this.editIsEvery && !(every >= 1 && every <= MAX_DAYS)) {
            this.toast('Remind every 1 to 365 days.', 'error');
            return;
        }
        if (this.editIsEvery && this.editUntil && this.editUntil < this.todayIso) {
            this.toast('Choose an end date from today onwards.', 'error');
            return;
        }
        await this.save(
            () =>
                changeReminders({
                    requestId,
                    mode: this.editMode,
                    everyDays: this.editIsEvery ? every : null,
                    until: this.editIsEvery ? this.editUntil : null
                }),
            'Reminders changed.'
        );
    }

    async save(call, message) {
        this.saving = true;
        try {
            await call();
            this.editor = null;
            this.toast(message + ' It is on the timeline.', 'success');
            this.loading = true;
            await refreshApex(this.wired);
        } catch (e) {
            this.toast((e && e.body && e.body.message) || 'Could not save the change.', 'error');
        } finally {
            this.saving = false;
            this.loading = false;
            this.groups = this.decorate(this.raw || []);
        }
    }

    toast(message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({ title: variant === 'error' ? 'Not saved' : 'Saved', message, variant })
        );
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

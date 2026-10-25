const memoryClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const memoryParams = new URLSearchParams(window.location.search);
let memoryId = memoryParams.get('memory_id') || '';
let requestedTimelineId = memoryParams.get('timeline_id') || '';
let photoAttachments;
let documentAttachments;
let draftPhotoAttachments;
let coverAttachmentId = null;
let coverUpdateInProgress = false;
let formBaseline = null;
let leavePromptInProgress = false;
let browserBackGuardArmed = false;

const memoryForm = document.getElementById('memory-form');
const memoryMessage = document.getElementById('memory-message');
const memoryTitle = document.getElementById('memory-title');
const memoryOccurredOn = document.getElementById('memory-occurred-on');
const memoryDescription = document.getElementById('memory-description');
const memorySubmit = document.getElementById('memory-submit');
const memoryDelete = document.getElementById('memory-delete');
const memoryShare = document.getElementById('memory-share');
const memoryPageTitle = document.getElementById('memory-page-title');
const memoryPageIntro = document.getElementById('memory-page-intro');
const memoryPhotosSection = document.getElementById('memory-photos-section');
const memoryDocumentsSection = document.getElementById('memory-documents-section');
const memoryBackLink = document.getElementById('memory-back-link');
const memoryCancel = document.getElementById('memory-cancel');

const photoMimeTypes = ['image/jpeg', 'image/png', 'image/webp'];
const documentMimeTypes = ['application/pdf'];
// Single switch for the future return of PDF attachments inside photo albums.
// Keep the existing document markup and controller code intact while disabled.
const memoryDocumentsEnabled = false;
// Kept false until the activation SQL patch and the invitation Edge Function are deployed.
// The UI and its server calls are ready, but no email invitation can be created meanwhile.
const memoryShareEmailInvitesEnabled = true;

function setMessage(text = '', isError = false) {
  memoryMessage.textContent = text;
  memoryMessage.classList.toggle('is-error', isError);
}

function setSaving(inProgress) {
  memorySubmit.disabled = inProgress;
  memoryDelete.disabled = inProgress;
  memoryShare.disabled = inProgress;
  memorySubmit.textContent = inProgress ? 'Salvataggio...' : (memoryId ? 'Salva modifiche' : 'Salva album');
}

function currentFormState() {
  return JSON.stringify({
    occurredOn: memoryOccurredOn.value || '',
    title: memoryTitle.value.trim(),
    description: memoryDescription.value.trim() || null
  });
}

function captureFormBaseline() {
  formBaseline = currentFormState();
}

function hasUnsavedChanges() {
  return formBaseline !== null && (
    currentFormState() !== formBaseline
    || Boolean(draftPhotoAttachments?.pendingCount())
  );
}

function timelineHref() {
  const params = new URLSearchParams({ type: 'memory' });
  const timelineId = requestedTimelineId;
  if (memoryId) params.set('memory_id', memoryId);
  if (timelineId) params.set('timeline_id', timelineId);
  const query = params.toString();
  return `timeline.html${query ? `?${query}` : ''}`;
}

function updateTimelineLinks() {
  const href = timelineHref();
  memoryBackLink.href = href;
  memoryCancel.href = href;
}

function returnToTimeline() {
  window.location.assign(timelineHref());
}

function populateMemory(memory) {
  memoryOccurredOn.value = memory.occurred_on || '';
  memoryTitle.value = memory.title || '';
  memoryDescription.value = memory.description || '';
  coverAttachmentId = memory.cover_attachment_id || null;
  requestedTimelineId = memory.timeline_id || requestedTimelineId;
}

async function verifyMemoryTimeline(timelineId = requestedTimelineId) {
  if (!timelineId) {
    throw new Error('Timeline Ricordi non specificata. Torna alla Timeline e seleziona “+ Nuovo album”.');
  }
  const { data, error } = await memoryClient.rpc('get_my_timelines', { p_timeline_type: 'memory' });
  if (error || !Array.isArray(data)) {
    throw error || new Error('Risposta Timeline incompatibile');
  }
  if (!data.some((timeline) => timeline.id === timelineId)) {
    throw new Error('Timeline Ricordi non trovata o non disponibile.');
  }
}

function createCoverActions(attachment) {
  if (!memoryId) return null;

  const action = document.createElement('button');
  action.type = 'button';
  action.className = 'secondary-button';

  if (attachment.id === coverAttachmentId) {
    const status = document.createElement('span');
    status.className = 'fa-v2-status';
    status.textContent = 'Copertina';
    action.textContent = 'Rimuovi copertina';
    action.addEventListener('click', async () => updateMemoryCover(null, action));
    return [status, action];
  }

  action.textContent = 'Usa come copertina';
  action.addEventListener('click', async () => updateMemoryCover(attachment.id, action));
  return action;
}

async function updateMemoryCover(attachmentId, action) {
  if (!memoryId || coverUpdateInProgress) return;

  coverUpdateInProgress = true;
  action.disabled = true;
  setMessage('Aggiornamento della copertina in corso...');
  try {
    const { data, error } = await memoryClient.rpc('set_memory_cover', {
      p_memory_id: memoryId,
      p_attachment_id: attachmentId
    });
    if (error) throw error;

    coverAttachmentId = data?.cover_attachment_id || null;
    setMessage(coverAttachmentId ? 'Fotografia impostata come copertina.' : 'Copertina rimossa.');
    await photoAttachments.load();
  } catch (error) {
    console.error('memory cover update failed', error);
    setMessage(error?.message || 'Impossibile aggiornare la copertina.', true);
  } finally {
    coverUpdateInProgress = false;
    action.disabled = false;
  }
}

function updatePageForStoredMemory() {
  memoryPageTitle.textContent = 'Modifica album';
  memoryPageIntro.textContent = 'Aggiorna l’album e le sue fotografie.';
  memorySubmit.textContent = 'Salva modifiche';
  memoryDelete.hidden = false;
  memoryShare.hidden = false;
  memoryPhotosSection.hidden = false;
  memoryDocumentsSection.hidden = !memoryDocumentsEnabled;
  updateTimelineLinks();
}

function initialiseDraftPhotoAttachments() {
  if (draftPhotoAttachments || memoryId) return;
  draftPhotoAttachments = window.FamilAreaDeadlineAttachments.createDraft({
    client: memoryClient,
    input: document.getElementById('memory-photo-input'),
    uploadControl: document.getElementById('memory-photo-upload'),
    message: document.getElementById('memory-photos-message'),
    empty: document.getElementById('memory-photos-empty'),
    list: document.getElementById('memory-photos-list'),
    targetType: 'memory',
    allowedMimeTypes: photoMimeTypes,
    multipleProgressLabel: 'fotografie',
    multipleCompleteLabel: 'Fotografie caricate'
  });
}

function attachmentController(options) {
  return window.FamilAreaDeadlineAttachments.create({
    client: memoryClient,
    targetId: memoryId,
    targetType: 'memory',
    canManage: true,
    ...options
  });
}

async function initialiseAttachments() {
  if (!memoryId || photoAttachments || documentAttachments) return;
  updatePageForStoredMemory();
  photoAttachments = attachmentController({
    input: document.getElementById('memory-photo-input'),
    uploadControl: document.getElementById('memory-photo-upload'),
    message: document.getElementById('memory-photos-message'),
    empty: document.getElementById('memory-photos-empty'),
    list: document.getElementById('memory-photos-list'),
    allowedMimeTypes: photoMimeTypes,
    allowMultiple: true,
    renderAttachmentActions: createCoverActions,
    onAttachmentDeleted: async (attachment) => {
      if (attachment.id === coverAttachmentId) {
        coverAttachmentId = null;
        setMessage('Fotografia eliminata. La copertina è stata rimossa.');
      }
    }
  });
  if (memoryDocumentsEnabled) {
    documentAttachments = attachmentController({
      input: document.getElementById('memory-document-input'),
      uploadControl: document.getElementById('memory-document-upload'),
      message: document.getElementById('memory-documents-message'),
      empty: document.getElementById('memory-documents-empty'),
      list: document.getElementById('memory-documents-list'),
      allowedMimeTypes: documentMimeTypes
    });
  }
  await Promise.all([
    photoAttachments.load(),
    ...(documentAttachments ? [documentAttachments.load()] : [])
  ]);
}

function rpcMessage(subject, error) {
  console.error(`[FamilArea memories] ${subject}`, error);
  const code = error?.code ? ` (${error.code})` : '';
  const reason = error?.message || error?.details || 'Risposta non disponibile.';
  return `Impossibile ${subject}${code}: ${reason}`;
}

function memorySharingInitials(name = '') {
  const words = String(name).trim().split(/\s+/).filter(Boolean);
  return (words.slice(0, 2).map((word) => word[0]).join('') || '?').toUpperCase();
}

function renderMemorySharingAvatar(avatar, account) {
  const name = account.display_name || account.account_name || 'Account FamilArea';
  avatar.textContent = memorySharingInitials(name);
  const avatarPath = account.avatar_path;
  if (!avatarPath) return;
  const bucket = account.account_type === 'organization' ? 'organization-avatars' : 'profile-avatars';
  memoryClient.storage.from(bucket).createSignedUrl(avatarPath, 3600).then(({ data, error }) => {
    if (error || !data?.signedUrl) return;
    const image = document.createElement('img');
    image.src = data.signedUrl;
    image.alt = '';
    image.addEventListener('error', () => image.remove());
    avatar.replaceChildren(image);
  }).catch(() => {});
}

function createMemorySharingRow(account, { status = '', actionLabel = '', action = null, busy = false } = {}) {
  const row = document.createElement('div');
  row.className = 'fa-v2-list-row fa-v2-list-row--media';
  const avatar = document.createElement('span');
  avatar.className = 'contact-directory-avatar';
  renderMemorySharingAvatar(avatar, account);
  const details = document.createElement('div');
  const title = document.createElement('strong');
  title.textContent = account.display_name || account.account_name || 'Account FamilArea';
  const meta = document.createElement('p');
  meta.className = 'fa-v2-status';
  const accountType = account.account_type === 'organization' ? 'Organizzazione' : 'Persona';
  meta.textContent = status ? `${accountType} · ${status}` : accountType;
  details.append(title, meta);
  row.append(avatar, details);
  if (action) {
    const actions = document.createElement('div');
    actions.className = 'fa-v2-card-actions';
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'fa-v2-button fa-v2-button--secondary';
    button.textContent = actionLabel;
    button.disabled = busy;
    button.addEventListener('click', action);
    actions.append(button);
    row.append(actions);
  }
  return row;
}



function memoryShareInvitationStatusLabel(status, collaborationStatus) {
  if (status === 'accepted' && collaborationStatus === 'revoked') return 'Abbandonato dal destinatario';
  if (status === 'accepted' && collaborationStatus !== undefined && collaborationStatus !== 'accepted') return 'Accesso non disponibile';
  return ({ pending: 'In attesa', accepted: 'Accettato', declined: 'Rifiutato', revoked: 'Revocato', expired: 'Scaduto', cancelled: 'Annullato' })[status] || 'Stato non disponibile';
}

function createMemoryShareEmailContactRow(contact, { selected = false, onSelect = null } = {}) {
  const row = document.createElement('div');
  row.className = 'fa-v2-list-row fa-v2-list-row--media memory-share-email-row';
  const avatar = document.createElement('span');
  avatar.className = 'contact-directory-avatar';
  avatar.textContent = memorySharingInitials(contact.display_name || 'Contatto');
  const details = document.createElement('div');
  const name = document.createElement('strong');
  name.textContent = contact.display_name || 'Contatto senza nome';
  const email = document.createElement('p');
  email.className = 'fa-v2-status';
  email.textContent = contact.recipient_email;
  details.append(name, email);
  const actions = document.createElement('div');
  actions.className = 'fa-v2-card-actions';
  const select = document.createElement('button');
  select.type = 'button';
  select.className = 'fa-v2-button fa-v2-button--secondary';
  select.textContent = selected ? 'Selezionato' : 'Seleziona';
  select.disabled = selected;
  if (onSelect) select.addEventListener('click', onSelect);
  actions.append(select);
  row.append(avatar, details, actions);
  return row;
}

function openMemorySharingDialog() {
  if (!memoryId || document.getElementById('memory-sharing-overlay')) return;

  const previousFocus = document.activeElement;
  const background = [...document.body.children].filter((element) => element.id !== 'memory-sharing-overlay');
  const previousInert = background.map((element) => ({ element, inert: element.inert }));
  previousInert.forEach(({ element }) => { element.inert = true; });
  document.body.classList.add('confirm-modal-open');

  const overlay = document.createElement('div');
  overlay.id = 'memory-sharing-overlay';
  overlay.className = 'confirm-modal-overlay';
  const dialog = document.createElement('section');
  dialog.className = 'confirm-modal memory-share-email-dialog';
  dialog.setAttribute('role', 'dialog');
  dialog.setAttribute('aria-modal', 'true');
  dialog.setAttribute('aria-labelledby', 'memory-sharing-title');
  dialog.tabIndex = -1;
  const title = document.createElement('h2');
  title.id = 'memory-sharing-title';
  title.className = 'confirm-modal-title';
  title.textContent = 'Condividi album';
  const close = document.createElement('button');
  close.type = 'button';
  close.className = 'confirm-modal-close';
  close.setAttribute('aria-label', 'Chiudi');
  close.textContent = '×';
  const intro = document.createElement('p');
  intro.className = 'confirm-modal-message';
  intro.textContent = 'Cerca un contatto della tua rubrica e invia l’invito al suo indirizzo email.';
  const availability = document.createElement('p');
  availability.className = 'confirm-modal-warning';
  availability.hidden = memoryShareEmailInvitesEnabled;
  availability.textContent = 'Gli inviti via email sono in preparazione. Potrai cercare, selezionare e inviare quando il servizio sarà attivato.';
  const status = document.createElement('p');
  status.className = 'fa-v2-status';
  status.setAttribute('aria-live', 'polite');
  const searchLabel = document.createElement('label');
  searchLabel.htmlFor = 'memory-sharing-search';
  searchLabel.textContent = 'Cerca un contatto';
  const search = document.createElement('input');
  search.id = 'memory-sharing-search';
  search.type = 'search';
  search.className = 'fa-v2-input';
  search.placeholder = 'Nome o indirizzo email';
  search.autocomplete = 'off';
  search.disabled = !memoryShareEmailInvitesEnabled;
  const results = document.createElement('div');
  results.className = 'fa-v2-list memory-share-email-results';
  const selected = document.createElement('div');
  selected.className = 'memory-share-email-selected';
  selected.hidden = true;
  const sendInvite = document.createElement('button');
  sendInvite.type = 'button';
  sendInvite.className = 'fa-v2-button fa-v2-button--primary';
  sendInvite.textContent = 'Invia invito';
  sendInvite.disabled = true;
  const emailInvitesTitle = document.createElement('h3');
  emailInvitesTitle.textContent = 'Inviti via email';
  const emailInvites = document.createElement('div');
  emailInvites.className = 'fa-v2-list';
  const pendingTitle = document.createElement('h3');
  pendingTitle.textContent = 'Inviti FamilArea esistenti';
  const pending = document.createElement('div');
  pending.className = 'fa-v2-list';
  const acceptedTitle = document.createElement('h3');
  acceptedTitle.textContent = 'Accessi FamilArea esistenti';
  const accepted = document.createElement('div');
  accepted.className = 'fa-v2-list';
  dialog.append(close, title, intro, availability, status, searchLabel, search, results, selected, sendInvite, emailInvitesTitle, emailInvites, pendingTitle, pending, acceptedTitle, accepted);
  overlay.append(dialog);
  document.body.append(overlay);

  let searchTimer;
  let actionPending = false;
  let selectedContact = null;
  const setStatus = (message = '', isError = false) => {
    status.textContent = message;
    status.classList.toggle('is-error', isError);
  };
  const syncInvitationControls = () => {
    search.disabled = actionPending || !memoryShareEmailInvitesEnabled;
    sendInvite.disabled = actionPending || !memoryShareEmailInvitesEnabled || !selectedContact;
  };
  const setBusy = (busy) => {
    actionPending = busy;
    dialog.querySelectorAll('button, input').forEach((element) => {
      if (element !== close) element.disabled = busy;
    });
    if (!busy) syncInvitationControls();
  };
  const closeDialog = () => {
    window.clearTimeout(searchTimer);
    document.removeEventListener('keydown', onKeyDown);
    overlay.remove();
    document.body.classList.remove('confirm-modal-open');
    previousInert.forEach(({ element, inert }) => { element.inert = inert; });
    if (previousFocus instanceof HTMLElement) previousFocus.focus();
  };
  const onKeyDown = (event) => {
    if (event.key === 'Escape' && !actionPending) closeDialog();
  };
  close.addEventListener('click', closeDialog);
  overlay.addEventListener('click', (event) => {
    if (event.target === overlay && !actionPending) closeDialog();
  });
  document.addEventListener('keydown', onKeyDown);

  const renderSelectedContact = () => {
    selected.replaceChildren();
    selected.hidden = !selectedContact;
    if (!selectedContact) return;
    const caption = document.createElement('p');
    caption.className = 'fa-v2-status';
    caption.textContent = 'Invito da inviare a';
    const identity = document.createElement('strong');
    identity.textContent = selectedContact.display_name || 'Contatto senza nome';
    const email = document.createElement('p');
    email.className = 'memory-share-email-address';
    email.textContent = selectedContact.recipient_email;
    selected.append(caption, identity, email);
    syncInvitationControls();
  };

  const refreshLegacyManagement = async () => {
    const { data, error } = await memoryClient.rpc('get_memory_collaboration_management', { p_memory_id: memoryId });
    if (error) {
      setStatus(rpcMessage('caricare le condivisioni esistenti', error), true);
      return;
    }
    pending.replaceChildren();
    accepted.replaceChildren();
    const pendingItems = Array.isArray(data?.pending) ? data.pending : [];
    const acceptedItems = Array.isArray(data?.collaborators) ? data.collaborators : [];
    const appendManagement = (container, item, label, rpcName, confirmation) => {
      const account = { display_name: item.display_name, account_type: item.account_type, avatar_path: item.avatar_path };
      container.append(createMemorySharingRow(account, {
        status: label,
        actionLabel: confirmation.confirmText,
        action: async () => {
          if (actionPending) return;
          const confirmed = await FamilAreaConfirm.confirm(confirmation);
          if (!confirmed) return;
          setBusy(true);
          setStatus(`${confirmation.confirmText} in corso…`);
          const { error: actionError } = await memoryClient.rpc(rpcName, { p_collaboration_id: item.collaboration_id });
          setBusy(false);
          if (actionError) {
            setStatus(rpcMessage(confirmation.subject, actionError), true);
            return;
          }
          await refreshLegacyManagement();
          setStatus('');
        }
      }));
    };
    pendingItems.forEach((item) => appendManagement(pending, item, 'In attesa', 'cancel_memory_collaboration', {
      title: 'Annullare invito?', message: 'Il destinatario non potrà più accettare questo invito.', confirmText: 'Annulla invito', subject: 'annullare l’invito'
    }));
    acceptedItems.forEach((item) => appendManagement(accepted, item, 'Può visualizzare l’album', 'revoke_memory_collaboration', {
      variant: 'danger', title: 'Revocare accesso?', message: 'Il destinatario non potrà più aprire questo album.', confirmText: 'Revoca accesso', subject: 'revocare l’accesso'
    }));
    if (!pendingItems.length) pending.textContent = 'Nessun invito FamilArea in attesa.';
    if (!acceptedItems.length) accepted.textContent = 'Nessun accesso FamilArea attivo.';
  };

  const refreshEmailManagement = async () => {
    emailInvites.replaceChildren();
    if (!memoryShareEmailInvitesEnabled) {
      emailInvites.textContent = 'Gli stati degli inviti via email saranno disponibili qui dopo l’attivazione.';
      return;
    }
    const { data, error } = await memoryClient.rpc('get_memory_share_invitation_management', { p_memory_id: memoryId });
    if (error) {
      setStatus(rpcMessage('caricare gli inviti via email', error), true);
      return;
    }
    const invitations = Array.isArray(data) ? data : [];
    if (!invitations.length) {
      emailInvites.textContent = 'Nessun invito via email.';
      return;
    }
    invitations.forEach((invite) => {
      const row = document.createElement('div');
      row.className = 'fa-v2-list-row memory-share-email-row';
      const details = document.createElement('div');
      const email = document.createElement('strong');
      email.textContent = invite.recipient_email;
      const meta = document.createElement('p');
      meta.className = 'fa-v2-status';
      meta.textContent = memoryShareInvitationStatusLabel(invite.status, invite.collaboration_status);
      details.append(email, meta);
      row.append(details);
      emailInvites.append(row);
    });
  };

  const searchRecipients = async () => {
    const query = search.value.trim();
    results.replaceChildren();
    selectedContact = null;
    renderSelectedContact();
    if (!memoryShareEmailInvitesEnabled || query.length < 2) return;
    setStatus('Ricerca contatti…');
    const { data, error } = await memoryClient.rpc('search_my_memory_share_contacts', { p_memory_id: memoryId, p_query: query });
    if (error) {
      setStatus(rpcMessage('cercare i contatti', error), true);
      return;
    }
    const contacts = Array.isArray(data) ? data : [];
    if (!contacts.length) {
      results.textContent = 'Nessun contatto con un indirizzo email valido.';
      setStatus('');
      return;
    }
    contacts.forEach((contact) => {
      results.append(createMemoryShareEmailContactRow(contact, {
        onSelect: () => {
          selectedContact = contact;
          renderSelectedContact();
          [...results.querySelectorAll('button')].forEach((button) => { button.disabled = true; });
          setStatus('');
        }
      }));
    });
    setStatus('');
  };

  sendInvite.addEventListener('click', async () => {
    if (!memoryShareEmailInvitesEnabled || !selectedContact || actionPending) return;
    setBusy(true);
    setStatus('Creazione e consegna dell’invito…');
    const { data, error } = await memoryClient.functions.invoke('send-memory-share-invitation', {
      body: { memory_id: memoryId, contact_id: selectedContact.contact_id }
    });
    setBusy(false);
    if (error || !data?.invitation_id || data.status !== 'pending') {
      setStatus(rpcMessage('inviare l’invito via email', error || new Error('Consegna non confermata')), true);
      return;
    }
    selectedContact = null;
    search.value = '';
    results.replaceChildren();
    renderSelectedContact();
    await refreshEmailManagement();
    setStatus('Invito consegnato.');
  });
  search.addEventListener('input', () => {
    window.clearTimeout(searchTimer);
    searchTimer = window.setTimeout(() => { void searchRecipients(); }, 250);
  });
  syncInvitationControls();
  void refreshLegacyManagement();
  void refreshEmailManagement();
  dialog.focus();
}

function openRequestedMemorySharing() {
  if (memoryParams.get('share') !== '1' || !memoryId) return;
  const url = new URL(window.location.href);
  url.searchParams.delete('share');
  window.history.replaceState(window.history.state, '', `${url.pathname}${url.search}${url.hash}`);
  openMemorySharingDialog();
}

async function loadMemory() {
  const { data: sessionData, error: sessionError } = await memoryClient.auth.getSession();
  if (sessionError || !sessionData?.session) {
    window.location.replace(`login.html?return_to=${encodeURIComponent(`ricordo.html${window.location.search}`)}`);
    return;
  }

  if (!memoryId) {
    try {
      await verifyMemoryTimeline();
    } catch (error) {
      memoryForm.hidden = true;
      setMessage(rpcMessage('caricare le Timeline Ricordi', error), true);
      return;
    }
    initialiseDraftPhotoAttachments();
    memoryForm.hidden = false;
    setMessage('');
    captureFormBaseline();
    updateTimelineLinks();
    return;
  }

  const { data, error } = await memoryClient.rpc('get_memory', { p_memory_id: memoryId });
  if (error || !data?.id) {
    memoryForm.hidden = true;
    setMessage(error ? rpcMessage('caricare l’album', error) : 'Album non trovato o non disponibile.', true);
    return;
  }

  populateMemory(data);
  try {
    await verifyMemoryTimeline(data.timeline_id);
  } catch (timelineError) {
    memoryForm.hidden = true;
    setMessage(rpcMessage('caricare le Timeline Ricordi', timelineError), true);
    return;
  }
  memoryForm.hidden = false;
  setMessage('');
  await initialiseAttachments();
  captureFormBaseline();
  updateTimelineLinks();
  openRequestedMemorySharing();
}

async function saveMemory({ redirectOnSuccess = true } = {}) {
  if (memorySubmit.disabled) return;

  const occurredOn = memoryOccurredOn.value;
  const title = memoryTitle.value.trim();
  const description = memoryDescription.value.trim() || null;
  const timelineId = requestedTimelineId;
  if (!occurredOn || !title || !timelineId) {
    setMessage('Apri una Timeline Ricordi e seleziona “+ Nuovo album” prima di salvare.', true);
    return false;
  }

  setSaving(true);
  setMessage('Salvataggio album...');
  const params = memoryId
    ? { p_memory_id: memoryId, p_timeline_id: timelineId, p_occurred_on: occurredOn, p_title: title, p_description: description }
    : { p_timeline_id: timelineId, p_occurred_on: occurredOn, p_title: title, p_description: description };
  const rpcName = memoryId ? 'update_memory_in_timeline' : 'create_memory_in_timeline';
  try {
    const { data, error } = await memoryClient.rpc(rpcName, params);
    if (error || !data?.id) throw error || new Error('Risposta RPC incompatibile');

    const wasNew = !memoryId;
    memoryId = data.id;
    populateMemory(data);
    requestedTimelineId = data.timeline_id || timelineId;
    window.history.replaceState({}, '', `ricordo.html?${new URLSearchParams({ memory_id: memoryId, timeline_id: requestedTimelineId })}`);
    updatePageForStoredMemory({ showDocuments: false });

    let uploadResult = { ok: true, failed: 0 };
    if (draftPhotoAttachments?.pendingCount()) {
      uploadResult = await draftPhotoAttachments.uploadSelected(memoryId);
    }
    if (uploadResult.ok) draftPhotoAttachments = undefined;
    captureFormBaseline();
    updateTimelineLinks();
    if (!uploadResult.ok) {
      setMessage(
        `Album ${wasNew ? 'creato' : 'salvato'}, ma ${uploadResult.failed} fotograf${uploadResult.failed === 1 ? 'ia non è stata caricata' : 'ie non sono state caricate'}. Riprova senza creare un nuovo album.`,
        true
      );
      return false;
    }

    setMessage(wasNew ? 'Album e fotografie salvati.' : 'Modifiche salvate.');
    if (redirectOnSuccess) window.location.replace(timelineHref());
    return true;
  } catch (error) {
    setMessage(rpcMessage('salvare l’album', error), true);
    return false;
  } finally {
    setSaving(false);
  }
}

memoryForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  await saveMemory();
});

async function requestLeave(destination) {
  if (leavePromptInProgress) return;
  if (!hasUnsavedChanges()) {
    destination();
    return;
  }

  leavePromptInProgress = true;
  try {
    const choice = await FamilAreaConfirm.choice({
      title: 'Hai modifiche non salvate. Cosa vuoi fare?',
        message: 'Le modifiche a data, titolo e descrizione non sono ancora state salvate.',
      choices: [
        { value: 'continue', label: 'Continua a modificare', className: 'confirm-modal-cancel' },
        { value: 'discard', label: 'Esci senza salvare', className: 'confirm-modal-cancel list-item-delete' },
        { value: 'save', label: 'Salva modifiche', className: 'confirm-modal-confirm' }
      ]
    });
    if (choice === 'save') {
      const saved = await saveMemory({ redirectOnSuccess: false });
      if (saved) destination();
    }
    if (choice === 'discard') destination();
  } finally {
    leavePromptInProgress = false;
  }
}

function setupBrowserBackGuard() {
  if (browserBackGuardArmed) return;
  browserBackGuardArmed = true;
  window.history.pushState({ ...(window.history.state || {}), memoryEditorGuard: true }, '', window.location.href);
  window.addEventListener('popstate', () => {
    window.history.pushState({ ...(window.history.state || {}), memoryEditorGuard: true }, '', window.location.href);
    void requestLeave(returnToTimeline);
  });
}

document.addEventListener('click', (event) => {
  if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  const link = event.target.closest('a[href]');
  if (!link || link.target === '_blank' || link.hasAttribute('download')) return;
  const url = new URL(link.href, window.location.href);
  if (url.origin !== window.location.origin || (url.pathname === window.location.pathname && url.search === window.location.search)) return;
  event.preventDefault();
  event.stopImmediatePropagation();
  void requestLeave(() => window.location.assign(url.href));
}, true);

window.addEventListener('beforeunload', (event) => {
  if (!hasUnsavedChanges()) return;
  event.preventDefault();
  event.returnValue = '';
});

memoryDelete.addEventListener('click', async () => {
  if (!memoryId || memoryDelete.disabled) return;
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: 'Eliminare l’album?',
    message: 'Rimuovi prima tutte le fotografie e i documenti collegati. Questa operazione non puÃ² essere annullata.',
    confirmText: 'Elimina'
  });
  if (!confirmed) return;

  setSaving(true);
  setMessage('Eliminazione album...');
  const { error } = await memoryClient.rpc('delete_memory', { p_memory_id: memoryId });
  if (error) {
    setSaving(false);
    const hasAttachments = /remove memory attachments/i.test(error.message || '');
    setMessage(hasAttachments
      ? 'Rimuovi prima tutti gli allegati collegati. I PDF già presenti sono temporaneamente nascosti: riattiva la sezione Documenti prima di eliminare un album che li contiene.'
      : rpcMessage('eliminare l’album', error), true);
    return;
  }
  window.location.replace(timelineHref());
});

memoryShare.addEventListener('click', openMemorySharingDialog);

void loadMemory().then(setupBrowserBackGuard);

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
let memoryParticipants = [];
let memoryContacts = [];
let memoryParticipantsLoading = false;
let memoryPhotoParticipantTags = new Map();
let memoryPhotoTagStates = new Map();
let memoryPhotoTagsLoaded = false;
let activeMemoryPhotoAttachmentId = '';
let memoryPhotoTagsSaving = false;
let memoryPhotoShareableAttachments = new Map();
let memoryPhotoShareOwner = false;


const memoryForm = document.getElementById('memory-form');
const memoryMessage = document.getElementById('memory-message');
const memoryTitle = document.getElementById('memory-title');
const memoryOccurredOn = document.getElementById('memory-occurred-on');
const memoryDescription = document.getElementById('memory-description');
const memorySubmit = document.getElementById('memory-submit');
const memoryDelete = document.getElementById('memory-delete');
const memoryShare = document.getElementById('memory-share');
const memoryPhotoShare = document.getElementById('memory-photo-share');
const memoryPageTitle = document.getElementById('memory-page-title');
const memoryPageIntro = document.getElementById('memory-page-intro');
const memoryPhotosSection = document.getElementById('memory-photos-section');
const memoryDocumentsSection = document.getElementById('memory-documents-section');
const memoryBackLink = document.getElementById('memory-back-link');
const memoryCancel = document.getElementById('memory-cancel');
const memoryParticipantsNote = document.getElementById('memory-participants-note');
const memoryParticipantsControls = document.getElementById('memory-participants-controls');
const memoryParticipantsMessage = document.getElementById('memory-participants-message');
const memoryParticipantsEmpty = document.getElementById('memory-participants-empty');
const memoryParticipantsList = document.getElementById('memory-participants-list');
const memoryParticipantSearch = document.getElementById('memory-participant-search');
const memoryParticipantSearchResults = document.getElementById('memory-participant-search-results');
const memoryParticipantCreateToggle = document.getElementById('memory-participant-create-toggle');
const memoryParticipantCreate = document.getElementById('memory-participant-create');
const memoryParticipantFirstName = document.getElementById('memory-participant-first-name');
const memoryParticipantLastName = document.getElementById('memory-participant-last-name');
const memoryParticipantEmail = document.getElementById('memory-participant-email');
const memoryParticipantCreateSubmit = document.getElementById('memory-participant-create-submit');
const memoryParticipantCreateCancel = document.getElementById('memory-participant-create-cancel');
const memoryPhotoTagsDialog = document.getElementById('memory-photo-tags-dialog');
const memoryPhotoTagsClose = document.getElementById('memory-photo-tags-close');
const memoryPhotoTagsIntro = document.getElementById('memory-photo-tags-intro');
const memoryPhotoTagsList = document.getElementById('memory-photo-tags-list');
const memoryPhotoTagsEmpty = document.getElementById('memory-photo-tags-empty');
const memoryPhotoTagsMessage = document.getElementById('memory-photo-tags-message');
const memoryPhotoTagsCancel = document.getElementById('memory-photo-tags-cancel');
const memoryPhotoTagsSave = document.getElementById('memory-photo-tags-save');


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
  memoryPhotoShare.disabled = inProgress;
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

function participantName(person) {
  return [person.first_name, person.last_name].filter(Boolean).join(' ') || 'Contatto senza nome';
}

function setParticipantsMessage(text = '', isError = false) {
  memoryParticipantsMessage.textContent = text;
  memoryParticipantsMessage.classList.toggle('is-error', isError);
}

function setParticipantsBusy(inProgress) {
  memoryParticipantsLoading = inProgress;
  memoryParticipantSearch.disabled = inProgress;
  memoryParticipantCreateToggle.disabled = inProgress;
  memoryParticipantCreateSubmit.disabled = inProgress;
  memoryParticipantCreateCancel.disabled = inProgress;
}

function renderParticipantSearch() {
  const query = memoryParticipantSearch.value.trim().toLocaleLowerCase('it-IT');
  memoryParticipantSearchResults.replaceChildren();
  if (!memoryId || !query) {
    memoryParticipantSearchResults.hidden = true;
    return;
  }

  const selectedContactIds = new Set(memoryParticipants.map((participant) => participant.contact_id));
  const matches = memoryContacts.filter((contact) => (
    !selectedContactIds.has(contact.id)
    && participantName(contact).toLocaleLowerCase('it-IT').includes(query)
  )).slice(0, 8);

  if (!matches.length) {
    const empty = document.createElement('p');
    empty.className = 'fa-v2-status';
    empty.textContent = 'Nessun contatto disponibile.';
    memoryParticipantSearchResults.append(empty);
  } else {
    matches.forEach((contact) => {
      const row = document.createElement('div');
      row.className = 'fa-v2-list-row';
      const details = document.createElement('div');
      const name = document.createElement('strong');
      name.textContent = participantName(contact);
      details.append(name);
      const actions = document.createElement('div');
      actions.className = 'fa-v2-card-actions';
      const add = document.createElement('button');
      add.type = 'button';
      add.className = 'fa-v2-button fa-v2-button--secondary';
      add.textContent = 'Aggiungi';
      add.disabled = memoryParticipantsLoading;
      add.addEventListener('click', () => { void addMemoryParticipant(contact.id); });
      actions.append(add);
      row.append(details, actions);
      memoryParticipantSearchResults.append(row);
    });
  }
  memoryParticipantSearchResults.hidden = false;
}

function renderMemoryParticipants() {
  memoryParticipantsList.replaceChildren();
  memoryParticipantsEmpty.hidden = Boolean(memoryParticipants.length) || !memoryId;
  memoryParticipants.forEach((participant) => {
    const row = document.createElement('div');
    row.className = 'fa-v2-list-row';
    const details = document.createElement('div');
    const name = document.createElement('strong');
    name.textContent = participantName(participant);
    details.append(name);
    if (participant.email) {
      const email = document.createElement('p');
      email.className = 'fa-v2-status';
      email.textContent = participant.email;
      details.append(email);
    }
    const actions = document.createElement('div');
    actions.className = 'fa-v2-card-actions';
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'fa-v2-button fa-v2-button--secondary list-item-delete';
    remove.textContent = 'Rimuovi dall’album';
    remove.disabled = memoryParticipantsLoading;
    remove.addEventListener('click', () => { void removeMemoryParticipant(participant.contact_id); });
    actions.append(remove);
    row.append(details, actions);
    memoryParticipantsList.append(row);
  });
  renderParticipantSearch();
}

async function loadMemoryContacts() {
  const { data, error } = await memoryClient.rpc('get_my_contacts');
  if (error) throw error;
  memoryContacts = Array.isArray(data) ? data : [];
}

async function loadMemoryParticipants() {
  if (!memoryId) {
    memoryParticipants = [];
    memoryParticipantsNote.hidden = false;
    memoryParticipantsControls.hidden = true;
    memoryParticipantsEmpty.hidden = true;
    memoryParticipantsList.replaceChildren();
    memoryParticipantSearchResults.hidden = true;
    return;
  }

  setParticipantsBusy(true);
  try {
    const [{ data: participants, error: participantsError }] = await Promise.all([
      memoryClient.rpc('get_memory_participants', { p_memory_id: memoryId }),
      loadMemoryContacts()
    ]);
    if (participantsError) throw participantsError;
    memoryParticipants = Array.isArray(participants) ? participants : [];
    memoryParticipantsNote.hidden = true;
    memoryParticipantsControls.hidden = false;
    setParticipantsMessage('');
    renderMemoryParticipants();
  } catch (error) {
    memoryParticipants = [];
    memoryParticipantsControls.hidden = true;
    memoryParticipantsEmpty.hidden = true;
    memoryParticipantsList.replaceChildren();
    setParticipantsMessage(rpcMessage('caricare i partecipanti', error), true);
  } finally {
    setParticipantsBusy(false);
    if (!memoryParticipantsControls.hidden) renderMemoryParticipants();
  }
}

async function addMemoryParticipant(contactId) {
  if (!memoryId || memoryParticipantsLoading) return;
  setParticipantsBusy(true);
  setParticipantsMessage('Aggiunta partecipante...');
  try {
    const { error } = await memoryClient.rpc('add_memory_participant', {
      p_memory_id: memoryId,
      p_contact_id: contactId
    });
    if (error) {
      if (error.message === 'memory_participant_already_exists') {
        await loadMemoryParticipants();
        setParticipantsMessage('Questo contatto partecipa già all’album.', true);
        return;
      }
      throw error;
    }
    memoryParticipantSearch.value = '';
    setParticipantsMessage('Partecipante aggiunto.');
    await loadMemoryParticipants();
  } catch (error) {
    setParticipantsMessage(rpcMessage('aggiungere il partecipante', error), true);
  } finally {
    setParticipantsBusy(false);
  }
}

async function removeMemoryParticipant(contactId) {
  if (!memoryId || memoryParticipantsLoading) return;
  const confirmed = await FamilAreaConfirm.confirm({
    title: 'Rimuovere il partecipante?',
    message: 'Il contatto resterà nella tua rubrica.',
    confirmText: 'Rimuovi'
  });
  if (!confirmed) return;

  setParticipantsBusy(true);
  setParticipantsMessage('Rimozione partecipante...');
  try {
    const { error } = await memoryClient.rpc('remove_memory_participant', {
      p_memory_id: memoryId,
      p_contact_id: contactId
    });
    if (error) throw error;
    setParticipantsMessage('Partecipante rimosso dall’album.');
    await loadMemoryParticipants();
  } catch (error) {
    setParticipantsMessage(rpcMessage('rimuovere il partecipante', error), true);
  } finally {
    setParticipantsBusy(false);
  }
}

function closeMemoryParticipantCreate() {
  memoryParticipantCreate.hidden = true;
  memoryParticipantFirstName.value = '';
  memoryParticipantLastName.value = '';
  memoryParticipantEmail.value = '';
}

async function createAndAddMemoryParticipant() {
  if (!memoryId || memoryParticipantsLoading) return;
  const firstName = memoryParticipantFirstName.value.trim();
  const lastName = memoryParticipantLastName.value.trim();
  const email = memoryParticipantEmail.value.trim();
  if (!firstName) {
    setParticipantsMessage('Inserisci il nome del contatto.', true);
    memoryParticipantFirstName.focus();
    return;
  }
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    setParticipantsMessage('Inserisci un indirizzo email valido.', true);
    memoryParticipantEmail.focus();
    return;
  }

  setParticipantsBusy(true);
  setParticipantsMessage('Creazione contatto...');
  try {
    const { data: contactId, error: contactError } = await memoryClient.rpc('create_contact', {
      p_first_name: firstName,
      p_last_name: lastName || null,
      p_birth_date: null
    });
    if (contactError || !contactId) throw contactError || new Error('Contatto non creato');
    if (email) {
      const { error: methodsError } = await memoryClient.rpc('replace_contact_methods', {
        p_contact_id: contactId,
        p_methods: [{ type: 'email', value: email, is_primary: true }]
      });
      if (methodsError) throw methodsError;
    }
    const { error: participantError } = await memoryClient.rpc('add_memory_participant', {
      p_memory_id: memoryId,
      p_contact_id: contactId
    });
    if (participantError) throw participantError;
    closeMemoryParticipantCreate();
    memoryParticipantSearch.value = '';
    setParticipantsMessage('Contatto creato e aggiunto all’album.');
    await loadMemoryParticipants();
  } catch (error) {
    setParticipantsMessage(rpcMessage('creare il contatto', error), true);
  } finally {
    setParticipantsBusy(false);
  }
}
function setMemoryPhotoTagsMessage(text = '', isError = false) {
  memoryPhotoTagsMessage.textContent = text;
  memoryPhotoTagsMessage.classList.toggle('is-error', isError);
}

function photoTagIdsForAttachment(id) {
  return memoryPhotoParticipantTags.get(id) || [];
}

function photoTagStateForAttachment(id) {
  return memoryPhotoTagStates.get(id) || null;
}

function isOwnerTaggedForAttachment(id) {
  const state = photoTagStateForAttachment(id);
  if (state?.statePresent) return state.ownerTagged;
  return photoTagIdsForAttachment(id).length === 0;
}

function photoTagCountForAttachment(id) {
  const state = photoTagStateForAttachment(id);
  return photoTagIdsForAttachment(id).length + (state?.statePresent && state.ownerTagged ? 1 : 0);
}

async function loadMemoryPhotoParticipantTags() {
  memoryPhotoParticipantTags = new Map();
  memoryPhotoTagStates = new Map();
  memoryPhotoTagsLoaded = false;
  if (!memoryId) return false;

  const { data, error } = await memoryClient.rpc('get_memory_photo_tags', {
    p_memory_id: memoryId
  });
  if (error) {
    console.error('[FamilArea memories] caricare i tag delle fotografie', error);
    return false;
  }

  (Array.isArray(data) ? data : []).forEach((tag) => {
    if (!tag?.attachment_id) return;
    const participantIds = Array.isArray(tag.memory_participant_ids)
      ? tag.memory_participant_ids.filter((id) => typeof id === 'string')
      : [];
    memoryPhotoParticipantTags.set(tag.attachment_id, participantIds);
    memoryPhotoTagStates.set(tag.attachment_id, {
      statePresent: tag.state_present === true,
      ownerTagged: tag.owner_tagged === true
    });
  });

  memoryPhotoTagsLoaded = true;
  return true;
}

function renderMemoryPhotoTagChoices() {
  memoryPhotoTagsList.replaceChildren();

  const selected = new Set(photoTagIdsForAttachment(activeMemoryPhotoAttachmentId));
  const ownerRow = document.createElement('label');
  ownerRow.className = 'fa-v2-list-row';
  const ownerInput = document.createElement('input');
  ownerInput.type = 'checkbox';
  ownerInput.dataset.memoryPhotoOwner = 'true';
  ownerInput.checked = isOwnerTaggedForAttachment(activeMemoryPhotoAttachmentId);
  ownerInput.disabled = memoryPhotoTagsSaving;
  const ownerName = document.createElement('strong');
  ownerName.textContent = 'Io';
  ownerRow.append(ownerInput, ownerName);
  memoryPhotoTagsList.append(ownerRow);

  memoryPhotoTagsEmpty.hidden = Boolean(memoryParticipants.length);
  memoryParticipants.forEach((participant) => {
    const row = document.createElement('label');
    row.className = 'fa-v2-list-row';
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.value = participant.id;
    input.dataset.memoryParticipantId = 'true';
    input.checked = selected.has(participant.id);
    input.disabled = memoryPhotoTagsSaving;
    const name = document.createElement('strong');
    name.textContent = participantName(participant);
    row.append(input, name);
    memoryPhotoTagsList.append(row);
  });

  memoryPhotoTagsSave.disabled = memoryPhotoTagsSaving;
}

function closeMemoryPhotoTagsDialog() {
  if (memoryPhotoTagsSaving) return;
  activeMemoryPhotoAttachmentId = '';
  memoryPhotoTagsDialog.hidden = true;
  document.body.classList.remove('confirm-modal-open');
}

function openMemoryPhotoTagsDialog(attachment) {
  if (!memoryId || !attachment?.id || !memoryPhotoTagsLoaded) return;
  activeMemoryPhotoAttachmentId = attachment.id;
  memoryPhotoTagsIntro.textContent = `Seleziona le persone presenti in "${attachment.original_filename}".`;
  setMemoryPhotoTagsMessage('');
  renderMemoryPhotoTagChoices();
  memoryPhotoTagsDialog.hidden = false;
  document.body.classList.add('confirm-modal-open');
  memoryPhotoTagsList.querySelector('input')?.focus();
}

async function saveMemoryPhotoTags() {
  if (!memoryId || !activeMemoryPhotoAttachmentId || memoryPhotoTagsSaving) return;

  const ownerTagged = memoryPhotoTagsList.querySelector('[data-memory-photo-owner="true"]')?.checked === true;
  const ids = [...memoryPhotoTagsList.querySelectorAll('[data-memory-participant-id="true"]:checked')]
    .map((input) => input.value);
  memoryPhotoTagsSaving = true;
  memoryPhotoTagsSave.disabled = true;
  setMemoryPhotoTagsMessage('Salvataggio tag...');

  try {
    const { error } = await memoryClient.rpc('replace_memory_photo_tags', {
      p_memory_id: memoryId,
      p_attachment_id: activeMemoryPhotoAttachmentId,
      p_owner_tagged: ownerTagged,
      p_memory_participant_ids: ids
    });
    if (error) throw error;

    memoryPhotoParticipantTags.set(activeMemoryPhotoAttachmentId, ids);
    memoryPhotoTagStates.set(activeMemoryPhotoAttachmentId, {
      statePresent: true,
      ownerTagged
    });
    memoryPhotoTagsSaving = false;
    closeMemoryPhotoTagsDialog();
    await photoAttachments?.load();
    setMessage('Tag della fotografia aggiornati.');
  } catch (error) {
    memoryPhotoTagsSaving = false;
    memoryPhotoTagsSave.disabled = false;
    setMemoryPhotoTagsMessage(rpcMessage('salvare i tag della fotografia', error), true);
  }
}

function createPhotoActions(attachment) {
  if (attachment?.id && photoMimeTypes.includes(attachment.mime_type)) memoryPhotoShareableAttachments.set(attachment.id, attachment);
  const cover = createCoverActions(attachment);
  const actions = Array.isArray(cover) ? [...cover] : (cover ? [cover] : []);
  if (!memoryPhotoTagsLoaded) return actions;

  const tag = document.createElement('button');
  tag.type = 'button';
  tag.className = 'secondary-button';
  const count = photoTagCountForAttachment(attachment.id);
  tag.textContent = count ? `Tag persone (${count})` : 'Tag persone';
  tag.addEventListener('click', () => openMemoryPhotoTagsDialog(attachment));
  actions.push(tag);
  return actions;
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
  memoryPhotoShare.hidden = !memoryPhotoShareOwner;
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
    renderAttachmentActions: createPhotoActions,
    onAttachmentDeleted: async (attachment) => {
      memoryPhotoShareableAttachments.delete(attachment.id);
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
      const isPendingAndValid = invite.status === 'pending'
        && typeof invite.invitation_id === 'string'
        && Number.isFinite(Date.parse(invite.expires_at))
        && Date.parse(invite.expires_at) > Date.now();
      if (isPendingAndValid) {
        const actions = document.createElement('div');
        actions.className = 'fa-v2-card-actions';
        const resend = document.createElement('button');
        resend.type = 'button';
        resend.className = 'fa-v2-button fa-v2-button--secondary';
        resend.textContent = 'Reinvia email';
        resend.addEventListener('click', async () => {
          if (actionPending) return;
          setBusy(true);
          setStatus('Reinvio dellâ€™email in corsoâ€¦');
          const { data, error: resendError } = await memoryClient.functions.invoke('send-memory-share-invitation', {
            body: { invitation_id: invite.invitation_id }
          });
          setBusy(false);
          if (resendError || !data?.invitation_id || data.status !== 'pending') {
            setStatus(rpcMessage('reinviare lâ€™email di invito', resendError || new Error('Consegna non confermata')), true);
            return;
          }
          await refreshEmailManagement();
          setStatus('Email di invito reinviata.');
        });
        actions.append(resend);
        row.append(actions);
      }
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

const memoryPhotoShareEmailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function memoryPhotoShareStatusLabel(status) {
  return ({ pending: 'In attesa di accettazione', accepted: 'Accettata', declined: 'Rifiutata', revoked: 'Revocata', expired: 'Scaduta', cancelled: 'Annullata' })[status] || 'Stato non disponibile';
}

function normalizedMemoryPhotoShareEmail(value) {
  const email = typeof value === 'string' ? value.trim().toLowerCase() : '';
  return email && email.length <= 254 && memoryPhotoShareEmailPattern.test(email) ? email : '';
}

function availableMemoryPhotoSharePhotos() {
  return [...memoryPhotoShareableAttachments.values()]
    .filter((attachment) => attachment?.id && photoMimeTypes.includes(attachment.mime_type));
}

async function getMemoryPhotoShares() {
  const { data, error } = await memoryClient.rpc('get_memory_photo_shares', { p_memory_id: memoryId });
  if (error) throw error;
  return Array.isArray(data) ? data : [];
}

async function getMemoryPhotoShareAttachmentIds(shareId) {
  const { data, error } = await memoryClient.rpc('get_memory_photo_share_attachments', { p_share_id: shareId });
  if (error) throw error;
  return new Set((Array.isArray(data) ? data : []).map((attachment) => attachment?.attachment_id).filter(Boolean));
}

function openMemoryPhotoShareDialog(editShare = null) {
  if (!memoryId || !memoryPhotoShareOwner || document.getElementById('memory-photo-share-overlay')) return;

  const photos = availableMemoryPhotoSharePhotos();
  if (!photos.length) {
    setMessage('Aggiungi almeno una fotografia all’album prima di condividerla.', true);
    return;
  }

  const previousFocus = document.activeElement;
  const background = [...document.body.children].filter((element) => element.id !== 'memory-photo-share-overlay');
  const previousInert = background.map((element) => ({ element, inert: element.inert }));
  previousInert.forEach(({ element }) => { element.inert = true; });
  document.body.classList.add('confirm-modal-open');

  const overlay = document.createElement('div');
  overlay.id = 'memory-photo-share-overlay';
  overlay.className = 'confirm-modal-overlay';
  const dialog = document.createElement('section');
  dialog.className = 'confirm-modal memory-share-email-dialog';
  dialog.setAttribute('role', 'dialog');
  dialog.setAttribute('aria-modal', 'true');
  dialog.setAttribute('aria-labelledby', 'memory-photo-share-title');
  dialog.tabIndex = -1;
  const close = document.createElement('button');
  close.type = 'button';
  close.className = 'confirm-modal-close';
  close.setAttribute('aria-label', 'Chiudi');
  close.textContent = '×';
  const title = document.createElement('h2');
  title.id = 'memory-photo-share-title';
  title.className = 'confirm-modal-title';
  title.textContent = editShare ? 'Modifica fotografie condivise' : 'Condividi fotografie';
  const intro = document.createElement('p');
  intro.className = 'confirm-modal-message';
  intro.textContent = editShare
    ? 'Scegli le fotografie che resteranno accessibili a questo destinatario.'
    : 'Seleziona le fotografie e i destinatari. La consegna dell’email verrà messa in coda.';
  const status = document.createElement('p');
  status.className = 'fa-v2-status';
  status.setAttribute('aria-live', 'polite');
  const photoHeading = document.createElement('h3');
  photoHeading.textContent = 'Fotografie da condividere';
  const photoList = document.createElement('div');
  photoList.className = 'fa-v2-list memory-photo-share-grid';
  const recipientArea = document.createElement('div');
  const sharesHeading = document.createElement('h3');
  sharesHeading.textContent = 'Condivisioni esistenti';
  const sharesList = document.createElement('div');
  sharesList.className = 'fa-v2-list';
  const actions = document.createElement('div');
  actions.className = 'confirm-modal-actions';
  const cancel = document.createElement('button');
  cancel.type = 'button';
  cancel.className = 'fa-v2-button fa-v2-button--secondary confirm-modal-cancel';
  cancel.textContent = 'Annulla';
  const submit = document.createElement('button');
  submit.type = 'button';
  submit.className = 'fa-v2-button fa-v2-button--primary confirm-modal-confirm';
  submit.textContent = editShare ? 'Salva selezione' : 'Invia';
  actions.append(cancel, submit);
  dialog.append(close, title, intro, status, photoHeading, photoList);
  if (!editShare) dialog.append(recipientArea, sharesHeading, sharesList);
  dialog.append(actions);
  overlay.append(dialog);
  document.body.append(overlay);

  let busy = false;
  let selectionLoading = Boolean(editShare);
  let searchTimer;
  let selectedPhotoIds = new Set(photos.map((photo) => photo.id));
  const photoThumbnailUrls = new Map();
  const photoThumbnailRequests = new Map();
  const recipients = [];
  const setStatus = (message = '', isError = false) => {
    status.textContent = message;
    status.classList.toggle('is-error', isError);
  };
  const closeDialog = () => {
    if (busy) return;
    window.clearTimeout(searchTimer);
    document.removeEventListener('keydown', onKeyDown);
    overlay.remove();
    document.body.classList.remove('confirm-modal-open');
    previousInert.forEach(({ element, inert }) => { element.inert = inert; });
    if (previousFocus instanceof HTMLElement) previousFocus.focus();
  };
  const onKeyDown = (event) => { if (event.key === 'Escape') closeDialog(); };
  const setBusy = (inProgress) => {
    busy = inProgress;
    dialog.querySelectorAll('button, input').forEach((element) => { element.disabled = inProgress; });
    if (!inProgress) render();
  };
  close.addEventListener('click', closeDialog);
  cancel.addEventListener('click', closeDialog);
  overlay.addEventListener('click', (event) => { if (event.target === overlay) closeDialog(); });
  document.addEventListener('keydown', onKeyDown);

  const selectedPhotoCount = () => selectedPhotoIds.size;
  const getPhotoThumbnailUrl = (photo) => {
    if (photoThumbnailUrls.has(photo.id)) return Promise.resolve(photoThumbnailUrls.get(photo.id));
    const pendingRequest = photoThumbnailRequests.get(photo.id);
    if (pendingRequest) return pendingRequest;

    const request = window.FamilAreaAttachmentPreview.getSignedUrl(memoryClient, photo, 300)
      .then((signedUrl) => {
        photoThumbnailUrls.set(photo.id, signedUrl);
        return signedUrl;
      })
      .catch(() => {
        photoThumbnailUrls.set(photo.id, null);
        return null;
      })
      .finally(() => photoThumbnailRequests.delete(photo.id));
    photoThumbnailRequests.set(photo.id, request);
    return request;
  };
  const renderPhotoThumbnail = (photo, thumbnail, filename) => {
    const setUnavailable = () => {
      thumbnail.replaceChildren();
      thumbnail.setAttribute('aria-busy', 'false');
      const fallback = document.createElement('span');
      fallback.className = 'memory-photo-share-thumbnail-fallback';
      fallback.textContent = 'Anteprima non disponibile';
      thumbnail.append(fallback);
    };

    void getPhotoThumbnailUrl(photo).then((signedUrl) => {
      if (!thumbnail.isConnected) return;
      if (!signedUrl) {
        setUnavailable();
        return;
      }
      const image = document.createElement('img');
      image.src = signedUrl;
      image.alt = `Miniatura di ${filename}`;
      image.addEventListener('error', setUnavailable, { once: true });
      thumbnail.setAttribute('aria-busy', 'false');
      thumbnail.replaceChildren(image);
    });
  };
  const renderPhotos = () => {
    photoList.replaceChildren();
    photos.forEach((photo) => {
      const filename = photo.original_filename || 'Fotografia';
      const card = document.createElement('article');
      card.className = 'memory-photo-share-card';
      card.classList.toggle('is-selected', selectedPhotoIds.has(photo.id));
      const thumbnail = document.createElement('div');
      thumbnail.className = 'memory-photo-share-thumbnail';
      thumbnail.setAttribute('aria-busy', 'true');
      const loading = document.createElement('span');
      loading.className = 'memory-photo-share-thumbnail-fallback';
      loading.textContent = 'Caricamento anteprima...';
      thumbnail.append(loading);
      const row = document.createElement('label');
      row.className = 'memory-photo-share-selection';
      const input = document.createElement('input');
      input.type = 'checkbox';
      input.id = `memory-photo-share-selection-${photo.id}`;
      input.checked = selectedPhotoIds.has(photo.id);
      input.disabled = busy || selectionLoading || (editShare?.status === 'pending' && selectedPhotoCount() === 1 && input.checked);
      input.addEventListener('change', () => {
        if (input.checked) selectedPhotoIds.add(photo.id);
        else selectedPhotoIds.delete(photo.id);
        renderPhotos();
      });
      const name = document.createElement('span');
      name.className = 'memory-photo-share-filename';
      name.textContent = filename;
      row.append(input, name);
      card.append(thumbnail, row);
      photoList.append(card);
      renderPhotoThumbnail(photo, thumbnail, filename);
    });
  };

  const addRecipient = (recipient) => {
    const email = normalizedMemoryPhotoShareEmail(recipient?.email);
    if (!email) return false;
    if (recipients.some((item) => item.email === email)) return false;
    recipients.push({ email, contactId: typeof recipient.contactId === 'string' ? recipient.contactId : null, label: recipient.label || email });
    return true;
  };
  const renderRecipients = () => {
    recipientArea.replaceChildren();
    const heading = document.createElement('h3');
    heading.textContent = 'Destinatari';
    const note = document.createElement('p');
    note.className = 'confirm-modal-message';
    note.textContent = 'Scegli contatti con email oppure aggiungi un indirizzo email.';
    const search = document.createElement('input');
    search.type = 'search';
    search.className = 'fa-v2-input';
    search.placeholder = 'Cerca nella rubrica';
    search.autocomplete = 'off';
    const results = document.createElement('div');
    results.className = 'fa-v2-list';
    const manualEmail = document.createElement('input');
    manualEmail.type = 'email';
    manualEmail.className = 'fa-v2-input';
    manualEmail.placeholder = 'nome@esempio.it';
    manualEmail.autocomplete = 'email';
    const addEmail = document.createElement('button');
    addEmail.type = 'button';
    addEmail.className = 'fa-v2-button fa-v2-button--secondary';
    addEmail.textContent = 'Aggiungi email';
    const selected = document.createElement('div');
    selected.className = 'fa-v2-list';
    const renderResults = () => {
      const query = search.value.trim().toLocaleLowerCase('it-IT');
      results.replaceChildren();
      if (query.length < 2) return;
      const matches = memoryContacts
        .map((contact) => ({ contact, email: normalizedMemoryPhotoShareEmail(contact.primary_email || contact.email) }))
        .filter(({ contact, email }) => email && (`${participantName(contact)} ${email}`).toLocaleLowerCase('it-IT').includes(query))
        .slice(0, 12);
      if (!matches.length) {
        results.textContent = 'Nessun contatto con un indirizzo email valido.';
        return;
      }
      matches.forEach(({ contact, email }) => {
        const row = document.createElement('div');
        row.className = 'fa-v2-list-row';
        const details = document.createElement('div');
        const name = document.createElement('strong');
        name.textContent = participantName(contact);
        const address = document.createElement('p');
        address.className = 'fa-v2-status';
        address.textContent = email;
        details.append(name, address);
        const add = document.createElement('button');
        add.type = 'button';
        add.className = 'fa-v2-button fa-v2-button--secondary';
        add.textContent = recipients.some((item) => item.email === email) ? 'Aggiunto' : 'Aggiungi';
        add.disabled = busy || recipients.some((item) => item.email === email);
        add.addEventListener('click', () => { if (addRecipient({ email, contactId: contact.id, label: participantName(contact) })) render(); });
        row.append(details, add);
        results.append(row);
      });
    };
    recipients.forEach((recipient) => {
      const row = document.createElement('div');
      row.className = 'fa-v2-list-row';
      const details = document.createElement('div');
      const label = document.createElement('strong');
      label.textContent = recipient.label;
      const email = document.createElement('p');
      email.className = 'fa-v2-status';
      email.textContent = recipient.email;
      details.append(label, email);
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'fa-v2-button fa-v2-button--secondary list-item-delete';
      remove.textContent = 'Rimuovi';
      remove.disabled = busy;
      remove.addEventListener('click', () => { recipients.splice(recipients.indexOf(recipient), 1); render(); });
      row.append(details, remove);
      selected.append(row);
    });
    search.addEventListener('input', () => {
      window.clearTimeout(searchTimer);
      searchTimer = window.setTimeout(renderResults, 200);
    });
    addEmail.addEventListener('click', () => {
      if (!addRecipient({ email: manualEmail.value, label: manualEmail.value.trim() })) {
        setStatus('Inserisci un indirizzo email valido e non già selezionato.', true);
        return;
      }
      setStatus('');
      render();
    });
    recipientArea.append(heading, note, search, results, manualEmail, addEmail, selected);
  };

  const renderShares = async () => {
    sharesList.replaceChildren();
    try {
      const shares = await getMemoryPhotoShares();
      if (!shares.length) {
        sharesList.textContent = 'Nessuna condivisione fotografica.';
        return;
      }
      shares.forEach((share) => {
        const row = document.createElement('div');
        row.className = 'fa-v2-list-row';
        const details = document.createElement('div');
        const email = document.createElement('strong');
        email.textContent = share.recipient_email || 'Destinatario non disponibile';
        const meta = document.createElement('p');
        meta.className = 'fa-v2-status';
        meta.textContent = `${memoryPhotoShareStatusLabel(share.status)} · ${Number(share.photo_count) || 0} fotografi${Number(share.photo_count) === 1 ? 'a' : 'e'}`;
        details.append(email, meta);
        const rowActions = document.createElement('div');
        rowActions.className = 'fa-v2-card-actions';
        if (share.status === 'pending' || share.status === 'accepted') {
          const edit = document.createElement('button');
          edit.type = 'button';
          edit.className = 'fa-v2-button fa-v2-button--secondary';
          edit.textContent = 'Modifica foto';
          edit.disabled = busy;
          edit.addEventListener('click', () => { closeDialog(); openMemoryPhotoShareDialog(share); });
          const revoke = document.createElement('button');
          revoke.type = 'button';
          revoke.className = 'fa-v2-button fa-v2-button--secondary list-item-delete';
          revoke.textContent = 'Revoca';
          revoke.disabled = busy;
          revoke.addEventListener('click', async () => {
            const confirmed = await FamilAreaConfirm.confirm({ variant: 'danger', title: 'Revocare la condivisione?', message: 'Il destinatario non potrà più visualizzare queste fotografie.', confirmText: 'Revoca' });
            if (!confirmed || busy) return;
            setBusy(true);
            setStatus('Revoca in corso...');
            const { error } = await memoryClient.rpc('revoke_memory_photo_share', { p_share_id: share.share_id });
            setBusy(false);
            if (error) setStatus(rpcMessage('revocare la condivisione fotografica', error), true);
            else {
              setStatus('Condivisione revocata.');
              await renderShares();
            }
          });
          rowActions.append(edit, revoke);
        }
        row.append(details, rowActions);
        sharesList.append(row);
      });
    } catch (error) {
      setStatus(rpcMessage('caricare le condivisioni fotografiche', error), true);
    }
  };

  const render = () => {
    renderPhotos();
    if (!editShare) renderRecipients();
    submit.disabled = busy || selectionLoading || (!editShare && (selectedPhotoCount() === 0 || recipients.length === 0)) || (editShare?.status === 'pending' && selectedPhotoCount() === 0);
  };

  submit.addEventListener('click', async () => {
    if (busy || selectionLoading || (!editShare && (selectedPhotoCount() === 0 || recipients.length === 0)) || (editShare?.status === 'pending' && selectedPhotoCount() === 0)) return;
    setBusy(true);
    const attachmentIds = [...selectedPhotoIds];
    try {
      if (editShare) {
        setStatus('Aggiornamento della selezione...');
        const { data, error } = await memoryClient.rpc('replace_memory_photo_share_attachments', {
          p_share_id: editShare.share_id,
          p_attachment_ids: attachmentIds
        });
        if (error) throw error;
        const added = Number(data?.added_photo_count) || 0;
        const removed = Number(data?.removed_photo_count) || 0;
        setStatus(added
          ? `Selezione aggiornata: ${added} fotografi${added === 1 ? 'a aggiunta' : 'e aggiunte'}. L’email di aggiornamento è in coda.`
          : removed ? 'Selezione aggiornata. L’accesso alle fotografie rimosse è stato revocato.' : 'La selezione non è cambiata.');
      } else {
        setStatus('Creazione delle condivisioni in corso...');
        let queued = 0;
        const failures = [];
        for (const recipient of recipients) {
          const { data, error } = await memoryClient.functions.invoke('send-memory-photo-share', {
            body: {
              memory_id: memoryId,
              recipient: { email: recipient.email, contact_id: recipient.contactId },
              attachment_ids: attachmentIds
            }
          });
          if (error || !data?.share_id || data.status !== 'pending' || data.delivery_queued !== true) failures.push(recipient.email);
          else queued += 1;
        }
        if (failures.length) {
          setStatus(queued
            ? `${queued} condivision${queued === 1 ? 'e creata' : 'i create'} e consegna email in coda. Alcuni destinatari non sono stati aggiunti.`
            : 'Impossibile creare le condivisioni richieste.', true);
        } else {
          setStatus(`${queued} condivision${queued === 1 ? 'e creata' : 'i create'}: la consegna email è in coda.`);
        }
        recipients.splice(0, recipients.length);
      }
      if (!editShare) await renderShares();
    } catch (error) {
      setStatus(rpcMessage(editShare ? 'aggiornare la selezione fotografica' : 'creare la condivisione fotografica', error), true);
    } finally {
      setBusy(false);
    }
  });

  render();
  if (editShare) {
    setStatus('Caricamento della selezione...');
    void getMemoryPhotoShareAttachmentIds(editShare.share_id).then((ids) => {
      selectedPhotoIds = ids;
      selectionLoading = false;
      setStatus('');
      render();
    }).catch((error) => {
      selectionLoading = false;
      setStatus(rpcMessage('caricare la selezione fotografica', error), true);
      render();
    });
  } else {
    void renderShares();
  }
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
    await loadMemoryParticipants();
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
  const { data: currentAccount, error: currentAccountError } = await memoryClient.rpc('get_current_account');
  memoryPhotoShareOwner = !currentAccountError
    && typeof currentAccount?.account_id === 'string'
    && currentAccount.account_id === data.owner_account_id;
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
  await loadMemoryParticipants();
  if (await loadMemoryPhotoParticipantTags()) await photoAttachments?.load();
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
    await loadMemoryParticipants();

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

memoryParticipantSearch.addEventListener('input', renderParticipantSearch);
memoryParticipantCreateToggle.addEventListener('click', () => {
  memoryParticipantCreate.hidden = !memoryParticipantCreate.hidden;
  if (!memoryParticipantCreate.hidden) memoryParticipantFirstName.focus();
});
memoryParticipantCreateCancel.addEventListener('click', closeMemoryParticipantCreate);
memoryParticipantCreateSubmit.addEventListener('click', () => { void createAndAddMemoryParticipant(); });
memoryPhotoTagsClose.addEventListener('click', closeMemoryPhotoTagsDialog);
memoryPhotoTagsCancel.addEventListener('click', closeMemoryPhotoTagsDialog);
memoryPhotoTagsSave.addEventListener('click', () => { void saveMemoryPhotoTags(); });
document.addEventListener('keydown', (event) => { if (event.key === 'Escape' && !memoryPhotoTagsDialog.hidden) closeMemoryPhotoTagsDialog(); });

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
memoryPhotoShare.addEventListener('click', () => { openMemoryPhotoShareDialog(); });

void loadMemory().then(setupBrowserBackGuard);

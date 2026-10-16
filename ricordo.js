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
const memoryPageTitle = document.getElementById('memory-page-title');
const memoryPageIntro = document.getElementById('memory-page-intro');
const memoryPhotosSection = document.getElementById('memory-photos-section');
const memoryDocumentsSection = document.getElementById('memory-documents-section');
const memoryBackLink = document.getElementById('memory-back-link');
const memoryCancel = document.getElementById('memory-cancel');

const photoMimeTypes = ['image/jpeg', 'image/png', 'image/webp'];
const documentMimeTypes = ['application/pdf'];

function setMessage(text = '', isError = false) {
  memoryMessage.textContent = text;
  memoryMessage.classList.toggle('is-error', isError);
}

function setSaving(inProgress) {
  memorySubmit.disabled = inProgress;
  memoryDelete.disabled = inProgress;
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

function updatePageForStoredMemory({ showDocuments = true } = {}) {
  memoryPageTitle.textContent = 'Modifica album';
  memoryPageIntro.textContent = 'Aggiorna l’album e le sue fotografie.';
  memorySubmit.textContent = 'Salva modifiche';
  memoryDelete.hidden = false;
  memoryPhotosSection.hidden = false;
  memoryDocumentsSection.hidden = !showDocuments;
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
  documentAttachments = attachmentController({
    input: document.getElementById('memory-document-input'),
    uploadControl: document.getElementById('memory-document-upload'),
    message: document.getElementById('memory-documents-message'),
    empty: document.getElementById('memory-documents-empty'),
    list: document.getElementById('memory-documents-list'),
    allowedMimeTypes: documentMimeTypes
  });
  await Promise.all([photoAttachments.load(), documentAttachments.load()]);
}

function rpcMessage(subject, error) {
  console.error(`[FamilArea memories] ${subject}`, error);
  const code = error?.code ? ` (${error.code})` : '';
  const reason = error?.message || error?.details || 'Risposta non disponibile.';
  return `Impossibile ${subject}${code}: ${reason}`;
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
      ? 'Rimuovi prima tutte le fotografie e i documenti collegati, poi elimina il ricordo.'
      : rpcMessage('eliminare l’album', error), true);
    return;
  }
  window.location.replace(timelineHref());
});

void loadMemory().then(setupBrowserBackGuard);

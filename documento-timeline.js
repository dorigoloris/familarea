const timelineDocumentClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const timelineDocumentParams = new URLSearchParams(window.location.search);
let timelineDocumentId = timelineDocumentParams.get('timeline_document_id') || '';
let timelineDocumentTimelineId = timelineDocumentParams.get('timeline_id') || '';
let timelineDocumentAttachments;
let timelineDocumentDraftAttachments;
let documentFormBaseline = null;
let documentLeavePromptInProgress = false;

const timelineDocumentForm = document.getElementById('timeline-document-form');
const timelineDocumentMessage = document.getElementById('timeline-document-message');
const timelineDocumentOccurredOn = document.getElementById('timeline-document-occurred-on');
const timelineDocumentTitle = document.getElementById('timeline-document-title');
const timelineDocumentDescription = document.getElementById('timeline-document-description');
const timelineDocumentSubmit = document.getElementById('timeline-document-submit');
const timelineDocumentDelete = document.getElementById('timeline-document-delete');
const timelineDocumentPageTitle = document.getElementById('timeline-document-page-title');
const timelineDocumentPageIntro = document.getElementById('timeline-document-page-intro');
const timelineDocumentBackLink = document.getElementById('timeline-document-back');
const timelineDocumentCancel = document.getElementById('timeline-document-cancel');

const timelineDocumentMimeTypes = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];

function setTimelineDocumentMessage(text = '', isError = false) {
  timelineDocumentMessage.textContent = text;
  timelineDocumentMessage.classList.toggle('is-error', isError);
}

function timelineDocumentRpcMessage(subject, error) {
  console.error(`[FamilArea timeline document] ${subject}`, error);
  const code = error?.code ? ` (${error.code})` : '';
  const reason = error?.message || error?.details || 'Risposta non disponibile.';
  return `Impossibile ${subject}${code}: ${reason}`;
}

function timelineDocumentTimelineHref() {
  const params = new URLSearchParams({ type: 'document' });
  if (timelineDocumentTimelineId) params.set('timeline_id', timelineDocumentTimelineId);
  return `timeline.html?${params}`;
}

function updateTimelineDocumentLinks() {
  const href = timelineDocumentTimelineHref();
  timelineDocumentBackLink.href = href;
  timelineDocumentCancel.href = href;
}

function currentTimelineDocumentFormState() {
  return JSON.stringify({
    occurredOn: timelineDocumentOccurredOn.value || '',
    title: timelineDocumentTitle.value.trim(),
    description: timelineDocumentDescription.value.trim() || null
  });
}

function captureTimelineDocumentBaseline() {
  documentFormBaseline = currentTimelineDocumentFormState();
}

function hasUnsavedTimelineDocumentChanges() {
  return documentFormBaseline !== null && (
    currentTimelineDocumentFormState() !== documentFormBaseline
    || Boolean(timelineDocumentDraftAttachments?.pendingCount())
  );
}

function setTimelineDocumentSaving(inProgress) {
  timelineDocumentSubmit.disabled = inProgress;
  timelineDocumentDelete.disabled = inProgress;
  timelineDocumentSubmit.textContent = inProgress
    ? 'Salvataggio...'
    : (timelineDocumentId ? 'Salva modifiche' : 'Salva documento');
}

function populateTimelineDocument(timelineDocument) {
  timelineDocumentTimelineId = timelineDocument.timeline_id || timelineDocumentTimelineId;
  timelineDocumentOccurredOn.value = timelineDocument.occurred_on || '';
  timelineDocumentTitle.value = timelineDocument.title || '';
  timelineDocumentDescription.value = timelineDocument.description || '';
}

async function verifyDocumentTimeline() {
  if (!timelineDocumentTimelineId) throw new Error('Timeline Documenti non specificata');
  const { data, error } = await timelineDocumentClient.rpc('get_my_timelines', { p_timeline_type: 'document' });
  if (error || !Array.isArray(data)) throw error || new Error('Risposta Timeline incompatibile');
  if (!data.some((timeline) => timeline.id === timelineDocumentTimelineId)) {
    throw new Error('Timeline Documenti non trovata o non disponibile');
  }
}

function updatePageForStoredTimelineDocument() {
  timelineDocumentPageTitle.textContent = 'Modifica documento';
  timelineDocumentPageIntro.textContent = 'Aggiorna il documento e gli allegati collegati.';
  timelineDocumentSubmit.textContent = 'Salva modifiche';
  timelineDocumentDelete.hidden = false;
  updateTimelineDocumentLinks();
}

function initialiseTimelineDocumentDraftAttachments() {
  if (timelineDocumentDraftAttachments || timelineDocumentId) return;
  timelineDocumentDraftAttachments = window.FamilAreaDeadlineAttachments.createDraft({
    client: timelineDocumentClient,
    input: document.getElementById('timeline-document-input'),
    uploadControl: document.getElementById('timeline-document-upload'),
    message: document.getElementById('timeline-document-attachments-message'),
    empty: document.getElementById('timeline-document-attachments-empty'),
    list: document.getElementById('timeline-document-attachments-list'),
    targetType: 'timeline_document',
    allowedMimeTypes: timelineDocumentMimeTypes,
    multipleProgressLabel: 'allegati',
    multipleCompleteLabel: 'Allegati caricati'
  });
}

async function initialiseTimelineDocumentAttachments() {
  if (!timelineDocumentId || timelineDocumentAttachments) return;
  updatePageForStoredTimelineDocument();
  timelineDocumentAttachments = window.FamilAreaDeadlineAttachments.create({
    client: timelineDocumentClient,
    targetId: timelineDocumentId,
    targetType: 'timeline_document',
    canManage: true,
    input: document.getElementById('timeline-document-input'),
    uploadControl: document.getElementById('timeline-document-upload'),
    message: document.getElementById('timeline-document-attachments-message'),
    empty: document.getElementById('timeline-document-attachments-empty'),
    list: document.getElementById('timeline-document-attachments-list'),
    allowedMimeTypes: timelineDocumentMimeTypes,
    allowMultiple: true,
    multipleProgressLabel: 'allegati',
    multipleCompleteLabel: 'Allegati caricati'
  });
  await timelineDocumentAttachments.load();
}

async function loadTimelineDocument() {
  const { data: sessionData, error: sessionError } = await timelineDocumentClient.auth.getSession();
  if (sessionError || !sessionData?.session) {
    window.location.replace(`login.html?return_to=${encodeURIComponent(`documento-timeline.html${window.location.search}`)}`);
    return;
  }

  try {
    if (!timelineDocumentId) {
      await verifyDocumentTimeline();
      initialiseTimelineDocumentDraftAttachments();
      timelineDocumentForm.hidden = false;
      setTimelineDocumentMessage('');
      captureTimelineDocumentBaseline();
      updateTimelineDocumentLinks();
      return;
    }

    const { data, error } = await timelineDocumentClient.rpc('get_timeline_document', {
      p_timeline_document_id: timelineDocumentId
    });
    if (error || !data?.id) throw error || new Error('Documento non trovato o non disponibile');

    populateTimelineDocument(data);
    await verifyDocumentTimeline();
    timelineDocumentForm.hidden = false;
    setTimelineDocumentMessage('');
    await initialiseTimelineDocumentAttachments();
    captureTimelineDocumentBaseline();
    updateTimelineDocumentLinks();
  } catch (error) {
    timelineDocumentForm.hidden = true;
    setTimelineDocumentMessage(timelineDocumentRpcMessage('caricare il documento', error), true);
  }
}

async function saveTimelineDocument({ redirectOnSuccess = true } = {}) {
  if (timelineDocumentSubmit.disabled) return false;

  const occurredOn = timelineDocumentOccurredOn.value;
  const title = timelineDocumentTitle.value.trim();
  const description = timelineDocumentDescription.value.trim() || null;
  if (!occurredOn || !title) {
    setTimelineDocumentMessage('Inserisci data e titolo del documento.', true);
    return false;
  }

  setTimelineDocumentSaving(true);
  setTimelineDocumentMessage('Salvataggio documento...');
  const rpcName = timelineDocumentId ? 'update_timeline_document' : 'create_timeline_document';
  const params = timelineDocumentId
    ? {
      p_timeline_document_id: timelineDocumentId,
      p_occurred_on: occurredOn,
      p_title: title,
      p_description: description
    }
    : {
      p_timeline_id: timelineDocumentTimelineId,
      p_occurred_on: occurredOn,
      p_title: title,
      p_description: description
    };

  try {
    const { data, error } = await timelineDocumentClient.rpc(rpcName, params);
    if (error || !data?.id) throw error || new Error('Risposta RPC incompatibile');

    const wasNew = !timelineDocumentId;
    timelineDocumentId = data.id;
    populateTimelineDocument(data);
    window.history.replaceState({}, '', `documento-timeline.html?${new URLSearchParams({
      timeline_document_id: timelineDocumentId,
      timeline_id: timelineDocumentTimelineId
    })}`);
    updatePageForStoredTimelineDocument();
    let uploadResult = { ok: true, failed: 0 };
    if (timelineDocumentDraftAttachments?.pendingCount()) {
      uploadResult = await timelineDocumentDraftAttachments.uploadSelected(timelineDocumentId);
    }
    if (uploadResult.ok) timelineDocumentDraftAttachments = undefined;
    captureTimelineDocumentBaseline();
    updateTimelineDocumentLinks();
    if (!uploadResult.ok) {
      setTimelineDocumentMessage(
        `Documento ${wasNew ? 'creato' : 'salvato'}, ma ${uploadResult.failed} allegat${uploadResult.failed === 1 ? 'o non è stato caricato' : 'i non sono stati caricati'}. Riprova senza creare un nuovo documento.`,
        true
      );
      return false;
    }
    setTimelineDocumentMessage(wasNew ? 'Documento e allegati salvati.' : 'Modifiche salvate.');
    if (redirectOnSuccess) window.location.replace(timelineDocumentTimelineHref());
    return true;
  } catch (error) {
    setTimelineDocumentMessage(timelineDocumentRpcMessage('salvare il documento', error), true);
    return false;
  } finally {
    setTimelineDocumentSaving(false);
  }
}

async function requestTimelineDocumentLeave(destination) {
  if (documentLeavePromptInProgress) return;
  if (!hasUnsavedTimelineDocumentChanges()) {
    destination();
    return;
  }

  documentLeavePromptInProgress = true;
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
      const saved = await saveTimelineDocument({ redirectOnSuccess: false });
      if (saved) destination();
    }
    if (choice === 'discard') destination();
  } finally {
    documentLeavePromptInProgress = false;
  }
}

timelineDocumentForm.addEventListener('submit', (event) => {
  event.preventDefault();
  void saveTimelineDocument();
});

document.addEventListener('click', (event) => {
  if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  const link = event.target.closest('a[href]');
  if (!link || link.target === '_blank' || link.hasAttribute('download')) return;
  const url = new URL(link.href, window.location.href);
  if (url.origin !== window.location.origin || (url.pathname === window.location.pathname && url.search === window.location.search)) return;
  event.preventDefault();
  event.stopImmediatePropagation();
  void requestTimelineDocumentLeave(() => window.location.assign(url.href));
}, true);

window.addEventListener('beforeunload', (event) => {
  if (!hasUnsavedTimelineDocumentChanges()) return;
  event.preventDefault();
  event.returnValue = '';
});

timelineDocumentDelete.addEventListener('click', async () => {
  if (!timelineDocumentId || timelineDocumentDelete.disabled) return;
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: 'Eliminare il documento?',
    message: 'Rimuovi prima tutti gli allegati collegati. Questa operazione non può essere annullata.',
    confirmText: 'Elimina documento'
  });
  if (!confirmed) return;

  setTimelineDocumentSaving(true);
  setTimelineDocumentMessage('Eliminazione documento...');
  try {
    const { error } = await timelineDocumentClient.rpc('delete_timeline_document', {
      p_timeline_document_id: timelineDocumentId
    });
    if (error) throw error;
    window.location.replace(timelineDocumentTimelineHref());
  } catch (error) {
    const hasAttachments = /remove timeline document attachments/i.test(error?.message || '');
    setTimelineDocumentMessage(
      hasAttachments
        ? 'Rimuovi prima tutti gli allegati, poi elimina il documento.'
        : timelineDocumentRpcMessage('eliminare il documento', error),
      true
    );
    setTimelineDocumentSaving(false);
  }
});

void loadTimelineDocument();

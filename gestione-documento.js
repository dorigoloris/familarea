const personalDocumentClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const personalDocumentForm = document.getElementById('personal-document-form');
const personalDocumentMessage = document.getElementById('deadline-form-message');
const personalDocumentType = document.getElementById('personal-document-type');
const personalDocumentHolder = document.getElementById('personal-document-holder');
const personalDocumentNumber = document.getElementById('personal-document-number');
const personalDocumentIssuedOn = document.getElementById('personal-document-issued-on');
const personalDocumentExpiryDate = document.getElementById('personal-document-expiry-date');
const personalDocumentReminder = document.getElementById('personal-document-reminder');
const personalDocumentIssuer = document.getElementById('personal-document-issuer');
const personalDocumentNotes = document.getElementById('personal-document-notes');
const personalDocumentDelete = document.getElementById('personal-document-delete');
const personalDocumentSubmit = document.getElementById('personal-document-submit');
const personalDocumentBackLink = document.getElementById('document-back-link');
const personalDocumentCancel = document.getElementById('personal-document-cancel');
const personalDocumentId = new URLSearchParams(window.location.search).get('document_id');
const personalDocumentFileSection = document.getElementById('personal-document-file-section');
const personalDocumentFileInput = document.getElementById('personal-document-file-input');
const personalDocumentFileUpload = document.getElementById('personal-document-file-upload');
const personalDocumentFileMessage = document.getElementById('personal-document-file-message');
const personalDocumentFileEmpty = document.getElementById('personal-document-file-empty');
const personalDocumentFileDetails = document.getElementById('personal-document-file-details');
const personalDocumentAttachmentPreview = window.FamilAreaAttachmentPreview;
let personalDocumentFamily = null;
let personalDocumentContext = null;
let editingPersonalDocument = null;
let personalDocumentOwner = null;
let personalDocumentMembers = [];
let personalDocumentAttachment = null;
let personalDocumentFileBusy = false;

function setPersonalDocumentMessage(text = '', isError = false, isSuccess = false) {
  personalDocumentMessage.textContent = text;
  personalDocumentMessage.classList.toggle('is-error', isError);
  personalDocumentMessage.classList.toggle('deadline-form-message--success', isSuccess);
}

function memberName(member) {
  return window.FamilAreaManagedContext.memberName(member);
}

function listHref() {
  return personalDocumentContext?.member
    ? window.FamilAreaManagedContext.withMember('gestione-scadenze-documenti.html', personalDocumentContext.member.id)
    : 'gestione-scadenze-documenti.html';
}

function memberIsEligible(member) {
  return member?.member_type === 'person' || member?.member_type === 'assisted_person';
}

function setHolderOptions(familyData, selected = '') {
  const options = [];
  if (personalDocumentContext?.member) {
    const member = personalDocumentContext.member;
    options.push({ value: `family_member:${member.id}`, text: memberName(member) });
    personalDocumentHolder.disabled = true;
  } else {
    const ownerName = memberName(familyData.owner) || 'Proprietario/a della Famiglia';
    options.push({ value: 'owner', text: ownerName });
    (familyData.members || []).filter(memberIsEligible).forEach((member) => {
      options.push({ value: `family_member:${member.id}`, text: memberName(member) });
    });
    personalDocumentHolder.disabled = false;
  }
  personalDocumentHolder.replaceChildren(...options.map((optionData) => {
    const option = document.createElement('option');
    option.value = optionData.value;
    option.textContent = optionData.text;
    return option;
  }));
  personalDocumentHolder.value = selected || options[0]?.value || '';
}

function holderValues() {
  if (personalDocumentHolder.value === 'owner') return { holderKind: 'owner', familyMemberId: null };
  const [, familyMemberId] = personalDocumentHolder.value.split(':');
  return { holderKind: 'family_member', familyMemberId: familyMemberId || null };
}

function clearableValue(input) {
  return input.value.trim() || null;
}

function formatPersonalDocumentFileSize(bytes) {
  const size = Number(bytes) || 0;
  if (size < 1024 * 1024) return `${Math.max(1, Math.round(size / 1024))} KB`;
  return `${(size / (1024 * 1024)).toLocaleString('it-IT', {
    minimumFractionDigits: 1,
    maximumFractionDigits: 1
  })} MB`;
}

function setPersonalDocumentFileMessage(text = '', isError = false) {
  personalDocumentFileMessage.textContent = text;
  personalDocumentFileMessage.classList.toggle('is-error', isError);
}

function setPersonalDocumentFileBusy(isBusy) {
  personalDocumentFileBusy = isBusy;
  personalDocumentFileInput.disabled = isBusy;
  personalDocumentFileUpload.setAttribute('aria-disabled', String(isBusy));
  personalDocumentFileDetails.querySelectorAll('button').forEach((button) => { button.disabled = isBusy; });
}

function personalDocumentFilePath(file) {
  const ownerAccountId = editingPersonalDocument?.owner_account_id;
  if (!ownerAccountId || !editingPersonalDocument?.id) throw new Error('Documento non disponibile');
  const extensionByMimeType = {
    'application/pdf': 'pdf',
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/webp': 'webp'
  };
  const extension = extensionByMimeType[file.type];
  if (!extension) throw new Error('Formato file non supportato');
  return `attachments/${ownerAccountId}/personal_document/${editingPersonalDocument.id}/${crypto.randomUUID()}.${extension}`;
}

function renderPersonalDocumentAttachment() {
  const attachment = personalDocumentAttachment;
  personalDocumentFileEmpty.hidden = Boolean(attachment);
  personalDocumentFileDetails.hidden = !attachment;
  personalDocumentFileUpload.textContent = attachment ? 'Sostituisci' : 'Carica documento';
  if (!attachment) {
    personalDocumentFileDetails.replaceChildren();
    return;
  }

  const row = document.createElement('div');
  row.className = 'deadline-attachment';
  const info = document.createElement('div');
  info.className = 'deadline-attachment-info';
  const name = document.createElement('strong');
  name.textContent = attachment.original_filename;
  const details = document.createElement('span');
  details.textContent = `${personalDocumentAttachmentPreview.formatAttachmentType(attachment.mime_type)} · ${formatPersonalDocumentFileSize(attachment.byte_size)}`;
  info.append(name, details);

  const actions = document.createElement('div');
  actions.className = 'deadline-attachment-actions';
  const view = document.createElement('button');
  view.type = 'button';
  view.className = 'fa-button fa-button-secondary fa-button-compact';
  view.textContent = 'Visualizza';
  view.addEventListener('click', () => void viewPersonalDocumentAttachment(attachment, view));
  const download = document.createElement('button');
  download.type = 'button';
  download.className = 'fa-button fa-button-secondary fa-button-compact';
  download.textContent = 'Scarica';
  download.addEventListener('click', () => void downloadPersonalDocumentAttachment(attachment, download));
  const remove = document.createElement('button');
  remove.type = 'button';
  remove.className = 'fa-button fa-button-danger fa-button-compact';
  remove.textContent = 'Rimuovi';
  remove.addEventListener('click', () => void removePersonalDocumentAttachment(attachment));
  actions.append(view, download, remove);
  row.append(info, actions);
  personalDocumentFileDetails.replaceChildren(row);
}

async function loadPersonalDocumentAttachment() {
  if (!editingPersonalDocument) return;
  const { data, error } = await personalDocumentClient.rpc('get_attachments', {
    p_target_type: 'personal_document',
    p_target_id: editingPersonalDocument.id
  });
  if (error) {
    personalDocumentAttachment = null;
    renderPersonalDocumentAttachment();
    setPersonalDocumentFileMessage('Non è stato possibile caricare il file del documento.', true);
    return;
  }
  personalDocumentAttachment = (data || [])[0] || null;
  renderPersonalDocumentAttachment();
}

async function viewPersonalDocumentAttachment(attachment, button) {
  if (personalDocumentFileBusy) return;
  button.disabled = true;
  const { data, error } = await personalDocumentClient.storage
    .from('familarea-attachments')
    .createSignedUrl(attachment.storage_path, 60);
  button.disabled = false;
  if (error || !data?.signedUrl) {
    setPersonalDocumentFileMessage('Non è stato possibile visualizzare il documento. Riprova.', true);
    return;
  }
  window.open(data.signedUrl, '_blank', 'noopener');
}

async function downloadPersonalDocumentAttachment(attachment, button) {
  if (personalDocumentFileBusy) return;
  button.disabled = true;
  const { data, error } = await personalDocumentClient.storage
    .from('familarea-attachments')
    .download(attachment.storage_path);
  button.disabled = false;
  if (error || !data) {
    setPersonalDocumentFileMessage('Non è stato possibile scaricare il documento. Riprova.', true);
    return;
  }
  const url = URL.createObjectURL(data);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = attachment.original_filename || 'documento';
  document.body.append(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
}

async function deleteAttachmentMetadataAndBlob(attachment) {
  const { error: metadataError } = await personalDocumentClient.rpc('delete_attachment', {
    p_attachment_id: attachment.id
  });
  if (metadataError) return { ok: false, message: 'Non è stato possibile rimuovere il file del documento.' };
  const { error: storageError } = await personalDocumentClient.storage
    .from('familarea-attachments')
    .remove([attachment.storage_path]);
  if (storageError) return {
    ok: false,
    metadataRemoved: true,
    message: 'Il file non è più collegato al documento, ma non è stato possibile rimuoverlo dallo spazio di archiviazione.'
  };
  return { ok: true };
}

async function removePersonalDocumentAttachment(attachment) {
  if (personalDocumentFileBusy) return;
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: 'Vuoi rimuovere il file di questo documento?',
    message: 'Il file verrà eliminato definitivamente.',
    confirmText: 'Rimuovi'
  });
  if (!confirmed) return;
  setPersonalDocumentFileBusy(true);
  const result = await deleteAttachmentMetadataAndBlob(attachment);
  setPersonalDocumentFileBusy(false);
  if (!result.ok) {
    if (result.metadataRemoved) {
      personalDocumentAttachment = null;
      renderPersonalDocumentAttachment();
    }
    setPersonalDocumentFileMessage(result.message, true);
    return;
  }
  personalDocumentAttachment = null;
  renderPersonalDocumentAttachment();
  setPersonalDocumentFileMessage('Documento rimosso.');
}

async function uploadPersonalDocumentFile(file) {
  const replacingExistingFile = Boolean(personalDocumentAttachment);
  const path = personalDocumentFilePath(file);
  const { error: uploadError } = await personalDocumentClient.storage
    .from('familarea-attachments')
    .upload(path, file, { contentType: file.type, upsert: false });
  if (uploadError) throw uploadError;

  const { data: replacement, error: replacementError } = await personalDocumentClient.rpc('replace_personal_document_attachment', {
    p_document_id: editingPersonalDocument.id,
    p_storage_path: path,
    p_original_filename: file.name,
    p_mime_type: file.type,
    p_byte_size: file.size
  });
  if (replacementError || !replacement?.storage_path) {
    await personalDocumentClient.storage.from('familarea-attachments').remove([path]);
    throw replacementError || new Error('Registrazione file non riuscita');
  }
  if (replacement.previous_storage_path) {
    const { error: previousRemovalError } = await personalDocumentClient.storage
      .from('familarea-attachments')
      .remove([replacement.previous_storage_path]);
    if (previousRemovalError) {
      await loadPersonalDocumentAttachment();
      setPersonalDocumentFileMessage('Documento sostituito, ma non è stato possibile rimuovere il file precedente.', true);
      return;
    }
  }
  await loadPersonalDocumentAttachment();
  setPersonalDocumentFileMessage(replacingExistingFile ? 'Documento sostituito.' : 'Documento caricato.');
}

personalDocumentFileInput.addEventListener('change', async (event) => {
  if (personalDocumentFileBusy || !editingPersonalDocument) return;
  const file = event.target.files[0];
  event.target.value = '';
  if (!file) return;
  if (!personalDocumentAttachmentPreview.isSupportedMimeType(file.type)) {
    setPersonalDocumentFileMessage('Formato non supportato. Puoi caricare PDF, JPG, PNG o WebP.', true);
    return;
  }
  if (file.size > personalDocumentAttachmentPreview.maxAttachmentBytes) {
    setPersonalDocumentFileMessage('Il file supera il limite massimo di 10 MB.', true);
    return;
  }
  setPersonalDocumentFileBusy(true);
  setPersonalDocumentFileMessage(personalDocumentAttachment ? 'Sostituzione documento in corso…' : 'Caricamento documento in corso…');
  try {
    await uploadPersonalDocumentFile(file);
  } catch (error) {
    console.error('personal document file upload failed', error);
    setPersonalDocumentFileMessage('Non è stato possibile caricare il documento. Riprova.', true);
  } finally {
    setPersonalDocumentFileBusy(false);
  }
});

function documentBelongsToManagedMember(document) {
  const member = personalDocumentContext?.member;
  return !member || (document.holder_kind === 'family_member' && document.family_member_id === member.id);
}

function setEditingDocument(record) {
  editingPersonalDocument = record;
  window.document.getElementById('document-form-title').textContent = 'Modifica documento';
  window.document.getElementById('document-form-intro').textContent = 'Aggiorna le informazioni del documento.';
  personalDocumentSubmit.textContent = 'Salva modifiche';
  personalDocumentDelete.hidden = false;
  personalDocumentFileSection.hidden = false;
  personalDocumentType.value = record.document_type || 'other';
  setHolderOptions({ owner: personalDocumentOwner, members: personalDocumentMembers }, record.holder_kind === 'owner' ? 'owner' : `family_member:${record.family_member_id}`);
  personalDocumentNumber.value = record.document_number || '';
  personalDocumentIssuedOn.value = record.issued_on || '';
  personalDocumentExpiryDate.value = record.expiry_date || '';
  personalDocumentReminder.value = record.reminder_days ?? '';
  personalDocumentIssuer.value = record.issuer || '';
  personalDocumentNotes.value = record.notes || '';
}

async function loadEditingDocument() {
  const { data, error } = await personalDocumentClient.rpc('get_my_personal_document', {
    p_document_id: personalDocumentId
  });
  if (error || !data || !documentBelongsToManagedMember(data)) {
    setPersonalDocumentMessage('Il documento selezionato non è disponibile in questo contesto.', true);
    return false;
  }
  setEditingDocument(data);
  return true;
}

async function removePersonalDocument() {
  const record = editingPersonalDocument;
  if (!record || personalDocumentFileBusy) return;
  const { data: attachments, error: attachmentError } = await personalDocumentClient.rpc('get_attachments', {
    p_target_type: 'personal_document',
    p_target_id: record.id
  });
  if (attachmentError) {
    setPersonalDocumentMessage('Impossibile verificare la presenza di allegati. Il documento non è stato eliminato.', true);
    return;
  }
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: 'Vuoi davvero eliminare questo documento?',
    message: 'La relativa scadenza verrà rimossa.',
    confirmText: 'Elimina'
  });
  if (!confirmed) return;
  const attachment = (attachments || [])[0] || null;
  setPersonalDocumentFileBusy(true);
  if (attachment) {
    const attachmentResult = await deleteAttachmentMetadataAndBlob(attachment);
    if (!attachmentResult.ok) {
      setPersonalDocumentFileBusy(false);
      if (attachmentResult.metadataRemoved) {
        personalDocumentAttachment = null;
        renderPersonalDocumentAttachment();
      }
      setPersonalDocumentMessage(attachmentResult.message, true);
      return;
    }
    personalDocumentAttachment = null;
    renderPersonalDocumentAttachment();
  }
  personalDocumentDelete.disabled = true;
  const { error } = await personalDocumentClient.rpc('delete_personal_document', { p_document_id: record.id });
  setPersonalDocumentFileBusy(false);
  if (error) {
    personalDocumentDelete.disabled = false;
    setPersonalDocumentMessage(attachment ? 'Il file è stato rimosso, ma non è stato possibile eliminare il documento.' : 'Impossibile eliminare il documento.', true);
    return;
  }
  window.location.assign(listHref());
}

personalDocumentForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (personalDocumentFileBusy) {
    setPersonalDocumentMessage('Attendi il completamento della gestione del file.', true);
    return;
  }
  if (!personalDocumentType.value || !personalDocumentHolder.value) {
    setPersonalDocumentMessage('Seleziona tipo documento e intestatario.', true);
    return;
  }
  const { holderKind, familyMemberId } = holderValues();
  if (!holderKind || (holderKind === 'family_member' && !familyMemberId)) {
    setPersonalDocumentMessage('Seleziona un intestatario valido.', true);
    return;
  }
  const params = {
    p_holder_kind: holderKind,
    p_document_type: personalDocumentType.value,
    p_family_member_id: familyMemberId,
    p_document_number: clearableValue(personalDocumentNumber),
    p_issued_on: personalDocumentIssuedOn.value || null,
    p_issuer: clearableValue(personalDocumentIssuer),
    p_notes: clearableValue(personalDocumentNotes),
    p_expiry_date: personalDocumentExpiryDate.value || null,
    p_reminder_days: personalDocumentReminder.value === '' ? null : Number(personalDocumentReminder.value)
  };
  const rpc = editingPersonalDocument ? 'update_personal_document' : 'create_personal_document';
  if (editingPersonalDocument) params.p_document_id = editingPersonalDocument.id;
  else params.p_family_id = personalDocumentFamily.id;
  personalDocumentSubmit.disabled = true;
  setPersonalDocumentMessage('');
  const { data, error } = await personalDocumentClient.rpc(rpc, params);
  personalDocumentSubmit.disabled = false;
  if (error || !data) {
    setPersonalDocumentMessage('Impossibile salvare il documento. Riprova.', true);
    return;
  }
  if (!editingPersonalDocument) {
    window.location.assign(listHref());
    return;
  }
  editingPersonalDocument = data;
  setPersonalDocumentMessage('Modifiche salvate.', false, true);
});

async function initialisePersonalDocument() {
  if (!await window.FamilAreaDeadlineManagementReady) return;
  const [{ data: familyData, error: familyError }, context] = await Promise.all([
    personalDocumentClient.rpc('get_my_family'),
    window.FamilAreaManagedContext.load()
  ]);
  if (familyError || !familyData?.family || familyData?.viewer?.can_manage !== true) {
    setPersonalDocumentMessage('Non disponi dell’autorizzazione per gestire i documenti personali.', true);
    return;
  }
  personalDocumentFamily = familyData.family;
  personalDocumentContext = context;
  personalDocumentOwner = familyData.owner || null;
  personalDocumentMembers = familyData.members || [];
  personalDocumentBackLink.href = personalDocumentCancel.href = listHref();
  if (context.requested && !context.member) {
    setPersonalDocumentMessage('Il membro selezionato non è gestibile dalla tua Famiglia.', true);
    return;
  }
  if (context.member) {
    if (!memberIsEligible(context.member)) {
      setPersonalDocumentMessage('I documenti personali sono disponibili solo per persone e persone assistite.', true);
      return;
    }
    document.getElementById('managed-context').hidden = false;
    window.FamilAreaManagedContext.renderBar(document.getElementById('managed-context'), context.member, { backHref: listHref() });
  }
  setHolderOptions(familyData);
  if (personalDocumentId && !await loadEditingDocument()) return;
  personalDocumentForm.hidden = false;
  if (editingPersonalDocument) await loadPersonalDocumentAttachment();
  setPersonalDocumentMessage('');
  personalDocumentDelete.addEventListener('click', removePersonalDocument);
}

void initialisePersonalDocument();

const personalDocumentsClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const personalDocumentsMessage = document.getElementById('documents-message');
const personalDocumentsList = document.getElementById('documents-list');
const personalDocumentsEmpty = document.getElementById('documents-empty');
const personalDocumentCreate = document.getElementById('document-create');
const personalDocumentsBackLink = document.querySelector('.account-back-link > a');
const personalDocumentLabels = {
  identity_card: 'Carta d’identità',
  driving_license: 'Patente',
  passport: 'Passaporto',
  health_card: 'Tessera sanitaria',
  permit_license: 'Permesso/licenza',
  other: 'Altro documento'
};
let personalDocumentsFamily = null;
let personalDocumentsOwner = null;
let personalDocumentsMembers = [];
let personalDocumentsContext = null;

function setPersonalDocumentsMessage(text = '', isError = false) {
  personalDocumentsMessage.textContent = text;
  personalDocumentsMessage.classList.toggle('is-error', isError);
}

function memberName(member) {
  return window.FamilAreaManagedContext.memberName(member);
}

function holderName(record) {
  if (record.holder_kind === 'owner') return memberName(personalDocumentsOwner) || 'Proprietario/a della Famiglia';
  return memberName(personalDocumentsMembers.find((member) => member.id === record.family_member_id));
}

function documentHref(documentId) {
  const path = `gestione-documento.html?document_id=${encodeURIComponent(documentId)}`;
  return personalDocumentsContext?.member
    ? window.FamilAreaManagedContext.withMember(path, personalDocumentsContext.member.id)
    : path;
}

function isPersonalDocumentCardControl(target) { return target instanceof Element && Boolean(target.closest('button, a, input, select, textarea, [data-card-control]')); }
function openPersonalDocumentDetails(href) { window.location.assign(href); }

async function openPersonalDocumentAttachment(attachment, button) {
  button.disabled = true;
  try {
    const signedUrl = await window.FamilAreaAttachmentPreview.getSignedUrl(personalDocumentsClient, attachment, 60);
    window.open(signedUrl, '_blank', 'noopener');
  } catch (_) {
    setPersonalDocumentsMessage('Non è stato possibile aprire l’allegato del documento. Riprova.', true);
  } finally {
    button.disabled = false;
  }
}

async function renderDocumentThumbnail(record, visual, documentLabel) {
  try {
    const { data, error } = await personalDocumentsClient.rpc('get_attachments', {
      p_target_type: 'personal_document',
      p_target_id: record.id
    });
    if (error) return;
    const attachment = (data || []).find((row) => window.FamilAreaAttachmentPreview.isSupportedMimeType(row.mime_type));
    if (!attachment || !visual.isConnected) return;

    const open = document.createElement('button');
    open.type = 'button';
    open.className = 'fa-v2-card-visual deadline-card-attachment-preview';
    open.setAttribute('data-card-control', 'attachment-preview');
    open.setAttribute('aria-label', `Apri allegato di ${documentLabel}`);
    open.textContent = attachment.mime_type === 'application/pdf' ? 'PDF' : 'Apri allegato';
    open.addEventListener('click', (event) => {
      event.stopPropagation();
      void openPersonalDocumentAttachment(attachment, open);
    });
    visual.replaceWith(open);
    await window.FamilAreaAttachmentPreview.renderCardPreview({ client: personalDocumentsClient, attachment, container: open });
  } catch (_) {
    // The document details card remains usable when its optional preview is unavailable.
  }
}

function documentRow(record) {
  const href = documentHref(record.id);
  const documentLabel = personalDocumentLabels[record.document_type] || 'Altro documento';
  const row = document.createElement('article');
  row.className = 'fa-v2-deadline-card fa-v2-deadline-card--interactive fa-v2-card-media-layout';
  row.tabIndex = 0;
  row.setAttribute('role', 'link');
  row.setAttribute('aria-label', `Apri ${documentLabel} di ${holderName(record)}`);
  row.addEventListener('click', (event) => {
    if (!isPersonalDocumentCardControl(event.target)) openPersonalDocumentDetails(href);
  });
  row.addEventListener('keydown', (event) => {
    if (event.target !== row || (event.key !== 'Enter' && event.key !== ' ')) return;
    event.preventDefault();
    openPersonalDocumentDetails(href);
  });

  const image = document.createElement('span');
  image.className = 'fa-v2-card-visual';
  image.setAttribute('aria-hidden', 'true');
  image.textContent = (documentLabel.trim().charAt(0) || 'D').toLocaleUpperCase('it-IT');
  void renderDocumentThumbnail(record, image, documentLabel);
  const title = document.createElement('h2');
  title.className = 'fa-v2-card-title';
  title.textContent = documentLabel;
  const details = document.createElement('span');
  details.className = 'fa-v2-card-description';
  details.textContent = [
    record.document_number ? `Numero: ${record.document_number}` : '',
    record.expiry_date ? `Scadenza: ${window.FamilAreaDateUtils.formatDateDisplay(record.expiry_date)}` : 'Nessuna scadenza'
  ].filter(Boolean).join(' · ');
  const content = document.createElement('div');
  content.className = 'fa-v2-card-content';
  content.append(title, details);
  const actions = document.createElement('div');
  actions.className = 'fa-v2-card-actions';
  const action = document.createElement('button');
  action.type = 'button';
  action.className = 'fa-button fa-button-secondary fa-button-compact';
  action.textContent = 'Modifica';
  action.addEventListener('click', (event) => { event.stopPropagation(); openPersonalDocumentDetails(href); });
  actions.append(action);
  row.append(image, content, actions);
  return row;
}
async function loadPersonalDocuments() {
  const { data, error } = await personalDocumentsClient.rpc('get_my_personal_documents', {
    p_family_id: personalDocumentsFamily.id
  });
  if (error) {
    setPersonalDocumentsMessage('Impossibile caricare i documenti personali.', true);
    return;
  }
  const documents = (data || []).filter((document) => !personalDocumentsContext.member
    || (document.holder_kind === 'family_member' && document.family_member_id === personalDocumentsContext.member.id));
  personalDocumentsList.replaceChildren(...documents.map(documentRow));
  personalDocumentsEmpty.hidden = documents.length > 0;
}

async function initialisePersonalDocuments() {
  if (!await window.FamilAreaDeadlineManagementReady) return;
  const [{ data: familyData, error: familyError }, context] = await Promise.all([
    personalDocumentsClient.rpc('get_my_family'),
    window.FamilAreaManagedContext.load()
  ]);
  if (familyError || !familyData?.family || familyData?.viewer?.can_manage !== true) {
    personalDocumentCreate.hidden = true;
    setPersonalDocumentsMessage('Non disponi dell’autorizzazione per gestire i documenti personali.', true);
    return;
  }

  personalDocumentsFamily = familyData.family;
  personalDocumentsOwner = familyData.owner || null;
  personalDocumentsMembers = familyData.members || [];
  personalDocumentsContext = context;
  if (context.requested && !context.member) {
    setPersonalDocumentsMessage('Il membro selezionato non è gestibile dalla tua Famiglia.', true);
    return;
  }
  if (context.member) {
    const member = context.member;
    document.getElementById('managed-context').hidden = false;
    window.FamilAreaManagedContext.renderBar(document.getElementById('managed-context'), member, {
      backHref: window.FamilAreaManagedContext.withMember('scadenze.html', member.id)
    });
    personalDocumentsBackLink.href = window.FamilAreaManagedContext.withMember('scadenze.html', member.id);
    personalDocumentCreate.href = window.FamilAreaManagedContext.withMember('gestione-documento.html', member.id);
    if (member.member_type === 'pet') {
      personalDocumentCreate.hidden = true;
      setPersonalDocumentsMessage('I documenti personali sono disponibili solo per persone e persone assistite.', true);
      return;
    }
  }
  await loadPersonalDocuments();
}

void initialisePersonalDocuments();

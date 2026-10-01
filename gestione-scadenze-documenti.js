const personalDocumentsClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const personalDocumentsMessage = document.getElementById('documents-message');
const personalDocumentsList = document.getElementById('documents-list');
const personalDocumentsEmpty = document.getElementById('documents-empty');
const personalDocumentCreate = document.getElementById('document-create');
const personalDocumentsBackLink = document.getElementById('documents-back-link');
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

function documentRow(record) {
  const row = document.createElement('a');
  row.className = 'deadline-management-row deadline-management-row--clickable fa-surface';
  row.href = documentHref(record.id);
  row.setAttribute('aria-label', `Apri ${personalDocumentLabels[record.document_type] || 'documento'} di ${holderName(record)}`);

  const copy = document.createElement('div');
  copy.className = 'deadline-management-row-copy';
  const title = document.createElement('span');
  title.className = 'deadline-management-row-title';
  title.textContent = personalDocumentLabels[record.document_type] || 'Altro documento';
  const holder = document.createElement('small');
  holder.textContent = `Intestatario: ${holderName(record)}`;
  copy.append(title, holder);
  if (record.document_number) {
    const number = document.createElement('small');
    number.textContent = `Numero: ${record.document_number}`;
    copy.append(number);
  }

  const expiry = document.createElement('small');
  expiry.textContent = record.expiry_date
    ? `Scadenza: ${window.FamilAreaDateUtils.formatDateDisplay(record.expiry_date)}`
    : 'Nessuna scadenza';
  row.append(copy, expiry);
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

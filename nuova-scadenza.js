const c = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const f = document.getElementById('deadline-form');
const m = document.getElementById('deadline-form-message');
const familyMemberField = document.getElementById('deadline-family-member-field');
const managedMemberField = document.getElementById('deadline-managed-member');
const deadlineItemField = document.getElementById('deadline-item-context');
const referenceField = document.getElementById('deadline-reference-field');
const deadlineItemSelectorField = document.getElementById('deadline-item-selector-field');
const deadlineItemSelector = document.getElementById('deadline-item-selector');
const titleField = document.getElementById('deadline-title').closest('div');
const categoryField = document.getElementById('deadline-category').closest('div');
const contextContainer = document.getElementById('managed-context');
const backLink = document.querySelector('.account-back-link a');
const cancelLink = document.getElementById('deadline-cancel-link');
const formTitle = document.getElementById('deadline-form-title');
const formIntro = document.getElementById('deadline-form-intro');
const submitButton = document.getElementById('deadline-submit');
const startTimeInput = document.getElementById('deadline-start-time');
const endTimeInput = document.getElementById('deadline-end-time');
const categoryInput = document.getElementById('deadline-category');
const deadlineTypeChoice = document.getElementById('deadline-type-choice');
const deadlineTypeNote = document.getElementById('deadline-type-note');
const deadlineTypeInputs = [...document.querySelectorAll('input[name="deadline-type"]')];
const deadlineAttachmentsSection = document.getElementById('deadline-attachments-section');
const deadlineAttachmentInput = document.getElementById('deadline-attachment-input');
const deadlineAttachmentUpload = document.getElementById('deadline-attachment-upload');
const deadlineAttachmentsMessage = document.getElementById('deadline-attachments-message');
const deadlineAttachmentsEmpty = document.getElementById('deadline-attachments-empty');
const deadlineAttachmentsList = document.getElementById('deadline-attachments-list');
const deadlineSharingSection = document.getElementById('deadline-sharing-section');
const deadlineSharingMessage = document.getElementById('deadline-sharing-message');
const deadlineSharingSearch = document.getElementById('deadline-sharing-search');
const deadlineSharingSearchStatus = document.getElementById('deadline-sharing-search-status');
const deadlineSharingSearchResults = document.getElementById('deadline-sharing-search-results');
const deadlineSharingPending = document.getElementById('deadline-sharing-pending');
const deadlineSharingCollaborators = document.getElementById('deadline-sharing-collaborators');
const deadlineSharingEmpty = document.getElementById('deadline-sharing-empty');
let otherOptionsToggle = null;
let otherOptionsContent = null;
let managedMember = null;
let deadlineItem = null;
let editingDeadline = null;
let headerDeadlineItem = null;
let availableDeadlineItems = [];
let draftDeadlineAttachments = null;
let createdDeadlinePendingAttachments = null;
let deadlineSharingSearchTimer;
let deadlineSharingSearchRequest = 0;
let deadlineSharingActionPending = false;
let deadlineSharingInitialised = false;
const query = new URLSearchParams(window.location.search);
const requestedDeadlineItemId = query.get('deadline_item_id');
let editingDeadlineId = query.get('deadline_id');
const isSingleDeadlineCreate = query.get('mode') === 'single';
const isCommitmentContext = query.get('context') === 'commitment';
let isSingleDeadlineFlow = isSingleDeadlineCreate;
const presetTitle = query.get('preset_title')?.trim() || '';
const presetKind = query.get('preset_kind')?.trim() || '';
const deadlineItemCategoryLabels = {
  vehicle: 'Veicolo',
  home: 'Casa',
  utilities: 'Utenze e bollette',
  other: 'Altro'
};
const deadlineItemTemplates = {
  vehicle: [
    { title: 'Assicurazione RCA', kind: 'vehicle_insurance' }, { title: 'Bollo', kind: 'vehicle_tax' },
    { title: 'Collaudo / Revisione', kind: 'vehicle_inspection' }, { title: 'Tagliando', kind: 'vehicle_service' }
  ],
  home: [
    { title: 'Caldaia / Impianto termico', kind: 'home_heating' }, { title: 'Assicurazione casa', kind: 'home_insurance' },
    { title: 'Imposte e tributi', kind: 'home_taxes' }, { title: 'Rifiuti', kind: 'home_waste' }
  ]
};
let deadlineItemKind = null;

function setFormMessage(text, isSuccess = false) {
  m.textContent = text;
  m.classList.toggle('deadline-form-message--success', Boolean(text) && isSuccess);
}

function managedHref(path) {
  return managedMember
    ? window.FamilAreaManagedContext.withMember(path, managedMember.id)
    : path;
}

function applyCommitmentReturn() {
  if (!isCommitmentContext) return;
  backLink.href = 'impegni.html';
  backLink.textContent = 'Torna agli Impegni';
  cancelLink.href = 'impegni.html';
}

function deadlineItemHref(itemId) {
  return `gestione-scadenza-item.html?item_id=${encodeURIComponent(itemId)}`;
}

function returnToAssociatedDeadlineItem(itemId) {
  if (!itemId) return false;
  location.href = deadlineItemHref(itemId);
  return true;
}

function deadlineDetailHref(deadlineId) {
  return `scadenza.html?deadline_id=${encodeURIComponent(deadlineId)}`;
}

function deadlineItemTemplateTitle(category, value) {
  const normalisedValue = String(value || '').trim().replace(/\s+/g, ' ').toLocaleLowerCase('it-IT');
  return (deadlineItemTemplates[category] || []).find((template) => (
    template.title.toLocaleLowerCase('it-IT') === normalisedValue
      && template.kind === presetKind
  )) || null;
}

function setAssociatedDeadlineHeader(item, title = '') {
  headerDeadlineItem = item;
  formTitle.textContent = title ? `${item.name} · ${title}` : item.name;
  formIntro.hidden = true;
  deadlineItemField.hidden = true;
}

function clearAssociatedDeadlineHeader() {
  headerDeadlineItem = null;
  formTitle.textContent = 'Gestione scadenza';
  formIntro.hidden = false;
}

function applyStandardCreateDefaults() {
  document.getElementById('deadline-category').value = 'vehicle';
  document.getElementById('deadline-recurrence').value = 'none';
  document.getElementById('deadline-reminder').value = '30';
}

function configureDeadlineItemCreateForm(item) {
  const template = deadlineItemTemplateTitle(item.category, presetTitle);
  const isTemplate = Boolean(template);
  document.getElementById('deadline-category').value = item.category;
  titleField.hidden = isTemplate;
  categoryField.hidden = true;
  if (isTemplate) {
    deadlineItemKind = template.kind;
    document.getElementById('deadline-title').value = template.title;
  }
  setAssociatedDeadlineHeader(item, template?.title || document.getElementById('deadline-title').value);
  updateVehicleDeadlineTimeFields();
}

function selectedDeadlineItem() {
  return availableDeadlineItems.find((item) => item.id === deadlineItemSelector.value) || null;
}

function isVehicleDeadlineContext() {
  return !isSingleDeadlineFlow && (deadlineItem?.category === 'vehicle' || selectedDeadlineItem()?.category === 'vehicle');
}

function updateVehicleDeadlineTimeFields() {
  const isVehicleDeadline = isVehicleDeadlineContext();
  startTimeInput.closest('div').hidden = isVehicleDeadline;
  endTimeInput.closest('div').hidden = isVehicleDeadline;
  if (!isVehicleDeadline) return;
  startTimeInput.value = '';
  endTimeInput.value = '';
  endTimeInput.setCustomValidity('');
}

function updateDeadlineItemAssociationFields() {
  const item = selectedDeadlineItem();
  const isAssociated = Boolean(item);
  referenceField.hidden = Boolean(editingDeadline) || isAssociated;
  if (!editingDeadline) familyMemberField.hidden = isAssociated;
  if (item?.category === 'vehicle') {
    document.getElementById('deadline-title').setAttribute('list', 'vehicle-deadline-suggestions');
  } else {
    document.getElementById('deadline-title').removeAttribute('list');
  }
  if (item) setAssociatedDeadlineHeader(item, document.getElementById('deadline-title').value);
  else if (!deadlineItem) clearAssociatedDeadlineHeader();
  updateVehicleDeadlineTimeFields();
}

async function loadDeadlineItemSelector(selectedItemId = '') {
  const results = await Promise.all(['vehicle', 'home'].map((p_category) => c.rpc('get_my_deadline_items', { p_category })));
  if (results.some((result) => result.error)) {
    console.error('get_my_deadline_items failed while configuring deadline form', results.find((result) => result.error)?.error);
    return false;
  }

  availableDeadlineItems = results.flatMap((result) => result.data || []);
  const noItemValue = '__none__';
  deadlineItemSelector.replaceChildren(
    new Option('Seleziona elemento', '', false, isSingleDeadlineCreate),
    new Option('Nessun elemento', noItemValue, false, !isSingleDeadlineCreate)
  );
  availableDeadlineItems.forEach((item) => {
    const category = deadlineItemCategoryLabels[item.category] || 'Elemento';
    deadlineItemSelector.add(new Option(`${item.name} — ${category}`, item.id));
  });
  deadlineItemSelector.value = availableDeadlineItems.some((item) => item.id === selectedItemId)
    ? selectedItemId
    : (isSingleDeadlineCreate ? '' : noItemValue);
  deadlineItemSelectorField.hidden = false;
  deadlineItemSelector.onchange = updateDeadlineItemAssociationFields;
  updateDeadlineItemAssociationFields();
  return true;
}

function populateEditForm(deadline) {
  document.getElementById('deadline-title').value = deadline.title || '';
  document.getElementById('deadline-category').value = deadline.category || 'other';
  document.getElementById('deadline-first-due-on').value = deadline.first_due_on || '';
  document.getElementById('deadline-recurrence').value = deadline.recurrence_months || 'none';
  document.getElementById('deadline-reminder').value = deadline.reminder_days ?? '';
  document.getElementById('deadline-notes').value = deadline.notes || '';
  startTimeInput.value = String(deadline.start_time || '').slice(0, 5);
  endTimeInput.value = String(deadline.end_time || '').slice(0, 5);
  if (isSingleDeadlineFlow) setDeadlineType(deadline.start_time ? 'appointment' : 'deadline');
  updateTimeValidation();
}

function selectedDeadlineType() {
  return deadlineTypeInputs.find((input) => input.checked)?.value || 'deadline';
}

function setDeadlineType(type) {
  const isAppointment = type === 'appointment';
  deadlineTypeInputs.forEach((input) => { input.checked = input.value === type; });
  startTimeInput.closest('div').hidden = !isAppointment;
  endTimeInput.closest('div').hidden = !isAppointment;
  startTimeInput.required = isAppointment;
  deadlineTypeNote.textContent = isAppointment
    ? 'Un appuntamento prevede un orario di inizio e, facoltativamente, di fine.'
    : 'Una scadenza indica una data da ricordare, senza un orario.';
  updateTimeValidation();
}

function setOtherOptionsOpen(isOpen) {
  if (!otherOptionsToggle || !otherOptionsContent) return;
  otherOptionsToggle.setAttribute('aria-expanded', String(isOpen));
  otherOptionsContent.hidden = !isOpen;
}

function updateTimeValidation(showMessage = false) {
  const startTime = startTimeInput.value;
  const endTime = endTimeInput.value;
  endTimeInput.setCustomValidity('');

  const isAppointment = isSingleDeadlineFlow && selectedDeadlineType() === 'appointment';
  if (isAppointment && !startTime) {
    if (showMessage) setFormMessage('Inserisci l’ora di inizio.');
    return false;
  }
  if (isSingleDeadlineFlow && !isAppointment) return true;
  if (endTime && !startTime) {
    endTimeInput.setCustomValidity('Inserisci prima l’ora di inizio.');
    if (showMessage) setFormMessage('Inserisci prima l’ora di inizio.');
    return false;
  }
  if (startTime && endTime && endTime <= startTime) {
    endTimeInput.setCustomValidity('L’ora fine deve essere successiva all’ora di inizio.');
    if (showMessage) setFormMessage('L’ora fine deve essere successiva all’ora di inizio.');
    return false;
  }
  return true;
}

function configureSingleDeadlineLayout() {
  if (!isSingleDeadlineFlow || f.classList.contains('deadline-form--single')) return;

  const grid = f.querySelector('.deadline-form-grid');
  const notesField = document.getElementById('deadline-notes').closest('div');
  const dateField = document.getElementById('deadline-first-due-on').closest('div');
  const startTimeField = startTimeInput.closest('div');
  const endTimeField = endTimeInput.closest('div');
  const primaryFields = document.createElement('div');
  const otherOptions = document.createElement('section');
  const otherOptionsChevron = document.createElement('span');

  primaryFields.className = 'deadline-form-primary-grid';
  titleField.classList.add('deadline-form-title-field');
  dateField.classList.add('deadline-form-date-field');
  startTimeField.classList.add('deadline-form-start-time-field');
  endTimeField.classList.add('deadline-form-end-time-field');
  notesField.classList.add('deadline-form-notes-field');
  document.querySelector('label[for="deadline-first-due-on"]').textContent = 'Data *';
  document.querySelector('label[for="deadline-start-time"]').textContent = 'Ora inizio *';
  categoryInput.required = false;
  document.querySelector('label[for="deadline-category"]').textContent = 'Categoria';

  primaryFields.append(titleField, dateField, startTimeField, endTimeField, notesField);
  otherOptions.className = 'deadline-form-other-options';
  otherOptionsToggle = document.createElement('button');
  otherOptionsToggle.type = 'button';
  otherOptionsToggle.className = 'fa-v2-button fa-v2-button--secondary deadline-form-other-options-toggle';
  otherOptionsToggle.textContent = 'Altre opzioni';
  otherOptionsToggle.setAttribute('aria-controls', 'deadline-other-options');
  otherOptionsToggle.setAttribute('aria-expanded', 'false');
  otherOptionsChevron.className = 'deadline-form-other-options-chevron';
  otherOptionsChevron.setAttribute('aria-hidden', 'true');
  otherOptionsChevron.textContent = '⌄';
  otherOptionsToggle.append(otherOptionsChevron);
  otherOptionsContent = grid;
  otherOptionsContent.id = 'deadline-other-options';
  otherOptionsContent.classList.add('deadline-form-other-options-content');
  otherOptions.append(otherOptionsToggle, otherOptionsContent);
  grid.append(referenceField);
  f.insertBefore(primaryFields, f.querySelector('.form-actions'));
  f.insertBefore(otherOptions, f.querySelector('.form-actions'));
  f.classList.add('deadline-form--single');
  deadlineTypeChoice.hidden = false;
  setDeadlineType(selectedDeadlineType());
  setOtherOptionsOpen(false);
  otherOptionsToggle.addEventListener('click', () => {
    setOtherOptionsOpen(otherOptionsToggle.getAttribute('aria-expanded') !== 'true');
  });
}

async function loadDeadlineAttachments() {
  if (!editingDeadline) return;
  deadlineAttachmentsSection.hidden = false;
  deadlineAttachmentInput.multiple = false;
  deadlineAttachmentsEmpty.textContent = 'Nessun allegato.';
  const attachments = window.FamilAreaDeadlineAttachments.create({
    client: c,
    deadlineId: editingDeadline.id,
    input: deadlineAttachmentInput,
    uploadControl: deadlineAttachmentUpload,
    message: deadlineAttachmentsMessage,
    empty: deadlineAttachmentsEmpty,
    list: deadlineAttachmentsList
  });
  await attachments.load();
}

function initialiseDraftDeadlineAttachments() {
  deadlineAttachmentsSection.hidden = false;
  deadlineAttachmentInput.multiple = true;
  deadlineAttachmentsEmpty.textContent = 'Nessun allegato selezionato.';
  draftDeadlineAttachments = window.FamilAreaDeadlineAttachments.createDraft({
    client: c,
    input: deadlineAttachmentInput,
    uploadControl: deadlineAttachmentUpload,
    message: deadlineAttachmentsMessage,
    empty: deadlineAttachmentsEmpty,
    list: deadlineAttachmentsList
  });
}

function deadlineSharingInitials(name) {
  return (name || 'U').trim().split(/\s+/).slice(0, 2).map((part) => part[0]).join('').toLocaleUpperCase('it-IT') || 'U';
}

function renderDeadlineSharingAvatar(avatar, avatarPath, name) {
  avatar.replaceChildren();
  avatar.textContent = deadlineSharingInitials(name);
  if (!avatarPath) return;
  c.storage.from('profile-avatars').createSignedUrl(avatarPath, 3600).then(({ data, error }) => {
    if (error || !data?.signedUrl || !avatar.isConnected) return;
    const image = document.createElement('img');
    image.alt = '';
    image.onload = () => { if (avatar.isConnected) avatar.replaceChildren(image); };
    image.src = `${data.signedUrl}${data.signedUrl.includes('?') ? '&' : '?'}v=${Date.now()}`;
  });
}

function setDeadlineSharingMessage(text = '') {
  deadlineSharingMessage.textContent = text;
}

function deadlineSharingButton(text, variant, onClick) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = `fa-v2-button fa-v2-button--${variant}`;
  button.textContent = text;
  button.disabled = deadlineSharingActionPending;
  button.addEventListener('click', onClick);
  return button;
}

function deadlineSharingRow(person, action) {
  const row = document.createElement('div');
  const avatar = document.createElement('span');
  const name = document.createElement('strong');
  const actions = document.createElement('div');
  const displayName = person.display_name || 'Utente FamilArea';
  row.className = 'fa-v2-list-row fa-v2-list-row--media';
  avatar.className = 'contact-directory-avatar';
  avatar.title = displayName;
  avatar.setAttribute('aria-label', displayName);
  name.textContent = displayName;
  actions.className = 'fa-v2-card-actions';
  actions.append(action);
  renderDeadlineSharingAvatar(avatar, person.avatar_path, displayName);
  row.append(avatar, name, actions);
  return row;
}

function renderDeadlineSharingManagement(data) {
  const pending = data?.pending || [];
  const collaborators = data?.collaborators || [];
  deadlineSharingPending.replaceChildren(...pending.map((collaboration) => deadlineSharingRow(
    collaboration,
    deadlineSharingButton('Annulla', 'secondary', () => { void cancelDeadlineCollaboration(collaboration); })
  )));
  deadlineSharingCollaborators.replaceChildren(...collaborators.map((collaboration) => deadlineSharingRow(
    collaboration,
    deadlineSharingButton('Revoca', 'danger', () => { void revokeDeadlineCollaboration(collaboration); })
  )));
  deadlineSharingPending.hidden = pending.length === 0;
  deadlineSharingCollaborators.hidden = collaborators.length === 0;
  deadlineSharingEmpty.hidden = pending.length > 0 || collaborators.length > 0;
}

async function loadDeadlineSharingManagement() {
  if (!editingDeadline || managedMember) return false;
  const { data, error } = await c.rpc('get_deadline_collaboration_management', {
    p_deadline_id: editingDeadline.id
  });
  if (error || !data) {
    setDeadlineSharingMessage('Impossibile caricare la condivisione della scadenza.');
    return false;
  }
  renderDeadlineSharingManagement(data);
  return true;
}

async function searchInvitableDeadlineAccounts() {
  const queryText = deadlineSharingSearch.value.trim();
  const request = ++deadlineSharingSearchRequest;
  deadlineSharingSearchResults.replaceChildren();
  deadlineSharingSearchResults.hidden = true;
  if (!queryText || !editingDeadline || managedMember) {
    deadlineSharingSearchStatus.textContent = '';
    return;
  }
  deadlineSharingSearchStatus.textContent = 'Ricerca in corso...';
  const { data, error } = await c.rpc('search_invitable_deadline_accounts', {
    p_deadline_id: editingDeadline.id,
    p_query: queryText
  });
  if (request !== deadlineSharingSearchRequest) return;
  if (error) {
    deadlineSharingSearchStatus.textContent = 'Impossibile cercare una persona. Riprova.';
    return;
  }
  const results = data || [];
  deadlineSharingSearchResults.replaceChildren(...results.map((person) => deadlineSharingRow(
    person,
    deadlineSharingButton('Invita', 'primary', () => { void inviteDeadlineCollaborator(person); })
  )));
  deadlineSharingSearchResults.hidden = results.length === 0;
  deadlineSharingSearchStatus.textContent = results.length ? '' : 'Nessuna persona disponibile trovata.';
}

async function inviteDeadlineCollaborator(person) {
  if (deadlineSharingActionPending || !editingDeadline) return;
  deadlineSharingActionPending = true;
  setDeadlineSharingMessage('Invito in corso...');
  const { error } = await c.rpc('create_deadline_collaboration', {
    p_deadline_id: editingDeadline.id,
    p_recipient_account_id: person.account_id
  });
  deadlineSharingActionPending = false;
  if (error) {
    setDeadlineSharingMessage('Non è stato possibile inviare l\'invito.');
    return;
  }
  setDeadlineSharingMessage('Invito inviato.');
  await loadDeadlineSharingManagement();
  await searchInvitableDeadlineAccounts();
}

async function cancelDeadlineCollaboration(collaboration) {
  if (deadlineSharingActionPending || !await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: 'Annullare questo invito?',
    message: 'La persona non potrà più accettare la richiesta.',
    confirmText: 'Annulla invito'
  })) return;
  deadlineSharingActionPending = true;
  setDeadlineSharingMessage('Annullamento in corso...');
  const { error } = await c.rpc('cancel_deadline_collaboration', {
    p_collaboration_id: collaboration.collaboration_id
  });
  deadlineSharingActionPending = false;
  if (error) {
    setDeadlineSharingMessage('Non è stato possibile annullare l\'invito.');
    return;
  }
  setDeadlineSharingMessage('Invito annullato.');
  await loadDeadlineSharingManagement();
  await searchInvitableDeadlineAccounts();
}

async function revokeDeadlineCollaboration(collaboration) {
  if (deadlineSharingActionPending || !await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: 'Revocare l\'accesso?',
    message: 'La persona non potrà più visualizzare questa scadenza.',
    confirmText: 'Revoca'
  })) return;
  deadlineSharingActionPending = true;
  setDeadlineSharingMessage('Revoca in corso...');
  const { error } = await c.rpc('revoke_deadline_collaboration', {
    p_collaboration_id: collaboration.collaboration_id
  });
  deadlineSharingActionPending = false;
  if (error) {
    setDeadlineSharingMessage('Non è stato possibile revocare l\'accesso.');
    return;
  }
  setDeadlineSharingMessage('Accesso revocato.');
  await loadDeadlineSharingManagement();
  await searchInvitableDeadlineAccounts();
}

function initialiseDeadlineSharing() {
  if (!editingDeadline || managedMember || isCommitmentContext || deadlineSharingInitialised) return;
  deadlineSharingInitialised = true;
  deadlineSharingSection.hidden = false;
  deadlineSharingSearch.addEventListener('input', () => {
    window.clearTimeout(deadlineSharingSearchTimer);
    deadlineSharingSearchTimer = window.setTimeout(() => {
      void searchInvitableDeadlineAccounts();
    }, 250);
  });
  void loadDeadlineSharingManagement();
}

async function initialiseEditMode(account) {
  const { data, error } = await c.rpc('get_deadline', { p_deadline_id: editingDeadlineId });
  if (error || !data) {
    setFormMessage('Scadenza non disponibile.');
    return false;
  }

  editingDeadline = data;
  if (!editingDeadline.deadline_item_id) {
    isSingleDeadlineFlow = true;
    configureSingleDeadlineLayout();
  }
  populateEditForm(editingDeadline);
  clearAssociatedDeadlineHeader();
  formIntro.textContent = 'Aggiorna le informazioni della scadenza.';
  submitButton.textContent = 'Salva modifiche';
  referenceField.hidden = true;
  familyMemberField.hidden = true;
  backLink.href = deadlineItem?.id ? deadlineItemHref(deadlineItem.id) : deadlineDetailHref(editingDeadline.id);
  cancelLink.href = backLink.href;
  if (!await loadDeadlineItemSelector(editingDeadline.deadline_item_id || '')) {
    setFormMessage('Impossibile preparare il selettore degli elementi.');
    return false;
  }
  const associatedItem = selectedDeadlineItem();
  if (associatedItem) setAssociatedDeadlineHeader(associatedItem, editingDeadline.title);
  if (associatedItem?.id === requestedDeadlineItemId) {
    backLink.href = deadlineItemHref(associatedItem.id);
    cancelLink.href = backLink.href;
  }
  await loadDeadlineAttachments();
  return true;
}

async function initialiseCreateMode(account, context) {
  if (!isSingleDeadlineCreate) applyStandardCreateDefaults();
  initialiseDraftDeadlineAttachments();

  if (context.member) {
    managedMember = context.member;
    contextContainer.hidden = false;
    window.FamilAreaManagedContext.renderBar(contextContainer, managedMember);
    managedMemberField.hidden = false;
    managedMemberField.textContent = `Riferita a: ${window.FamilAreaManagedContext.memberName(managedMember)}`;
    familyMemberField.hidden = true;
    backLink.href = managedHref('scadenze.html');
    cancelLink.href = managedHref('scadenze.html');
    return true;
  }

  familyMemberField.hidden = account?.account_type === 'organization';
  if (requestedDeadlineItemId) {
    const { data: item, error: itemError } = await c.rpc('get_my_deadline_item', {
      p_item_id: requestedDeadlineItemId
    });
    if (itemError || !item || !deadlineItemTemplates[item.category]) {
      setFormMessage('Elemento non disponibile. Stai creando una scadenza normale.');
      return true;
    }

    deadlineItem = item;
    referenceField.hidden = true;
    familyMemberField.hidden = true;
    configureDeadlineItemCreateForm(item);
    if (item.category === 'vehicle') document.getElementById('deadline-title').setAttribute('list', 'vehicle-deadline-suggestions');
    backLink.href = deadlineItemHref(item.id);
    cancelLink.href = backLink.href;
    return true;
  }

  await loadDeadlineItemSelector();
  return true;
}

async function init() {
  const context = await window.FamilAreaManagedContext.load();
  if (context.requested && !context.member) {
    m.classList.remove('deadline-form-message--success');
    m.textContent = 'Il membro selezionato non Ã¨ gestibile dalla tua Famiglia. Stai creando una scadenza personale.';
  }

  const { data: account, error } = await c.rpc('get_current_account');
  if (error) {
    console.error('get_current_account failed while configuring deadline form', error);
    setFormMessage('Impossibile preparare il modulo.');
    return;
  }

  const ready = editingDeadlineId && !context.member
    ? await initialiseEditMode(account)
    : await initialiseCreateMode(account, context);
  if (!ready) return;

  f.hidden = false;
  initialiseDeadlineSharing();
  if (editingDeadline || context.member || (!context.requested && !requestedDeadlineItemId) || deadlineItem) setFormMessage('');
  if (isCommitmentContext && !managedMember && !requestedDeadlineItemId) applyCommitmentReturn();
}

document.getElementById('deadline-title').addEventListener('input', () => {
  if (headerDeadlineItem) setAssociatedDeadlineHeader(headerDeadlineItem, document.getElementById('deadline-title').value);
});

startTimeInput.addEventListener('input', () => updateTimeValidation());
endTimeInput.addEventListener('change', () => updateTimeValidation());
startTimeInput.addEventListener('invalid', () => {
  if (isSingleDeadlineFlow && selectedDeadlineType() === 'appointment') setFormMessage('Inserisci l’ora di inizio.');
});
endTimeInput.addEventListener('invalid', () => updateTimeValidation(true));
deadlineTypeInputs.forEach((input) => input.addEventListener('change', () => {
  if (isSingleDeadlineFlow) setDeadlineType(selectedDeadlineType());
}));
startTimeInput.addEventListener('keydown', (event) => {
  if (!isSingleDeadlineFlow || selectedDeadlineType() !== 'appointment' || event.key !== 'Enter') return;
  event.preventDefault();
  if (startTimeInput.value) endTimeInput.focus();
});
endTimeInput.addEventListener('keydown', (event) => {
  if (!isSingleDeadlineFlow || selectedDeadlineType() !== 'appointment' || event.key !== 'Enter') return;
  event.preventDefault();
  document.getElementById('deadline-notes').focus();
});

async function transitionToEdit(deadlineId) {
  editingDeadlineId = deadlineId;
  const url = new URL(window.location.href);
  url.search = '';
  url.searchParams.set('deadline_id', deadlineId);
  window.history.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`);
  const ready = await initialiseEditMode();
  if (ready) {
    initialiseDeadlineSharing();
    setFormMessage('Scadenza creata.');
  }
}

async function finishDeadlineCreation(deadlineId, associatedItem) {
  if (returnToAssociatedDeadlineItem(associatedItem?.id)) return;
  if (isCommitmentContext) {
    location.href = 'impegni.html';
    return;
  }
  if (managedMember || isSingleDeadlineCreate) {
    location.href = managedHref('scadenze.html');
    return;
  }
  deadlineItem = associatedItem || null;
  await transitionToEdit(deadlineId);
}

async function uploadDraftDeadlineAttachments() {
  if (!createdDeadlinePendingAttachments || !draftDeadlineAttachments) return true;
  submitButton.disabled = true;
  const result = await draftDeadlineAttachments.uploadSelected(createdDeadlinePendingAttachments.id);
  submitButton.disabled = false;
  if (result.ok) return true;
  submitButton.textContent = 'Completa caricamento';
  setFormMessage(`Scadenza creata, ma ${result.failed} allegat${result.failed === 1 ? 'o non è stato caricato' : 'i non sono stati caricati'}. Riprova.`);
  return false;
}

f.onsubmit = async (event) => {
  event.preventDefault();
  if (createdDeadlinePendingAttachments) {
    if (await uploadDraftDeadlineAttachments()) {
      const { id, associatedItem } = createdDeadlinePendingAttachments;
      createdDeadlinePendingAttachments = null;
      await finishDeadlineCreation(id, associatedItem);
    }
    return;
  }
  if (!updateTimeValidation(true)) return;
  const recurrenceValue = document.getElementById('deadline-recurrence').value;
  const reminderValue = document.getElementById('deadline-reminder').value;
  const categoryValue = categoryInput.value;
  const isVehicleDeadline = isVehicleDeadlineContext();
  if (!isSingleDeadlineFlow && (!recurrenceValue || !reminderValue)) {
    setFormMessage('Seleziona ricorrenza e promemoria.');
    return;
  }
  const commonParams = {
    p_title: document.getElementById('deadline-title').value.trim(),
    p_category: isSingleDeadlineFlow ? (categoryValue || 'other') : categoryValue,
    p_first_due_on: document.getElementById('deadline-first-due-on').value,
    p_recurrence_months: Number(recurrenceValue) || null,
    p_reminder_days: reminderValue ? Number(reminderValue) : null,
    p_notes: document.getElementById('deadline-notes').value.trim() || null,
    p_start_time: !isVehicleDeadline && (!isSingleDeadlineFlow || selectedDeadlineType() === 'appointment') ? (startTimeInput.value || null) : null,
    p_end_time: !isVehicleDeadline && (!isSingleDeadlineFlow || selectedDeadlineType() === 'appointment') ? (endTimeInput.value || null) : null
  };

  if (editingDeadline) {
    const { error } = await c.rpc('update_my_deadline_with_item', {
      p_deadline_id: editingDeadline.id,
      ...commonParams,
      p_deadline_item_id: selectedDeadlineItem()?.id || null
    });
    if (error) {
      setFormMessage('Impossibile aggiornare la scadenza.');
      return;
    }
    if (returnToAssociatedDeadlineItem(selectedDeadlineItem()?.id || editingDeadline.deadline_item_id)) return;
    setFormMessage('Modifiche salvate.', true);
    if (isSingleDeadlineFlow) setOtherOptionsOpen(false);
    return;
  }

  const associatedItem = deadlineItem || selectedDeadlineItem();
  const { data, error } = associatedItem
    ? await c.rpc('create_deadline_for_item', {
      p_item_id: associatedItem.id,
      ...commonParams,
      p_deadline_kind: deadlineItemKind
    })
    : await c.rpc('create_deadline', {
      ...commonParams,
      p_family_member_id: managedMember
        ? managedMember.id
        : (familyMemberField.hidden ? null : (document.getElementById('deadline-family-member').value || null))
    });
  if (error) {
    setFormMessage('Impossibile creare la scadenza.');
    return;
  }
  createdDeadlinePendingAttachments = { id: data, associatedItem };
  if (!await uploadDraftDeadlineAttachments()) return;
  createdDeadlinePendingAttachments = null;
  await finishDeadlineCreation(data, associatedItem);
};

configureSingleDeadlineLayout();
init();

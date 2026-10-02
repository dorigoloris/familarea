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
const backLink = document.getElementById('deadline-back-link');
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
let otherOptionsToggle = null;
let otherOptionsContent = null;
let managedMember = null;
let deadlineItem = null;
let editingDeadline = null;
let headerDeadlineItem = null;
let availableDeadlineItems = [];
const query = new URLSearchParams(window.location.search);
const requestedDeadlineItemId = query.get('deadline_item_id');
let editingDeadlineId = query.get('deadline_id');
const isSingleDeadlineCreate = query.get('mode') === 'single';
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

function deadlineItemHref(itemId) {
  return `gestione-scadenza-item.html?item_id=${encodeURIComponent(itemId)}`;
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
}

function selectedDeadlineItem() {
  return availableDeadlineItems.find((item) => item.id === deadlineItemSelector.value) || null;
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
  return true;
}

async function initialiseCreateMode(account, context) {
  if (!isSingleDeadlineCreate) applyStandardCreateDefaults();

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
  if (editingDeadline || context.member || (!context.requested && !requestedDeadlineItemId) || deadlineItem) setFormMessage('');
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
  if (ready) setFormMessage('Scadenza creata.');
}

f.onsubmit = async (event) => {
  event.preventDefault();
  if (!updateTimeValidation(true)) return;
  const recurrenceValue = document.getElementById('deadline-recurrence').value;
  const reminderValue = document.getElementById('deadline-reminder').value;
  const categoryValue = categoryInput.value;
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
    p_start_time: !isSingleDeadlineFlow || selectedDeadlineType() === 'appointment' ? (startTimeInput.value || null) : null,
    p_end_time: !isSingleDeadlineFlow || selectedDeadlineType() === 'appointment' ? (endTimeInput.value || null) : null
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

  if (managedMember || isSingleDeadlineCreate) {
    location.href = managedHref('scadenze.html');
    return;
  }
  deadlineItem = associatedItem || null;
  await transitionToEdit(data);
};

configureSingleDeadlineLayout();
init();

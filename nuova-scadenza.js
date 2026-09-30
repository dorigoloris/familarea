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
let managedMember = null;
let deadlineItem = null;
let editingDeadline = null;
let availableDeadlineItems = [];
const query = new URLSearchParams(window.location.search);
const requestedDeadlineItemId = query.get('deadline_item_id');
const editingDeadlineId = query.get('deadline_id');
const presetTitle = query.get('preset_title')?.trim() || '';
const presetKind = query.get('preset_kind')?.trim() || '';
const deadlineItemCategoryLabels = {
  vehicle: 'Veicolo',
  home: 'Casa',
  utilities: 'Utenze e bollette',
  other: 'Altro'
};
const vehicleDeadlineTemplates = [
  { title: 'Assicurazione RCA', kind: 'vehicle_insurance' },
  { title: 'Bollo', kind: 'vehicle_tax' },
  { title: 'Collaudo / Revisione', kind: 'vehicle_inspection' },
  { title: 'Tagliando', kind: 'vehicle_service' }
];
let vehicleDeadlineKind = null;

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

function vehicleDeadlineTemplateTitle(value) {
  const normalisedValue = String(value || '').trim().replace(/\s+/g, ' ').toLocaleLowerCase('it-IT');
  return vehicleDeadlineTemplates.find((template) => (
    template.title.toLocaleLowerCase('it-IT') === normalisedValue
      && template.kind === presetKind
  )) || null;
}

function renderVehicleDeadlineContext(item, title = '') {
  deadlineItemField.replaceChildren();
  const vehicle = document.createElement('div');
  vehicle.textContent = `Veicolo: ${item.name}`;
  deadlineItemField.append(vehicle);
  if (title) {
    const deadline = document.createElement('div');
    deadline.textContent = `Scadenza: ${title}`;
    deadlineItemField.append(deadline);
  }
}

function configureVehicleItemCreateForm(item) {
  const template = vehicleDeadlineTemplateTitle(presetTitle);
  const isTemplate = Boolean(template);
  document.getElementById('deadline-category').value = 'vehicle';
  titleField.hidden = isTemplate;
  categoryField.hidden = true;
  if (isTemplate) {
    vehicleDeadlineKind = template.kind;
    document.getElementById('deadline-title').value = template.title;
    formTitle.textContent = `Gestione ${template.title}`;
  }
  renderVehicleDeadlineContext(item, template?.title || '');
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
}

async function loadDeadlineItemSelector(selectedItemId = '') {
  const { data, error } = await c.rpc('get_my_deadline_items', { p_category: 'vehicle' });
  if (error) {
    console.error('get_my_deadline_items failed while configuring deadline form', error);
    return false;
  }

  availableDeadlineItems = data || [];
  deadlineItemSelector.replaceChildren(new Option('Nessun elemento', ''));
  availableDeadlineItems.forEach((item) => {
    const category = deadlineItemCategoryLabels[item.category] || 'Elemento';
    deadlineItemSelector.add(new Option(`${item.name} — ${category}`, item.id));
  });
  deadlineItemSelector.value = availableDeadlineItems.some((item) => item.id === selectedItemId)
    ? selectedItemId
    : '';
  deadlineItemSelectorField.hidden = false;
  deadlineItemSelector.onchange = updateDeadlineItemAssociationFields;
  updateDeadlineItemAssociationFields();
  return true;
}

function populateEditForm(deadline) {
  document.getElementById('deadline-title').value = deadline.title || '';
  document.getElementById('deadline-category').value = deadline.category || 'other';
  document.getElementById('deadline-first-due-on').value = deadline.first_due_on || '';
  document.getElementById('deadline-recurrence').value = deadline.recurrence_months || '';
  document.getElementById('deadline-reminder').value = deadline.reminder_days ?? 30;
  document.getElementById('deadline-notes').value = deadline.notes || '';
}

async function initialiseEditMode(account) {
  const { data, error } = await c.rpc('get_deadline', { p_deadline_id: editingDeadlineId });
  if (error || !data) {
    m.textContent = 'Scadenza non disponibile.';
    return false;
  }

  editingDeadline = data;
  populateEditForm(editingDeadline);
  formTitle.textContent = 'Modifica scadenza';
  formIntro.textContent = 'Aggiorna le informazioni della scadenza.';
  submitButton.textContent = 'Salva modifiche';
  referenceField.hidden = true;
  familyMemberField.hidden = true;
  backLink.href = deadlineDetailHref(editingDeadline.id);
  cancelLink.href = backLink.href;
  if (!await loadDeadlineItemSelector(editingDeadline.deadline_item_id || '')) {
    m.textContent = 'Impossibile preparare il selettore degli elementi.';
    return false;
  }
  return true;
}

async function initialiseCreateMode(account, context) {
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
    if (itemError || !item || item.category !== 'vehicle') {
      m.textContent = 'Veicolo non disponibile. Stai creando una scadenza normale.';
      return true;
    }

    deadlineItem = item;
    deadlineItemField.hidden = false;
    referenceField.hidden = true;
    familyMemberField.hidden = true;
    configureVehicleItemCreateForm(item);
    document.getElementById('deadline-title').setAttribute('list', 'vehicle-deadline-suggestions');
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
    m.textContent = 'Il membro selezionato non Ã¨ gestibile dalla tua Famiglia. Stai creando una scadenza personale.';
  }

  const { data: account, error } = await c.rpc('get_current_account');
  if (error) {
    console.error('get_current_account failed while configuring deadline form', error);
    m.textContent = 'Impossibile preparare il modulo.';
    return;
  }

  const ready = editingDeadlineId && !context.member
    ? await initialiseEditMode(account)
    : await initialiseCreateMode(account, context);
  if (!ready) return;

  f.hidden = false;
  if (editingDeadline || context.member || (!context.requested && !requestedDeadlineItemId) || deadlineItem) m.textContent = '';
}

f.onsubmit = async (event) => {
  event.preventDefault();
  const commonParams = {
    p_title: document.getElementById('deadline-title').value.trim(),
    p_category: document.getElementById('deadline-category').value,
    p_first_due_on: document.getElementById('deadline-first-due-on').value,
    p_recurrence_months: Number(document.getElementById('deadline-recurrence').value) || null,
    p_reminder_days: Number(document.getElementById('deadline-reminder').value),
    p_notes: document.getElementById('deadline-notes').value.trim() || null
  };

  if (editingDeadline) {
    const { error } = await c.rpc('update_my_deadline_with_item', {
      p_deadline_id: editingDeadline.id,
      ...commonParams,
      p_deadline_item_id: selectedDeadlineItem()?.id || null
    });
    if (error) {
      m.textContent = 'Impossibile aggiornare la scadenza.';
      return;
    }
    location.href = deadlineDetailHref(editingDeadline.id);
    return;
  }

  const associatedItem = deadlineItem || selectedDeadlineItem();
  const { data, error } = associatedItem
    ? await c.rpc('create_deadline_for_item', {
      p_item_id: associatedItem.id,
      ...commonParams,
      p_deadline_kind: vehicleDeadlineKind
    })
    : await c.rpc('create_deadline', {
      ...commonParams,
      p_family_member_id: managedMember
        ? managedMember.id
        : (familyMemberField.hidden ? null : (document.getElementById('deadline-family-member').value || null))
    });
  if (error) {
    m.textContent = 'Impossibile creare la scadenza.';
    return;
  }

  location.href = deadlineItem
    ? deadlineItemHref(deadlineItem.id)
    : (managedMember
      ? managedHref('scadenze.html')
      : deadlineDetailHref(data));
};

init();

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
let headerDeadlineItem = null;
let availableDeadlineItems = [];
const query = new URLSearchParams(window.location.search);
const requestedDeadlineItemId = query.get('deadline_item_id');
let editingDeadlineId = query.get('deadline_id');
const isSingleDeadlineCreate = query.get('mode') === 'single';
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
}

async function initialiseEditMode(account) {
  const { data, error } = await c.rpc('get_deadline', { p_deadline_id: editingDeadlineId });
  if (error || !data) {
    m.textContent = 'Scadenza non disponibile.';
    return false;
  }

  editingDeadline = data;
  populateEditForm(editingDeadline);
  clearAssociatedDeadlineHeader();
  formIntro.textContent = 'Aggiorna le informazioni della scadenza.';
  submitButton.textContent = 'Salva modifiche';
  referenceField.hidden = true;
  familyMemberField.hidden = true;
  backLink.href = deadlineItem?.id ? deadlineItemHref(deadlineItem.id) : deadlineDetailHref(editingDeadline.id);
  cancelLink.href = backLink.href;
  if (!await loadDeadlineItemSelector(editingDeadline.deadline_item_id || '')) {
    m.textContent = 'Impossibile preparare il selettore degli elementi.';
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
      m.textContent = 'Elemento non disponibile. Stai creando una scadenza normale.';
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

document.getElementById('deadline-title').addEventListener('input', () => {
  if (headerDeadlineItem) setAssociatedDeadlineHeader(headerDeadlineItem, document.getElementById('deadline-title').value);
});

async function transitionToEdit(deadlineId) {
  editingDeadlineId = deadlineId;
  const url = new URL(window.location.href);
  url.search = '';
  url.searchParams.set('deadline_id', deadlineId);
  window.history.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`);
  const ready = await initialiseEditMode();
  if (ready) m.textContent = 'Scadenza creata.';
}

f.onsubmit = async (event) => {
  event.preventDefault();
  if (!document.getElementById('deadline-recurrence').value || !document.getElementById('deadline-reminder').value) {
    m.textContent = 'Seleziona ricorrenza e promemoria.';
    return;
  }
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
    m.textContent = 'Modifiche salvate.';
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
    m.textContent = 'Impossibile creare la scadenza.';
    return;
  }

  if (managedMember) {
    location.href = managedHref('scadenze.html');
    return;
  }
  deadlineItem = associatedItem || null;
  await transitionToEdit(data);
};

init();

const deadlineItemClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const deadlineItemId = new URLSearchParams(window.location.search).get('item_id');
const deadlineItemMessage = document.getElementById('deadline-item-message');
const deadlineItemTypeLabels = { car: 'Auto', motorcycle: 'Moto', other: 'Altro' };
const deadlineItemPredefinedCards = document.getElementById('deadline-item-predefined-cards');
const deadlineItemCustomDeadlines = document.getElementById('deadline-item-custom-deadlines');
const deadlineItemDeadlinesList = document.getElementById('deadline-item-deadlines-list');
const predefinedVehicleDeadlines = [
  { title: 'Assicurazione RCA', kind: 'vehicle_insurance', icon: 'R' },
  { title: 'Bollo', kind: 'vehicle_tax', icon: 'B' },
  { title: 'Collaudo / Revisione', kind: 'vehicle_inspection', icon: 'C' },
  { title: 'Tagliando', kind: 'vehicle_service', icon: 'T' }
];

function itemDeadlineHref(path) {
  const url = new URL(path, window.location.href);
  url.searchParams.set('deadline_item_id', deadlineItemId);
  return `${url.pathname.split('/').pop()}${url.search}`;
}

function itemDeadlineCreateHref(title = '', kind = '') {
  const url = new URL(itemDeadlineHref('nuova-scadenza.html'), window.location.href);
  if (title) url.searchParams.set('preset_title', title);
  if (kind) url.searchParams.set('preset_kind', kind);
  return `${url.pathname.split('/').pop()}${url.search}`;
}

function createDeadlineCard({ title, kind = '', icon, deadline, presetTitle = title }) {
  const card = document.createElement('a');
  card.className = 'area-card fa-item-card';
  card.href = deadline
    ? (kind === 'vehicle_service'
      ? `gestione-tagliando.html?deadline_id=${encodeURIComponent(deadline.id)}`
      : `gestione-scadenza-veicolo.html?deadline_id=${encodeURIComponent(deadline.id)}`)
    : itemDeadlineCreateHref(presetTitle, kind);

  const cardIcon = document.createElement('span');
  cardIcon.className = 'area-card-icon fa-item-card-icon';
  cardIcon.setAttribute('aria-hidden', 'true');
  cardIcon.textContent = icon;

  const copy = document.createElement('span');
  copy.className = 'fa-item-card-copy';
  const heading = document.createElement('h3');
  heading.textContent = title;
  const detail = document.createElement('p');
  detail.textContent = deadline
    ? `Prima scadenza: ${window.FamilAreaDateUtils.formatDateDisplay(deadline.first_due_on)}`
    : 'Aggiungi scadenza';
  copy.append(heading, detail);

  const indicator = document.createElement('span');
  indicator.className = 'area-card-open-indicator fa-item-card-open-indicator';
  indicator.setAttribute('aria-hidden', 'true');
  indicator.textContent = '→';
  card.append(cardIcon, copy, indicator);
  return card;
}

function renderCustomDeadlines(rows) {
  deadlineItemCustomDeadlines.hidden = rows.length === 0;
  deadlineItemDeadlinesList.replaceChildren(...rows.map((deadline) => {
    const row = document.createElement('a');
    row.className = 'deadline-card';
    row.href = `scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}`;
    row.textContent = `${deadline.title} — ${window.FamilAreaDateUtils.formatDateDisplay(deadline.first_due_on)}`;
    return row;
  }));
}

function renderItemDeadlines(rows) {
  const unmatchedRows = new Set(rows);
  const cards = predefinedVehicleDeadlines.map((template) => {
    const deadline = rows.find((row) => (
      unmatchedRows.has(row) && row.deadline_kind === template.kind
    ));
    if (deadline) unmatchedRows.delete(deadline);
    return createDeadlineCard({ ...template, deadline });
  });
  cards.push(createDeadlineCard({ title: 'Aggiungi scadenza', icon: '+', deadline: null, presetTitle: '' }));
  deadlineItemPredefinedCards.replaceChildren(...cards);
  renderCustomDeadlines([...unmatchedRows]);
}

async function loadItemDeadlines() {
  const { data, error } = await deadlineItemClient.rpc('get_my_deadlines_for_item', {
    p_item_id: deadlineItemId
  });
  if (error) {
    deadlineItemMessage.textContent = 'Impossibile caricare le scadenze del veicolo.';
    return;
  }
  renderItemDeadlines(data || []);
}

async function loadDeadlineItem() {
  if (!deadlineItemId) {
    deadlineItemMessage.textContent = 'Veicolo non disponibile.';
    return;
  }
  const { data, error } = await deadlineItemClient.rpc('get_my_deadline_item', { p_item_id: deadlineItemId });
  if (error || !data || data.category !== 'vehicle') {
    deadlineItemMessage.textContent = 'Veicolo non disponibile.';
    return;
  }
  document.getElementById('deadline-item-title').textContent = data.name;
  const typeLabel = deadlineItemTypeLabels[data.item_type] || 'Altro';
  document.getElementById('deadline-item-type').textContent = data.plate
    ? `${typeLabel} · ${data.plate}`
    : typeLabel;
  const itemImage = document.getElementById('deadline-item-image');
  itemImage.replaceChildren();
  itemImage.textContent = (data.name.trim().charAt(0) || 'V').toLocaleUpperCase('it-IT');
  if (data.image_path) void window.FamilAreaDeadlineItemImage.render(itemImage, data.image_path, `Foto di ${data.name}`);
  document.getElementById('deadline-item-content').hidden = false;
  deadlineItemMessage.textContent = '';
  await loadItemDeadlines();
}

async function initialiseDeadlineItem() {
  if (!await window.FamilAreaDeadlineManagementReady) return;
  await loadDeadlineItem();
}

void initialiseDeadlineItem();

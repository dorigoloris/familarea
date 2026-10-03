const deadlineItemClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const deadlineItemId = new URLSearchParams(window.location.search).get('item_id');
const deadlineItemMessage = document.getElementById('deadline-item-message');
const deadlineItemPredefinedCards = document.getElementById('deadline-item-predefined-cards');
const deadlineItemCustomDeadlines = document.getElementById('deadline-item-custom-deadlines');
const deadlineItemDeadlinesList = document.getElementById('deadline-item-deadlines-list');
const itemConfigurations = {
  vehicle: { label: 'Veicolo', imageLabel: 'Foto del veicolo', backHref: 'gestione-scadenze-veicoli.html', templates: [
    { title: 'Assicurazione RCA', kind: 'vehicle_insurance', icon: 'R' }, { title: 'Bollo', kind: 'vehicle_tax', icon: 'B' },
    { title: 'Collaudo / Revisione', kind: 'vehicle_inspection', icon: 'C' }, { title: 'Tagliando', kind: 'vehicle_service', icon: 'T' }
  ] },
  home: { label: 'Casa', imageLabel: 'Foto della casa', backHref: 'scadenze.html', templates: [
    { title: 'Caldaia / Impianto termico', kind: 'home_heating', icon: 'I' }, { title: 'Assicurazione casa', kind: 'home_insurance', icon: 'A' },
    { title: 'Imposte e tributi', kind: 'home_taxes', icon: 'T' }, { title: 'Rifiuti', kind: 'home_waste', icon: 'R' }
  ] }
};
let currentConfiguration;
let currentDeadlineItem = null;
let deadlineItemEditPreviousFocus = null;
const deadlineItemImageService = window.FamilAreaDeadlineItemImage;
const homeAnnualCalendarSection = document.getElementById('home-annual-calendar');
const isHomeDeadlineContext = new URLSearchParams(window.location.search).get('context') === 'home';
let homeAnnualCalendar = null;
const deadlineItemImageEditor = deadlineItemImageService.createEditor({ client: deadlineItemClient, input: document.getElementById('deadline-item-image-input'), preview: document.getElementById('deadline-item-image-preview'), upload: document.getElementById('deadline-item-image-upload'), remove: document.getElementById('deadline-item-image-remove'), message: document.getElementById('deadline-item-image-message'), getItem: () => currentDeadlineItem, fallback: (item) => item?.name || 'E', noun: 'foto' });

function itemDeadlineHref(path) { const url = new URL(path, window.location.href); url.searchParams.set('deadline_item_id', deadlineItemId); return `${url.pathname.split('/').pop()}${url.search}`; }
function itemDeadlineCreateHref(title = '', kind = '') { const url = new URL(itemDeadlineHref('nuova-scadenza.html'), window.location.href); if (title) url.searchParams.set('preset_title', title); if (kind) url.searchParams.set('preset_kind', kind); return `${url.pathname.split('/').pop()}${url.search}`; }
function createDeadlineCard({ title, kind, icon, deadline, presetTitle = title }) {
  const card = document.createElement('a');
  const href = deadline ? (kind === 'vehicle_service' ? `gestione-tagliando.html?deadline_id=${encodeURIComponent(deadline.id)}` : `nuova-scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}&deadline_item_id=${encodeURIComponent(deadlineItemId)}`) : itemDeadlineCreateHref(presetTitle, kind);
  card.href = href;
  card.className = 'deadline-item-summary-card deadline-item-summary-card--clickable fa-v2-list-row';
  const image = document.createElement('span'); image.className = 'deadline-management-item-image deadline-item-summary-image'; image.setAttribute('aria-hidden', 'true'); image.textContent = icon;
  if (deadline) void window.FamilAreaAttachmentPreview.renderTargetCardPreview({
    client: deadlineItemClient,
    targetType: 'deadline',
    targetId: deadline.id,
    container: image
  });
  const type = document.createElement('p'); type.className = 'deadline-item-summary-type'; type.textContent = currentConfiguration?.label || '';
  const heading = document.createElement('h2'); heading.className = 'deadline-item-summary-name'; heading.textContent = title;
  const detail = document.createElement('span'); detail.className = 'deadline-item-summary-plate'; detail.textContent = deadline ? window.FamilAreaDateUtils.formatDateDisplay(deadline.first_due_on) : 'Nessuna scadenza';
  const action = document.createElement('span'); action.className = 'fa-button fa-button-secondary fa-button-compact deadline-item-summary-action'; action.textContent = deadline ? 'Modifica' : 'Aggiungi';
  card.append(image, type, heading, detail, action);
  return card;
}
function renderCustomDeadlines(rows) { deadlineItemCustomDeadlines.hidden = rows.length === 0; deadlineItemDeadlinesList.replaceChildren(...rows.map((deadline) => { const row = document.createElement('a'); row.className = 'deadline-card'; row.href = `nuova-scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}&deadline_item_id=${encodeURIComponent(deadlineItemId)}`; row.textContent = `${deadline.title} — ${window.FamilAreaDateUtils.formatDateDisplay(deadline.first_due_on)}`; return row; })); }
function renderItemDeadlines(rows) { const unmatchedRows = new Set(rows); const cards = currentConfiguration.templates.map((template) => { const deadline = rows.find((row) => unmatchedRows.has(row) && row.deadline_kind === template.kind); if (deadline) unmatchedRows.delete(deadline); return createDeadlineCard({ ...template, deadline }); }); deadlineItemPredefinedCards.replaceChildren(...cards); renderCustomDeadlines([...unmatchedRows]); }
async function loadItemDeadlines() { const { data, error } = await deadlineItemClient.rpc('get_my_deadlines_for_item', { p_item_id: deadlineItemId }); if (error) { deadlineItemMessage.textContent = 'Impossibile caricare le scadenze dell’elemento.'; return; } renderItemDeadlines(data || []); }
function applyHomeV2() {
  if (currentConfiguration?.label !== 'Casa') return;
  document.body.classList.add('fa-v2-app', 'home-deadline-item');
  document.querySelector('.deadline-management-page')?.classList.add('fa-v2-page', 'fa-v2-page-stack');
  document.getElementById('deadline-item-content')?.classList.add('fa-v2-page-stack');
  deadlineItemMessage.classList.add('fa-v2-status', 'fa-v2-stack-optional');
  document.querySelector('.deadline-item-hero')?.classList.add('fa-v2-list-row');
  const deadlinesSection = document.querySelector('.deadline-item-deadlines');
  deadlinesSection?.setAttribute('aria-label', 'Scadenze');
  document.getElementById('deadline-item-deadlines-title')?.remove();
  const createButton = document.getElementById('deadline-item-create');
  createButton?.classList.remove('fa-button', 'fa-button-secondary', 'fa-button-compact');
  createButton?.classList.add('fa-v2-button', 'fa-v2-button--primary');
}

function initialiseHomeAnnualCalendar() {
  if (!isHomeDeadlineContext || currentConfiguration?.label !== 'Casa' || !currentDeadlineItem) return;
  if (homeAnnualCalendar) return;
  homeAnnualCalendarSection.hidden = false;
  homeAnnualCalendar = window.FamilAreaAnnualDeadlineCalendar.create({
    client: deadlineItemClient,
    gridElement: document.getElementById('home-annual-calendar-grid'),
    yearElement: document.getElementById('home-calendar-year'),
    messageElement: document.getElementById('home-calendar-message'),
    previousButton: document.getElementById('home-calendar-previous-year'),
    nextButton: document.getElementById('home-calendar-next-year'),
    getItems: () => [currentDeadlineItem],
    itemFallback: 'Casa',
    imageService: deadlineItemImageService,
    idPrefix: 'home-calendar',
    isOccurrence: (occurrence) => occurrence.deadline_id
      && occurrence.deadline_item_category === 'home'
      && occurrence.deadline_item_id === currentDeadlineItem.id
  });
}

async function loadDeadlineItem() {
  if (!deadlineItemId) { deadlineItemMessage.textContent = 'Elemento non disponibile.'; return; }
  const { data, error } = await deadlineItemClient.rpc('get_my_deadline_item', { p_item_id: deadlineItemId }); currentConfiguration = itemConfigurations[data?.category];
  if (error || !data || !currentConfiguration) { deadlineItemMessage.textContent = 'Elemento non disponibile.'; return; }
  if (data.category === 'home' && !isHomeDeadlineContext) {
    const homeUrl = new URL(window.location.href);
    homeUrl.searchParams.set('context', 'home');
    location.replace(`${homeUrl.pathname.split('/').pop()}${homeUrl.search}`);
    return;
  }
  currentDeadlineItem = data;
  document.title = `${currentConfiguration.label} - Scadenze - FamilArea`; document.querySelector('.account-back-link a').href = currentConfiguration.backHref; document.getElementById('deadline-item-page-title').textContent = data.name; document.getElementById('deadline-item-title').textContent = data.name;
  document.getElementById('deadline-item-type').textContent = data.category === 'vehicle' ? (data.item_type === 'car' ? 'Auto' : data.item_type === 'motorcycle' ? 'Moto' : 'Altro') : '';
  document.getElementById('deadline-item-plate').textContent = data.plate || '';
  const itemImage = document.getElementById('deadline-item-image'); itemImage.replaceChildren(); itemImage.textContent = (data.name.trim().charAt(0) || 'E').toLocaleUpperCase('it-IT'); itemImage.setAttribute('aria-label', `Foto di ${data.name}`); if (data.image_path) void deadlineItemImageService.render(itemImage, data.image_path, `Foto di ${data.name}`);
  document.getElementById('deadline-item-image-label').textContent = currentConfiguration.imageLabel; document.getElementById('deadline-item-edit-title').textContent = `Modifica ${currentConfiguration.label.toLocaleLowerCase('it-IT')}`; deadlineItemImageEditor.reset(); void deadlineItemImageEditor.refresh();
  applyHomeV2();
  initialiseHomeAnnualCalendar();
  document.getElementById('deadline-item-content').hidden = false; deadlineItemMessage.textContent = ''; await loadItemDeadlines(); await homeAnnualCalendar?.load();
}
function openDeadlineItemEdit() { deadlineItemEditPreviousFocus = document.activeElement; document.getElementById('deadline-item-edit-modal').hidden = false; document.body.classList.add('confirm-modal-open'); void deadlineItemImageEditor.refresh(); document.getElementById('deadline-item-edit-close').focus(); }
function closeDeadlineItemEdit() { document.getElementById('deadline-item-edit-modal').hidden = true; document.body.classList.remove('confirm-modal-open'); deadlineItemEditPreviousFocus?.focus?.(); deadlineItemEditPreviousFocus = null; }
async function saveDeadlineItemImage() {
  if (!currentDeadlineItem) return;
  try { await deadlineItemImageEditor.save(currentDeadlineItem, currentDeadlineItem.image_path); closeDeadlineItemEdit(); await loadDeadlineItem(); }
  catch (error) { console.error('deadline item image save failed', error); deadlineItemImageEditor.setMessage('Impossibile aggiornare la foto.', true); }
}
async function initialiseDeadlineItem() {
  if (!await window.FamilAreaDeadlineManagementReady) return;
  document.getElementById('deadline-item-create').addEventListener('click', () => { window.location.href = itemDeadlineCreateHref(); });
  document.getElementById('deadline-item-image-save').addEventListener('click', () => { void saveDeadlineItemImage(); });
  document.getElementById('deadline-item-edit-close').addEventListener('click', closeDeadlineItemEdit);
  document.getElementById('deadline-item-edit-modal').addEventListener('click', (event) => { if (event.target.id === 'deadline-item-edit-modal') closeDeadlineItemEdit(); });
  document.addEventListener('keydown', (event) => { if (event.key === 'Escape' && !document.getElementById('deadline-item-edit-modal').hidden) closeDeadlineItemEdit(); });
  await loadDeadlineItem();
}
void initialiseDeadlineItem();

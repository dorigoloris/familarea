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
  home: { label: 'Casa', imageLabel: 'Foto della casa', backHref: 'gestione-scadenze-casa.html', templates: [
    { title: 'Caldaia / Impianto termico', kind: 'home_heating', icon: 'I' }, { title: 'Assicurazione casa', kind: 'home_insurance', icon: 'A' },
    { title: 'Imposte e tributi', kind: 'home_taxes', icon: 'T' }, { title: 'Rifiuti', kind: 'home_waste', icon: 'R' }
  ] }
};
let currentConfiguration;
let currentDeadlineItem = null;
let deadlineItemEditPreviousFocus = null;
const deadlineItemImageService = window.FamilAreaDeadlineItemImage;
const deadlineItemImageEditor = deadlineItemImageService.createEditor({ client: deadlineItemClient, input: document.getElementById('deadline-item-image-input'), preview: document.getElementById('deadline-item-image-preview'), upload: document.getElementById('deadline-item-image-upload'), remove: document.getElementById('deadline-item-image-remove'), message: document.getElementById('deadline-item-image-message'), getItem: () => currentDeadlineItem, fallback: (item) => item?.name || 'E', noun: 'foto' });

function itemDeadlineHref(path) { const url = new URL(path, window.location.href); url.searchParams.set('deadline_item_id', deadlineItemId); return `${url.pathname.split('/').pop()}${url.search}`; }
function itemDeadlineCreateHref(title = '', kind = '') { const url = new URL(itemDeadlineHref('nuova-scadenza.html'), window.location.href); if (title) url.searchParams.set('preset_title', title); if (kind) url.searchParams.set('preset_kind', kind); return `${url.pathname.split('/').pop()}${url.search}`; }
function createDeadlineCard({ title, kind, icon, deadline, presetTitle = title }) {
  const card = document.createElement('a'); card.className = 'deadline-item-preset-card fa-surface';
  card.href = deadline ? (kind === 'vehicle_service' ? `gestione-tagliando.html?deadline_id=${encodeURIComponent(deadline.id)}` : `nuova-scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}&deadline_item_id=${encodeURIComponent(deadlineItemId)}`) : itemDeadlineCreateHref(presetTitle, kind);
  const cardIcon = document.createElement('span'); cardIcon.className = 'deadline-item-preset-icon'; cardIcon.setAttribute('aria-hidden', 'true'); cardIcon.textContent = icon;
  const copy = document.createElement('span'); copy.className = 'fa-item-card-copy'; const heading = document.createElement('h3'); heading.textContent = title;
  const detail = document.createElement('p'); detail.textContent = deadline ? window.FamilAreaDateUtils.formatDateDisplay(deadline.first_due_on) : 'Nessuna scadenza'; copy.append(heading, detail);
  const action = document.createElement('span'); action.className = 'deadline-item-preset-action'; action.textContent = deadline ? 'Modifica' : 'Aggiungi'; card.append(cardIcon, copy, action); return card;
}
function renderCustomDeadlines(rows) { deadlineItemCustomDeadlines.hidden = rows.length === 0; deadlineItemDeadlinesList.replaceChildren(...rows.map((deadline) => { const row = document.createElement('a'); row.className = 'deadline-card'; row.href = `nuova-scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}&deadline_item_id=${encodeURIComponent(deadlineItemId)}`; row.textContent = `${deadline.title} — ${window.FamilAreaDateUtils.formatDateDisplay(deadline.first_due_on)}`; return row; })); }
function renderItemDeadlines(rows) { const unmatchedRows = new Set(rows); const cards = currentConfiguration.templates.map((template) => { const deadline = rows.find((row) => unmatchedRows.has(row) && row.deadline_kind === template.kind); if (deadline) unmatchedRows.delete(deadline); return createDeadlineCard({ ...template, deadline }); }); deadlineItemPredefinedCards.replaceChildren(...cards); renderCustomDeadlines([...unmatchedRows]); }
async function loadItemDeadlines() { const { data, error } = await deadlineItemClient.rpc('get_my_deadlines_for_item', { p_item_id: deadlineItemId }); if (error) { deadlineItemMessage.textContent = 'Impossibile caricare le scadenze dell’elemento.'; return; } renderItemDeadlines(data || []); }
async function loadDeadlineItem() {
  if (!deadlineItemId) { deadlineItemMessage.textContent = 'Elemento non disponibile.'; return; }
  const { data, error } = await deadlineItemClient.rpc('get_my_deadline_item', { p_item_id: deadlineItemId }); currentConfiguration = itemConfigurations[data?.category];
  if (error || !data || !currentConfiguration) { deadlineItemMessage.textContent = 'Elemento non disponibile.'; return; }
  currentDeadlineItem = data;
  document.title = `${currentConfiguration.label} - Scadenze - FamilArea`; document.getElementById('deadline-item-back-link').href = currentConfiguration.backHref; document.getElementById('deadline-item-page-title').textContent = data.name; document.getElementById('deadline-item-title').textContent = data.name;
  document.getElementById('deadline-item-type').textContent = data.category === 'vehicle' ? (data.item_type === 'car' ? 'Auto' : data.item_type === 'motorcycle' ? 'Moto' : 'Altro') : '';
  document.getElementById('deadline-item-plate').textContent = data.plate || '';
  const itemImage = document.getElementById('deadline-item-image'); itemImage.replaceChildren(); itemImage.textContent = (data.name.trim().charAt(0) || 'E').toLocaleUpperCase('it-IT'); itemImage.setAttribute('aria-label', `Foto di ${data.name}`); if (data.image_path) void deadlineItemImageService.render(itemImage, data.image_path, `Foto di ${data.name}`);
  document.getElementById('deadline-item-image-label').textContent = currentConfiguration.imageLabel; document.getElementById('deadline-item-edit-title').textContent = `Modifica ${currentConfiguration.label.toLocaleLowerCase('it-IT')}`; deadlineItemImageEditor.reset(); void deadlineItemImageEditor.refresh();
  document.getElementById('deadline-item-content').hidden = false; deadlineItemMessage.textContent = ''; await loadItemDeadlines();
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

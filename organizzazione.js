const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const organizationId = new URLSearchParams(location.search).get('organization_id');
const message = document.getElementById('organization-message');
const detail = document.getElementById('organization-detail');
const editButton = document.getElementById('edit-organization');
const editForm = document.getElementById('organization-edit-form');
const statusLabel = { draft: 'Bozza', active: 'Attiva', archived: 'Archiviata' };
const roleLabel = { owner: 'Proprietario', admin: 'Amministratore', collaborator: 'Collaboratore' };
const editFields = {
  name: document.getElementById('edit-organization-name'),
  type: document.getElementById('edit-organization-type'),
  description: document.getElementById('edit-organization-description'),
  status: document.getElementById('edit-organization-status'),
  statusWrap: document.getElementById('edit-status-wrap')
};
let currentOrganization;

function showError(text) { message.textContent = text; message.classList.add('is-error'); }
function canEdit() { return currentOrganization && ['owner', 'admin'].includes(currentOrganization.my_role); }

function populateEditForm() {
  if (!currentOrganization) return;
  editFields.name.value = currentOrganization.name || '';
  editFields.type.value = currentOrganization.organization_type || '';
  editFields.description.value = currentOrganization.description || '';
  editFields.statusWrap.hidden = currentOrganization.my_role !== 'owner';
  editFields.status.value = currentOrganization.status || 'draft';
}

function render() {
  document.getElementById('organization-name').textContent = currentOrganization.name;
  document.getElementById('organization-type').textContent = currentOrganization.organization_type;
  document.getElementById('organization-description').textContent = currentOrganization.description || 'Nessuna descrizione disponibile.';
  document.getElementById('organization-status').textContent = statusLabel[currentOrganization.status] || currentOrganization.status;
  document.getElementById('organization-role').textContent = roleLabel[currentOrganization.my_role] || currentOrganization.my_role;
  editButton.hidden = !canEdit();
  detail.hidden = false;
  message.textContent = '';
}

function openEdit() {
  populateEditForm();
  editForm.hidden = false;
  editButton.hidden = true;
  document.getElementById('edit-organization-name').focus();
}

function closeEdit() { editForm.hidden = true; editButton.hidden = !canEdit(); }

function createAreaRow(area) {
  const link = document.createElement('a');
  link.className = 'organization-area-row';
  link.href = `area.html?area_id=${encodeURIComponent(area.id)}`;
  const text = document.createElement('span');
  const name = document.createElement('strong'); name.textContent = area.name;
  const type = document.createElement('small'); type.textContent = area.area_type;
  text.append(name, type);
  const arrow = document.createElement('span'); arrow.textContent = '→'; arrow.setAttribute('aria-hidden', 'true');
  link.append(text, arrow);
  return link;
}

async function loadAreas() {
  if (!['owner', 'admin'].includes(currentOrganization.my_role)) return;
  const section = document.getElementById('organization-areas');
  const list = document.getElementById('organization-areas-list');
  const empty = document.getElementById('organization-areas-empty');
  const { data, error } = await supabaseClient.rpc('get_organization_areas', { p_organization_id: organizationId });
  if (error) return;
  list.replaceChildren();
  (data || []).forEach((area) => list.appendChild(createAreaRow(area)));
  empty.hidden = (data || []).length > 0;
  section.hidden = false;
}

async function load() {
  const { data: session } = await supabaseClient.auth.getSession();
  if (!session.session) { location.href = 'login.html'; return; }
  if (!organizationId) { showError('Organizzazione non specificata.'); return; }
  const { data, error } = await supabaseClient.rpc('get_organization', { p_organization_id: organizationId });
  if (error || !data?.[0]) { showError('Non puoi aprire questa Organizzazione o non è disponibile.'); return; }
  currentOrganization = { ...data[0] };
  render();
  loadAreas().catch(() => {});
}

editButton.addEventListener('click', openEdit);
document.getElementById('cancel-organization-edit').addEventListener('click', closeEdit);
editForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const name = document.getElementById('edit-organization-name').value.trim();
  const type = document.getElementById('edit-organization-type').value.trim();
  if (!name || !type) { showError('Nome e tipo sono obbligatori.'); return; }
  const save = document.getElementById('save-organization');
  save.disabled = true;
  const { error } = await supabaseClient.rpc('update_organization', {
    p_organization_id: organizationId, p_name: name, p_organization_type: type,
    p_description: document.getElementById('edit-organization-description').value.trim() || null,
    p_status: currentOrganization.my_role === 'owner' ? editFields.status.value : currentOrganization.status
  });
  if (error) { showError('Impossibile salvare le modifiche. Verifica le autorizzazioni e riprova.'); save.disabled = false; return; }
  closeEdit();
  await load();
  save.disabled = false;
});

load().catch(() => showError('Impossibile caricare l’Organizzazione. Riprova.'));

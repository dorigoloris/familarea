const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('organizations-message');
const surface = document.getElementById('organizations-surface');
const list = document.getElementById('organizations-list');
const empty = document.getElementById('organizations-empty');

const statusLabel = { draft: 'Bozza', active: 'Attiva', archived: 'Archiviata' };
const roleLabel = { owner: 'Proprietario', admin: 'Amministratore', collaborator: 'Collaboratore' };

function createCard(organization) {
  const card = document.createElement('a');
  card.className = 'organization-card';
  card.href = `organizzazione.html?organization_id=${encodeURIComponent(organization.id)}`;
  const identity = document.createElement('div');
  const title = document.createElement('h2');
  title.textContent = organization.name;
  const type = document.createElement('p');
  type.textContent = organization.organization_type;
  identity.append(title, type);
  const meta = document.createElement('div');
  meta.className = 'organization-card-meta';
  const status = document.createElement('span');
  status.textContent = statusLabel[organization.status] || organization.status;
  const role = document.createElement('span');
  role.textContent = roleLabel[organization.my_role] || organization.my_role;
  meta.append(status, role);
  const arrow = document.createElement('span');
  arrow.className = 'organization-card-arrow';
  arrow.setAttribute('aria-hidden', 'true');
  arrow.textContent = '→';
  card.append(identity, meta, arrow);
  return card;
}

async function load() {
  const { data: session } = await supabaseClient.auth.getSession();
  if (!session.session) { location.href = 'login.html'; return; }
  const { data, error } = await supabaseClient.rpc('get_my_organizations');
  if (error) { message.textContent = 'Impossibile caricare le Organizzazioni. Riprova.'; message.classList.add('is-error'); return; }
  list.replaceChildren();
  (data || []).forEach((organization) => list.appendChild(createCard(organization)));
  surface.hidden = false;
  empty.hidden = (data || []).length > 0;
  message.textContent = '';
}

load().catch(() => { message.textContent = 'Impossibile caricare le Organizzazioni. Riprova.'; message.classList.add('is-error'); });

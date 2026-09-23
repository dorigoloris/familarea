const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const groups = {
  admin: { container: document.getElementById('managed-areas-group'), list: document.getElementById('managed-areas-list'), empty: document.getElementById('managed-areas-empty') },
  member: { container: document.getElementById('member-areas-group'), list: document.getElementById('member-areas-list'), empty: document.getElementById('member-areas-empty') }
};

function createAreaCard(area) {
  const card = document.createElement('a');
  card.className = 'area-card';
  card.href = `area.html?area_id=${encodeURIComponent(area.id)}`;
  const icon = document.createElement('span');
  icon.className = 'area-card-icon';
  icon.setAttribute('aria-hidden', 'true');
  icon.textContent = '⌂';
  const title = document.createElement('h3');
  title.textContent = area.name;
  const indicator = document.createElement('span');
  indicator.className = 'area-card-open-indicator';
  indicator.setAttribute('aria-hidden', 'true');
  indicator.textContent = '→';
  card.append(icon, title, indicator);
  void renderAreaCardImage(area, card);
  return card;
}

async function renderAreaCardImage(area, card) {
  if (!area.image_path) return;
  const { data, error } = await supabaseClient.storage.from('area-images').createSignedUrl(area.image_path, 3600);
  if (error || !data?.signedUrl || !card.isConnected) return;
  const safeUrl = data.signedUrl.replace(/["\\]/g, '\\$&');
  card.style.setProperty('--area-card-cover', `url("${safeUrl}")`);
  card.classList.add('has-area-cover');
}

function renderGroup(group, memberships) {
  group.list.replaceChildren();
  group.container.hidden = false;
  group.empty.hidden = memberships.length > 0;
  memberships.forEach((membership) => group.list.appendChild(createAreaCard(membership)));
}

function renderAreas(areas) {
  const visibleAreas = areas || [];
  if (!visibleAreas.length) {
    groups.admin.container.hidden = true;
    groups.member.container.hidden = true;
    message.textContent = 'Non hai ancora nessuna Area.';
    return;
  }
  renderGroup(groups.admin, visibleAreas.filter((area) => area.role === 'owner' || area.role === 'admin'));
  renderGroup(groups.member, visibleAreas.filter((area) => area.role !== 'owner' && area.role !== 'admin'));
  message.textContent = '';
}

async function loadAreas() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }
  const { data: areas, error } = await supabaseClient.rpc('get_my_areas');
  if (error) { message.textContent = 'Impossibile caricare le Aree.'; return; }
  renderAreas(areas);
}

loadAreas();

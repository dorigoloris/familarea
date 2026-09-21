const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const groups = {
  admin: { container: document.getElementById('managed-areas-group'), list: document.getElementById('managed-areas-list'), empty: document.getElementById('managed-areas-empty') },
  member: { container: document.getElementById('member-areas-group'), list: document.getElementById('member-areas-list'), empty: document.getElementById('member-areas-empty') }
};

function roleLabel(role) {
  return ({ admin: 'Amministratore', member: 'Partecipante', managed: 'Profilo gestito' })[role] || role;
}

function createAreaCard(membership) {
  const area = membership.areas;
  const card = document.createElement('article');
  card.className = 'area-card';
  const icon = document.createElement('span');
  icon.className = 'area-card-icon';
  icon.setAttribute('aria-hidden', 'true');
  icon.textContent = '⌂';
  const title = document.createElement('h3');
  title.textContent = area.name;
  const info = document.createElement('p');
  info.textContent = `${area.area_type} — ${roleLabel(membership.role)}`;
  const link = document.createElement('a');
  link.className = 'btn';
  link.textContent = 'Apri Area';
  link.href = `area.html?area_id=${encodeURIComponent(area.id)}`;
  card.append(icon, title, info, link);
  return card;
}

function renderGroup(group, memberships) {
  group.list.replaceChildren();
  group.container.hidden = false;
  group.empty.hidden = memberships.length > 0;
  memberships.forEach((membership) => group.list.appendChild(createAreaCard(membership)));
}

function renderAreas(memberships) {
  const visibleMemberships = (memberships || []).filter((membership) => membership.areas);
  if (!visibleMemberships.length) {
    groups.admin.container.hidden = true;
    groups.member.container.hidden = true;
    message.textContent = 'Non hai ancora nessuna Area.';
    return;
  }
  renderGroup(groups.admin, visibleMemberships.filter((membership) => membership.role === 'admin'));
  renderGroup(groups.member, visibleMemberships.filter((membership) => membership.role !== 'admin'));
  message.textContent = '';
}

async function loadAreas() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }
  const { data: profile, error: profileError } = await supabaseClient
    .from('profiles').select('id').eq('user_id', sessionData.session.user.id).single();
  if (profileError || !profile) { message.textContent = 'Impossibile caricare le Aree.'; return; }
  const { data: memberships, error: membershipsError } = await supabaseClient
    .from('area_memberships').select('role,area_id,areas(id,name,area_type)').eq('profile_id', profile.id);
  if (membershipsError) { message.textContent = 'Impossibile caricare le Aree.'; return; }
  renderAreas(memberships);
}

loadAreas();

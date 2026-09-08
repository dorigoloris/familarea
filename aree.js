const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const areasList = document.getElementById('areas-list');
const headerUserName = document.getElementById('header-user-name');

function roleLabel(role) {
  return ({ admin: 'Amministratore', member: 'Partecipante', managed: 'Profilo gestito' })[role] || role;
}

function renderAreas(memberships) {
  areasList.replaceChildren();
  if (!memberships?.length) {
    message.textContent = 'Non hai ancora nessuna Area.';
    return;
  }
  memberships.forEach((membership) => {
    const area = membership.areas;
    if (!area) return;
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
    areasList.appendChild(card);
  });
  message.textContent = '';
}

async function loadAreas() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }
  const user = sessionData.session.user;
  const name = user.user_metadata?.full_name || user.user_metadata?.name || user.email;
  if (name) {
    headerUserName.textContent = name;
    headerUserName.hidden = false;
  }
  const { data: profile, error: profileError } = await supabaseClient
    .from('profiles')
    .select('id')
    .eq('user_id', user.id)
    .single();
  if (profileError || !profile) {
    message.textContent = 'Impossibile caricare le Aree.';
    return;
  }
  const { data: memberships, error: membershipsError } = await supabaseClient
    .from('area_memberships')
    .select('role,area_id,areas(id,name,area_type)')
    .eq('profile_id', profile.id);
  if (membershipsError) {
    message.textContent = 'Impossibile caricare le Aree.';
    return;
  }
  renderAreas(memberships);
}

loadAreas();

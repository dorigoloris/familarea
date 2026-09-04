const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const areaNameElement = document.getElementById('area-name');
const message = document.getElementById('message');
const membersList = document.getElementById('members-list');
const addMemberLink = document.getElementById('add-member-link');

async function loadArea() {
  const { data: sessionData } = await supabaseClient.auth.getSession();

  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }

  const params = new URLSearchParams(window.location.search);
  const areaId = params.get('area_id');

  if (!areaId) {
    message.textContent = 'Area non specificata.';
    return;
  }

  addMemberLink.href = `aggiungi-membro.html?area_id=${encodeURIComponent(areaId)}`;

  const { data: area, error: areaError } = await supabaseClient
    .from('areas')
    .select('id, name, area_type')
    .eq('id', areaId)
    .single();

  if (areaError) {
    message.textContent = `Errore Area: ${areaError.message}`;
    return;
  }

  areaNameElement.textContent = area.name;

  const { data: memberships, error: membersError } = await supabaseClient
    .from('area_memberships')
    .select(`
      role,
      profile_id,
      profiles (
        first_name,
        last_name
      )
    `)
    .eq('area_id', areaId);

  if (membersError) {
    message.textContent = `Errore membri: ${membersError.message}`;
    return;
  }

  membersList.innerHTML = '';

  memberships.forEach((membership) => {
    const li = document.createElement('li');

    const firstName = membership.profiles?.first_name || '';
    const lastName = membership.profiles?.last_name || '';
    const fullName = `${firstName} ${lastName}`.trim();

    let roleLabel = membership.role;

    if (membership.role === 'admin') {
      roleLabel = 'Amministratore';
    } else if (membership.role === 'member') {
      roleLabel = 'Membro';
    } else if (membership.role === 'managed') {
      roleLabel = 'Profilo gestito';
    }

    li.textContent = `${fullName} — ${roleLabel}`;
    membersList.appendChild(li);
  });

  message.textContent = 'Area caricata correttamente.';
}

loadArea();
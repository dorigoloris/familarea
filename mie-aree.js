const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const message = document.getElementById('message');
const areasList = document.getElementById('areas-list');

async function loadMyAreas() {

  const { data: sessionData } = await supabaseClient.auth.getSession();

  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }

  const userId = sessionData.session.user.id;

  // Recupera il profilo collegato all'utente autenticato
  const { data: profile, error: profileError } = await supabaseClient
    .from('profiles')
    .select('id')
    .eq('user_id', userId)
    .single();

  if (profileError) {
    message.textContent = `Errore profilo: ${profileError.message}`;
    return;
  }

  // Recupera le Aree a cui appartiene il profilo
  const { data: memberships, error: membershipsError } = await supabaseClient
    .from('area_memberships')
    .select(`
      role,
      area_id,
      areas (
        id,
        name,
        area_type
      )
    `)
    .eq('profile_id', profile.id);

  if (membershipsError) {
    message.textContent = `Errore Aree: ${membershipsError.message}`;
    return;
  }

  areasList.innerHTML = '';

  if (!memberships || memberships.length === 0) {
    message.textContent = 'Non hai ancora nessuna Area.';
    return;
  }

  memberships.forEach((membership) => {

    const area = membership.areas;

    if (!area) {
      return;
    }

    const container = document.createElement('div');

    const title = document.createElement('h2');
    title.textContent = area.name;

    const info = document.createElement('p');

    let roleLabel = membership.role;

    if (membership.role === 'admin') {
      roleLabel = 'Amministratore';
    } else if (membership.role === 'member') {
      roleLabel = 'Membro';
    } else if (membership.role === 'managed') {
      roleLabel = 'Profilo gestito';
    }

    info.textContent = `${area.area_type} — ${roleLabel}`;

    const button = document.createElement('button');
    button.textContent = 'Apri Area';

    button.addEventListener('click', () => {
      window.location.href =
        `area.html?area_id=${encodeURIComponent(area.id)}`;
    });

    container.appendChild(title);
    container.appendChild(info);
    container.appendChild(button);

    areasList.appendChild(container);
  });

  message.textContent = '';
}

loadMyAreas();
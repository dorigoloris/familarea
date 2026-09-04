const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const memberNameElement = document.getElementById('member-name');
const message = document.getElementById('message');
const firstNameElement = document.getElementById('member-first-name');
const lastNameElement = document.getElementById('member-last-name');
const birthDateElement = document.getElementById('member-birth-date');
const roleElement = document.getElementById('member-role');
const backToAreaLink = document.getElementById('back-to-area-link');

const viewMode = document.getElementById('view-mode');
const editButton = document.getElementById('edit-button');
const editForm = document.getElementById('edit-form');
const cancelButton = document.getElementById('cancel-button');
const editFirstNameInput = document.getElementById('edit-first-name');
const editLastNameInput = document.getElementById('edit-last-name');
const editBirthDateInput = document.getElementById('edit-birth-date');

let currentAreaId = null;
let currentProfileId = null;
let currentProfile = null;

function renderProfile(profile, roleLabel) {
  const fullName = `${profile.first_name || ''} ${profile.last_name || ''}`.trim();

  memberNameElement.textContent = fullName || 'Scheda membro';
  firstNameElement.textContent = profile.first_name || '';
  lastNameElement.textContent = profile.last_name || '';
  birthDateElement.textContent = profile.birth_date || 'Non indicata';
  roleElement.textContent = roleLabel;
}

function roleToLabel(role) {
  if (role === 'admin') return 'Amministratore';
  if (role === 'member') return 'Membro';
  if (role === 'managed') return 'Profilo gestito';
  return role;
}

function showEditForm() {
  editFirstNameInput.value = currentProfile.first_name || '';
  editLastNameInput.value = currentProfile.last_name || '';
  editBirthDateInput.value = currentProfile.birth_date || '';

  viewMode.hidden = true;
  editForm.hidden = false;
}

function showViewMode() {
  editForm.hidden = true;
  viewMode.hidden = false;
}

async function loadMember() {
  const { data: sessionData } = await supabaseClient.auth.getSession();

  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }

  const userId = sessionData.session.user.id;

  const params = new URLSearchParams(window.location.search);
  const areaId = params.get('area_id');
  const profileId = params.get('profile_id');

  if (!areaId || !profileId) {
    message.textContent = 'Scheda membro non disponibile.';
    return;
  }

  currentAreaId = areaId;
  currentProfileId = profileId;

  backToAreaLink.href = `area.html?area_id=${encodeURIComponent(areaId)}`;

  // la RLS su area_memberships consente di leggere solo le membership della propria Area
  const { data: membership, error: membershipError } = await supabaseClient
    .from('area_memberships')
    .select('role')
    .eq('area_id', areaId)
    .eq('profile_id', profileId)
    .single();

  if (membershipError || !membership) {
    message.textContent = 'Impossibile caricare la scheda membro.';
    return;
  }

  // la RLS su profiles consente di leggere solo i profili delle proprie Aree
  const { data: profile, error: profileError } = await supabaseClient
    .from('profiles')
    .select('first_name, last_name, birth_date')
    .eq('id', profileId)
    .single();

  if (profileError || !profile) {
    message.textContent = 'Impossibile caricare la scheda membro.';
    return;
  }

  currentProfile = profile;
  renderProfile(profile, roleToLabel(membership.role));

  // il pulsante "Modifica" è solo un aiuto di interfaccia: il permesso reale
  // viene verificato lato server dalla RPC update_area_member
  const { data: ownProfile } = await supabaseClient
    .from('profiles')
    .select('id')
    .eq('user_id', userId)
    .single();

  if (ownProfile) {
    const { data: ownMembership } = await supabaseClient
      .from('area_memberships')
      .select('role')
      .eq('area_id', areaId)
      .eq('profile_id', ownProfile.id)
      .single();

    if (ownMembership && ownMembership.role === 'admin') {
      editButton.hidden = false;
    }
  }

  message.textContent = '';
}

editButton.addEventListener('click', () => {
  showEditForm();
});

cancelButton.addEventListener('click', () => {
  showViewMode();
});

editForm.addEventListener('submit', async (event) => {
  event.preventDefault();

  const firstName = editFirstNameInput.value.trim();
  const lastName = editLastNameInput.value.trim();
  const birthDate = editBirthDateInput.value || null;

  message.textContent = 'Salvataggio in corso...';

  const { error } = await supabaseClient.rpc('update_area_member', {
    p_area_id: currentAreaId,
    p_profile_id: currentProfileId,
    p_first_name: firstName,
    p_last_name: lastName,
    p_birth_date: birthDate
  });

  if (error) {
    message.textContent = 'Impossibile salvare le modifiche.';
    return;
  }

  currentProfile = {
    first_name: firstName,
    last_name: lastName,
    birth_date: birthDate
  };

  renderProfile(currentProfile, roleElement.textContent);
  showViewMode();
  message.textContent = 'Dati aggiornati correttamente.';
});

loadMember();

const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const areaNameElement = document.getElementById('area-name');
const message = document.getElementById('message');
const membersList = document.getElementById('members-list');
const addMemberLink = document.getElementById('add-member-link');
const areaInvitesLink = document.getElementById('area-invites-link');
const activitiesSection = document.getElementById('activities-section');
const activitiesMessage = document.getElementById('activities-message');
const activitiesLink = document.getElementById('activities-link');
const eventsLink = document.getElementById('events-link');
const listsSection = document.getElementById('lists-section');
const listsMessage = document.getElementById('lists-message');
const listsLink = document.getElementById('lists-link');

function participantRoleLabel(participant) {
  if (participant.is_personal_contact_participant) return 'Partecipante';
  return ({ admin: 'Amministratore', member: 'Partecipante', managed: 'Profilo gestito' })[participant.role] || participant.role;
}

async function loadActivities(areaId) {
  activitiesSection.hidden = false;
  activitiesMessage.textContent = 'Caricamento riepilogo attività...';
  const { data, error } = await supabaseClient.rpc('get_area_activities', { p_area_id: areaId, p_status: 'open' });
  if (error) {
    activitiesMessage.textContent = 'Impossibile caricare il riepilogo delle attività.';
    return;
  }
  const count = data?.length || 0;
  activitiesMessage.textContent = count === 0
    ? 'Nessuna attività aperta.'
    : `${count} attività apert${count === 1 ? 'a' : 'e'}.`;
}

async function loadLists(areaId) {
  listsSection.hidden = false;
  listsMessage.textContent = 'Caricamento liste...';
  const { data, error } = await supabaseClient.rpc('get_area_lists', { p_area_id: areaId });
  if (error) {
    listsMessage.textContent = 'Impossibile caricare il riepilogo delle liste.';
    return;
  }
  const count = data?.length || 0;
  listsMessage.textContent = count === 0
    ? 'Nessuna lista.'
    : `${count} list${count === 1 ? 'a' : 'e'}.`;
}

function renderMembers(participants, areaId) {
  membersList.replaceChildren();
  participants.forEach((participant) => {
    const item = document.createElement('li');
    const info = document.createElement('span');
    const open = document.createElement('a');
    const name = `${participant.first_name || ''} ${participant.last_name || ''}`.trim() || 'Partecipante dell’Area';
    item.className = 'member-list-item';
    info.textContent = `${name} — ${participantRoleLabel(participant)}`;
    open.className = 'btn member-open-link';
    open.textContent = 'Apri';
    open.href = `membro.html?area_id=${encodeURIComponent(areaId)}&profile_id=${encodeURIComponent(participant.profile_id)}`;
    item.append(info, open);
    membersList.appendChild(item);
  });
}

async function loadArea() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }

  const areaId = new URLSearchParams(window.location.search).get('area_id');
  if (!areaId) {
    message.textContent = 'Area non specificata.';
    return;
  }

  addMemberLink.href = `inviti-area.html?area_id=${encodeURIComponent(areaId)}`;
  areaInvitesLink.href = `inviti-area.html?area_id=${encodeURIComponent(areaId)}`;
  activitiesLink.href = `attivita-area.html?area_id=${encodeURIComponent(areaId)}`;
  eventsLink.href = `eventi.html?area_id=${encodeURIComponent(areaId)}`;
  listsLink.href = `liste.html?area_id=${encodeURIComponent(areaId)}`;

  const { data: area, error: areaError } = await supabaseClient
    .from('areas')
    .select('id,name,area_type')
    .eq('id', areaId)
    .single();
  if (areaError || !area) {
    message.textContent = 'Impossibile caricare l’Area.';
    return;
  }
  areaNameElement.textContent = area.name;

  const { data: participants, error: participantsError } = await supabaseClient.rpc('get_area_participants', {
    p_area_id: areaId
  });
  if (participantsError || !participants) {
    message.textContent = 'Impossibile caricare i partecipanti.';
    return;
  }

  renderMembers(participants, areaId);
  const { data: ownProfile } = await supabaseClient
    .from('profiles')
    .select('id')
    .eq('user_id', sessionData.session.user.id)
    .single();
  const ownParticipant = participants.find((participant) => participant.profile_id === ownProfile?.id);
  const isAreaAdmin = ownParticipant?.role === 'admin';
  addMemberLink.hidden = !isAreaAdmin;
  areaInvitesLink.hidden = !isAreaAdmin;
  message.textContent = 'Area caricata correttamente.';
  await loadActivities(areaId);
  await loadLists(areaId);
}

loadArea();

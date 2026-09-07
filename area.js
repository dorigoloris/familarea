const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const areaNameElement = document.getElementById('area-name');
const message = document.getElementById('message');
const membersList = document.getElementById('members-list');
const addMemberLink = document.getElementById('add-member-link');
const activitiesSection = document.getElementById('activities-section');
const activitiesMessage = document.getElementById('activities-message');
const activitiesList = document.getElementById('activities-list');
const newActivityLink = document.getElementById('new-activity-link');
const eventsLink = document.getElementById('events-link');
const newEventLink = document.getElementById('new-event-link');
const listsSection = document.getElementById('lists-section');
const listsMessage = document.getElementById('lists-message');
const listsPreview = document.getElementById('lists-preview');
const listsLink = document.getElementById('lists-link');
const newListLink = document.getElementById('new-list-link');

const typeLabel = (value) => ({ task: 'Da fare', reminder: 'Promemoria', deadline: 'Scadenza', appointment: 'Appuntamento' })[value] || 'Attività';
const priorityLabel = (value) => ({ low: 'Bassa', normal: 'Normale', high: 'Alta' })[value] || 'Normale';
const statusLabel = (value) => ({ open: 'Aperta', completed: 'Completata', cancelled: 'Annullata' })[value] || 'Aperta';
const formatDateTime = (value) => value ? new Date(value).toLocaleString('it-IT') : 'Nessuna scadenza';

function participantRoleLabel(participant) {
  if (participant.is_personal_contact_participant) return 'Partecipante';
  return ({ admin: 'Amministratore', member: 'Partecipante', managed: 'Profilo gestito' })[participant.role] || participant.role;
}

async function loadActivities(areaId) {
  activitiesSection.hidden = false;
  activitiesMessage.textContent = 'Caricamento attività...';
  const { data, error } = await supabaseClient.rpc('get_area_activities', { p_area_id: areaId, p_status: 'open' });
  if (error) {
    activitiesMessage.textContent = 'Impossibile caricare le attività.';
    return;
  }

  activitiesList.replaceChildren();
  if (!data?.length) {
    const item = document.createElement('li');
    item.textContent = 'Nessuna attività visibile aperta.';
    activitiesList.appendChild(item);
  } else {
    data.forEach((activity) => {
      const item = document.createElement('li');
      const title = document.createElement('strong');
      const metadata = document.createElement('div');
      const due = document.createElement('div');
      const open = document.createElement('a');
      item.className = 'activity-card';
      title.className = 'activity-card-title';
      title.textContent = activity.title;
      metadata.className = 'activity-card-meta';
      [
        ['activity-type-badge', typeLabel(activity.activity_type)],
        [`activity-priority-badge activity-priority-${activity.priority}`, priorityLabel(activity.priority)],
        ['activity-status-badge', statusLabel(activity.status)]
      ].forEach(([className, text]) => {
        const badge = document.createElement('span');
        badge.className = className;
        badge.textContent = text;
        metadata.appendChild(badge);
      });
      due.className = 'activity-card-due';
      due.textContent = `Scadenza: ${formatDateTime(activity.due_at)}`;
      open.className = 'btn';
      open.textContent = 'Apri';
      open.href = `attivita.html?area_id=${encodeURIComponent(areaId)}&activity_id=${encodeURIComponent(activity.id)}`;
      item.append(title, metadata, due, open);
      activitiesList.appendChild(item);
    });
  }
  activitiesMessage.textContent = '';
}

async function loadLists(areaId) {
  listsSection.hidden = false;
  listsMessage.textContent = 'Caricamento liste...';
  const { data, error } = await supabaseClient.rpc('get_area_lists', { p_area_id: areaId });
  if (error) {
    listsMessage.textContent = 'Impossibile caricare le liste visibili.';
    return;
  }
  listsPreview.replaceChildren();
  if (!data?.length) {
    const item = document.createElement('li');
    item.textContent = 'Nessuna lista visibile in questa Area.';
    listsPreview.appendChild(item);
  } else {
    data.slice(0, 3).forEach((list) => {
      const item = document.createElement('li');
      const title = document.createElement('strong');
      const open = document.createElement('a');
      title.textContent = list.title;
      open.className = 'btn member-open-link';
      open.textContent = 'Apri';
      open.href = `lista.html?area_id=${encodeURIComponent(areaId)}&list_id=${encodeURIComponent(list.id)}`;
      item.className = 'member-list-item';
      item.append(title, open);
      listsPreview.appendChild(item);
    });
  }
  listsMessage.textContent = '';
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

  addMemberLink.href = `aggiungi-membro.html?area_id=${encodeURIComponent(areaId)}`;
  newActivityLink.href = `nuova-attivita.html?area_id=${encodeURIComponent(areaId)}`;
  eventsLink.href = `eventi.html?area_id=${encodeURIComponent(areaId)}`;
  if (newEventLink) {
    newEventLink.href = `nuovo-evento.html?area_id=${encodeURIComponent(areaId)}`;
  }
  listsLink.href = `liste.html?area_id=${encodeURIComponent(areaId)}`;
  newListLink.href = `nuova-lista.html?area_id=${encodeURIComponent(areaId)}`;

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
  message.textContent = 'Area caricata correttamente.';
  await loadActivities(areaId);
  await loadLists(areaId);
}

loadArea();

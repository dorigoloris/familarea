const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const areaNameElement = document.getElementById('area-name');
const areaTypeLabel = document.getElementById('area-type-label');
const areaIllustration = document.getElementById('area-illustration');
const areaRoleBadge = document.getElementById('area-role-badge');
const message = document.getElementById('message');
const membersList = document.getElementById('members-list');
const participantsCount = document.getElementById('participants-count');
const membersToggle = document.getElementById('members-toggle');
const areaManageMenu = document.getElementById('area-manage-menu');
const areaManageTrigger = document.getElementById('area-manage-trigger');
const areaManageModal = document.getElementById('area-manage-modal');
const areaManageDialog = document.getElementById('area-manage-dialog');
const areaManageClose = document.getElementById('area-manage-close');
const areaManageActions = document.getElementById('area-manage-actions');
const addMemberLink = document.getElementById('add-member-link');
const areaInvitesLink = document.getElementById('area-invites-link');
const activitiesSection = document.getElementById('activities-section');
const activitiesMessage = document.getElementById('activities-message');
const activitiesCount = document.getElementById('activities-count');
const activitiesPreview = document.getElementById('activities-preview');
const activitiesLink = document.getElementById('activities-link');
const eventsSection = document.getElementById('events-section');
const eventsMessage = document.getElementById('events-message');
const eventsCount = document.getElementById('events-count');
const eventsPreview = document.getElementById('events-preview');
const eventsLink = document.getElementById('events-link');
const listsSection = document.getElementById('lists-section');
const listsMessage = document.getElementById('lists-message');
const listsCount = document.getElementById('lists-count');
const listsPreview = document.getElementById('lists-preview');
const listsLink = document.getElementById('lists-link');

const areaTypeLabels = {
  family: 'Famiglia',
  school: 'Scuola',
  sport: 'Sport',
  friends: 'Amici',
  course: 'Corso',
  travel: 'Viaggio',
  other: 'Area'
};

const svgNamespace = 'http://www.w3.org/2000/svg';

function closeAreaManageMenu(returnFocus = false) {
  if (!areaManageModal || !areaManageTrigger) return;
  areaManageModal.hidden = true;
  areaManageTrigger.setAttribute('aria-expanded', 'false');
  document.body.classList.remove('area-manage-modal-open');
  if (returnFocus) areaManageTrigger.focus();
}

function openAreaManageModal() {
  if (!areaManageModal || !areaManageTrigger) return;
  areaManageModal.hidden = false;
  areaManageTrigger.setAttribute('aria-expanded', 'true');
  document.body.classList.add('area-manage-modal-open');
  requestAnimationFrame(() => areaManageActions?.querySelector('a:not([hidden])')?.focus());
}

if (areaManageMenu && areaManageTrigger && areaManageModal && areaManageDialog) {
  areaManageTrigger.addEventListener('click', openAreaManageModal);
  areaManageClose?.addEventListener('click', () => closeAreaManageMenu(true));
  areaManageModal.addEventListener('pointerdown', (event) => {
    if (event.target === areaManageModal) closeAreaManageMenu(true);
  });
  areaManageActions?.addEventListener('click', () => closeAreaManageMenu());
  document.addEventListener('keydown', (event) => {
    if (areaManageModal.hidden) return;
    if (event.key === 'Escape') {
      event.preventDefault();
      closeAreaManageMenu(true);
    }
    if (event.key !== 'Tab') return;
    const focusable = [...areaManageDialog.querySelectorAll('button:not([disabled]), a[href]:not([hidden])')];
    const first = focusable[0];
    const last = focusable.at(-1);
    if (!first || !last) return;
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  });
}

function svgElement(name, attributes = {}) {
  const element = document.createElementNS(svgNamespace, name);
  Object.entries(attributes).forEach(([attribute, value]) => element.setAttribute(attribute, value));
  return element;
}

function renderAreaIllustration(areaType) {
  if (!areaIllustration) return;
  const svg = svgElement('svg', {
    viewBox: '0 0 220 150',
    focusable: 'false',
    'aria-hidden': 'true'
  });

  svg.append(
    svgElement('rect', { x: '5', y: '5', width: '210', height: '140', rx: '30', fill: '#e9f4f6' }),
    svgElement('circle', { cx: '177', cy: '38', r: '23', fill: '#c9e5ce' }),
    svgElement('path', { d: 'M16 118c32-25 62-15 87-29 31-18 61-11 102 12v34H16Z', fill: '#d8ecdc' })
  );

  const stroke = { fill: 'none', stroke: '#0d2b4f', 'stroke-width': '4', 'stroke-linecap': 'round', 'stroke-linejoin': 'round' };
  const greenStroke = { ...stroke, stroke: '#4d8b4f' };

  if (areaType === 'family') {
    svg.append(
      svgElement('path', { d: 'M62 111V76l48-37 48 37v35', fill: '#ffffff', stroke: '#0d2b4f', 'stroke-width': '4', 'stroke-linejoin': 'round' }),
      svgElement('path', { d: 'M54 78 110 33l56 45', ...greenStroke }),
      svgElement('path', { d: 'M98 111V88h24v23M78 82h10M132 82h10', ...greenStroke }),
      svgElement('path', { d: 'M40 112V87M31 97l9-17 9 17M180 112V86M170 98l10-19 10 19', ...greenStroke })
    );
  } else if (areaType === 'school' || areaType === 'course') {
    svg.append(
      svgElement('path', { d: 'M57 111V57h106v54M48 57h124M79 57V42h62v15M78 78h10M105 78h10M132 78h10M105 111V92h18v19', ...stroke }),
      svgElement('path', { d: 'M48 57h124', ...greenStroke })
    );
  } else if (areaType === 'sport') {
    svg.append(
      svgElement('rect', { x: '56', y: '47', width: '108', height: '70', rx: '9', fill: '#ffffff', stroke: '#0d2b4f', 'stroke-width': '4' }),
      svgElement('circle', { cx: '110', cy: '82', r: '18', ...greenStroke }),
      svgElement('path', { d: 'M56 82h108M110 47v70M71 65h13v34M149 65h-13v34', ...greenStroke })
    );
  } else if (areaType === 'friends') {
    svg.append(
      svgElement('circle', { cx: '88', cy: '67', r: '17', fill: '#ffffff', stroke: '#0d2b4f', 'stroke-width': '4' }),
      svgElement('circle', { cx: '132', cy: '67', r: '17', fill: '#ffffff', stroke: '#0d2b4f', 'stroke-width': '4' }),
      svgElement('path', { d: 'M57 112c4-20 17-30 31-30s27 10 31 30M101 112c4-20 17-30 31-30s27 10 31 30', ...greenStroke })
    );
  } else if (areaType === 'travel') {
    svg.append(
      svgElement('rect', { x: '72', y: '51', width: '76', height: '65', rx: '9', fill: '#ffffff', stroke: '#0d2b4f', 'stroke-width': '4' }),
      svgElement('path', { d: 'M94 51V42h32v9M72 76h76M110 51v65M84 91h8M128 91h8', ...greenStroke })
    );
  } else {
    svg.append(
      svgElement('path', { d: 'M66 112V59h88v53M55 59l55-30 55 30M94 112V85h32v27', ...stroke }),
      svgElement('path', { d: 'M76 73h13M131 73h13', ...greenStroke })
    );
  }

  areaIllustration.replaceChildren(svg);
}

function participantRoleLabel(participant) {
  if (participant.is_personal_contact_participant) return 'Partecipante';
  return ({ admin: 'Amministratore', member: 'Partecipante', managed: 'Partecipante' })[participant.role] || 'Partecipante';
}

function formatCount(count, singular, plural) {
  return `${count} ${count === 1 ? singular : plural}`;
}

function formatActivityDue(activity) {
  if (!activity.due_at) return activity.priority === 'high' ? 'Priorità alta' : '';
  const options = activity.is_all_day
    ? { day: 'numeric', month: 'short' }
    : { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' };
  const date = new Intl.DateTimeFormat('it-IT', options).format(new Date(activity.due_at));
  return activity.priority === 'high' ? `Scadenza ${date} · Priorità alta` : `Scadenza ${date}`;
}

function formatEventWhen(event) {
  const date = new Date(event.starts_at);
  const options = event.is_all_day
    ? { weekday: 'short', day: 'numeric', month: 'short' }
    : { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' };
  return new Intl.DateTimeFormat('it-IT', options).format(date);
}

function initials(firstName, lastName) {
  return [firstName, lastName]
    .map((value) => (value || '').trim().charAt(0))
    .filter(Boolean)
    .join('')
    .slice(0, 2)
    .toLocaleUpperCase('it-IT') || 'P';
}

function createCompactRow({ title, metadata, href }) {
  const row = document.createElement('a');
  row.className = 'area-compact-row';
  row.href = href;
  row.setAttribute('aria-label', `${title}: apri dettaglio`);

  const content = document.createElement('span');
  content.className = 'area-compact-row-content';
  const titleElement = document.createElement('strong');
  titleElement.textContent = title;
  content.appendChild(titleElement);

  if (metadata) {
    const metadataElement = document.createElement('span');
    metadataElement.className = 'area-compact-row-meta';
    metadataElement.textContent = metadata;
    content.appendChild(metadataElement);
  }

  const indicator = document.createElement('span');
  indicator.className = 'area-row-indicator';
  indicator.setAttribute('aria-hidden', 'true');
  indicator.textContent = '→';
  row.append(content, indicator);
  return row;
}

function renderEmptyState(target, title, description) {
  target.replaceChildren();
  const titleElement = document.createElement('strong');
  titleElement.className = 'area-empty-state-title';
  titleElement.textContent = title;
  const descriptionElement = document.createElement('span');
  descriptionElement.className = 'area-empty-state-description';
  descriptionElement.textContent = description;
  target.append(titleElement, descriptionElement);
}

async function loadActivities(areaId) {
  activitiesSection.hidden = false;
  activitiesMessage.textContent = 'Caricamento attività...';
  activitiesPreview.replaceChildren();

  const { data, error } = await supabaseClient.rpc('get_area_activities', {
    p_area_id: areaId,
    p_status: 'open'
  });
  if (error) {
    activitiesMessage.textContent = 'Impossibile caricare le attività.';
    return;
  }

  const activities = data || [];
  activitiesCount.textContent = String(activities.length);
  if (!activities.length) {
    renderEmptyState(
      activitiesMessage,
      'Nessuna attività aperta.',
      'Organizza le cose da fare e tieni tutto sotto controllo.'
    );
    return;
  }

  activitiesMessage.textContent = formatCount(activities.length, 'attività aperta', 'attività aperte');
  activities
    .slice()
    .sort((first, second) => {
      const firstDue = first.due_at ? new Date(first.due_at).getTime() : Number.MAX_SAFE_INTEGER;
      const secondDue = second.due_at ? new Date(second.due_at).getTime() : Number.MAX_SAFE_INTEGER;
      return firstDue - secondDue;
    })
    .slice(0, 2)
    .forEach((activity) => activitiesPreview.appendChild(createCompactRow({
      title: activity.title,
      metadata: formatActivityDue(activity),
      href: `attivita.html?area_id=${encodeURIComponent(areaId)}&activity_id=${encodeURIComponent(activity.id)}`
    })));
}

async function loadEvents(areaId) {
  eventsSection.hidden = false;
  eventsMessage.textContent = 'Caricamento eventi...';
  eventsPreview.replaceChildren();

  const { data, error } = await supabaseClient.rpc('get_area_events', { p_area_id: areaId });
  if (error) {
    eventsMessage.textContent = 'Impossibile caricare gli eventi.';
    return;
  }

  const now = Date.now();
  const events = (data || [])
    .filter((event) => event.status !== 'cancelled' && new Date(event.starts_at).getTime() >= now)
    .sort((first, second) => new Date(first.starts_at).getTime() - new Date(second.starts_at).getTime());
  eventsCount.textContent = String(events.length);
  if (!events.length) {
    renderEmptyState(
      eventsMessage,
      'Nessun evento in programma.',
      'Crea un evento per coinvolgere i partecipanti.'
    );
    return;
  }

  eventsMessage.textContent = formatCount(events.length, 'evento in programma', 'eventi in programma');
  events.slice(0, 2).forEach((event) => {
    const details = [formatEventWhen(event), event.location].filter(Boolean).join(' · ');
    eventsPreview.appendChild(createCompactRow({
      title: event.title,
      metadata: details,
      href: `evento.html?area_id=${encodeURIComponent(areaId)}&event_id=${encodeURIComponent(event.id)}`
    }));
  });
}

async function loadLists(areaId) {
  listsSection.hidden = false;
  listsMessage.textContent = 'Caricamento liste...';
  listsPreview.replaceChildren();

  const { data, error } = await supabaseClient.rpc('get_area_lists', { p_area_id: areaId });
  if (error) {
    listsMessage.textContent = 'Impossibile caricare le liste.';
    return;
  }

  const lists = data || [];
  listsCount.textContent = String(lists.length);
  if (!lists.length) {
    renderEmptyState(
      listsMessage,
      'Nessuna lista visibile.',
      'Crea una lista per collaborare con i partecipanti.'
    );
    return;
  }

  listsMessage.textContent = formatCount(lists.length, 'lista visibile', 'liste visibili');
  lists.slice(0, 2).forEach((list) => listsPreview.appendChild(createCompactRow({
    title: list.title,
    metadata: list.description || '',
    href: `lista.html?area_id=${encodeURIComponent(areaId)}&list_id=${encodeURIComponent(list.id)}`
  })));
}

function renderMembers(participants, areaId, showAll = false) {
  membersList.replaceChildren();
  const visibleParticipants = showAll ? participants : participants.slice(0, 4);

  visibleParticipants.forEach((participant) => {
    const item = document.createElement('li');
    item.className = 'area-participant-row';

    const avatar = document.createElement('span');
    avatar.className = 'area-participant-initials';
    avatar.setAttribute('aria-hidden', 'true');
    avatar.textContent = initials(participant.first_name, participant.last_name);

    const info = document.createElement('span');
    info.className = 'area-participant-info';
    const nameElement = document.createElement('strong');
    const role = document.createElement('span');
    const name = `${participant.first_name || ''} ${participant.last_name || ''}`.trim() || 'Partecipante dell’Area';
    nameElement.textContent = name;
    role.className = 'area-participant-role';
    role.textContent = participantRoleLabel(participant);
    info.append(nameElement, role);

    const open = document.createElement('a');
    open.className = 'area-participant-open';
    open.textContent = 'Apri';
    open.href = `membro.html?area_id=${encodeURIComponent(areaId)}&profile_id=${encodeURIComponent(participant.profile_id)}`;

    item.append(avatar, info, open);
    membersList.appendChild(item);
  });

  const hasMore = participants.length > 4;
  membersToggle.hidden = !hasMore;
  membersToggle.textContent = showAll ? 'Mostra meno partecipanti' : `Mostra tutti i ${participants.length} partecipanti`;
  membersToggle.setAttribute('aria-expanded', String(showAll));
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
  areaTypeLabel.textContent = areaTypeLabels[area.area_type] || 'Area';
  renderAreaIllustration(area.area_type);

  const { data: participants, error: participantsError } = await supabaseClient.rpc('get_area_participants', {
    p_area_id: areaId
  });
  if (participantsError || !participants) {
    message.textContent = 'Impossibile caricare i partecipanti.';
    return;
  }

  const { data: ownProfile } = await supabaseClient
    .from('profiles')
    .select('id')
    .eq('user_id', sessionData.session.user.id)
    .single();
  const ownParticipant = participants.find((participant) => participant.profile_id === ownProfile?.id);
  const isAreaAdmin = ownParticipant?.role === 'admin';
  areaRoleBadge.textContent = isAreaAdmin ? 'Amministratore' : 'Partecipante';
  areaRoleBadge.hidden = !ownParticipant;
  participantsCount.textContent = String(participants.length);

  let showingAllParticipants = false;
  renderMembers(participants, areaId, showingAllParticipants);
  membersToggle.onclick = () => {
    showingAllParticipants = !showingAllParticipants;
    renderMembers(participants, areaId, showingAllParticipants);
  };

  areaManageMenu.hidden = !isAreaAdmin;
  addMemberLink.hidden = !isAreaAdmin;
  areaInvitesLink.hidden = !isAreaAdmin;
  message.textContent = '';
  await Promise.all([loadActivities(areaId), loadEvents(areaId), loadLists(areaId)]);
}

loadArea();

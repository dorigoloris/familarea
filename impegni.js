const commitmentsClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const commitmentsMessage = document.getElementById('commitments-message');
const commitmentsList = document.getElementById('commitments-list');
const commitmentsEmpty = document.getElementById('commitments-empty');

function formatDate(value) {
  if (!value) return 'Data non indicata';
  const date = /^\d{4}-\d{2}-\d{2}$/.test(value)
    ? new Date(...value.split('-').map((part, index) => index === 1 ? Number(part) - 1 : Number(part)))
    : new Date(value);
  return Number.isNaN(date.getTime()) ? 'Data non indicata' : date.toLocaleDateString('it-IT');
}

function localDateKey(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

function addLocalDays(dateValue, days) {
  const [year, month, day] = dateValue.split('-').map(Number);
  const date = new Date(year, month - 1, day);
  date.setDate(date.getDate() + days);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

function formatEventWhen(event) {
  const start = new Date(event.starts_at);
  const date = start.toLocaleDateString('it-IT');
  const startDate = localDateKey(event.starts_at);
  const endDate = event.ends_at ? localDateKey(event.ends_at) : '';
  if (event.ends_at && startDate !== endDate) {
    const displayEnd = event.is_all_day ? addLocalDays(endDate, -1) : endDate;
    return `${date} → ${formatDate(displayEnd)}`;
  }
  if (event.is_all_day) return date;
  const startTime = start.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' });
  const endTime = event.ends_at
    ? ` – ${new Date(event.ends_at).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' })}`
    : '';
  return `${date}, ${startTime}${endTime}`;
}

function eventIdOf(event) {
  return event.id || event.event_id;
}

function eventHref(event) {
  const query = new URLSearchParams({ event_id: eventIdOf(event) });
  return `evento.html?${query}`;
}

function statusLabel(status) {
  return ({ active: 'Attivo', cancelled: 'Annullato' })[status] || status;
}

function createCommitmentRow({ title, when, type, status, href, label }) {
  const row = document.createElement('a');
  row.className = 'fa-v2-list-row fa-v2-list-row--media';
  row.href = href;
  row.setAttribute('aria-label', label);

  const visual = document.createElement('span');
  visual.setAttribute('aria-hidden', 'true');
  visual.textContent = (title || '').trim().charAt(0).toLocaleUpperCase('it-IT') || 'I';
  const copy = document.createElement('div');
  copy.className = 'fa-v2-card-content';
  const heading = document.createElement('h3');
  heading.className = 'fa-v2-card-title';
  heading.textContent = title;
  const date = document.createElement('p');
  date.className = 'fa-v2-card-description';
  date.textContent = when;
  copy.append(heading, date);

  const controls = document.createElement('div');
  controls.className = 'fa-v2-card-actions';
  const typeBadge = document.createElement('span');
  typeBadge.className = 'fa-v2-badge';
  typeBadge.textContent = type;
  controls.appendChild(typeBadge);
  if (status && status !== 'active') {
    const stateBadge = document.createElement('span');
    stateBadge.className = 'fa-v2-badge';
    stateBadge.textContent = statusLabel(status);
    controls.appendChild(stateBadge);
  }

  const action = document.createElement('span');
  action.className = 'fa-v2-button fa-v2-button--secondary';
  action.textContent = 'Apri';
  controls.appendChild(action);
  row.append(visual, copy, controls);
  return row;
}

function standaloneDeadlineCard(deadline) {
  return createCommitmentRow({
    title: deadline.title,
    when: formatDate(deadline.first_due_on),
    type: 'Impegno',
    status: deadline.status,
    href: `nuova-scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}`,
    label: `Apri impegno da ricordare ${deadline.title}`
  });
}

function commitmentEventCard(event) {
  return createCommitmentRow({
    title: event.title,
    when: formatEventWhen(event),
    type: 'Impegno',
    status: event.status,
    href: eventHref(event),
    label: `Apri impegno ${event.title}`
  });
}

function eventCard(event) {
  return createCommitmentRow({
    title: event.title,
    when: formatEventWhen(event),
    type: 'Evento',
    status: event.status,
    href: eventHref(event),
    label: `Apri evento ${event.title}`
  });
}

function sortByWhen(first, second) {
  return new Date(first.when) - new Date(second.when);
}

async function loadCommitments() {
  const { data: sessionData } = await commitmentsClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }

  const [deadlinesResult, eventsResult] = await Promise.all([
    commitmentsClient.rpc('get_my_deadlines'),
    commitmentsClient.rpc('get_visible_events')
  ]);
  if (deadlinesResult.error || eventsResult.error) {
    commitmentsMessage.textContent = 'Impossibile caricare gli impegni.';
    return;
  }

  // Le deadline storiche restano visibili finché non verranno trattate separatamente.
  // Nuovi Impegni sono invece sempre eventi con event_kind = commitment.
  const standaloneDeadlines = (deadlinesResult.data || []).filter((deadline) => (
    !deadline.deadline_item_id
    && !deadline.family_member_id
    && deadline.category !== 'personal_document'
  ));
  const visibleEvents = [...new Map((eventsResult.data || [])
    .map((event) => [eventIdOf(event), event]))
    .values()];
  const commitmentEvents = visibleEvents.filter((event) => event.event_kind === 'commitment');
  const participantEvents = visibleEvents.filter((event) => (
    event.event_kind !== 'commitment'
    && ['owner', 'creator', 'participant'].includes(event.visibility_source)
  ));
  const commitments = [
    ...standaloneDeadlines.map((deadline) => ({ when: `${deadline.first_due_on}T00:00:00`, card: standaloneDeadlineCard(deadline) })),
    ...commitmentEvents.map((event) => ({ when: event.starts_at, card: commitmentEventCard(event) })),
    ...participantEvents.map((event) => ({ when: event.starts_at, card: eventCard(event) }))
  ].sort(sortByWhen);

  commitmentsList.replaceChildren(...commitments.map((commitment) => commitment.card));
  commitmentsEmpty.hidden = commitments.length > 0;
  commitmentsMessage.textContent = '';
}

void loadCommitments();

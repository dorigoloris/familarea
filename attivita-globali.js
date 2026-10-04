const activitiesClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const activitiesMessage = document.getElementById('message');
const coursesList = document.getElementById('courses-list');
const coursesEmpty = document.getElementById('courses-empty');
const appointmentsList = document.getElementById('appointments-list');
const appointmentsEmpty = document.getElementById('appointments-empty');

function initials(value, fallback) {
  return (value || '').trim().charAt(0).toLocaleUpperCase('it-IT') || fallback;
}

function formatWhen(event) {
  if (!event.starts_at) return 'Data non indicata';
  const start = new Date(event.starts_at);
  const date = start.toLocaleDateString('it-IT');
  if (event.is_all_day ?? event.all_day) return `${date} · Tutto il giorno`;
  const time = start.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' });
  const end = event.ends_at
    ? ` – ${new Date(event.ends_at).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' })}`
    : '';
  return `${date}, ${time}${end}`;
}

function eventHref(event) {
  const query = new URLSearchParams({ event_id: event.id || event.event_id });
  if (event.area_id) query.set('area_id', event.area_id);
  return `evento.html?${query}`;
}

function recurrenceLabel(event) {
  const labels = {
    daily: ['Ogni giorno', 'giorni'],
    weekly: ['Ogni settimana', 'settimane'],
    monthly: ['Ogni mese', 'mesi'],
    yearly: ['Ogni anno', 'anni']
  };
  const [base, unit] = labels[event.recurrence_frequency] || ['Ricorrente', 'intervalli'];
  return event.recurrence_interval > 1 ? `Ogni ${event.recurrence_interval} ${unit}` : base;
}

function isActivityEvent(event) {
  if (event.event_kind === 'activity') return true;
  if (event.event_kind === 'commitment') return false;
  return Boolean(event.recurrence_frequency);
}

function provenanceLabel(event, occurrence) {
  if (event.organization_name) return event.organization_name;
  if (occurrence?.area_name) return occurrence.area_name;
  if (event.area_name) return event.area_name;
  if (event.visibility_source === 'participant') return 'Partecipi';
  if (event.visibility_source === 'owner') return 'Organizzato da te';
  if (event.visibility_source === 'creator') return 'Creato da te';
  return '';
}

function activityHierarchyLabel(event, occurrence) {
  const organization = event.organizer_name;
  const group = occurrence?.area_name || event.area_name;
  return [organization, group].filter((value, index, values) => value && values.indexOf(value) === index).join(' · ');
}

function createSummaryCard({ title, details, href, fallback, label }) {
  const card = document.createElement('a');
  card.className = 'deadline-item-summary-card fa-v2-deadline-card fa-v2-deadline-card--interactive fa-v2-list-row';
  card.href = href;
  card.setAttribute('aria-label', label);

  const image = document.createElement('span');
  image.className = 'deadline-management-item-image deadline-item-summary-image';
  image.setAttribute('aria-hidden', 'true');
  image.textContent = initials(title, fallback);

  const heading = document.createElement('h3');
  heading.className = 'deadline-item-summary-name';
  heading.textContent = title;
  const metadata = document.createElement('span');
  metadata.className = 'deadline-item-summary-plate';
  if (typeof details === 'string') metadata.textContent = details;
  else if (details) metadata.append(details);
  const action = document.createElement('span');
  action.className = 'fa-button fa-button-secondary fa-button-compact deadline-item-summary-action';
  action.textContent = 'Apri';
  card.append(image, heading, metadata, action);
  return card;
}

function activityDetails(event, occurrence) {
  const details = document.createElement('span');
  details.className = 'deadline-item-summary-details';
  const hierarchy = activityHierarchyLabel(event, occurrence);
  const nextDate = occurrence ? `Prossima data: ${formatWhen(occurrence)}` : 'Prossima data non disponibile';
  const recurrence = recurrenceLabel(event);

  [hierarchy, nextDate, recurrence ? `Ricorrenza: ${recurrence}` : ''].filter(Boolean).forEach((value, index) => {
    const line = document.createElement('span');
    line.className = index === 1
      ? 'deadline-item-summary-meta deadline-item-summary-meta--schedule'
      : 'deadline-item-summary-meta';
    line.textContent = value;
    details.append(line);
  });
  return details;
}

function activityCard(event, occurrence) {
  return createSummaryCard({
    title: event.title,
    details: activityDetails(event, occurrence),
    href: eventHref(event),
    fallback: 'A',
    label: `Apri attività ${event.title}`
  });
}

function appointmentCard(occurrence, event) {
  const item = document.createElement('a');
  const title = occurrence.title || event.title;
  item.className = 'deadline-card deadline-card--with-item-thumbnail';
  item.href = eventHref(event);
  item.setAttribute('aria-label', `Apri appuntamento ${title}`);
  const thumbnail = document.createElement('span');
  thumbnail.className = 'deadline-item-thumbnail';
  thumbnail.setAttribute('aria-hidden', 'true');
  thumbnail.textContent = initials(title, 'A');
  const copy = document.createElement('span');
  copy.className = 'deadline-card-item-copy';
  copy.textContent = `${formatWhen(occurrence)} — ${title}`;
  item.append(thumbnail, copy);
  return item;
}

function futureWindow() {
  const from = new Date();
  const to = new Date(from);
  to.setFullYear(to.getFullYear() + 1);
  return { from, to };
}

async function loadActivities() {
  const { data: sessionData } = await activitiesClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }

  const { from, to } = futureWindow();
  const [eventsResult, occurrencesResult] = await Promise.all([
    activitiesClient.rpc('get_visible_events'),
    activitiesClient.rpc('get_calendar_occurrences', { p_from: from.toISOString(), p_to: to.toISOString() })
  ]);
  if (eventsResult.error) {
    activitiesMessage.textContent = 'Impossibile caricare le attività.';
    return;
  }

  const visibleEvents = eventsResult.data || [];
  const eventsById = new Map(visibleEvents.map((event) => [event.id || event.event_id, event]));
  const activities = visibleEvents.filter(isActivityEvent);
  const activityEventIds = new Set(activities.map((event) => event.id || event.event_id));
  const occurrences = occurrencesResult.error ? [] : (occurrencesResult.data || [])
    .filter((occurrence) => occurrence.kind === 'event' && activityEventIds.has(occurrence.event_id || occurrence.id))
    .sort((first, second) => new Date(first.starts_at) - new Date(second.starts_at));
  const nextOccurrenceByEventId = new Map();
  occurrences.forEach((occurrence) => {
    const eventId = occurrence.event_id || occurrence.id;
    if (!nextOccurrenceByEventId.has(eventId)) nextOccurrenceByEventId.set(eventId, occurrence);
  });
  coursesList.replaceChildren(...activities.map((event) => activityCard(event, nextOccurrenceByEventId.get(event.id || event.event_id))));
  coursesEmpty.hidden = activities.length > 0;
  appointmentsList.replaceChildren(...occurrences.slice(0, 5).map((occurrence) => appointmentCard(occurrence, eventsById.get(occurrence.event_id || occurrence.id))));
  appointmentsEmpty.hidden = occurrences.length > 0;
  activitiesMessage.textContent = '';

}

void loadActivities();

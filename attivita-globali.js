const activitiesClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const activitiesMessage = document.getElementById('message');
const coursesList = document.getElementById('courses-list');
const coursesEmpty = document.getElementById('courses-empty');
const appointmentsList = document.getElementById('appointments-list');
const appointmentsEmpty = document.getElementById('appointments-empty');

function initials(value, fallback) {
  return (value || '').trim().charAt(0).toLocaleUpperCase('it-IT') || fallback;
}

function formatWhen(activity) {
  const startsAt = activity.starts_at || activity.due_at;
  if (!startsAt) return 'Data non indicata';
  const start = new Date(startsAt);
  const date = start.toLocaleDateString('it-IT');
  if (activity.is_all_day ?? activity.all_day) return `${date} · Tutto il giorno`;
  const time = start.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' });
  const endsAt = activity.due_at || activity.ends_at;
  const end = endsAt && endsAt !== startsAt
    ? ` – ${new Date(endsAt).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' })}`
    : '';
  return `${date}, ${time}${end}`;
}

function activityHref(activity) {
  const query = new URLSearchParams({ activity_id: activity.id || activity.activity_id });
  return `attivita.html?${query}`;
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

function createSummaryCard({ title, details, href, fallback, label }) {
  const card = document.createElement('a');
  card.className = 'fa-v2-deadline-card fa-v2-deadline-card--interactive fa-v2-card-media-layout';
  card.href = href;
  card.setAttribute('aria-label', label);

  const visual = document.createElement('span');
  visual.className = 'fa-v2-card-visual';
  visual.setAttribute('aria-hidden', 'true');
  visual.textContent = initials(title, fallback);

  const heading = document.createElement('h3');
  heading.className = 'fa-v2-card-title';
  heading.textContent = title;
  const content = document.createElement('div');
  content.className = 'fa-v2-card-content';
  const metadata = document.createElement('div');
  metadata.className = 'fa-v2-card-description';
  if (typeof details === 'string') metadata.textContent = details;
  else if (details) metadata.append(details);
  content.append(heading, metadata);
  const actions = document.createElement('span');
  actions.className = 'fa-v2-card-actions';
  const action = document.createElement('span');
  action.className = 'fa-v2-button fa-v2-button--secondary';
  action.textContent = 'Apri';
  actions.append(action);
  card.append(visual, content, actions);
  return card;
}

function activityDetails(activity, occurrence) {
  const details = document.createElement('div');
  const nextDate = occurrence ? `Prossima data: ${formatWhen(occurrence)}` : 'Prossima data non disponibile';
  const recurrence = recurrenceLabel(activity);

  [nextDate, recurrence ? `Ricorrenza: ${recurrence}` : ''].filter(Boolean).forEach((value) => {
    const line = document.createElement('div');
    line.textContent = value;
    details.append(line);
  });
  return details;
}

function activityCard(activity, occurrence) {
  return createSummaryCard({
    title: activity.title,
    details: activityDetails(activity, occurrence),
    href: activityHref(activity),
    fallback: 'A',
    label: `Apri attività ${activity.title}`
  });
}

function appointmentCard(occurrence, activity) {
  const item = document.createElement('a');
  const title = occurrence.title || activity.title;
  item.className = 'fa-v2-list-row fa-v2-list-row--media';
  item.href = activityHref(activity);
  item.setAttribute('aria-label', `Apri appuntamento ${title}`);
  const thumbnail = document.createElement('span');
  thumbnail.setAttribute('aria-hidden', 'true');
  thumbnail.textContent = initials(title, 'A');
  const copy = document.createElement('span');
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

function rpcFailureMessage(subject, error) {
  console.error(`[FamilArea activities] ${subject}`, error);
  const code = error?.code ? ` (${error.code})` : '';
  const reason = error?.message || error?.details || 'Risposta non disponibile.';
  return `Impossibile caricare ${subject}${code}: ${reason}`;
}

async function loadActivities() {
  const { data: sessionData } = await activitiesClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }

  const { from, to } = futureWindow();
  const [accountResult, activitiesResult, occurrencesResult] = await Promise.all([
    activitiesClient.rpc('get_current_account'),
    activitiesClient.rpc('get_visible_activities'),
    activitiesClient.rpc('get_calendar_occurrences', { p_from: from.toISOString(), p_to: to.toISOString() })
  ]);
  if (activitiesResult.error) {
    activitiesMessage.textContent = rpcFailureMessage('le attività', activitiesResult.error);
    return;
  }
  if (!Array.isArray(activitiesResult.data)) {
    activitiesMessage.textContent = 'Impossibile caricare le attività: risposta RPC incompatibile.';
    console.error('[FamilArea activities] risposta get_visible_activities incompatibile', activitiesResult.data);
    return;
  }

  const activities = activitiesResult.data;
  console.info('[FamilArea activities] get_visible_activities', {
    account: accountResult.error ? null : accountResult.data?.account_id,
    accountType: accountResult.error ? null : accountResult.data?.account_type,
    count: activities.length
  });
  const activitiesById = new Map(activities.map((activity) => [activity.id || activity.activity_id, activity]));
  const activityIds = new Set(activities.map((activity) => activity.id || activity.activity_id));
  const occurrences = occurrencesResult.error ? [] : (occurrencesResult.data || [])
    .filter((occurrence) => occurrence.kind === 'activity' && activityIds.has(occurrence.activity_id || occurrence.id))
    .sort((first, second) => new Date(first.starts_at) - new Date(second.starts_at));
  const nextOccurrenceByActivityId = new Map();
  occurrences.forEach((occurrence) => {
    const activityId = occurrence.activity_id || occurrence.id;
    if (!nextOccurrenceByActivityId.has(activityId)) nextOccurrenceByActivityId.set(activityId, occurrence);
  });
  coursesList.replaceChildren(...activities.map((activity) => activityCard(activity, nextOccurrenceByActivityId.get(activity.id || activity.activity_id))));
  coursesEmpty.hidden = activities.length > 0;
  if (occurrencesResult.error) {
    appointmentsList.replaceChildren();
    appointmentsEmpty.hidden = true;
    activitiesMessage.textContent = rpcFailureMessage('i prossimi appuntamenti', occurrencesResult.error);
    return;
  }
  appointmentsList.replaceChildren(...occurrences.slice(0, 5).map((occurrence) => appointmentCard(occurrence, activitiesById.get(occurrence.activity_id || occurrence.id))));
  appointmentsEmpty.hidden = occurrences.length > 0;
  activitiesMessage.textContent = '';

}

void loadActivities();

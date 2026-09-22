const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const section = document.getElementById('activities-section');
const list = document.getElementById('activities-list');
const empty = document.getElementById('activities-empty');

const statusLabels = { open: 'Da fare', completed: 'Completata', cancelled: 'Annullata' };

function formatDateTime(value, isAllDay) {
  if (!value) return '';
  return new Intl.DateTimeFormat('it-IT', isAllDay
    ? { dateStyle: 'long' }
    : { dateStyle: 'long', timeStyle: 'short' }).format(new Date(value));
}

function createBadge(className, text) {
  const badge = document.createElement('span');
  badge.className = className;
  badge.textContent = text;
  return badge;
}

function createActivityRow(activity) {
  const row = document.createElement('a');
  row.className = 'global-activity-row';
  const activityId = activity.id || activity.activity_id;
  row.href = activity.area_id ? `attivita.html?area_id=${encodeURIComponent(activity.area_id)}&activity_id=${encodeURIComponent(activityId)}` : `attivita.html?activity_id=${encodeURIComponent(activityId)}`;
  row.setAttribute('aria-label', `Apri attività ${activity.title}`);

  const main = document.createElement('div');
  main.className = 'global-activity-main';
  const title = document.createElement('h2');
  title.textContent = activity.title;
  const area = document.createElement('p');
  area.className = 'global-activity-area';
  area.textContent = activity.area_id ? 'Area condivisa' : 'Personale';
  main.append(title, area);

  const details = document.createElement('div');
  details.className = 'global-activity-details';
  const when = formatDateTime(activity.due_at || activity.starts_at, activity.is_all_day);
  if (when) {
    const date = document.createElement('span');
    date.className = 'global-activity-date';
    date.textContent = when;
    details.appendChild(date);
  }
  const badges = document.createElement('div');
  badges.className = 'global-activity-badges';
  badges.appendChild(createBadge(`global-activity-status global-activity-status-${activity.status}`, statusLabels[activity.status] || activity.status));
  if (activity.priority === 'high') badges.appendChild(createBadge('global-activity-priority', 'Priorità alta'));
  details.appendChild(badges);

  row.append(main, details);
  return row;
}

async function loadActivities() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }
  const { data, error } = await supabaseClient.rpc('get_visible_activities');
  if (error) { message.textContent = 'Impossibile caricare le attività visibili.'; return; }

  list.replaceChildren();
  section.hidden = false;
  if (!data?.length) {
    empty.hidden = false;
    message.textContent = '';
    return;
  }
  empty.hidden = true;
  data.forEach((activity) => list.appendChild(createActivityRow(activity)));
  message.textContent = '';
}

loadActivities();

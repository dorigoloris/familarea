const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const message = document.getElementById('message');
const backLink = document.getElementById('back-link');
const newActivityLink = document.getElementById('new-activity-link');

const groups = {
  open: {
    section: document.getElementById('open-activities-section'),
    list: document.getElementById('open-activities-list'),
    empty: 'Nessuna attività aperta.'
  },
  completed: {
    section: document.getElementById('completed-activities-section'),
    list: document.getElementById('completed-activities-list'),
    empty: 'Nessuna attività completata.'
  },
  cancelled: {
    section: document.getElementById('cancelled-activities-section'),
    list: document.getElementById('cancelled-activities-list'),
    empty: 'Nessuna attività annullata.'
  }
};

const typeLabels = { task: 'Da fare', reminder: 'Promemoria', deadline: 'Scadenza', appointment: 'Appuntamento' };
const priorityLabels = { low: 'Bassa', normal: 'Normale', high: 'Alta' };

function formatDateTime(value, isAllDay) {
  if (!value) return 'Nessuna scadenza';
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

function createActivityCard(activity, areaId) {
  const card = document.createElement('article');
  card.className = 'activity-card';

  const title = document.createElement('h3');
  title.className = 'activity-card-title';
  title.textContent = activity.title;

  const metadata = document.createElement('div');
  metadata.className = 'activity-card-meta';
  metadata.append(
    createBadge('activity-type-badge', typeLabels[activity.activity_type] || 'Attività'),
    createBadge(`activity-priority-badge activity-priority-${activity.priority}`, priorityLabels[activity.priority] || 'Normale'),
    createBadge(`activity-status-badge activity-status-${activity.status}`, activity.status === 'open' ? 'Aperta' : activity.status === 'completed' ? 'Completata' : 'Annullata')
  );

  const due = document.createElement('p');
  due.className = 'activity-card-due';
  due.textContent = `Scadenza: ${formatDateTime(activity.due_at, activity.is_all_day)}`;

  const open = document.createElement('a');
  open.className = 'btn activity-open-link';
  open.textContent = 'Apri';
  open.href = `attivita.html?area_id=${encodeURIComponent(areaId)}&activity_id=${encodeURIComponent(activity.id)}`;

  card.append(title, metadata, due, open);
  return card;
}

function renderGroup(status, activities, areaId) {
  const group = groups[status];
  group.list.replaceChildren();
  group.section.hidden = false;

  if (!activities.length) {
    const empty = document.createElement('p');
    empty.className = 'empty-state';
    empty.textContent = group.empty;
    group.list.appendChild(empty);
    return;
  }

  activities.forEach((activity) => group.list.appendChild(createActivityCard(activity, areaId)));
}

async function loadActivities() {
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

  backLink.href = `area.html?area_id=${encodeURIComponent(areaId)}`;
  newActivityLink.href = `nuova-attivita.html?area_id=${encodeURIComponent(areaId)}`;

  const { data, error } = await supabaseClient.rpc('get_area_activities', { p_area_id: areaId });
  if (error) {
    message.textContent = 'Impossibile caricare le attività visibili.';
    return;
  }

  const activities = data || [];
  renderGroup('open', activities.filter((activity) => activity.status === 'open'), areaId);
  renderGroup('completed', activities.filter((activity) => activity.status === 'completed'), areaId);

  const cancelled = activities.filter((activity) => activity.status === 'cancelled');
  if (cancelled.length) renderGroup('cancelled', cancelled, areaId);

  message.textContent = '';
}

loadActivities();

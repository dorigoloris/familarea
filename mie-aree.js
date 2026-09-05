const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const calendarUtils = window.FamilAreaCalendarUtils;

const message = document.getElementById('message');
const areasList = document.getElementById('areas-list');
const dashboardMessage = document.getElementById('dashboard-message');
const dashboardCalendarSection = document.getElementById('dashboard-calendar-section');
const dashboardMonthTitle = document.getElementById('dashboard-month-title');
const dashboardCalendarGrid = document.getElementById('dashboard-calendar-grid');
const dashboardPreviousMonthButton = document.getElementById('dashboard-previous-month');
const dashboardNextMonthButton = document.getElementById('dashboard-next-month');

const activitySections = {
  today: { list: document.getElementById('today-list'), empty: document.getElementById('today-empty') },
  upcoming: { list: document.getElementById('upcoming-list'), empty: document.getElementById('upcoming-empty') },
  todo: { list: document.getElementById('todo-list'), empty: document.getElementById('todo-empty') }
};

const activityTypeLabels = { task: 'Da fare', reminder: 'Promemoria', deadline: 'Scadenza', appointment: 'Appuntamento' };
const priorityLabels = { low: 'Bassa', normal: 'Normale', high: 'Alta' };
const statusLabels = { open: 'Aperta', completed: 'Completata', cancelled: 'Cancellata' };
let dashboardCalendarActivities = [];
let dashboardDisplayedMonth = new Date(new Date().getFullYear(), new Date().getMonth(), 1);

function getTodayBounds() {
  const now = new Date();
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const end = new Date(start);
  end.setDate(end.getDate() + 1);
  return { start, end };
}

function datesFor(activity) {
  return [activity.due_at, activity.starts_at].map(calendarUtils.toValidDate).filter(Boolean);
}

function fallsOnToday(activity, start, end) {
  return datesFor(activity).some((date) => date >= start && date < end);
}

function upcomingTime(activity, end) {
  return datesFor(activity).filter((date) => date >= end).sort((first, second) => first - second)[0] || null;
}

function compareActivities(first, second, dateForActivity) {
  const firstDate = dateForActivity(first);
  const secondDate = dateForActivity(second);
  if (firstDate && secondDate && firstDate.getTime() !== secondDate.getTime()) return firstDate - secondDate;
  if (firstDate) return -1;
  if (secondDate) return 1;
  const createdDifference = new Date(first.created_at) - new Date(second.created_at);
  if (createdDifference !== 0) return createdDifference;
  return String(first.activity_id).localeCompare(String(second.activity_id));
}

function formatActivityDate(activity) {
  const formatter = new Intl.DateTimeFormat('it-IT', {
    dateStyle: 'medium',
    ...(activity.is_all_day ? {} : { timeStyle: 'short' })
  });
  const dates = [];
  const startsAt = calendarUtils.toValidDate(activity.starts_at);
  const dueAt = calendarUtils.toValidDate(activity.due_at);
  if (startsAt) dates.push(`Inizio: ${formatter.format(startsAt)}`);
  if (dueAt) dates.push(`Scadenza: ${formatter.format(dueAt)}`);
  return dates.join(' · ');
}

function createBadge(text, className) {
  const badge = document.createElement('span');
  badge.className = className;
  badge.textContent = text;
  return badge;
}

function createActivityCard(activity) {
  const card = document.createElement('article');
  card.className = 'activity-card';

  const title = document.createElement('h3');
  title.className = 'activity-card-title';
  title.textContent = activity.title;

  const area = document.createElement('p');
  area.className = 'activity-card-area';
  area.textContent = activity.area_name;

  const meta = document.createElement('div');
  meta.className = 'activity-card-meta';
  meta.appendChild(createBadge(activityTypeLabels[activity.activity_type] || activity.activity_type, 'activity-type-badge'));
  meta.appendChild(createBadge(`Priorità: ${priorityLabels[activity.priority] || activity.priority}`, `activity-priority-badge activity-priority-${activity.priority}`));
  meta.appendChild(createBadge(`Stato: ${statusLabels[activity.status] || activity.status}`, `activity-status-badge activity-status-${activity.status}`));

  const dateText = formatActivityDate(activity);
  const date = document.createElement('p');
  date.className = 'activity-card-due';
  date.textContent = dateText;
  date.hidden = !dateText;

  const link = document.createElement('a');
  link.className = 'btn activity-open-link';
  link.textContent = 'Apri';
  link.href = `attivita.html?area_id=${encodeURIComponent(activity.area_id)}&activity_id=${encodeURIComponent(activity.activity_id)}`;

  card.appendChild(title);
  card.appendChild(area);
  card.appendChild(meta);
  card.appendChild(date);
  card.appendChild(link);
  return card;
}

function renderActivities(section, activities) {
  section.list.replaceChildren();
  section.empty.hidden = activities.length > 0;
  activities.forEach((activity) => section.list.appendChild(createActivityCard(activity)));
}

function renderDashboardCalendar() {
  calendarUtils.renderMonthCalendar({
    month: dashboardDisplayedMonth,
    titleElement: dashboardMonthTitle,
    gridElement: dashboardCalendarGrid,
    activities: dashboardCalendarActivities
  });
}

function changeDashboardMonth(offset) {
  dashboardDisplayedMonth = new Date(dashboardDisplayedMonth.getFullYear(), dashboardDisplayedMonth.getMonth() + offset, 1);
  renderDashboardCalendar();
}

async function loadDashboardActivities() {
  try {
    const { data: activities, error } = await supabaseClient.rpc('get_my_visible_activities');
    if (error) throw error;

    const visibleActivities = activities || [];
    const { start, end } = getTodayBounds();
    const activeActivities = visibleActivities.filter((activity) => activity.status !== 'cancelled');
    dashboardCalendarActivities = activeActivities;
    renderDashboardCalendar();
    const today = activeActivities
      .filter((activity) => fallsOnToday(activity, start, end))
      .sort((first, second) => compareActivities(first, second, (activity) => {
        return datesFor(activity).filter((date) => date >= start && date < end).sort((a, b) => a - b)[0] || null;
      }));
    const upcoming = activeActivities
      .filter((activity) => upcomingTime(activity, end))
      .sort((first, second) => compareActivities(first, second, (activity) => upcomingTime(activity, end)))
      .slice(0, 10);
    const todo = visibleActivities
      .filter((activity) => activity.status === 'open')
      .sort((first, second) => compareActivities(first, second, (activity) => calendarUtils.toValidDate(activity.due_at) || calendarUtils.toValidDate(activity.starts_at)));

    renderActivities(activitySections.today, today);
    renderActivities(activitySections.upcoming, upcoming);
    renderActivities(activitySections.todo, todo);
  } catch (error) {
    console.error('Errore nel caricamento delle attività della Dashboard:', error);
    dashboardMessage.textContent = 'Non è stato possibile caricare le attività. Riprova più tardi.';
    dashboardCalendarSection.hidden = true;
  }
}

async function loadMyAreas(userId) {
  const { data: profile, error: profileError } = await supabaseClient
    .from('profiles')
    .select('id')
    .eq('user_id', userId)
    .single();

  if (profileError) {
    message.textContent = `Errore profilo: ${profileError.message}`;
    return;
  }

  const { data: memberships, error: membershipsError } = await supabaseClient
    .from('area_memberships')
    .select(`
      role,
      area_id,
      areas (id, name, area_type)
    `)
    .eq('profile_id', profile.id);

  if (membershipsError) {
    message.textContent = `Errore Aree: ${membershipsError.message}`;
    return;
  }

  areasList.replaceChildren();
  if (!memberships || memberships.length === 0) {
    message.textContent = 'Non hai ancora nessuna Area.';
    return;
  }

  memberships.forEach((membership) => {
    const area = membership.areas;
    if (!area) return;
    const container = document.createElement('article');
    container.className = 'area-card';
    const title = document.createElement('h3');
    title.textContent = area.name;
    const info = document.createElement('p');
    const roleLabels = { admin: 'Amministratore', member: 'Membro', managed: 'Profilo gestito' };
    info.textContent = `${area.area_type} — ${roleLabels[membership.role] || membership.role}`;
    const link = document.createElement('a');
    link.className = 'btn';
    link.textContent = 'Apri Area';
    link.href = `area.html?area_id=${encodeURIComponent(area.id)}`;
    container.appendChild(title);
    container.appendChild(info);
    container.appendChild(link);
    areasList.appendChild(container);
  });

  message.textContent = '';
}

async function initialiseDashboard() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }
  await Promise.all([loadDashboardActivities(), loadMyAreas(sessionData.session.user.id)]);
}

dashboardPreviousMonthButton.addEventListener('click', () => changeDashboardMonth(-1));
dashboardNextMonthButton.addEventListener('click', () => changeDashboardMonth(1));
renderDashboardCalendar();
initialiseDashboard();

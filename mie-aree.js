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
const dashboardTodayButton = document.getElementById('dashboard-today');
const headerUserName = document.getElementById('header-user-name');
const dashboardInvitesSection = document.getElementById('dashboard-invites-section');
const dashboardInvitesTitle = document.getElementById('dashboard-invites-title');
const dashboardInvitesDescription = document.getElementById('dashboard-invites-description');
const sections = {
  today: { list: document.getElementById('today-list'), empty: document.getElementById('today-empty') },
  upcoming: { list: document.getElementById('upcoming-list'), empty: document.getElementById('upcoming-empty') },
  todo: { list: document.getElementById('todo-list'), empty: document.getElementById('todo-empty') }
};
const typeLabels = { task: 'Da fare', reminder: 'Promemoria', deadline: 'Scadenza', appointment: 'Appuntamento' };
const priorityLabels = { low: 'Bassa', normal: 'Normale', high: 'Alta' };
const statusLabels = { open: 'Aperta', completed: 'Completata', cancelled: 'Cancellata' };
let dashboardCalendarItems = [];
let dashboardDisplayedMonth = new Date(new Date().getFullYear(), new Date().getMonth(), 1);

function getTodayBounds() {
  const now = new Date();
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const end = new Date(start);
  end.setDate(end.getDate() + 1);
  return { start, end };
}

function isEvent(item) { return calendarUtils.itemType(item) === 'event'; }
function datesForActivity(activity) { return [activity.due_at, activity.starts_at].map(calendarUtils.toValidDate).filter(Boolean); }
function datesForItem(item) { return isEvent(item) ? [calendarUtils.toValidDate(item.starts_at)].filter(Boolean) : datesForActivity(item); }
function fallsOnToday(item, start, end) { return datesForItem(item).some((date) => date >= start && date < end); }
function upcomingTime(item, end) { return datesForItem(item).filter((date) => date >= end).sort((a, b) => a - b)[0] || null; }
function itemId(item) { return item.event_id || item.activity_id; }

function compareItems(first, second, dateForItem) {
  const firstDate = dateForItem(first);
  const secondDate = dateForItem(second);
  if (firstDate && secondDate && firstDate.getTime() !== secondDate.getTime()) return firstDate - secondDate;
  if (firstDate) return -1;
  if (secondDate) return 1;
  const createdDifference = new Date(first.created_at) - new Date(second.created_at);
  if (createdDifference !== 0) return createdDifference;
  return String(itemId(first)).localeCompare(String(itemId(second)));
}

function formatActivityDate(activity) {
  const formatter = new Intl.DateTimeFormat('it-IT', { dateStyle: 'medium', ...(activity.is_all_day ? {} : { timeStyle: 'short' }) });
  const dates = [];
  const startsAt = calendarUtils.toValidDate(activity.starts_at);
  const dueAt = calendarUtils.toValidDate(activity.due_at);
  if (startsAt) dates.push(`Inizio: ${formatter.format(startsAt)}`);
  if (dueAt) dates.push(`Scadenza: ${formatter.format(dueAt)}`);
  return dates.join(' · ');
}

function formatEventDate(event) {
  const start = calendarUtils.toValidDate(event.starts_at);
  if (!start) return '';
  const dateFormatter = new Intl.DateTimeFormat('it-IT', { dateStyle: 'medium' });
  if (event.is_all_day) return dateFormatter.format(start);
  const timeFormatter = new Intl.DateTimeFormat('it-IT', { hour: '2-digit', minute: '2-digit' });
  const end = calendarUtils.toValidDate(event.ends_at);
  return `${dateFormatter.format(start)}, ${timeFormatter.format(start)}${end ? ` – ${timeFormatter.format(end)}` : ''}`;
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
  const title = document.createElement('h3'); title.className = 'activity-card-title'; title.textContent = activity.title;
  const area = document.createElement('p'); area.className = 'activity-card-area'; area.textContent = activity.area_name;
  const meta = document.createElement('div'); meta.className = 'activity-card-meta';
  meta.append(createBadge(typeLabels[activity.activity_type] || activity.activity_type, 'activity-type-badge'), createBadge(`Priorità: ${priorityLabels[activity.priority] || activity.priority}`, `activity-priority-badge activity-priority-${activity.priority}`), createBadge(`Stato: ${statusLabels[activity.status] || activity.status}`, `activity-status-badge activity-status-${activity.status}`));
  const date = document.createElement('p'); date.className = 'activity-card-due'; date.textContent = formatActivityDate(activity); date.hidden = !date.textContent;
  const link = document.createElement('a'); link.className = 'btn activity-open-link'; link.textContent = 'Apri'; link.href = calendarUtils.itemLink(activity);
  card.append(title, area, meta, date, link);
  return card;
}

function createEventCard(event) {
  const card = document.createElement('article');
  card.className = 'activity-card dashboard-event-card';
  const title = document.createElement('h3'); title.className = 'activity-card-title'; title.textContent = event.title;
  const area = document.createElement('p'); area.className = 'activity-card-area'; area.textContent = event.area_name;
  const meta = document.createElement('div'); meta.className = 'activity-card-meta'; meta.appendChild(createBadge('Evento', 'event-badge'));
  const date = document.createElement('p'); date.className = 'activity-card-due'; date.textContent = formatEventDate(event);
  const location = document.createElement('p'); location.className = 'activity-card-location'; location.textContent = event.location ? `Luogo: ${event.location}` : ''; location.hidden = !event.location;
  const link = document.createElement('a'); link.className = 'btn activity-open-link'; link.textContent = 'Apri'; link.href = calendarUtils.itemLink(event);
  card.append(title, area, meta, date, location, link);
  return card;
}

function renderItems(section, items, limit) {
  section.list.replaceChildren();
  section.empty.hidden = items.length > 0;
  items.slice(0, limit).forEach((item) => section.list.appendChild(isEvent(item) ? createEventCard(item) : createActivityCard(item)));
}

function renderDashboardCalendar() {
  calendarUtils.renderMonthCalendar({ month: dashboardDisplayedMonth, titleElement: dashboardMonthTitle, gridElement: dashboardCalendarGrid, activities: dashboardCalendarItems });
}

function changeDashboardMonth(offset) {
  dashboardDisplayedMonth = new Date(dashboardDisplayedMonth.getFullYear(), dashboardDisplayedMonth.getMonth() + offset, 1);
  renderDashboardCalendar();
}

function showCurrentMonth() {
  const now = new Date();
  dashboardDisplayedMonth = new Date(now.getFullYear(), now.getMonth(), 1);
  renderDashboardCalendar();
}

function resultData(result) { return result.status === 'fulfilled' && !result.value.error ? result.value.data || [] : []; }
function failed(result) { return result.status === 'rejected' || (result.status === 'fulfilled' && result.value.error); }

async function loadDashboardTimeline() {
  const [activityResult, eventResult] = await Promise.allSettled([supabaseClient.rpc('get_my_visible_activities'), supabaseClient.rpc('get_my_visible_events')]);
  const visibleActivities = resultData(activityResult);
  const visibleEvents = resultData(eventResult);
  const activities = visibleActivities.filter((activity) => activity.status !== 'cancelled');
  const events = visibleEvents.filter((event) => event.status !== 'cancelled');
  const { start, end } = getTodayBounds();

  dashboardCalendarItems = [...activities, ...events];
  renderDashboardCalendar();
  const today = [...activities.filter((activity) => fallsOnToday(activity, start, end)), ...events.filter((event) => fallsOnToday(event, start, end))]
    .sort((a, b) => compareItems(a, b, (item) => datesForItem(item).filter((date) => date >= start && date < end).sort((x, y) => x - y)[0] || null));
  const upcoming = [...activities.filter((activity) => upcomingTime(activity, end)), ...events.filter((event) => upcomingTime(event, end))]
    .sort((a, b) => compareItems(a, b, (item) => upcomingTime(item, end)));
  const todo = visibleActivities.filter((activity) => activity.status === 'open')
    .sort((a, b) => compareItems(a, b, (activity) => calendarUtils.toValidDate(activity.due_at) || calendarUtils.toValidDate(activity.starts_at)));
  renderItems(sections.today, today, 5);
  renderItems(sections.upcoming, upcoming, 5);
  renderItems(sections.todo, todo, 5);

  if (failed(activityResult) && failed(eventResult)) {
    dashboardMessage.textContent = 'Non è stato possibile caricare impegni ed eventi. Riprova più tardi.';
    dashboardCalendarSection.hidden = true;
  } else if (failed(activityResult)) dashboardMessage.textContent = 'Le attività non sono disponibili al momento; gli eventi visibili sono mostrati.';
  else if (failed(eventResult)) dashboardMessage.textContent = 'Gli eventi non sono disponibili al momento; le attività visibili sono mostrate.';
  else dashboardMessage.textContent = '';
}

async function loadPendingInvites() {
  try {
    const { data, error } = await supabaseClient.rpc('get_my_area_invites');
    if (error) return;
    const pendingInvites = (data || []).filter((invite) => invite.status === 'pending');
    if (!pendingInvites.length) {
      dashboardInvitesSection.hidden = true;
      return;
    }
    const count = pendingInvites.length;
    dashboardInvitesTitle.textContent = `Hai ${count} invit${count === 1 ? 'o' : 'i'} in attesa`;
    dashboardInvitesDescription.textContent = count === 1
      ? 'Sei stato invitato a partecipare a un’Area.'
      : 'Hai nuovi inviti a partecipare ad alcune Aree.';
    dashboardInvitesSection.hidden = false;
  } catch {
    dashboardInvitesSection.hidden = true;
  }
}

async function loadMyAreas(userId) {
  const { data: profile, error: profileError } = await supabaseClient.from('profiles').select('id').eq('user_id', userId).single();
  if (profileError) { message.textContent = `Errore profilo: ${profileError.message}`; return; }
  const { data: memberships, error: membershipsError } = await supabaseClient.from('area_memberships').select('role,area_id,areas (id, name, area_type)').eq('profile_id', profile.id);
  if (membershipsError) { message.textContent = `Errore Aree: ${membershipsError.message}`; return; }
  areasList.replaceChildren();
  if (!memberships?.length) { message.textContent = 'Non hai ancora nessuna Area.'; return; }
  memberships.forEach((membership) => {
    const area = membership.areas;
    if (!area) return;
    const card = document.createElement('article'); card.className = 'area-card';
    const icon = document.createElement('span'); icon.className = 'area-card-icon'; icon.setAttribute('aria-hidden', 'true'); icon.textContent = '⌂';
    const title = document.createElement('h3'); title.textContent = area.name;
    const info = document.createElement('p'); info.textContent = `${area.area_type} — ${{ admin: 'Amministratore', member: 'Partecipante', managed: 'Profilo gestito' }[membership.role] || membership.role}`;
    const link = document.createElement('a'); link.className = 'btn'; link.textContent = 'Apri Area'; link.href = `area.html?area_id=${encodeURIComponent(area.id)}`;
    card.append(icon, title, info, link); areasList.appendChild(card);
  });
  message.textContent = '';
}

async function initialiseDashboard() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }
  const user = sessionData.session.user;
  const userName = user.user_metadata?.full_name || user.user_metadata?.name || user.email;
  if (userName) { headerUserName.textContent = userName; headerUserName.hidden = false; }
  await Promise.all([loadDashboardTimeline(), loadMyAreas(user.id), loadPendingInvites()]);
}

dashboardPreviousMonthButton.addEventListener('click', () => changeDashboardMonth(-1));
dashboardNextMonthButton.addEventListener('click', () => changeDashboardMonth(1));
dashboardTodayButton.addEventListener('click', showCurrentMonth);
renderDashboardCalendar();
initialiseDashboard();

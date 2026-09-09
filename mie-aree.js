const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const calendarUtils = window.FamilAreaCalendarUtils;
const dashboardMessage = document.getElementById('dashboard-message');
const dashboardCalendarSection = document.getElementById('dashboard-calendar-section');
const dashboardWeekTitle = document.getElementById('dashboard-week-title');
const dashboardWeekGrid = document.getElementById('dashboard-week-grid');
const dashboardPreviousWeekButton = document.getElementById('dashboard-previous-week');
const dashboardNextWeekButton = document.getElementById('dashboard-next-week');
const dashboardCurrentWeekButton = document.getElementById('dashboard-current-week');
const dashboardInvitesSection = document.getElementById('dashboard-invites-section');
const dashboardInvitesTitle = document.getElementById('dashboard-invites-title');
const dashboardInvitesDescription = document.getElementById('dashboard-invites-description');
const sections = { today: { list: document.getElementById('today-list'), empty: document.getElementById('today-empty') }, upcoming: { list: document.getElementById('upcoming-list'), empty: document.getElementById('upcoming-empty') }, todo: { list: document.getElementById('todo-list'), empty: document.getElementById('todo-empty') } };
const typeLabels = { task: 'Da fare', reminder: 'Promemoria', deadline: 'Scadenza', appointment: 'Appuntamento' };
const priorityLabels = { low: 'Bassa', normal: 'Normale', high: 'Alta' };
const statusLabels = { open: 'Aperta', completed: 'Completata', cancelled: 'Cancellata' };
let dashboardCalendarItems = [];
let dashboardDisplayedWeek = calendarUtils.startOfWeek(new Date());
let visibleActivities = [];
let visibleEvents = [];

function dayStart(value = new Date()) { return new Date(value.getFullYear(), value.getMonth(), value.getDate()); }
function getTodayBounds() { const start = dayStart(); const end = new Date(start); end.setDate(end.getDate() + 1); return { start, end }; }
function weekBounds() { const start = calendarUtils.startOfWeek(dashboardDisplayedWeek); const end = new Date(start); end.setDate(end.getDate() + 7); return { start, end }; }
function occurrenceWindow() {
  const today = dayStart(); const { start: weekStart, end: weekEnd } = weekBounds(); const start = weekStart < today ? weekStart : today; const nextYear = new Date(today); nextYear.setDate(nextYear.getDate() + 365); const maxEnd = new Date(start); maxEnd.setDate(maxEnd.getDate() + 399); const desiredEnd = weekEnd > nextYear ? weekEnd : nextYear;
  return { start, end: desiredEnd > maxEnd ? maxEnd : desiredEnd };
}
function isEvent(item) { return calendarUtils.itemType(item) === 'event'; }
function datesForActivity(activity) { return [activity.occurrence_starts_at, activity.occurrence_ends_at, activity.due_at, activity.starts_at].map(calendarUtils.toValidDate).filter(Boolean); }
function datesForItem(item) { return isEvent(item) ? [calendarUtils.toValidDate(item.starts_at)].filter(Boolean) : datesForActivity(item); }
function fallsOnToday(item, start, end) { return datesForItem(item).some((date) => date >= start && date < end); }
function upcomingTime(item, end) { return datesForItem(item).filter((date) => date >= end).sort((a, b) => a - b)[0] || null; }
function itemId(item) { return item.event_id || `${item.activity_id || ''}-${item.occurrence_starts_at || ''}`; }
function compareItems(first, second, dateForItem) { const a = dateForItem(first); const b = dateForItem(second); if (a && b && a - b) return a - b; if (a) return -1; if (b) return 1; return String(itemId(first)).localeCompare(String(itemId(second))); }
function formatActivityDate(activity) {
  const start = calendarUtils.toValidDate(activity.occurrence_starts_at || activity.starts_at); const end = calendarUtils.toValidDate(activity.occurrence_ends_at || activity.due_at);
  if (!start && !end) return ''; const dateFormatter = new Intl.DateTimeFormat('it-IT', { dateStyle: 'medium' }); if (activity.is_all_day) return dateFormatter.format(start || end);
  const timeFormatter = new Intl.DateTimeFormat('it-IT', { hour: '2-digit', minute: '2-digit' }); const date = start || end;
  return `${dateFormatter.format(date)}, ${timeFormatter.format(start || end)}${start && end && start.getTime() !== end.getTime() ? ` – ${timeFormatter.format(end)}` : ''}`;
}
function formatEventDate(event) { const start = calendarUtils.toValidDate(event.starts_at); if (!start) return ''; const dateFormatter = new Intl.DateTimeFormat('it-IT', { dateStyle: 'medium' }); if (event.is_all_day) return dateFormatter.format(start); const timeFormatter = new Intl.DateTimeFormat('it-IT', { hour: '2-digit', minute: '2-digit' }); const end = calendarUtils.toValidDate(event.ends_at); return `${dateFormatter.format(start)}, ${timeFormatter.format(start)}${end ? ` – ${timeFormatter.format(end)}` : ''}`; }
function createBadge(text, className) { const badge = document.createElement('span'); badge.className = className; badge.textContent = text; return badge; }
function createActivityCard(activity) {
  const card = document.createElement('article'); card.className = 'activity-card'; const title = document.createElement('h3'); title.className = 'activity-card-title'; title.textContent = activity.title;
  const area = document.createElement('p'); area.className = 'activity-card-area'; area.textContent = activity.area_name;
  const meta = document.createElement('div'); meta.className = 'activity-card-meta'; meta.append(createBadge(typeLabels[activity.activity_type] || activity.activity_type, 'activity-type-badge'), createBadge(`Priorità: ${priorityLabels[activity.priority] || activity.priority}`, `activity-priority-badge activity-priority-${activity.priority}`), createBadge(`Stato: ${statusLabels[activity.status] || activity.status}`, `activity-status-badge activity-status-${activity.status}`));
  const date = document.createElement('p'); date.className = 'activity-card-due'; date.textContent = formatActivityDate(activity); date.hidden = !date.textContent;
  const link = document.createElement('a'); link.className = 'btn activity-open-link'; link.textContent = 'Apri'; link.href = calendarUtils.itemLink(activity); card.append(title, area, meta, date, link); return card;
}
function createEventCard(event) { const card = document.createElement('article'); card.className = 'activity-card dashboard-event-card'; const title = document.createElement('h3'); title.className = 'activity-card-title'; title.textContent = event.title; const area = document.createElement('p'); area.className = 'activity-card-area'; area.textContent = event.area_name; const meta = document.createElement('div'); meta.className = 'activity-card-meta'; meta.appendChild(createBadge('Evento', 'event-badge')); const date = document.createElement('p'); date.className = 'activity-card-due'; date.textContent = formatEventDate(event); const location = document.createElement('p'); location.className = 'activity-card-location'; location.textContent = event.location ? `Luogo: ${event.location}` : ''; location.hidden = !event.location; const link = document.createElement('a'); link.className = 'btn activity-open-link'; link.textContent = 'Apri'; link.href = calendarUtils.itemLink(event); card.append(title, area, meta, date, location, link); return card; }
function renderItems(section, items, limit) { section.list.replaceChildren(); section.empty.hidden = items.length > 0; items.slice(0, limit).forEach((item) => section.list.appendChild(isEvent(item) ? createEventCard(item) : createActivityCard(item))); }
function renderDashboardCalendar() { calendarUtils.renderWeekCalendar({ weekStart: dashboardDisplayedWeek, titleElement: dashboardWeekTitle, gridElement: dashboardWeekGrid, activities: dashboardCalendarItems }); }
function resultData(result) { return result.status === 'fulfilled' && !result.value.error ? result.value.data || [] : []; }
function failed(result) { return result.status === 'rejected' || (result.status === 'fulfilled' && result.value.error); }
async function loadDashboardTimeline() {
  const { start: windowStart, end: windowEnd } = occurrenceWindow();
  const [activityResult, occurrenceResult, eventResult] = await Promise.allSettled([
    supabaseClient.rpc('get_my_visible_activities'),
    supabaseClient.rpc('get_my_visible_activity_occurrences', { p_from: windowStart.toISOString(), p_to: windowEnd.toISOString() }),
    supabaseClient.rpc('get_my_visible_events')
  ]);
  visibleActivities = resultData(activityResult).filter((activity) => activity.status !== 'cancelled');
  visibleEvents = resultData(eventResult).filter((event) => event.status !== 'cancelled');
  const occurrences = failed(occurrenceResult) ? visibleActivities.filter((activity) => activity.starts_at || activity.due_at) : resultData(occurrenceResult);
  const { start: todayStart, end: todayEnd } = getTodayBounds();
  dashboardCalendarSection.hidden = false;
  dashboardCalendarItems = [...occurrences, ...visibleEvents]; renderDashboardCalendar();
  const today = [...occurrences.filter((item) => fallsOnToday(item, todayStart, todayEnd)), ...visibleEvents.filter((item) => fallsOnToday(item, todayStart, todayEnd))].sort((a, b) => compareItems(a, b, (item) => upcomingTime(item, todayStart)));
  const upcoming = [...occurrences.filter((item) => upcomingTime(item, todayEnd)), ...visibleEvents.filter((item) => upcomingTime(item, todayEnd))].sort((a, b) => compareItems(a, b, (item) => upcomingTime(item, todayEnd)));
  const todo = visibleActivities.filter((activity) => activity.status === 'open' && !activity.starts_at && !activity.due_at).sort((a, b) => compareItems(a, b, (item) => calendarUtils.toValidDate(item.created_at)));
  renderItems(sections.today, today, 5); renderItems(sections.upcoming, upcoming, 5); renderItems(sections.todo, todo, 5);
  if ((failed(activityResult) || failed(occurrenceResult)) && failed(eventResult)) { dashboardMessage.textContent = 'Non è stato possibile caricare impegni ed eventi. Riprova più tardi.'; dashboardCalendarSection.hidden = true; }
  else if (failed(occurrenceResult)) dashboardMessage.textContent = 'Le attività ricorrenti non sono disponibili al momento; gli altri impegni visibili sono mostrati.';
  else if (failed(eventResult)) dashboardMessage.textContent = 'Gli eventi non sono disponibili al momento; le attività visibili sono mostrate.';
  else dashboardMessage.textContent = '';
}
async function changeDashboardWeek(offset) { dashboardDisplayedWeek = new Date(dashboardDisplayedWeek); dashboardDisplayedWeek.setDate(dashboardDisplayedWeek.getDate() + (offset * 7)); await loadDashboardTimeline(); }
async function showCurrentWeek() { dashboardDisplayedWeek = calendarUtils.startOfWeek(new Date()); await loadDashboardTimeline(); }
async function loadPendingInvites() { try { const { data, error } = await supabaseClient.rpc('get_my_area_invites'); if (error) return; const pendingInvites = (data || []).filter((invite) => invite.status === 'pending'); if (!pendingInvites.length) { dashboardInvitesSection.hidden = true; return; } const count = pendingInvites.length; dashboardInvitesTitle.textContent = `Hai ${count} invit${count === 1 ? 'o' : 'i'} in attesa`; dashboardInvitesDescription.textContent = count === 1 ? 'Sei stato invitato a partecipare a un’Area.' : 'Hai nuovi inviti a partecipare ad alcune Aree.'; dashboardInvitesSection.hidden = false; } catch { dashboardInvitesSection.hidden = true; } }
async function initialiseDashboard() { const { data: sessionData } = await supabaseClient.auth.getSession(); if (!sessionData.session) { window.location.href = 'login.html'; return; } await Promise.all([loadDashboardTimeline(), loadPendingInvites()]); }
dashboardPreviousWeekButton.addEventListener('click', () => { void changeDashboardWeek(-1); });
dashboardNextWeekButton.addEventListener('click', () => { void changeDashboardWeek(1); });
dashboardCurrentWeekButton.addEventListener('click', () => { void showCurrentWeek(); });
renderDashboardCalendar(); initialiseDashboard();

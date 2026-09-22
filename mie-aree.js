const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const calendarUtils = window.FamilAreaCalendarUtils;
const dashboardMessage = document.getElementById('dashboard-message');
const dashboardTitle = document.getElementById('dashboard-title');
const dashboardCalendarSection = document.getElementById('dashboard-calendar-section');
const dashboardWeekTitle = document.getElementById('dashboard-week-title');
const dashboardWeekGrid = document.getElementById('dashboard-week-grid');
const dashboardPreviousWeekButton = document.getElementById('dashboard-previous-week');
const dashboardNextWeekButton = document.getElementById('dashboard-next-week');
const dashboardCurrentWeekButton = document.getElementById('dashboard-current-week');
const dashboardInvitesSection = document.getElementById('dashboard-invites-section');
const dashboardInvitesTitle = document.getElementById('dashboard-invites-title');
const dashboardInvitesDescription = document.getElementById('dashboard-invites-description');
const dashboardDeadlinesSection = document.getElementById('dashboard-deadlines-section');
const dashboardDeadlinesList = document.getElementById('dashboard-deadlines-list');
const sections = {
  today: { list: document.getElementById('today-list'), empty: document.getElementById('today-empty') },
  upcoming: { list: document.getElementById('upcoming-list'), empty: document.getElementById('upcoming-empty') },
  todo: { list: document.getElementById('todo-list'), empty: document.getElementById('todo-empty') }
};
const typeLabels = { task: 'Da fare', reminder: 'Promemoria', deadline: 'Scadenza', appointment: 'Appuntamento' };
const priorityLabels = { low: 'Bassa', normal: 'Normale', high: 'Alta' };
const statusLabels = { open: 'Aperta', completed: 'Completata', cancelled: 'Cancellata' };
let dashboardCalendarItems = [];
let dashboardDisplayedWeek = calendarUtils.startOfWeek(new Date());

function dayStart(value = new Date()) { return new Date(value.getFullYear(), value.getMonth(), value.getDate()); }
function weekBounds() { const start = calendarUtils.startOfWeek(dashboardDisplayedWeek); const end = new Date(start); end.setDate(end.getDate() + 7); return { start, end }; }
function dashboardWindow() {
  const today = dayStart();
  const { start: weekStart, end: weekEnd } = weekBounds();
  const start = weekStart < today ? weekStart : today;
  const thirtyDays = new Date(start); thirtyDays.setDate(thirtyDays.getDate() + 30);
  return { start, end: weekEnd > thirtyDays ? weekEnd : thirtyDays };
}
function isEvent(item) { return calendarUtils.itemType(item) === 'event'; }
function itemId(item) { return item.event_id || item.activity_id || item.deadline_id || ''; }
function datesForItem(item) {
  if (item.deadline_id) return [calendarUtils.toValidDate(item.occurs_on || item.occurrence_on)].filter(Boolean);
  if (isEvent(item)) return [calendarUtils.toValidDate(item.starts_at)].filter(Boolean);
  return [item.occurrence_starts_at, item.occurrence_ends_at, item.starts_at, item.due_at].map(calendarUtils.toValidDate).filter(Boolean);
}
function fallsWithin(item, start, end) { return datesForItem(item).some((date) => date >= start && date < end); }
function upcomingTime(item, after) { return datesForItem(item).filter((date) => date >= after).sort((a, b) => a - b)[0] || null; }
function compareItems(first, second, dateForItem) {
  const a = dateForItem(first); const b = dateForItem(second);
  if (a && b && a - b) return a - b;
  if (a) return -1;
  if (b) return 1;
  return String(itemId(first)).localeCompare(String(itemId(second)));
}
function normaliseItem(item, kind) {
  const occurrenceStart = item.occurrence_starts_at || item.starts_at || item.due_at;
  const occurrenceEnd = item.occurrence_ends_at || item.ends_at || item.due_at || occurrenceStart;
  if (kind === 'deadline') return { ...item, kind: 'deadline', occurs_on: item.occurs_on || item.occurrence_on, occurrence_on: item.occurrence_on || item.occurs_on, is_all_day: true, is_completed: Boolean(item.is_completed ?? item.completed) };
  return {
    ...item,
    kind,
    occurrence_starts_at: occurrenceStart,
    occurrence_ends_at: occurrenceEnd,
    starts_at: kind === 'event' ? occurrenceStart : item.starts_at,
    ends_at: kind === 'event' ? occurrenceEnd : item.ends_at,
    is_all_day: Boolean(item.is_all_day ?? item.all_day),
    area_name: item.area_name || (item.area_id ? 'Area condivisa' : 'Personale')
  };
}
function formatActivityDate(activity) {
  const start = calendarUtils.toValidDate(activity.occurrence_starts_at || activity.starts_at); const end = calendarUtils.toValidDate(activity.occurrence_ends_at || activity.due_at);
  if (!start && !end) return '';
  const dateFormatter = new Intl.DateTimeFormat('it-IT', { dateStyle: 'medium' });
  if (activity.is_all_day) return dateFormatter.format(start || end);
  const timeFormatter = new Intl.DateTimeFormat('it-IT', { hour: '2-digit', minute: '2-digit' }); const date = start || end;
  return `${dateFormatter.format(date)}, ${timeFormatter.format(start || end)}${start && end && start.getTime() !== end.getTime() ? ` – ${timeFormatter.format(end)}` : ''}`;
}
function createBadge(text, className) { const badge = document.createElement('span'); badge.className = className; badge.textContent = text; return badge; }
function createActivityCard(activity) {
  const card = document.createElement('article'); card.className = 'activity-card';
  const title = document.createElement('h3'); title.className = 'activity-card-title'; title.textContent = activity.title;
  const area = document.createElement('p'); area.className = 'activity-card-area'; area.textContent = activity.area_name;
  const meta = document.createElement('div'); meta.className = 'activity-card-meta';
  meta.append(createBadge(typeLabels[activity.activity_type] || activity.activity_type || 'Attività', 'activity-type-badge'), createBadge(`Priorità: ${priorityLabels[activity.priority] || activity.priority || 'Normale'}`, `activity-priority-badge activity-priority-${activity.priority || 'normal'}`), createBadge(`Stato: ${statusLabels[activity.status] || activity.status}`, `activity-status-badge activity-status-${activity.status}`));
  const date = document.createElement('p'); date.className = 'activity-card-due'; date.textContent = formatActivityDate(activity); date.hidden = !date.textContent;
  const link = document.createElement('a'); link.className = 'btn activity-open-link'; link.textContent = 'Apri'; link.href = calendarUtils.itemLink(activity);
  card.append(title, area, meta, date, link); return card;
}
function createEventCard(event) {
  const card = document.createElement('article'); card.className = 'activity-card dashboard-event-card';
  const title = document.createElement('h3'); title.className = 'activity-card-title'; title.textContent = event.title;
  const area = document.createElement('p'); area.className = 'activity-card-area'; area.textContent = event.area_name;
  const meta = document.createElement('div'); meta.className = 'activity-card-meta'; meta.appendChild(createBadge('Evento', 'event-badge'));
  const date = document.createElement('p'); date.className = 'activity-card-due'; date.textContent = formatActivityDate(event);
  const location = document.createElement('p'); location.className = 'activity-card-location'; location.textContent = event.location ? `Luogo: ${event.location}` : ''; location.hidden = !event.location;
  const link = document.createElement('a'); link.className = 'btn activity-open-link'; link.textContent = 'Apri'; link.href = calendarUtils.itemLink(event);
  card.append(title, area, meta, date, location, link); return card;
}
function deadlineUrgency(occurrenceOn) {
  const due = calendarUtils.toValidDate(occurrenceOn); if (!due) return '';
  const days = Math.round((due - dayStart()) / 86400000);
  if (days < 0) return `Scaduta da ${Math.abs(days)} ${Math.abs(days) === 1 ? 'giorno' : 'giorni'}`;
  if (days === 0) return 'Scade oggi'; if (days === 1) return 'Scade domani'; return `Scade tra ${days} giorni`;
}
function createDeadlineCard(deadline) {
  const link = document.createElement('a'); link.className = 'activity-card dashboard-deadline-card'; link.href = `scadenza.html?deadline_id=${encodeURIComponent(deadline.deadline_id)}`;
  const title = document.createElement('h3'); title.className = 'activity-card-title'; title.textContent = deadline.title;
  const date = document.createElement('p'); date.className = 'activity-card-due'; date.textContent = calendarUtils.toValidDate(deadline.occurrence_on)?.toLocaleDateString('it-IT', { dateStyle: 'medium' }) || '';
  const urgency = document.createElement('p'); urgency.className = 'dashboard-deadline-urgency'; urgency.textContent = deadlineUrgency(deadline.occurrence_on);
  link.append(title, date, urgency); return link;
}
function renderItems(section, items, limit) { section.list.replaceChildren(); section.empty.hidden = items.length > 0; items.slice(0, limit).forEach((item) => section.list.appendChild(isEvent(item) ? createEventCard(item) : createActivityCard(item))); }
function renderDashboardCalendar() { calendarUtils.renderWeekCalendar({ weekStart: dashboardDisplayedWeek, titleElement: dashboardWeekTitle, gridElement: dashboardWeekGrid, activities: dashboardCalendarItems }); }
function renderDeadlines(deadlines) { dashboardDeadlinesList.replaceChildren(); deadlines.forEach((deadline) => dashboardDeadlinesList.appendChild(createDeadlineCard(deadline))); dashboardDeadlinesSection.hidden = deadlines.length === 0; }
async function loadDashboardTimeline() {
  const { start, end } = dashboardWindow();
  const { data, error } = await supabaseClient.rpc('get_dashboard', { p_from: start.toISOString(), p_to: end.toISOString() });
  if (error || !data) {
    dashboardMessage.textContent = 'Non è stato possibile caricare la Dashboard. Riprova più tardi.';
    dashboardCalendarSection.hidden = true;
    renderItems(sections.today, [], 5); renderItems(sections.upcoming, [], 5); renderItems(sections.todo, [], 5); renderDeadlines([]);
    return;
  }
  const activities = (data.activities || []).map((item) => normaliseItem(item, 'activity'));
  const events = (data.events || []).map((item) => normaliseItem(item, 'event'));
  const deadlines = (data.deadlines || []).map((item) => normaliseItem(item, 'deadline')).sort((a, b) => calendarUtils.toValidDate(a.occurrence_on) - calendarUtils.toValidDate(b.occurrence_on));
  const todos = (data.todos || []).map((item) => normaliseItem(item, 'activity'));
  const todayStart = dayStart(); const todayEnd = new Date(todayStart); todayEnd.setDate(todayEnd.getDate() + 1);
  dashboardCalendarItems = [...activities, ...events, ...deadlines];
  dashboardCalendarSection.hidden = false;
  renderDashboardCalendar();
  const scheduled = [...activities, ...events];
  const today = scheduled.filter((item) => fallsWithin(item, todayStart, todayEnd)).sort((a, b) => compareItems(a, b, (item) => upcomingTime(item, todayStart)));
  const upcoming = scheduled.filter((item) => upcomingTime(item, todayEnd)).sort((a, b) => compareItems(a, b, (item) => upcomingTime(item, todayEnd)));
  renderItems(sections.today, today, 5); renderItems(sections.upcoming, upcoming, 5); renderItems(sections.todo, todos, 5); renderDeadlines(deadlines);
  dashboardMessage.textContent = '';
}
async function changeDashboardWeek(offset) { dashboardDisplayedWeek = new Date(dashboardDisplayedWeek); dashboardDisplayedWeek.setDate(dashboardDisplayedWeek.getDate() + (offset * 7)); await loadDashboardTimeline(); }
async function showCurrentWeek() { dashboardDisplayedWeek = calendarUtils.startOfWeek(new Date()); await loadDashboardTimeline(); }
async function loadPendingInvites(account) {
  if (account?.account_type !== 'personal') { dashboardInvitesSection.hidden = true; return; }
  const { data, error } = await supabaseClient.rpc('get_my_area_invites');
  if (error) { dashboardInvitesSection.hidden = true; return; }
  const pendingInvites = (data || []).filter((invite) => invite.status === 'pending');
  if (!pendingInvites.length) { dashboardInvitesSection.hidden = true; return; }
  const count = pendingInvites.length;
  dashboardInvitesTitle.textContent = `Hai ${count} invit${count === 1 ? 'o' : 'i'} in attesa`;
  dashboardInvitesDescription.textContent = count === 1 ? 'Sei stato invitato a partecipare a un’Area.' : 'Hai nuovi inviti a partecipare ad alcune Aree.';
  dashboardInvitesSection.hidden = false;
}
async function initialiseDashboard() {
  const { data } = await supabaseClient.auth.getSession();
  if (!data?.session) { window.location.href = 'login.html'; return; }
  const account = window.FamilAreaCurrentAccount ? await window.FamilAreaCurrentAccount : null;
  dashboardTitle.textContent = account?.account_type === 'organization' ? 'Dashboard' : 'La mia Dashboard';
  await Promise.all([loadDashboardTimeline(), loadPendingInvites(account)]);
}
dashboardPreviousWeekButton.addEventListener('click', () => { void changeDashboardWeek(-1); });
dashboardNextWeekButton.addEventListener('click', () => { void changeDashboardWeek(1); });
dashboardCurrentWeekButton.addEventListener('click', () => { void showCurrentWeek(); });
renderDashboardCalendar();
initialiseDashboard().catch(() => { dashboardMessage.textContent = 'Non è stato possibile inizializzare la Dashboard.'; });

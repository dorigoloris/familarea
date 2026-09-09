const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const calendarUtils = window.FamilAreaCalendarUtils;
const calendarMessage = document.getElementById('calendar-message');
const calendarContent = document.getElementById('calendar-content');
const monthTitle = document.getElementById('month-title');
const calendarGrid = document.getElementById('calendar-grid');
const monthCalendar = document.getElementById('month-calendar');
const weekCalendar = document.getElementById('week-calendar');
const previousMonthButton = document.getElementById('previous-month');
const nextMonthButton = document.getElementById('next-month');
const monthViewButton = document.getElementById('month-view');
const weekViewButton = document.getElementById('week-view');
const todayCalendarButton = document.getElementById('today-calendar');
const printToolbar = document.querySelector('.calendar-print-toolbar');
const printCalendarButton = document.getElementById('print-calendar');
const printMonthTitle = document.getElementById('print-month-title');
const undatedList = document.getElementById('undated-list');
const undatedEmpty = document.getElementById('undated-empty');
const typeLabels = { task: 'Da fare', reminder: 'Promemoria', deadline: 'Scadenza', appointment: 'Appuntamento' };
const priorityLabels = { low: 'Bassa', normal: 'Normale', high: 'Alta' };
let visibleActivities = [];
let visibleActivityOccurrences = [];
let visibleEvents = [];
let visibleBirthdays = [];
let visibleCalendarItems = [];
let displayedMonth = new Date(new Date().getFullYear(), new Date().getMonth(), 1);
let displayedWeek = calendarUtils.startOfWeek(new Date());
let activeView = 'month';
let printModeStyle = null;

function fullName(contact) { return `${contact.first_name || ''} ${contact.last_name || ''}`.trim() || 'Contatto'; }
function birthdayCalendarItems(birthdays) { return birthdays.map((birthday) => ({ birthday_contact_id: birthday.contact_id, title: `Compleanno di ${fullName(birthday)}`, occurs_on: birthday.occurs_on, is_all_day: true, status: 'open' })); }
function monthBounds() {
  const start = new Date(displayedMonth.getFullYear(), displayedMonth.getMonth(), 1);
  const end = new Date(displayedMonth.getFullYear(), displayedMonth.getMonth() + 1, 1);
  return { start, end };
}
function weekBounds() {
  const start = calendarUtils.startOfWeek(displayedWeek);
  const end = new Date(start); end.setDate(end.getDate() + 7);
  return { start, end };
}
function updateVisibleCalendarItems() { visibleCalendarItems = [...visibleActivityOccurrences, ...visibleEvents, ...visibleBirthdays]; }
function createUndatedActivity(activity) {
  const card = document.createElement('article'); card.className = 'activity-card';
  const title = document.createElement('h3'); title.className = 'activity-card-title'; title.textContent = activity.title;
  const area = document.createElement('p'); area.className = 'activity-card-area'; area.textContent = activity.area_name;
  const meta = document.createElement('div'); meta.className = 'activity-card-meta';
  [["activity-type-badge", typeLabels[activity.activity_type] || activity.activity_type], [`activity-priority-badge activity-priority-${activity.priority}`, `Priorità: ${priorityLabels[activity.priority] || activity.priority}`]].forEach(([className, text]) => { const badge = document.createElement('span'); badge.className = className; badge.textContent = text; meta.appendChild(badge); });
  const link = document.createElement('a'); link.className = 'btn activity-open-link'; link.href = calendarUtils.itemLink(activity); link.textContent = 'Apri'; card.append(title, area, meta, link); return card;
}
function renderUndatedActivities() {
  const undatedActivities = visibleActivities.filter((activity) => activity.status === 'open' && !activity.starts_at && !activity.due_at);
  undatedList.replaceChildren(); undatedEmpty.hidden = undatedActivities.length > 0; undatedActivities.forEach((activity) => undatedList.appendChild(createUndatedActivity(activity)));
}
function renderMonth() {
  calendarUtils.renderMonthCalendar({ month: displayedMonth, titleElement: monthTitle, gridElement: calendarGrid, activities: visibleCalendarItems });
  printMonthTitle.textContent = monthTitle.textContent;
}
function renderWeek() {
  calendarUtils.renderWeekAgenda({ weekStart: displayedWeek, titleElement: monthTitle, gridElement: weekCalendar, activities: visibleCalendarItems });
  printMonthTitle.textContent = monthTitle.textContent;
}
function updateViewUi() {
  const isWeek = activeView === 'week';
  monthCalendar.hidden = isWeek;
  weekCalendar.hidden = !isWeek;
  undatedList.closest('#undated-section').hidden = isWeek;
  printToolbar.hidden = false;
  monthViewButton.classList.toggle('is-active', !isWeek);
  weekViewButton.classList.toggle('is-active', isWeek);
  monthViewButton.setAttribute('aria-pressed', String(!isWeek));
  weekViewButton.setAttribute('aria-pressed', String(isWeek));
  previousMonthButton.setAttribute('aria-label', isWeek ? 'Settimana precedente' : 'Mese precedente');
  nextMonthButton.setAttribute('aria-label', isWeek ? 'Settimana successiva' : 'Mese successivo');
  printCalendarButton.setAttribute('aria-label', isWeek ? 'Stampa la settimana visualizzata' : 'Stampa il mese visualizzato');
}
function resultData(result) { return result.status === 'fulfilled' && !result.value.error ? result.value.data || [] : []; }
function failed(result) { return result.status === 'rejected' || (result.status === 'fulfilled' && result.value.error); }
function updateMessage(activityFailed, eventFailed, birthdayFailed) {
  if (activityFailed && eventFailed) return 'Non è stato possibile caricare il calendario. Riprova più tardi.';
  if (activityFailed) return 'Le attività ricorrenti non sono disponibili al momento; eventi e compleanni visibili sono mostrati.';
  if (eventFailed) return 'Gli eventi non sono disponibili al momento; le attività visibili sono mostrate.';
  if (birthdayFailed) return 'I compleanni non sono disponibili al momento; attività ed eventi visibili sono mostrati.';
  return '';
}
async function loadMonthSources() {
  const { start, end } = monthBounds();
  const [occurrenceResult, birthdayResult] = await Promise.allSettled([
    supabaseClient.rpc('get_my_visible_activity_occurrences', { p_from: start.toISOString(), p_to: end.toISOString() }),
    supabaseClient.rpc('get_my_contact_birthdays', { p_year: displayedMonth.getFullYear() })
  ]);
  const occurrenceFailed = failed(occurrenceResult);
  visibleActivityOccurrences = occurrenceFailed
    ? visibleActivities.filter((activity) => activity.status !== 'cancelled' && (activity.starts_at || activity.due_at))
    : resultData(occurrenceResult);
  visibleBirthdays = failed(birthdayResult) ? [] : birthdayCalendarItems(resultData(birthdayResult));
  updateVisibleCalendarItems();
  return { occurrenceFailed, birthdayFailed: failed(birthdayResult) };
}
async function loadWeekSources() {
  const { start, end } = weekBounds();
  const years = [...new Set([start.getFullYear(), new Date(end.getTime() - 1).getFullYear()])];
  const results = await Promise.allSettled([
    supabaseClient.rpc('get_my_visible_activity_occurrences', { p_from: start.toISOString(), p_to: end.toISOString() }),
    ...years.map((year) => supabaseClient.rpc('get_my_contact_birthdays', { p_year: year }))
  ]);
  const occurrenceFailed = failed(results[0]);
  visibleActivityOccurrences = occurrenceFailed
    ? visibleActivities.filter((activity) => activity.status !== 'cancelled' && (activity.starts_at || activity.due_at))
    : resultData(results[0]);
  visibleBirthdays = results.slice(1).flatMap((result) => failed(result) ? [] : birthdayCalendarItems(resultData(result)));
  updateVisibleCalendarItems();
  return { occurrenceFailed, birthdayFailed: results.slice(1).some(failed) };
}
async function changePeriod(offset) {
  if (activeView === 'week') {
    displayedWeek = new Date(displayedWeek); displayedWeek.setDate(displayedWeek.getDate() + offset * 7);
    const results = await loadWeekSources(); renderCurrentView(); calendarMessage.textContent = updateMessage(results.occurrenceFailed, false, results.birthdayFailed); return;
  }
  displayedMonth = new Date(displayedMonth.getFullYear(), displayedMonth.getMonth() + offset, 1);
  const results = await loadMonthSources(); renderCurrentView(); calendarMessage.textContent = updateMessage(results.occurrenceFailed, false, results.birthdayFailed);
}
function renderCurrentView() { updateViewUi(); if (activeView === 'week') renderWeek(); else renderMonth(); }
async function setView(view) {
  if (activeView === view) return;
  activeView = view;
  const results = activeView === 'week' ? await loadWeekSources() : await loadMonthSources();
  renderCurrentView(); calendarMessage.textContent = updateMessage(results.occurrenceFailed, false, results.birthdayFailed);
}
async function goToToday() {
  const now = new Date();
  if (activeView === 'week') displayedWeek = calendarUtils.startOfWeek(now);
  else displayedMonth = new Date(now.getFullYear(), now.getMonth(), 1);
  const results = activeView === 'week' ? await loadWeekSources() : await loadMonthSources();
  renderCurrentView(); calendarMessage.textContent = updateMessage(results.occurrenceFailed, false, results.birthdayFailed);
}
async function loadCalendar() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }
  const [activityResult, eventResult] = await Promise.allSettled([supabaseClient.rpc('get_my_visible_activities'), supabaseClient.rpc('get_my_visible_events')]);
  visibleActivities = resultData(activityResult).filter((activity) => activity.status !== 'cancelled');
  visibleEvents = resultData(eventResult).filter((event) => event.status !== 'cancelled');
  const monthResults = await loadMonthSources();
  const activityFailed = failed(activityResult) || monthResults.occurrenceFailed;
  const eventFailed = failed(eventResult);
  if (activityFailed && eventFailed) { calendarContent.hidden = true; calendarMessage.textContent = updateMessage(true, true, monthResults.birthdayFailed); return; }
  renderUndatedActivities(); renderCurrentView(); calendarContent.hidden = false; calendarMessage.textContent = updateMessage(activityFailed, eventFailed, monthResults.birthdayFailed);
}
previousMonthButton.addEventListener('click', () => { void changePeriod(-1); });
nextMonthButton.addEventListener('click', () => { void changePeriod(1); });
monthViewButton.addEventListener('click', () => { void setView('month'); });
weekViewButton.addEventListener('click', () => { void setView('week'); });
todayCalendarButton.addEventListener('click', () => { void goToToday(); });
function clearPrintMode() {
  document.body.classList.remove('calendar-print-month', 'calendar-print-week');
  if (printModeStyle) { printModeStyle.remove(); printModeStyle = null; }
}
function printCalendar() {
  clearPrintMode();
  const isWeek = activeView === 'week';
  document.body.classList.add(isWeek ? 'calendar-print-week' : 'calendar-print-month');
  printModeStyle = document.createElement('style');
  printModeStyle.textContent = `@page { size: A4 ${isWeek ? 'portrait' : 'landscape'}; margin: ${isWeek ? '9mm' : '10mm'}; }`;
  document.head.appendChild(printModeStyle);
  window.print();
}
window.addEventListener('afterprint', clearPrintMode);
printCalendarButton.addEventListener('click', printCalendar);
loadCalendar();

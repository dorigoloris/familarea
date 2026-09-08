const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const calendarUtils = window.FamilAreaCalendarUtils;

const calendarMessage = document.getElementById('calendar-message');
const calendarContent = document.getElementById('calendar-content');
const monthTitle = document.getElementById('month-title');
const calendarGrid = document.getElementById('calendar-grid');
const previousMonthButton = document.getElementById('previous-month');
const nextMonthButton = document.getElementById('next-month');
const undatedList = document.getElementById('undated-list');
const undatedEmpty = document.getElementById('undated-empty');

const typeLabels = { task: 'Da fare', reminder: 'Promemoria', deadline: 'Scadenza', appointment: 'Appuntamento' };
const priorityLabels = { low: 'Bassa', normal: 'Normale', high: 'Alta' };
let visibleActivities = [];
let visibleEvents = [];
let visibleBirthdays = [];
let visibleCalendarItems = [];
let displayedMonth = new Date(new Date().getFullYear(), new Date().getMonth(), 1);

function fullName(contact) {
  return `${contact.first_name || ''} ${contact.last_name || ''}`.trim() || 'Contatto';
}

function birthdayCalendarItems(birthdays) {
  return birthdays.map((birthday) => ({
    birthday_contact_id: birthday.contact_id,
    title: `Compleanno di ${fullName(birthday)}`,
    occurs_on: birthday.occurs_on,
    is_all_day: true,
    status: 'open'
  }));
}

function updateVisibleCalendarItems() {
  visibleCalendarItems = [...visibleActivities, ...visibleEvents, ...visibleBirthdays];
}

function createUndatedActivity(activity) {
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
  [["activity-type-badge", typeLabels[activity.activity_type] || activity.activity_type], [`activity-priority-badge activity-priority-${activity.priority}`, `Priorità: ${priorityLabels[activity.priority] || activity.priority}`]].forEach(([className, text]) => {
    const badge = document.createElement('span');
    badge.className = className;
    badge.textContent = text;
    meta.appendChild(badge);
  });
  const link = document.createElement('a');
  link.className = 'btn activity-open-link';
  link.href = calendarUtils.itemLink(activity);
  link.textContent = 'Apri';
  card.append(title, area, meta, link);
  return card;
}

function renderUndatedActivities() {
  const undatedActivities = visibleActivities.filter((activity) => activity.status === 'open' && !activity.starts_at && !activity.due_at);
  undatedList.replaceChildren();
  undatedEmpty.hidden = undatedActivities.length > 0;
  undatedActivities.forEach((activity) => undatedList.appendChild(createUndatedActivity(activity)));
}

function renderMonth() {
  calendarUtils.renderMonthCalendar({
    month: displayedMonth,
    titleElement: monthTitle,
    gridElement: calendarGrid,
    activities: visibleCalendarItems
  });
}

async function loadBirthdaysForDisplayedYear() {
  const { data, error } = await supabaseClient.rpc('get_my_contact_birthdays', {
    p_year: displayedMonth.getFullYear()
  });
  visibleBirthdays = error ? [] : birthdayCalendarItems(data || []);
  updateVisibleCalendarItems();
  renderMonth();
  if (error) {
    calendarMessage.textContent = 'I compleanni non sono disponibili al momento; attività ed eventi visibili sono mostrati.';
  } else {
    calendarMessage.textContent = '';
  }
}

async function changeMonth(offset) {
  displayedMonth = new Date(displayedMonth.getFullYear(), displayedMonth.getMonth() + offset, 1);
  await loadBirthdaysForDisplayedYear();
}

function loadErrorMessage(activityFailed, eventFailed, birthdayFailed) {
  if (activityFailed && eventFailed) {
    return 'Non è stato possibile caricare il calendario. Riprova più tardi.';
  }
  if (activityFailed) return 'Le attività non sono disponibili al momento; gli eventi visibili sono mostrati.';
  if (eventFailed) return 'Gli eventi non sono disponibili al momento; le attività visibili sono mostrate.';
  if (birthdayFailed) return 'I compleanni non sono disponibili al momento; attività ed eventi visibili sono mostrati.';
  return '';
}

async function loadCalendar() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }

  const [activityResult, eventResult, birthdayResult] = await Promise.allSettled([
    supabaseClient.rpc('get_my_visible_activities'),
    supabaseClient.rpc('get_my_visible_events'),
    supabaseClient.rpc('get_my_contact_birthdays', { p_year: displayedMonth.getFullYear() })
  ]);
  const activities = activityResult.status === 'fulfilled' && !activityResult.value.error
    ? activityResult.value.data || []
    : [];
  const events = eventResult.status === 'fulfilled' && !eventResult.value.error
    ? eventResult.value.data || []
    : [];
  const birthdays = birthdayResult.status === 'fulfilled' && !birthdayResult.value.error
    ? birthdayResult.value.data || []
    : [];
  const activityFailed = activityResult.status === 'rejected' || (activityResult.status === 'fulfilled' && activityResult.value.error);
  const eventFailed = eventResult.status === 'rejected' || (eventResult.status === 'fulfilled' && eventResult.value.error);
  const birthdayFailed = birthdayResult.status === 'rejected' || (birthdayResult.status === 'fulfilled' && birthdayResult.value.error);

  visibleActivities = activities.filter((activity) => activity.status !== 'cancelled');
  visibleEvents = events.filter((event) => event.status !== 'cancelled');
  visibleBirthdays = birthdayCalendarItems(birthdays);
  updateVisibleCalendarItems();
  const errorText = loadErrorMessage(activityFailed, eventFailed, birthdayFailed);

  if (activityFailed && eventFailed) {
    calendarContent.hidden = true;
    calendarMessage.textContent = errorText;
    return;
  }

  renderMonth();
  renderUndatedActivities();
  calendarContent.hidden = false;
  calendarMessage.textContent = errorText;
}

previousMonthButton.addEventListener('click', () => { changeMonth(-1); });
nextMonthButton.addEventListener('click', () => { changeMonth(1); });
loadCalendar();

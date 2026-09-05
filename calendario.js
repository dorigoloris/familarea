const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

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
const statusLabels = { open: 'Aperta', completed: 'Completata' };

let visibleActivities = [];
let displayedMonth = new Date(new Date().getFullYear(), new Date().getMonth(), 1);

function toValidDate(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

function placementDate(activity) {
  return toValidDate(activity.starts_at) || toValidDate(activity.due_at);
}

function sameLocalDay(left, right) {
  return left.getFullYear() === right.getFullYear()
    && left.getMonth() === right.getMonth()
    && left.getDate() === right.getDate();
}

function activityLink(activity) {
  return `attivita.html?area_id=${encodeURIComponent(activity.area_id)}&activity_id=${encodeURIComponent(activity.activity_id)}`;
}

function formatTime(activity) {
  const date = placementDate(activity);
  if (activity.is_all_day || !date) return '';
  return new Intl.DateTimeFormat('it-IT', { hour: '2-digit', minute: '2-digit' }).format(date);
}

function createCalendarActivity(activity) {
  const link = document.createElement('a');
  link.className = `calendar-activity ${activity.status === 'completed' ? 'calendar-activity-completed' : ''}`;
  link.href = activityLink(activity);
  link.title = `${activity.title} — ${activity.area_name}`;

  const title = document.createElement('span');
  title.className = 'calendar-activity-title';
  title.textContent = activity.title;
  const area = document.createElement('span');
  area.className = 'calendar-activity-area';
  area.textContent = activity.area_name;
  link.append(title, area);

  const time = formatTime(activity);
  if (time || activity.status === 'completed') {
    const details = document.createElement('span');
    details.className = 'calendar-activity-details';
    details.textContent = [time, activity.status === 'completed' ? statusLabels.completed : ''].filter(Boolean).join(' · ');
    link.appendChild(details);
  }
  return link;
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
  [['activity-type-badge', typeLabels[activity.activity_type] || activity.activity_type], [`activity-priority-badge activity-priority-${activity.priority}`, `Priorità: ${priorityLabels[activity.priority] || activity.priority}`]].forEach(([className, text]) => {
    const badge = document.createElement('span');
    badge.className = className;
    badge.textContent = text;
    meta.appendChild(badge);
  });
  const link = document.createElement('a');
  link.className = 'btn activity-open-link';
  link.href = activityLink(activity);
  link.textContent = 'Apri';
  card.append(title, area, meta, link);
  return card;
}

function renderUndatedActivities() {
  const undatedActivities = visibleActivities.filter((activity) => {
    return activity.status === 'open' && !activity.starts_at && !activity.due_at;
  });
  undatedList.replaceChildren();
  undatedEmpty.hidden = undatedActivities.length > 0;
  undatedActivities.forEach((activity) => undatedList.appendChild(createUndatedActivity(activity)));
}

function renderMonth() {
  const year = displayedMonth.getFullYear();
  const month = displayedMonth.getMonth();
  monthTitle.textContent = new Intl.DateTimeFormat('it-IT', { month: 'long', year: 'numeric' }).format(displayedMonth);
  calendarGrid.replaceChildren();

  const firstDay = new Date(year, month, 1);
  const leadingDays = (firstDay.getDay() + 6) % 7;
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  const today = new Date();

  for (let index = 0; index < leadingDays; index += 1) {
    const blank = document.createElement('div');
    blank.className = 'calendar-day calendar-day-empty';
    blank.setAttribute('aria-hidden', 'true');
    calendarGrid.appendChild(blank);
  }

  for (let day = 1; day <= daysInMonth; day += 1) {
    const cellDate = new Date(year, month, day);
    const cell = document.createElement('article');
    cell.className = 'calendar-day';
    if (sameLocalDay(cellDate, today)) cell.classList.add('calendar-day-today');

    const number = document.createElement('h3');
    number.className = 'calendar-day-number';
    number.textContent = String(day);
    cell.appendChild(number);

    const activities = visibleActivities.filter((activity) => {
      const date = placementDate(activity);
      return date && date.getFullYear() === year && date.getMonth() === month && date.getDate() === day;
    });
    activities.sort((first, second) => placementDate(first) - placementDate(second));

    const shownActivities = activities.slice(0, 2);
    shownActivities.forEach((activity) => cell.appendChild(createCalendarActivity(activity)));

    if (activities.length > shownActivities.length) {
      const extraId = `calendar-extra-${year}-${month}-${day}`;
      const extra = document.createElement('div');
      extra.id = extraId;
      extra.className = 'calendar-day-extra';
      extra.hidden = true;
      activities.slice(2).forEach((activity) => extra.appendChild(createCalendarActivity(activity)));

      const toggle = document.createElement('button');
      toggle.type = 'button';
      toggle.className = 'calendar-more-button';
      toggle.textContent = `+${activities.length - shownActivities.length} altre`;
      toggle.setAttribute('aria-expanded', 'false');
      toggle.setAttribute('aria-controls', extraId);
      toggle.addEventListener('click', () => {
        const expanded = toggle.getAttribute('aria-expanded') === 'true';
        extra.hidden = expanded;
        toggle.setAttribute('aria-expanded', String(!expanded));
        toggle.textContent = expanded ? `+${activities.length - shownActivities.length} altre` : 'Mostra meno';
      });
      cell.append(toggle, extra);
    }
    calendarGrid.appendChild(cell);
  }
}

function changeMonth(offset) {
  displayedMonth = new Date(displayedMonth.getFullYear(), displayedMonth.getMonth() + offset, 1);
  renderMonth();
}

async function loadCalendar() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }

  try {
    const { data, error } = await supabaseClient.rpc('get_my_visible_activities');
    if (error) throw error;
    visibleActivities = (data || []).filter((activity) => activity.status !== 'cancelled');
    renderMonth();
    renderUndatedActivities();
    calendarContent.hidden = false;
    calendarMessage.textContent = '';
  } catch (error) {
    console.error('Errore nel caricamento del Calendario:', error);
    calendarContent.hidden = true;
    calendarMessage.textContent = 'Non è stato possibile caricare il calendario. Riprova più tardi.';
  }
}

previousMonthButton.addEventListener('click', () => changeMonth(-1));
nextMonthButton.addEventListener('click', () => changeMonth(1));
loadCalendar();

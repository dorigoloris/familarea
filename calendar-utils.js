(function attachCalendarUtils(global) {
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
      details.textContent = [time, activity.status === 'completed' ? 'Completata' : ''].filter(Boolean).join(' · ');
      link.appendChild(details);
    }
    return link;
  }

  function renderMonthCalendar({ month, titleElement, gridElement, activities }) {
    const year = month.getFullYear();
    const monthIndex = month.getMonth();
    titleElement.textContent = new Intl.DateTimeFormat('it-IT', { month: 'long', year: 'numeric' }).format(month);
    const firstDay = new Date(year, monthIndex, 1);
    const leadingDays = (firstDay.getDay() + 6) % 7;
    const daysInMonth = new Date(year, monthIndex + 1, 0).getDate();
    const today = new Date();
    const calendarActivities = Array.isArray(activities) ? activities : [];
    const cells = document.createDocumentFragment();

    for (let index = 0; index < leadingDays; index += 1) {
      const blank = document.createElement('div');
      blank.className = 'calendar-day calendar-day-empty';
      blank.setAttribute('aria-hidden', 'true');
      cells.appendChild(blank);
    }

    for (let day = 1; day <= daysInMonth; day += 1) {
      const cellDate = new Date(year, monthIndex, day);
      const cell = document.createElement('article');
      cell.className = 'calendar-day';
      if (sameLocalDay(cellDate, today)) cell.classList.add('calendar-day-today');

      const number = document.createElement('h3');
      number.className = 'calendar-day-number';
      number.textContent = String(day);
      cell.appendChild(number);

      const dayActivities = calendarActivities
        .filter((activity) => {
          const date = placementDate(activity);
          return date && date.getFullYear() === year && date.getMonth() === monthIndex && date.getDate() === day;
        })
        .sort((first, second) => placementDate(first) - placementDate(second));
      const shownActivities = dayActivities.slice(0, 2);
      shownActivities.forEach((activity) => cell.appendChild(createCalendarActivity(activity)));

      if (dayActivities.length > shownActivities.length) {
        const extraId = `calendar-extra-${gridElement.id}-${year}-${monthIndex}-${day}`;
        const extra = document.createElement('div');
        extra.id = extraId;
        extra.className = 'calendar-day-extra';
        extra.hidden = true;
        dayActivities.slice(2).forEach((activity) => extra.appendChild(createCalendarActivity(activity)));

        const toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.className = 'calendar-more-button';
        toggle.textContent = `+${dayActivities.length - shownActivities.length} altre`;
        toggle.setAttribute('aria-expanded', 'false');
        toggle.setAttribute('aria-controls', extraId);
        toggle.addEventListener('click', () => {
          const expanded = toggle.getAttribute('aria-expanded') === 'true';
          extra.hidden = expanded;
          toggle.setAttribute('aria-expanded', String(!expanded));
          toggle.textContent = expanded ? `+${dayActivities.length - shownActivities.length} altre` : 'Mostra meno';
        });
        cell.append(toggle, extra);
      }
      cells.appendChild(cell);
    }

    const totalCells = leadingDays + daysInMonth;
    const trailingDays = (7 - (totalCells % 7)) % 7;
    for (let index = 0; index < trailingDays; index += 1) {
      const blank = document.createElement('div');
      blank.className = 'calendar-day calendar-day-empty';
      blank.setAttribute('aria-hidden', 'true');
      cells.appendChild(blank);
    }

    gridElement.replaceChildren(cells);
  }

  global.FamilAreaCalendarUtils = { activityLink, placementDate, renderMonthCalendar, toValidDate };
}(window));

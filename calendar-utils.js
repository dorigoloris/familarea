(function attachCalendarUtils(global) {
  function toValidDate(value) {
    if (!value) return null;
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? null : date;
  }

  function itemType(item) {
    return item.event_id ? 'event' : 'activity';
  }

  function placementDate(item) {
    if (itemType(item) === 'event') return toValidDate(item.starts_at);
    return toValidDate(item.starts_at) || toValidDate(item.due_at);
  }

  function sameLocalDay(left, right) {
    return left.getFullYear() === right.getFullYear()
      && left.getMonth() === right.getMonth()
      && left.getDate() === right.getDate();
  }

  function itemLink(item) {
    if (itemType(item) === 'event') {
      return `evento.html?area_id=${encodeURIComponent(item.area_id)}&event_id=${encodeURIComponent(item.event_id)}`;
    }
    return `attivita.html?area_id=${encodeURIComponent(item.area_id)}&activity_id=${encodeURIComponent(item.activity_id)}`;
  }

  function formatTime(item) {
    const start = placementDate(item);
    if (item.is_all_day || !start) return '';
    const formatter = new Intl.DateTimeFormat('it-IT', { hour: '2-digit', minute: '2-digit' });
    if (itemType(item) !== 'event') return formatter.format(start);
    const end = toValidDate(item.ends_at);
    return end ? `${formatter.format(start)} – ${formatter.format(end)}` : formatter.format(start);
  }

  function createCalendarItem(item) {
    const type = itemType(item);
    const link = document.createElement('a');
    link.className = `calendar-activity${type === 'event' ? ' calendar-event' : ''}${item.status === 'completed' ? ' calendar-activity-completed' : ''}`;
    link.href = itemLink(item);
    link.title = `${item.title} — ${item.area_name}`;

    const title = document.createElement('span');
    title.className = 'calendar-activity-title';
    title.textContent = item.title;
    const area = document.createElement('span');
    area.className = 'calendar-activity-area';
    area.textContent = item.area_name;
    link.append(title, area);

    if (type === 'event') {
      const badge = document.createElement('span');
      badge.className = 'calendar-item-kind';
      badge.textContent = 'Evento';
      link.appendChild(badge);
    }

    const time = formatTime(item);
    if (time || item.status === 'completed') {
      const details = document.createElement('span');
      details.className = 'calendar-activity-details';
      details.textContent = [time, item.status === 'completed' ? 'Completata' : ''].filter(Boolean).join(' · ');
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
    const calendarItems = Array.isArray(activities) ? activities : [];
    const cells = document.createDocumentFragment();

    for (let index = 0; index < leadingDays; index += 1) {
      const blank = document.createElement('div');
      blank.className = 'calendar-day calendar-day-empty';
      blank.setAttribute('aria-hidden', 'true');
      cells.appendChild(blank);
    }

    for (let day = 1; day <= daysInMonth; day += 1) {
      const cell = document.createElement('article');
      cell.className = 'calendar-day';
      if (sameLocalDay(new Date(year, monthIndex, day), today)) cell.classList.add('calendar-day-today');

      const number = document.createElement('h3');
      number.className = 'calendar-day-number';
      number.textContent = String(day);
      cell.appendChild(number);

      const dayItems = calendarItems
        .filter((item) => {
          const date = placementDate(item);
          return date && date.getFullYear() === year && date.getMonth() === monthIndex && date.getDate() === day;
        })
        .sort((first, second) => placementDate(first) - placementDate(second));
      const shownItems = dayItems.slice(0, 2);
      shownItems.forEach((item) => cell.appendChild(createCalendarItem(item)));

      if (dayItems.length > shownItems.length) {
        const extraId = `calendar-extra-${gridElement.id}-${year}-${monthIndex}-${day}`;
        const extra = document.createElement('div');
        extra.id = extraId;
        extra.className = 'calendar-day-extra';
        extra.hidden = true;
        dayItems.slice(2).forEach((item) => extra.appendChild(createCalendarItem(item)));

        const toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.className = 'calendar-more-button';
        toggle.textContent = `+${dayItems.length - shownItems.length} altre`;
        toggle.setAttribute('aria-expanded', 'false');
        toggle.setAttribute('aria-controls', extraId);
        toggle.addEventListener('click', () => {
          const expanded = toggle.getAttribute('aria-expanded') === 'true';
          extra.hidden = expanded;
          toggle.setAttribute('aria-expanded', String(!expanded));
          toggle.textContent = expanded ? `+${dayItems.length - shownItems.length} altre` : 'Mostra meno';
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

  function startOfWeek(value) {
    const date = new Date(value.getFullYear(), value.getMonth(), value.getDate());
    date.setDate(date.getDate() - ((date.getDay() + 6) % 7));
    return date;
  }

  function renderWeekCalendar({ weekStart, titleElement, gridElement, activities }) {
    const start = startOfWeek(weekStart);
    const end = new Date(start);
    end.setDate(end.getDate() + 6);
    const monthFormatter = new Intl.DateTimeFormat('it-IT', { month: 'long' });
    const dayFormatter = new Intl.DateTimeFormat('it-IT', { weekday: 'short', day: 'numeric' });
    const today = new Date();
    const calendarItems = Array.isArray(activities) ? activities : [];
    const days = document.createDocumentFragment();

    const startMonth = monthFormatter.format(start).toLocaleLowerCase('it-IT');
    const endMonth = monthFormatter.format(end).toLocaleLowerCase('it-IT');
    if (start.getFullYear() !== end.getFullYear()) {
      titleElement.textContent = `${start.getDate()} ${startMonth} ${start.getFullYear()} – ${end.getDate()} ${endMonth} ${end.getFullYear()}`;
    } else if (start.getMonth() !== end.getMonth()) {
      titleElement.textContent = `${start.getDate()} ${startMonth} – ${end.getDate()} ${endMonth} ${end.getFullYear()}`;
    } else {
      titleElement.textContent = `${start.getDate()}–${end.getDate()} ${endMonth} ${end.getFullYear()}`;
    }

    for (let offset = 0; offset < 7; offset += 1) {
      const date = new Date(start);
      date.setDate(start.getDate() + offset);
      const day = document.createElement('article');
      day.className = 'dashboard-week-day';
      if (sameLocalDay(date, today)) day.classList.add('is-today');

      const heading = document.createElement('h3');
      heading.className = 'dashboard-week-day-heading';
      heading.textContent = dayFormatter.format(date);
      day.appendChild(heading);

      const dayItems = calendarItems
        .filter((item) => {
          const placement = placementDate(item);
          return placement && sameLocalDay(placement, date);
        })
        .sort((first, second) => placementDate(first) - placementDate(second));

      if (!dayItems.length) {
        const empty = document.createElement('p');
        empty.className = 'dashboard-week-empty';
        empty.textContent = 'Nessun impegno';
        day.appendChild(empty);
      } else {
        dayItems.forEach((item) => day.appendChild(createCalendarItem(item)));
      }
      days.appendChild(day);
    }
    gridElement.replaceChildren(days);
  }

  global.FamilAreaCalendarUtils = { itemLink, itemType, placementDate, renderMonthCalendar, renderWeekCalendar, startOfWeek, toValidDate };
}(window));

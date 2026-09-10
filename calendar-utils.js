(function attachCalendarUtils(global) {
  function toValidDate(value) {
    if (!value) return null;
    if (typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)) {
      const [year, month, day] = value.split('-').map(Number);
      const date = new Date(year, month - 1, day);
      return Number.isNaN(date.getTime()) ? null : date;
    }
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? null : date;
  }

  function itemType(item) {
    if (item.deadline_id) return 'deadline';
    if (item.birthday_contact_id) return 'birthday';
    return item.event_id ? 'event' : 'activity';
  }

  function placementDate(item) {
    if (itemType(item) === 'birthday' || itemType(item) === 'deadline') return toValidDate(item.occurs_on);
    if (itemType(item) === 'event') return toValidDate(item.starts_at);
    return toValidDate(item.occurrence_starts_at) || toValidDate(item.starts_at) || toValidDate(item.due_at);
  }

  function sameLocalDay(left, right) {
    return left.getFullYear() === right.getFullYear()
      && left.getMonth() === right.getMonth()
      && left.getDate() === right.getDate();
  }

  function itemLink(item) {
    if (itemType(item) === 'deadline') {
      return `scadenza.html?deadline_id=${encodeURIComponent(item.deadline_id)}`;
    }
    if (itemType(item) === 'birthday') {
      return `contatto.html?contact_id=${encodeURIComponent(item.birthday_contact_id)}`;
    }
    if (itemType(item) === 'event') {
      return `evento.html?area_id=${encodeURIComponent(item.area_id)}&event_id=${encodeURIComponent(item.event_id)}`;
    }
    return `attivita.html?area_id=${encodeURIComponent(item.area_id)}&activity_id=${encodeURIComponent(item.activity_id)}`;
  }

  function formatTime(item) {
    const start = placementDate(item);
    if (item.is_all_day || !start) return '';
    const formatter = new Intl.DateTimeFormat('it-IT', { hour: '2-digit', minute: '2-digit' });
    const end = itemType(item) === 'event' ? toValidDate(item.ends_at) : toValidDate(item.occurrence_ends_at);
    if (itemType(item) !== 'event') return end && end.getTime() !== start.getTime() ? `${formatter.format(start)} – ${formatter.format(end)}` : formatter.format(start);
    return end ? `${formatter.format(start)} – ${formatter.format(end)}` : formatter.format(start);
  }

  function createCalendarItem(item) {
    const type = itemType(item);
    const link = document.createElement('a');
    link.className = `calendar-activity${type === 'event' ? ' calendar-event' : ''}${type === 'birthday' ? ' calendar-birthday' : ''}${type === 'deadline' ? ' calendar-deadline' : ''}${item.status === 'completed' ? ' calendar-activity-completed' : ''}${type === 'deadline' && item.is_completed ? ' calendar-deadline-completed' : ''}`;
    link.href = itemLink(item);
    link.title = (type === 'birthday' || type === 'deadline') ? item.title : `${item.title} — ${item.area_name}`;

    const title = document.createElement('span');
    title.className = 'calendar-activity-title';
    title.textContent = item.title;
    const area = document.createElement('span');
    area.className = 'calendar-activity-area';
    area.textContent = type === 'birthday' ? 'Contatto personale' : (type === 'deadline' ? 'Scadenza' : item.area_name);
    link.append(title, area);

    if (type === 'event' || type === 'birthday' || type === 'deadline') {
      const badge = document.createElement('span');
      badge.className = 'calendar-item-kind';
      badge.textContent = type === 'birthday' ? 'Compleanno' : (type === 'deadline' ? 'Scadenza' : 'Evento');
      link.appendChild(badge);
    }

    const time = formatTime(item);
    if (time || item.status === 'completed') {
      const details = document.createElement('span');
      details.className = 'calendar-activity-details';
      details.textContent = [time, (item.status === 'completed' || (type === 'deadline' && item.is_completed)) ? 'Completata' : ''].filter(Boolean).join(' · ');
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

  function weekTitle(start) {
    const end = new Date(start);
    end.setDate(end.getDate() + 6);
    const monthFormatter = new Intl.DateTimeFormat('it-IT', { month: 'long' });
    const startMonth = monthFormatter.format(start).toLocaleLowerCase('it-IT');
    const endMonth = monthFormatter.format(end).toLocaleLowerCase('it-IT');
    if (start.getFullYear() !== end.getFullYear()) return `${start.getDate()} ${startMonth} ${start.getFullYear()} – ${end.getDate()} ${endMonth} ${end.getFullYear()}`;
    if (start.getMonth() !== end.getMonth()) return `${start.getDate()} ${startMonth} – ${end.getDate()} ${endMonth} ${end.getFullYear()}`;
    return `${start.getDate()}–${end.getDate()} ${endMonth} ${end.getFullYear()}`;
  }

  function itemEndDate(item, start) {
    const value = itemType(item) === 'event' ? item.ends_at : item.occurrence_ends_at;
    const end = toValidDate(value);
    if (end && end > start) return end;
    return new Date(start.getTime() + 30 * 60 * 1000);
  }

  function agendaItem(item, className, showTime) {
    const link = document.createElement('a');
    const type = itemType(item);
    link.className = `${className} ${className}--${type}${item.status === 'completed' || (type === 'deadline' && item.is_completed) ? ` ${className}--completed` : ''}`;
    link.href = itemLink(item);
    link.title = (type === 'birthday' || type === 'deadline') ? item.title : `${item.title} — ${item.area_name || ''}`.trim();
    const title = document.createElement('span');
    title.className = `${className}-title`;
    title.textContent = item.title;
    link.appendChild(title);
    if (showTime) {
      const time = document.createElement('span');
      time.className = `${className}-time`;
      time.textContent = formatTime(item);
      link.appendChild(time);
    }
    return link;
  }

  function layoutOverlaps(items) {
    const sorted = [...items].sort((left, right) => left.start - right.start || left.end - right.end);
    const groups = [];
    let group = null;
    sorted.forEach((item) => {
      if (!group || item.start >= group.end) {
        group = { end: item.end, items: [] };
        groups.push(group);
      } else if (item.end > group.end) {
        group.end = item.end;
      }
      group.items.push(item);
    });
    groups.forEach((current) => {
      const columns = [];
      current.items.forEach((item) => {
        let column = columns.findIndex((lastEnd) => lastEnd <= item.start);
        if (column === -1) { column = columns.length; columns.push(item.end); } else columns[column] = item.end;
        item.column = column;
      });
      current.items.forEach((item) => { item.columns = columns.length; });
    });
    return sorted;
  }

  function renderWeekAgenda({ weekStart, titleElement, gridElement, activities, startHour = 7, endHour = 22 }) {
    const start = startOfWeek(weekStart);
    const today = new Date();
    const days = Array.from({ length: 7 }, (_, offset) => {
      const date = new Date(start);
      date.setDate(start.getDate() + offset);
      return date;
    });
    const items = Array.isArray(activities) ? activities : [];
    const dayFormatter = new Intl.DateTimeFormat('it-IT', { weekday: 'short', day: 'numeric' });
    const totalMinutes = (endHour - startHour) * 60;
    const minuteHeight = 56 / 60;
    titleElement.textContent = weekTitle(start);

    const agenda = document.createElement('div');
    agenda.className = 'week-agenda';
    agenda.style.setProperty('--week-agenda-height', `${totalMinutes * minuteHeight}px`);

    const header = document.createElement('div');
    header.className = 'week-agenda-header';
    const corner = document.createElement('div');
    corner.className = 'week-agenda-corner';
    corner.textContent = 'Ora';
    header.appendChild(corner);
    days.forEach((date) => {
      const dayHeader = document.createElement('div');
      dayHeader.className = 'week-agenda-day-header';
      if (sameLocalDay(date, today)) dayHeader.classList.add('is-today');
      dayHeader.textContent = dayFormatter.format(date);
      header.appendChild(dayHeader);
    });
    agenda.appendChild(header);

    const perDay = days.map(() => ({ allDay: [], outside: [], timed: [] }));
    items.forEach((item) => {
      const date = placementDate(item);
      if (!date) return;
      const dayIndex = days.findIndex((day) => sameLocalDay(day, date));
      if (dayIndex === -1) return;
      if (item.is_all_day || itemType(item) === 'birthday' || itemType(item) === 'deadline') { perDay[dayIndex].allDay.push(item); return; }
      const dayStart = new Date(date.getFullYear(), date.getMonth(), date.getDate(), startHour);
      const dayEnd = new Date(date.getFullYear(), date.getMonth(), date.getDate(), endHour);
      const end = itemEndDate(item, date);
      if (end <= dayStart || date >= dayEnd) { perDay[dayIndex].outside.push(item); return; }
      perDay[dayIndex].timed.push({ item, start: date, end });
    });

    const createLane = (className, label, key, showTime) => {
      const hasItems = perDay.some((day) => day[key].length);
      if (!hasItems && key === 'outside') return;
      const lane = document.createElement('div'); lane.className = className;
      const laneLabel = document.createElement('div'); laneLabel.className = `${className}-label`; laneLabel.textContent = label; lane.appendChild(laneLabel);
      perDay.forEach((day) => {
        const cell = document.createElement('div'); cell.className = `${className}-cell`;
        day[key].forEach((entry) => cell.appendChild(agendaItem(entry.item || entry, `${className}-item`, showTime)));
        lane.appendChild(cell);
      });
      agenda.appendChild(lane);
    };
    createLane('week-agenda-all-day', 'Tutto il giorno', 'allDay', false);
    createLane('week-agenda-outside', 'Fuori orario', 'outside', true);

    const body = document.createElement('div'); body.className = 'week-agenda-body';
    const axis = document.createElement('div'); axis.className = 'week-agenda-axis';
    for (let hour = startHour; hour <= endHour; hour += 1) {
      const label = document.createElement('span'); label.className = 'week-agenda-hour'; label.style.top = `${((hour - startHour) / (endHour - startHour)) * 100}%`; label.textContent = `${String(hour).padStart(2, '0')}:00`; axis.appendChild(label);
    }
    body.appendChild(axis);
    const columns = document.createElement('div'); columns.className = 'week-agenda-columns';
    perDay.forEach((day, index) => {
      const column = document.createElement('div'); column.className = 'week-agenda-day-column';
      if (sameLocalDay(days[index], today)) column.classList.add('is-today');
      layoutOverlaps(day.timed).forEach((entry) => {
        const viewStart = new Date(days[index].getFullYear(), days[index].getMonth(), days[index].getDate(), startHour);
        const viewEnd = new Date(days[index].getFullYear(), days[index].getMonth(), days[index].getDate(), endHour);
        const clippedStart = entry.start < viewStart ? viewStart : entry.start;
        const clippedEnd = entry.end > viewEnd ? viewEnd : entry.end;
        const minutesFromStart = (clippedStart - viewStart) / 60000;
        const duration = Math.max(20, (clippedEnd - clippedStart) / 60000);
        const itemElement = agendaItem(entry.item, 'week-agenda-timed-item', true);
        itemElement.style.top = `${(minutesFromStart / totalMinutes) * 100}%`;
        itemElement.style.height = `${(duration / totalMinutes) * 100}%`;
        itemElement.style.left = `calc(${(entry.column / entry.columns) * 100}% + 3px)`;
        itemElement.style.width = `calc(${100 / entry.columns}% - 6px)`;
        column.appendChild(itemElement);
      });
      columns.appendChild(column);
    });
    body.appendChild(columns); agenda.appendChild(body);
    gridElement.replaceChildren(agenda);
  }

  global.FamilAreaCalendarUtils = { itemLink, itemType, placementDate, renderMonthCalendar, renderWeekCalendar, renderWeekAgenda, startOfWeek, toValidDate };
}(window));

(function () {
  function calendarDateKey(value) {
    const match = String(value || '').match(/^(\d{4}-\d{2}-\d{2})/);
    return match ? match[1] : '';
  }

  function dateKey(year, monthIndex, day) {
    return `${year}-${String(monthIndex + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
  }

  function deadlineHref(occurrence) {
    const params = new URLSearchParams({ deadline_id: occurrence.deadline_id, deadline_item_id: occurrence.deadline_item_id });
    return `nuova-scadenza.html?${params}`;
  }

  function closeChoices(exceptCell = null) {
    document.querySelectorAll('.annual-deadline-day--choices-open').forEach((cell) => {
      if (cell === exceptCell) return;
      cell.classList.remove('annual-deadline-day--choices-open');
      cell.querySelector('.annual-deadline-day-action')?.setAttribute('aria-expanded', 'false');
      const choices = cell.querySelector('.annual-deadline-day-choices');
      if (choices) choices.hidden = true;
    });
  }

  function create(options) {
    let year = new Date().getFullYear();
    const itemName = (occurrence, itemsById) => (
      occurrence.deadline_item_name || itemsById.get(occurrence.deadline_item_id)?.name || options.itemFallback
    );
    const label = (occurrence, itemsById) => `${itemName(occurrence, itemsById)} — ${occurrence.title || 'Scadenza'}`;

    function avatar(occurrence, itemsById) {
      const name = itemName(occurrence, itemsById);
      const element = document.createElement('span');
      element.className = 'annual-deadline-calendar-avatar';
      element.textContent = (name.trim().charAt(0) || options.itemFallback.charAt(0)).toLocaleUpperCase('it-IT');
      element.title = label(occurrence, itemsById);
      element.setAttribute('aria-label', element.title);
      const imagePath = occurrence.deadline_item_image_path || itemsById.get(occurrence.deadline_item_id)?.image_path;
      if (imagePath) void options.imageService.render(element, imagePath, `Foto di ${name}`);
      return element;
    }

    function renderMonth(monthIndex, deadlinesByDate, itemsById) {
      const month = document.createElement('section');
      month.className = 'annual-deadline-month';
      const title = document.createElement('h3');
      title.textContent = new Intl.DateTimeFormat('it-IT', { month: 'long' }).format(new Date(year, monthIndex, 1));
      const weekdays = document.createElement('div');
      weekdays.className = 'annual-deadline-weekdays';
      ['L', 'M', 'M', 'G', 'V', 'S', 'D'].forEach((value) => {
        const weekday = document.createElement('span');
        weekday.textContent = value;
        weekdays.appendChild(weekday);
      });
      const days = document.createElement('div');
      days.className = 'annual-deadline-days';
      const leadingDays = (new Date(year, monthIndex, 1).getDay() + 6) % 7;
      const daysInMonth = new Date(year, monthIndex + 1, 0).getDate();
      const today = new Date();

      for (let index = 0; index < leadingDays; index += 1) {
        const blank = document.createElement('span');
        blank.className = 'annual-deadline-day annual-deadline-day--empty';
        blank.setAttribute('aria-hidden', 'true');
        days.appendChild(blank);
      }
      for (let day = 1; day <= daysInMonth; day += 1) {
        const cell = document.createElement('article');
        cell.className = 'annual-deadline-day';
        const cellDate = new Date(year, monthIndex, day);
        if (cellDate.getFullYear() === today.getFullYear() && cellDate.getMonth() === today.getMonth() && cellDate.getDate() === today.getDate()) {
          cell.classList.add('annual-deadline-day--today');
        }
        const dayDeadlines = deadlinesByDate.get(dateKey(year, monthIndex, day)) || [];
        const action = document.createElement(dayDeadlines.length === 1 ? 'a' : (dayDeadlines.length > 1 ? 'button' : 'span'));
        action.className = 'annual-deadline-day-action';
        if (dayDeadlines.length === 1) action.href = deadlineHref(dayDeadlines[0]);
        else if (dayDeadlines.length > 1) action.type = 'button';
        const number = document.createElement('span');
        number.className = 'annual-deadline-day-number';
        number.textContent = String(day);
        action.appendChild(number);

        if (!dayDeadlines.length) {
          cell.appendChild(action);
          days.appendChild(cell);
          continue;
        }

        cell.classList.add('annual-deadline-day--has-deadlines');
        const avatars = document.createElement('span');
        avatars.className = 'annual-deadline-day-avatars';
        dayDeadlines.slice(0, 3).forEach((occurrence) => avatars.appendChild(avatar(occurrence, itemsById)));
        if (dayDeadlines.length > 3) {
          const more = document.createElement('span');
          more.className = 'annual-deadline-day-more';
          more.textContent = `+${dayDeadlines.length - 3}`;
          more.title = dayDeadlines.slice(3).map((occurrence) => occurrence.title || 'Scadenza').join(', ');
          avatars.appendChild(more);
        }
        action.title = dayDeadlines.map((occurrence) => label(occurrence, itemsById)).join('\n');
        action.appendChild(avatars);

        if (dayDeadlines.length === 1) {
          action.setAttribute('aria-label', `Apri ${label(dayDeadlines[0], itemsById)}`);
          cell.appendChild(action);
        } else {
          const choices = document.createElement('div');
          const choicesId = `${options.idPrefix}-${year}-${monthIndex}-${day}-choices`;
          choices.id = choicesId;
          choices.className = 'annual-deadline-day-choices';
          choices.hidden = true;
          choices.setAttribute('aria-label', `Scadenze del ${day}`);
          dayDeadlines.forEach((occurrence) => {
            const choice = document.createElement('a');
            choice.className = 'annual-deadline-choice';
            choice.href = deadlineHref(occurrence);
            choice.textContent = label(occurrence, itemsById);
            choices.appendChild(choice);
          });
          action.setAttribute('aria-controls', choicesId);
          action.setAttribute('aria-expanded', 'false');
          action.setAttribute('aria-label', `Mostra ${dayDeadlines.length} scadenze del ${day}`);
          action.addEventListener('click', () => {
            const willOpen = choices.hidden;
            closeChoices(cell);
            choices.hidden = !willOpen;
            cell.classList.toggle('annual-deadline-day--choices-open', willOpen);
            action.setAttribute('aria-expanded', String(willOpen));
          });
          cell.append(action, choices);
        }
        days.appendChild(cell);
      }
      month.append(title, weekdays, days);
      return month;
    }

    function render(occurrences) {
      const itemsById = new Map((options.getItems() || []).map((item) => [item.id, item]));
      const deadlinesByDate = new Map();
      occurrences.forEach((occurrence) => {
        const key = calendarDateKey(occurrence.occurs_on || occurrence.starts_at);
        if (!key) return;
        const entries = deadlinesByDate.get(key) || [];
        entries.push(occurrence);
        deadlinesByDate.set(key, entries);
      });
      options.yearElement.textContent = String(year);
      options.gridElement.replaceChildren(...Array.from({ length: 12 }, (_, monthIndex) => renderMonth(monthIndex, deadlinesByDate, itemsById)));
    }

    async function load() {
      const from = new Date(Date.UTC(year, 0, 1));
      const to = new Date(Date.UTC(year + 1, 0, 1));
      options.yearElement.textContent = String(year);
      const { data, error } = await options.client.rpc('get_calendar_occurrences', { p_from: from.toISOString(), p_to: to.toISOString() });
      if (error) {
        options.messageElement.textContent = 'Impossibile caricare il calendario annuale.';
        return;
      }
      options.messageElement.textContent = '';
      render((data || []).filter(options.isOccurrence));
    }

    options.previousButton.addEventListener('click', () => { year -= 1; void load(); });
    options.nextButton.addEventListener('click', () => { year += 1; void load(); });
    return { load };
  }

  window.FamilAreaAnnualDeadlineCalendar = { create };
}());

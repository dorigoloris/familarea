const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const areaId = new URLSearchParams(location.search).get('area_id');
const eventId = new URLSearchParams(location.search).get('event_id');
const isArea = Boolean(areaId);
const message = document.getElementById('message');
let eventData;
let canManage = false;

const statusLabels = { active: 'Attivo', cancelled: 'Annullato' };

function localDate(value) {
  const date = new Date(value);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

function localTime(value) {
  return new Date(value).toTimeString().slice(0, 5);
}

function localIso(date, time = '00:00') {
  return new Date(`${date}T${time}`).toISOString();
}

function formatWhen(value, endValue, isAllDay) {
  if (!value) return '—';
  const formatter = new Intl.DateTimeFormat('it-IT', isAllDay
    ? { dateStyle: 'long' }
    : { dateStyle: 'long', timeStyle: 'short' });
  const end = endValue ? new Date(endValue) : null;
  return end && localDate(value) !== localDate(endValue)
    ? `${formatter.format(new Date(value))} → ${formatter.format(end)}`
    : formatter.format(new Date(value));
}

function statusLabel(status) {
  return statusLabels[status] || status || '—';
}

function recurrenceOf(event) {
  return {
    frequency: event.recurrence_frequency || '',
    until: event.recurrence_until || ''
  };
}

function formatRecurrenceDate(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value || '');
  return match ? `${match[3]}-${match[2]}-${match[1]}` : value;
}

function formRecurrence(startDate) {
  if (!document.getElementById('edit-recurrence-enabled').checked) return {};
  const until = document.getElementById('edit-recurrence-until').value;
  if (!until) throw new Error('Indica la fine della ripetizione.');
  if (until < startDate) throw new Error('La fine della ripetizione non può precedere la data iniziale.');
  return { frequency: 'weekly', until, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || eventData.recurrence_timezone || 'UTC' };
}

function editElements() {
  return {
    date: document.getElementById('edit-date'),
    start: document.getElementById('edit-start'),
    endDate: document.getElementById('edit-end-date'),
    end: document.getElementById('edit-end'),
    allDay: document.getElementById('edit-all-day'),
    multiDay: document.getElementById('edit-multi-day'),
    startDates: document.getElementById('edit-start-dates'),
    startTimeField: document.getElementById('edit-start-time-field'),
    endTimeField: document.getElementById('edit-end-time-field'),
    normalEndSlot: document.getElementById('edit-end-time-normal-slot'),
    multiDayEndSlot: document.getElementById('edit-end-time-multi-day-slot'),
    multiDayEndRow: document.getElementById('edit-multi-day-end-row')
  };
}

function syncEditMultiDayLayout() {
  const fields = editElements();
  const multiDay = fields.multiDay.checked;
  const allDay = fields.allDay.checked;
  if (multiDay && !fields.endDate.value) fields.endDate.value = fields.date.value;
  (multiDay ? fields.multiDayEndSlot : fields.normalEndSlot).appendChild(fields.endTimeField);
  fields.normalEndSlot.hidden = multiDay || allDay;
  fields.multiDayEndRow.hidden = !multiDay;
  fields.startDates.classList.toggle('is-multi-day', multiDay);
  fields.startDates.classList.toggle('is-all-day', allDay);
  fields.multiDayEndRow.classList.toggle('is-all-day', allDay);
  fields.startTimeField.hidden = allDay;
  fields.endTimeField.hidden = allDay;
}

function buildEditInterval() {
  const fields = editElements();
  const startDate = fields.date.value;
  const startTime = fields.start.value;
  const endDate = fields.multiDay.checked ? fields.endDate.value : startDate;
  const endTime = fields.end.value;
  const allDay = fields.allDay.checked || !startTime;
  if (!startDate) throw new Error('Indica la data dell’evento.');
  if (fields.multiDay.checked && !endDate) throw new Error('Indica la data di fine.');
  if (fields.multiDay.checked && endDate <= startDate) {
    throw new Error(endDate === startDate
      ? 'Per un’attività di un solo giorno, disattiva Più giorni.'
      : 'La data di fine non può essere precedente alla data iniziale.');
  }
  if (!fields.allDay.checked && endTime && !startTime) throw new Error('Indica prima l’ora di inizio.');
  if (fields.multiDay.checked && !allDay && !endTime) throw new Error('Indica l’ora di fine.');
  const startsAt = localIso(startDate, allDay ? '00:00' : startTime);
  const endsAt = allDay
    ? (fields.multiDay.checked ? localIso(endDate, '00:00') : startsAt)
    : endTime ? localIso(endDate, endTime) : null;
  if (endsAt && new Date(endsAt) <= new Date(startsAt)) throw new Error('La fine deve essere successiva all’inizio.');
  return { startsAt, endsAt, allDay };
}

function focusOnEnter(next) {
  return (event) => {
    if (event.key !== 'Enter') return;
    event.preventDefault();
    next()?.focus();
  };
}

async function renderParticipants(container, selected = []) {
  if (!isArea) return;
  const { data, error } = await supabaseClient.rpc('get_area_members', { p_area_id: areaId });
  if (error) throw error;

  container.replaceChildren();
  (data || []).forEach((member) => {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.value = member.profile_id;
    input.checked = selected.includes(member.profile_id);
    label.append(input, ` ${member.first_name || ''} ${member.last_name || ''}`.trim());
    container.append(label, document.createElement('br'));
  });
}

function renderStatus() {
  const select = document.getElementById('status-select');
  const save = document.getElementById('save-status');
  document.getElementById('status').textContent = statusLabel(eventData.status);
  select.value = statusLabels[eventData.status] ? eventData.status : 'active';
  save.disabled = select.value === eventData.status;
}

async function render() {
  document.getElementById('event-title').textContent = eventData.title;
  document.getElementById('when').textContent = formatWhen(eventData.starts_at, eventData.ends_at, eventData.is_all_day);
  document.getElementById('location').textContent = eventData.location || '—';
  document.getElementById('notes').textContent = eventData.description || '—';
  renderStatus();

  const recurrence = recurrenceOf(eventData);
  document.getElementById('recurrence-label').hidden = !recurrence.frequency;
  document.getElementById('recurrence').hidden = !recurrence.frequency;
  document.getElementById('recurrence').textContent = recurrence.frequency === 'weekly'
    ? `Ogni settimana fino al ${formatRecurrenceDate(recurrence.until)}`
    : recurrence.frequency;

  document.getElementById('participants-label').hidden = !isArea;
  document.getElementById('participant-list').hidden = !isArea;
  if (isArea) {
    const { data, error } = await supabaseClient.rpc('get_event_participants', { p_event_id: eventId });
    document.getElementById('participant-list').textContent = error
      ? 'Non disponibili.'
      : (data || []).map((person) => `${person.first_name || ''} ${person.last_name || ''}`.trim()).join(', ') || 'Nessuno';
  }

  document.getElementById('event-view').hidden = false;
  document.getElementById('creator-actions').hidden = !canManage;
  message.textContent = '';
}

async function load() {
  const { data: session } = await supabaseClient.auth.getSession();
  if (!session.session) {
    location.href = 'login.html';
    return;
  }
  if (!eventId) {
    message.textContent = 'Evento non specificato.';
    return;
  }

  document.getElementById('back-link').href = isArea
    ? `eventi.html?area_id=${encodeURIComponent(areaId)}`
    : 'eventi.html';
  document.getElementById('back-link').textContent = isArea ? 'Torna al programma' : 'Torna agli eventi';
  const [{ data: event, error }, { data: account }, { data: areas }] = await Promise.all([
    supabaseClient.rpc('get_event', { p_event_id: eventId }),
    supabaseClient.rpc('get_current_account'),
    supabaseClient.rpc('get_my_areas')
  ]);
  if (error || !event) {
    message.textContent = 'Evento non disponibile.';
    return;
  }
  eventData = event;
  canManage = !event.area_id
    ? event.owner_account_id === account?.account_id
    : (areas || []).some((area) => area.id === event.area_id && ['owner', 'admin'].includes(area.role));
  await render();
}

async function openEdit() {
  const form = document.getElementById('edit-form');
  const recurrence = recurrenceOf(eventData);
  document.getElementById('edit-title').value = eventData.title || '';
  document.getElementById('edit-notes').value = eventData.description || '';
  document.getElementById('edit-date').value = localDate(eventData.starts_at);
  document.getElementById('edit-start').value = eventData.is_all_day ? '' : localTime(eventData.starts_at);
  document.getElementById('edit-end').value = eventData.is_all_day || !eventData.ends_at ? '' : localTime(eventData.ends_at);
  document.getElementById('edit-all-day').checked = Boolean(eventData.is_all_day);
  document.getElementById('edit-multi-day').checked = Boolean(eventData.ends_at) && localDate(eventData.starts_at) !== localDate(eventData.ends_at);
  document.getElementById('edit-end-date').value = eventData.ends_at ? localDate(eventData.ends_at) : localDate(eventData.starts_at);
  syncEditMultiDayLayout();
  document.getElementById('edit-location').value = eventData.location || '';
  document.getElementById('edit-recurrence-enabled').checked = Boolean(recurrence.frequency);
  document.getElementById('edit-recurrence-fields').hidden = !recurrence.frequency;
  document.getElementById('edit-recurrence-until').value = recurrence.until || '';
  document.getElementById('edit-participants-fieldset').hidden = !isArea;

  if (isArea) {
    const { data } = await supabaseClient.rpc('get_event_participants', { p_event_id: eventId });
    await renderParticipants(
      document.getElementById('edit-participants'),
      (data || []).map((person) => person.profile_id)
    );
  }

  document.getElementById('event-view').hidden = true;
  form.hidden = false;
}

async function saveStatus() {
  const select = document.getElementById('status-select');
  const save = document.getElementById('save-status');
  if (select.value === eventData.status) return;
  save.disabled = true;
  const { error } = await supabaseClient.rpc('set_event_status', {
    p_event_id: eventId,
    p_status: select.value
  });
  if (error) {
    message.textContent = 'Impossibile aggiornare lo stato.';
    save.disabled = false;
    return;
  }
  eventData.status = select.value;
  renderStatus();
  message.textContent = '';
}

document.getElementById('edit-button').addEventListener('click', () => void openEdit());
document.getElementById('close-edit').addEventListener('click', () => {
  document.getElementById('edit-form').hidden = true;
  document.getElementById('event-view').hidden = false;
  message.textContent = '';
});
document.getElementById('status-select').addEventListener('change', (event) => {
  document.getElementById('save-status').disabled = event.target.value === eventData.status;
});
document.getElementById('save-status').addEventListener('click', () => void saveStatus());
document.getElementById('edit-recurrence-enabled').addEventListener('change', (event) => {
  document.getElementById('edit-recurrence-fields').hidden = !event.target.checked;
});
document.getElementById('edit-multi-day').addEventListener('change', syncEditMultiDayLayout);
document.getElementById('edit-all-day').addEventListener('change', syncEditMultiDayLayout);
document.getElementById('edit-date').addEventListener('change', () => {
  const fields = editElements();
  if (fields.multiDay.checked && !fields.endDate.value) fields.endDate.value = fields.date.value;
});
document.getElementById('edit-date').addEventListener('keydown', focusOnEnter(() => {
  const fields = editElements();
  return fields.allDay.checked ? (fields.multiDay.checked ? fields.endDate : null) : fields.start;
}));
document.getElementById('edit-start').addEventListener('keydown', focusOnEnter(() => document.getElementById('edit-multi-day').checked ? document.getElementById('edit-end-date') : document.getElementById('edit-end')));
document.getElementById('edit-end-date').addEventListener('keydown', focusOnEnter(() => document.getElementById('edit-all-day').checked ? null : document.getElementById('edit-end')));
document.getElementById('edit-end').addEventListener('keydown', focusOnEnter(() => null));

document.getElementById('edit-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  let interval;
  let recurrence;
  try {
    interval = buildEditInterval();
    recurrence = formRecurrence(document.getElementById('edit-date').value);
  } catch (error) {
    message.textContent = error.message;
    return;
  }

  const { error } = await supabaseClient.rpc('update_event', {
    p_event_id: eventId,
    p_title: document.getElementById('edit-title').value.trim(),
    p_starts_at: interval.startsAt,
    p_ends_at: interval.endsAt,
    p_description: document.getElementById('edit-notes').value.trim() || null,
    p_is_all_day: interval.allDay,
    p_location: document.getElementById('edit-location').value.trim() || null,
    p_recurrence: recurrence
  });
  if (error) {
    message.textContent = 'Impossibile salvare le modifiche.';
    return;
  }

  if (isArea) {
    const result = await supabaseClient.rpc('set_event_participants', {
      p_event_id: eventId,
      p_profile_ids: [...document.querySelectorAll('#edit-participants input:checked')].map((input) => input.value)
    });
    if (result.error) {
      message.textContent = 'Dati salvati, ma partecipanti non aggiornati.';
      return;
    }
  }

  document.getElementById('edit-form').hidden = true;
  document.getElementById('event-view').hidden = false;
  await load();
});

document.getElementById('delete-button').addEventListener('click', async () => {
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: 'Eliminare l’evento?',
    message: 'L’evento verrà eliminato definitivamente.',
    confirmText: 'Elimina'
  });
  if (!confirmed) return;
  const { error } = await supabaseClient.rpc('delete_event', { p_event_id: eventId });
  if (error) {
    message.textContent = 'Impossibile eliminare l’evento.';
    return;
  }
  location.href = isArea ? `eventi.html?area_id=${encodeURIComponent(areaId)}` : 'eventi.html';
});

async function renderParticipantControls() {
  if (!isArea) return;
  const list = document.getElementById('participant-list');
  const [{ data: participants, error: participantsError }, { data: members, error: membersError }] = await Promise.all([
    supabaseClient.rpc('get_event_participants', { p_event_id: eventId }),
    supabaseClient.rpc('get_area_members', { p_area_id: areaId })
  ]);
  if (participantsError || membersError) return;
  const selected = participants || [];
  list.replaceChildren();
  if (!selected.length) list.textContent = 'Nessun partecipante.';
  selected.forEach((person) => {
    const row = document.createElement('div');
    row.className = 'event-participant-row';
    row.textContent = `${person.first_name || ''} ${person.last_name || ''}`.trim() || 'Partecipante';
    if (canManage) {
      const remove = document.createElement('button'); remove.type = 'button'; remove.textContent = 'Rimuovi';
      remove.addEventListener('click', async () => {
        if (!await FamilAreaConfirm.confirm({ variant: 'standard', title: 'Rimuovere il partecipante?', message: 'La persona resterà membro dell’Area e negli altri elementi del Programma.', confirmText: 'Rimuovi' })) return;
        const { error } = await supabaseClient.rpc('set_event_participants', { p_event_id: eventId, p_profile_ids: selected.filter((item) => item.profile_id !== person.profile_id).map((item) => item.profile_id) });
        if (error) { message.textContent = 'Impossibile rimuovere il partecipante.'; return; }
        await renderParticipantControls();
      }); row.append(' ', remove);
    }
    list.appendChild(row);
  });
  if (!canManage) return;
  const available = (members || []).filter((member) => !selected.some((person) => person.profile_id === member.profile_id));
  const actions = document.createElement('div');
  actions.className = 'event-participant-actions';
  const invite = document.createElement('a');
  invite.className = 'secondary-button';
  invite.href = `inviti-area.html?area_id=${encodeURIComponent(areaId)}&return_to=${encodeURIComponent(location.pathname.split('/').pop() + location.search)}`;
  invite.textContent = 'Invita una persona';

  if (!available.length) {
    const unavailable = document.createElement('p');
    unavailable.className = 'event-participant-unavailable';
    unavailable.textContent = 'Non ci sono membri dell’Area disponibili da aggiungere.';
    actions.append(unavailable);
  } else {
    const addControls = document.createElement('div');
    addControls.className = 'event-participant-add-controls';
    const select = document.createElement('select');
    select.id = 'event-participant-select';
    select.setAttribute('aria-label', 'Seleziona un membro dell’Area');
    select.append(new Option('Seleziona un membro dell’Area', ''));
    available.forEach((member) => select.append(new Option(`${member.first_name || ''} ${member.last_name || ''}`.trim(), member.profile_id)));
    const add = document.createElement('button');
    add.type = 'button';
    add.className = 'fa-button fa-button-primary fa-button-compact';
    add.textContent = 'Aggiungi';
    add.disabled = true;
    select.addEventListener('change', () => { add.disabled = !select.value; });
    add.addEventListener('click', async () => {
      if (!select.value) return;
      const { error } = await supabaseClient.rpc('set_event_participants', {
        p_event_id: eventId,
        p_profile_ids: [...selected.map((person) => person.profile_id), select.value]
      });
      if (error) { message.textContent = 'Impossibile aggiungere il partecipante.'; return; }
      await renderParticipantControls();
    });
    addControls.append(select, add);
    actions.append(addControls);
  }
  const invitePrompt = document.createElement('div');
  invitePrompt.className = 'event-participant-invite';
  const prompt = document.createElement('p');
  prompt.textContent = 'La persona non fa ancora parte dell’Area?';
  invitePrompt.append(prompt, invite);
  actions.append(invitePrompt);
  list.appendChild(actions);
}
const renderEventView = render;
render = async function () { await renderEventView(); await renderParticipantControls(); };
load();

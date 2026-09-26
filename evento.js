const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const areaId = new URLSearchParams(location.search).get('area_id');
const eventId = new URLSearchParams(location.search).get('event_id');
const isArea = Boolean(areaId);
const message = document.getElementById('message');
let eventData;
let canManage = false;
let isPersonalAccount = false;

const statusLabels = { active: 'Attivo', cancelled: 'Annullato' };

function localDate(value) {
  const date = new Date(value);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

function localTime(value) {
  return new Date(value).toTimeString().slice(0, 5);
}

function eventInviteUrl(token) {
  const link = new URL('invito-evento.html', location.href);
  link.searchParams.set('token', token);
  return link.toString();
}

async function copyInviteUrl(inviteUrl) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(inviteUrl);
    return;
  }
  const fallback = document.createElement('textarea');
  fallback.value = inviteUrl;
  fallback.setAttribute('readonly', '');
  fallback.style.position = 'fixed';
  fallback.style.opacity = '0';
  document.body.appendChild(fallback);
  try {
    fallback.select();
    if (!document.execCommand('copy')) throw new Error('copy failed');
  } finally {
    fallback.remove();
  }
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
  const timezone = event.recurrence_timezone || Intl.DateTimeFormat().resolvedOptions().timeZone || 'Europe/Rome';
  const weekdayNumbers = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 };
  const startWeekday = weekdayNumbers[new Intl.DateTimeFormat('en-US', { weekday: 'short', timeZone: timezone }).format(new Date(event.starts_at))];
  return {
    frequency: event.recurrence_frequency || '',
    interval: Number(event.recurrence_interval) || 1,
    weekdays: Array.isArray(event.recurrence_weekdays) && event.recurrence_weekdays.length
      ? event.recurrence_weekdays.map(Number)
      : [startWeekday],
    until: event.recurrence_until || '',
    hasEndDate: Boolean(event.recurrence_until),
    timezone
  };
}

function formatRecurrenceDate(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value || '');
  return match ? `${match[3]}-${match[2]}-${match[1]}` : value;
}

function formatRecurrenceSummary(recurrence) {
  if (recurrence.frequency !== 'weekly') return recurrence.frequency;
  const interval = recurrence.interval === 1 ? 'Ogni settimana' : `Ogni ${recurrence.interval} settimane`;
  const weekdays = recurrence.weekdays.map((weekday) => new Intl.DateTimeFormat('it-IT', {
    weekday: 'long', timeZone: 'UTC'
  }).format(new Date(Date.UTC(2024, 0, weekday))));
  const days = weekdays.length > 1 ? `${weekdays.slice(0, -1).join(', ')} e ${weekdays.at(-1)}` : weekdays[0];
  const end = recurrence.until ? ` fino al ${formatRecurrenceDate(recurrence.until)}` : ' senza scadenza';
  return `${interval}${days ? `, ${days}` : ''}${end}`;
}

function setEditRecurrenceError(text = '') {
  const error = document.getElementById('edit-recurrence-error');
  error.textContent = text;
  error.hidden = !text;
}

function syncEditRecurrenceEndMode() {
  const hasEndDate = document.querySelector('input[name="edit-recurrence-end-mode"]:checked')?.value !== 'never';
  const until = document.getElementById('edit-recurrence-until');
  until.disabled = !hasEndDate;
  until.hidden = !hasEndDate;
}

function formRecurrence(startDate) {
  if (!document.getElementById('edit-recurrence-enabled').checked) return {};
  const hasEndDate = document.querySelector('input[name="edit-recurrence-end-mode"]:checked')?.value !== 'never';
  const until = hasEndDate ? document.getElementById('edit-recurrence-until').value : null;
  const interval = Number(document.getElementById('edit-recurrence-interval').value);
  const weekdays = [...document.querySelectorAll('input[name="edit-recurrence-weekday"]:checked')]
    .map((input) => Number(input.value)).sort((first, second) => first - second);
  if (!Number.isInteger(interval) || interval < 1) throw new Error('Inserisci un intervallo di almeno 1 settimana.');
  if (interval > 32767) throw new Error('L’intervallo massimo è 32767 settimane.');
  if (!weekdays.length) throw new Error('Seleziona almeno un giorno della settimana.');
  if (hasEndDate && !until) throw new Error('Inserisci una data di fine ripetizione.');
  if (until && until < startDate) throw new Error('La fine della ripetizione non può precedere la data di inizio.');
  return { frequency: 'weekly', interval, weekdays, until, timezone: eventData.recurrence_timezone || Intl.DateTimeFormat().resolvedOptions().timeZone || 'Europe/Rome' };
}

function editElements() {
  return {
    date: document.getElementById('edit-date'),
    start: document.getElementById('edit-start'),
    endDate: document.getElementById('edit-end-date'),
    end: document.getElementById('edit-end'),
    allDay: document.getElementById('edit-all-day'),
    multiDay: document.getElementById('edit-multi-day'),
    startTimeField: document.getElementById('edit-start-time-field'),
    endTimeField: document.getElementById('edit-end-time-field'),
    endDateField: document.getElementById('edit-end-date-field'),
    endSection: document.getElementById('edit-end-section'),
    endDates: document.getElementById('edit-end-dates')
  };
}

function syncEditMultiDayLayout() {
  const fields = editElements();
  const multiDay = fields.multiDay.checked;
  const allDay = fields.allDay.checked;
  if (multiDay && !fields.endDate.value) fields.endDate.value = fields.date.value;
  fields.startTimeField.hidden = allDay;
  fields.endTimeField.hidden = allDay;
  fields.endDateField.hidden = !multiDay;
  fields.endSection.hidden = allDay && !multiDay;
  fields.endDates.classList.toggle('is-multi-day', multiDay);
  fields.endDates.classList.toggle('is-all-day', allDay);
}

function selectInitialEditWeekday() {
  const fields = editElements();
  if (!fields.date.value) return;
  const selectedDays = [...document.querySelectorAll('input[name="edit-recurrence-weekday"]:checked')];
  if (!selectedDays.length) {
    const [year, month, day] = fields.date.value.split('-').map(Number);
    const weekday = new Date(year, month - 1, day).getDay();
    const initialDay = weekday === 0 ? 7 : weekday;
    const checkbox = document.querySelector(`input[name="edit-recurrence-weekday"][value="${initialDay}"]`);
    if (checkbox) checkbox.checked = true;
  }
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
  if (endsAt && (new Date(endsAt) < new Date(startsAt)
    || (new Date(endsAt).getTime() === new Date(startsAt).getTime() && !(allDay && !fields.multiDay.checked)))) {
    throw new Error('La fine deve essere successiva all’inizio.');
  }
  return { startsAt, endsAt, allDay };
}

function focusOnEnter(next) {
  return (event) => {
    if (event.key !== 'Enter') return;
    event.preventDefault();
    next()?.focus();
  };
}

function renderStatus() {
  const select = document.getElementById('status-select');
  const save = document.getElementById('save-status');
  document.getElementById('status').textContent = statusLabel(eventData.status);
  document.getElementById('status-editor').hidden = !canManage;
  select.value = statusLabels[eventData.status] ? eventData.status : 'active';
  save.disabled = select.value === eventData.status;
}

async function render() {
  document.getElementById('event-title').textContent = eventData.title;
  document.getElementById('when').textContent = formatWhen(eventData.starts_at, eventData.ends_at, eventData.is_all_day);
  document.getElementById('location').textContent = eventData.location || '—';
  document.getElementById('notes').textContent = eventData.description || '—';
  const visibilityLabel = document.getElementById('event-visibility-label');
  const visibility = document.getElementById('event-visibility');
  const personalOwner = isPersonalOwnerEvent();
  visibilityLabel.hidden = !personalOwner;
  visibility.hidden = !personalOwner;
  visibility.textContent = eventData.calendar_private ? 'Privato' : 'Condivisibile';
  renderStatus();

  const recurrence = recurrenceOf(eventData);
  document.getElementById('recurrence-label').hidden = !recurrence.frequency;
  document.getElementById('recurrence').hidden = !recurrence.frequency;
  document.getElementById('recurrence').textContent = formatRecurrenceSummary(recurrence);

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
  const [{ data: event, error }, { data: account }] = await Promise.all([
    supabaseClient.rpc('get_event', { p_event_id: eventId }),
    supabaseClient.rpc('get_current_account')
  ]);
  if (error || !event) {
    message.textContent = 'Evento non disponibile.';
    return;
  }
  eventData = event;
  canManage = event.can_manage === true;
  isPersonalAccount = account?.account_type === 'personal';
  await render();
}

async function openEdit() {
  if (!canManage) return;
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
  document.getElementById('edit-recurrence-interval').value = recurrence.interval;
  document.querySelectorAll('input[name="edit-recurrence-weekday"]').forEach((input) => {
    input.checked = recurrence.weekdays.includes(Number(input.value));
  });
  document.getElementById('edit-recurrence-until').value = recurrence.until || '';
  const recurrenceEndMode = recurrence.frequency && !recurrence.hasEndDate ? 'never' : 'date';
  document.querySelector(`input[name="edit-recurrence-end-mode"][value="${recurrenceEndMode}"]`).checked = true;
  syncEditRecurrenceEndMode();
  setEditRecurrenceError();
  document.getElementById('edit-participants-fieldset').hidden = true;
  const privateFieldset = document.getElementById('edit-calendar-private-fieldset');
  privateFieldset.hidden = !isPersonalOwnerEvent();
  document.getElementById('edit-calendar-private-spacing').hidden = privateFieldset.hidden;
  document.getElementById('edit-calendar-private').checked = eventData.calendar_private === true;

  document.getElementById('event-view').hidden = true;
  form.hidden = false;
}

async function saveStatus() {
  if (!canManage) return;
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
  if (event.target.checked) selectInitialEditWeekday();
  setEditRecurrenceError();
});
document.querySelectorAll('input[name="edit-recurrence-end-mode"]').forEach((input) => input.addEventListener('change', () => {
  syncEditRecurrenceEndMode();
  setEditRecurrenceError();
}));
document.getElementById('edit-recurrence-interval').addEventListener('input', () => setEditRecurrenceError());
document.getElementById('edit-recurrence-until').addEventListener('input', () => setEditRecurrenceError());
document.querySelectorAll('input[name="edit-recurrence-weekday"]').forEach((input) => input.addEventListener('change', () => setEditRecurrenceError()));
document.getElementById('edit-multi-day').addEventListener('change', syncEditMultiDayLayout);
document.getElementById('edit-all-day').addEventListener('change', syncEditMultiDayLayout);
document.getElementById('edit-date').addEventListener('change', () => {
  const fields = editElements();
  if (fields.multiDay.checked && !fields.endDate.value) fields.endDate.value = fields.date.value;
  if (document.getElementById('edit-recurrence-enabled').checked) selectInitialEditWeekday();
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
  try {
    interval = buildEditInterval();
  } catch (error) {
    message.textContent = error.message;
    return;
  }
  let recurrence;
  try {
    recurrence = formRecurrence(document.getElementById('edit-date').value);
    setEditRecurrenceError();
  } catch (error) {
    setEditRecurrenceError(error.message);
    return;
  }

  const payload = {
    p_event_id: eventId,
    p_title: document.getElementById('edit-title').value.trim(),
    p_starts_at: interval.startsAt,
    p_ends_at: interval.endsAt,
    p_description: document.getElementById('edit-notes').value.trim() || null,
    p_is_all_day: interval.allDay,
    p_location: document.getElementById('edit-location').value.trim() || null,
    p_recurrence: recurrence
  };
  if (isPersonalOwnerEvent()) {
    payload.p_calendar_private = document.getElementById('edit-calendar-private').checked;
  }
  const { error } = await supabaseClient.rpc('update_event', payload);
  if (error) {
    message.textContent = 'Impossibile salvare le modifiche.';
    return;
  }

  document.getElementById('edit-form').hidden = true;
  document.getElementById('event-view').hidden = false;
  await load();
});

document.getElementById('delete-button').addEventListener('click', async () => {
  if (!canManage) return;
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
  const [{ data: participants, error: participantsError }, { data: contacts, error: contactsError }, { data: pendingInvites, error: pendingInvitesError }] = await Promise.all([
    supabaseClient.rpc('get_event_participants', { p_event_id: eventId }),
    supabaseClient.rpc('get_my_contacts_for_event', { p_event_id: eventId }),
    supabaseClient.rpc('get_pending_event_invites', { p_event_id: eventId })
  ]);
  if (participantsError || contactsError || pendingInvitesError) return;
  const selected = participants || [];
  list.replaceChildren();
  if (!selected.length) list.textContent = 'Nessun partecipante.';
  selected.forEach((person) => {
    const row = document.createElement('div');
    row.className = 'event-participant-row';
    row.textContent = `${person.first_name || ''} ${person.last_name || ''}`.trim() || 'Partecipante';
    if (canManage && person.contact_id) {
      const remove = document.createElement('button'); remove.type = 'button'; remove.textContent = 'Rimuovi';
      remove.addEventListener('click', async () => {
        if (!await FamilAreaConfirm.confirm({ variant: 'standard', title: 'Rimuovere il partecipante?', message: 'La persona resterà nei Contatti e negli altri elementi del Programma.', confirmText: 'Rimuovi' })) return;
        const { error } = await supabaseClient.rpc('remove_event_participant', { p_event_id: eventId, p_contact_id: person.contact_id });
        if (error) { message.textContent = 'Impossibile rimuovere il partecipante.'; return; }
        await renderParticipantControls();
      }); row.append(' ', remove);
    }
    list.appendChild(row);
  });
  if (!canManage) return;
  const available = (contacts || []).filter((contact) => !contact.is_active_participant);
  const actions = document.createElement('div');
  actions.className = 'event-participant-actions';
  const invite = document.createElement('button');
  invite.type = 'button';
  invite.className = 'secondary-button';
  invite.textContent = 'Invita una persona';
  invite.addEventListener('click', async () => {
    const recipient = await FamilAreaConfirm.form({
      title: 'Invita una persona',
      message: 'Crea un Contatto privato e un invito per questa attività.',
      confirmText: 'Crea invito',
      fields: [
        { name: 'firstName', label: 'Nome', required: true, autocomplete: 'given-name' },
        { name: 'lastName', label: 'Cognome', autocomplete: 'family-name' },
        { name: 'email', label: 'Email', type: 'email', required: true, autocomplete: 'email' }
      ]
    });
    if (!recipient) return;
    const email = recipient.email.trim();
    const firstName = recipient.firstName.trim();
    const lastName = recipient.lastName.trim() || null;
    const { data, error } = await supabaseClient.rpc('create_event_invite', {
      p_event_id: eventId, p_recipient_email: email, p_first_name: firstName, p_last_name: lastName
    });
    if (error) {
      const knownErrors = {
        'pending event invite already exists': 'Esiste già un invito in attesa per questa email.',
        'contact already participates in this event': 'Questa persona partecipa già all’attività.',
        'ambiguous contact email': 'L’email è associata a più Contatti. Verifica i Contatti prima di inviare l’invito.',
        'permission denied': 'Non hai i permessi per invitare persone a questa attività.'
      };
      console.error('create_event_invite failed', { code: error.code, message: error.message, details: error.details, hint: error.hint });
      message.textContent = knownErrors[error.message] || 'Impossibile creare l’invito attività. Riprova.';
      return;
    }
    await renderParticipantControls();
    message.textContent = `Invito creato per ${email}.`;
  });

  if (!available.length) {
    const unavailable = document.createElement('p');
    unavailable.className = 'event-participant-unavailable';
    unavailable.textContent = 'Non ci sono Contatti disponibili da aggiungere.';
    actions.append(unavailable);
  } else {
    const addControls = document.createElement('div');
    addControls.className = 'event-participant-add-controls';
    const select = document.createElement('select');
    select.id = 'event-participant-select';
    select.setAttribute('aria-label', 'Seleziona un contatto');
    select.append(new Option('Seleziona un contatto', ''));
    available.forEach((contact) => select.append(new Option(`${contact.first_name || ''} ${contact.last_name || ''}`.trim(), contact.contact_id)));
    const add = document.createElement('button');
    add.type = 'button';
    add.className = 'fa-button fa-button-primary fa-button-compact';
    add.textContent = 'Aggiungi';
    add.disabled = true;
    select.addEventListener('change', () => { add.disabled = !select.value; });
    add.addEventListener('click', async () => {
      if (!select.value) return;
      const { error } = await supabaseClient.rpc('add_event_participant', { p_event_id: eventId, p_contact_id: select.value });
      if (error) { message.textContent = 'Impossibile aggiungere il partecipante.'; return; }
      await renderParticipantControls();
    });
    addControls.append(select, add);
    actions.append(addControls);
  }
  const invitePrompt = document.createElement('div');
  invitePrompt.className = 'event-participant-invite';
  const prompt = document.createElement('p');
  prompt.textContent = 'La persona non è ancora nei Contatti?';
  invitePrompt.append(prompt, invite);
  actions.append(invitePrompt);
  if ((pendingInvites || []).length) {
    const pendingSection = document.createElement('section');
    pendingSection.className = 'event-pending-invites';
    const pendingTitle = document.createElement('h3');
    pendingTitle.textContent = 'Inviti in attesa';
    pendingSection.appendChild(pendingTitle);
    pendingInvites.forEach((pendingInvite) => {
      const row = document.createElement('div');
      row.className = 'event-pending-invite-row';
      const details = document.createElement('div');
      const fullName = `${pendingInvite.first_name || ''} ${pendingInvite.last_name || ''}`.trim() || 'Contatto';
      const name = document.createElement('strong'); name.textContent = fullName;
      const email = document.createElement('span'); email.textContent = pendingInvite.recipient_email;
      const state = document.createElement('span'); state.className = 'event-pending-invite-state'; state.textContent = 'In attesa';
      details.append(name, email, state);
      const rowActions = document.createElement('div');
      rowActions.className = 'event-pending-invite-actions';
      const linkAction = document.createElement('button');
      linkAction.type = 'button';
      linkAction.className = 'secondary-button';
      linkAction.textContent = 'Genera nuovo link';
      linkAction.addEventListener('click', async () => {
        try {
          const { data, error } = await supabaseClient.rpc('regenerate_event_invite_link', { p_event_invite_id: pendingInvite.invite_id });
          if (error) throw error;
          await copyInviteUrl(eventInviteUrl(data.token));
          message.textContent = 'Link invito copiato. Ora invialo alla persona invitata.';
        } catch (error) {
          console.error('event invite link failed', { code: error.code, message: error.message, details: error.details, hint: error.hint });
          message.textContent = 'Non è stato possibile generare o copiare il link invito.';
        }
      });
      const cancelAction = document.createElement('button');
      cancelAction.type = 'button';
      cancelAction.className = 'area-delete-button event-pending-invite-cancel';
      cancelAction.textContent = 'Annulla invito';
      cancelAction.addEventListener('click', async () => {
        const confirmed = await FamilAreaConfirm.confirm({
          variant: 'danger',
          title: 'Annulla invito',
          message: `Vuoi annullare l'invito inviato a ${fullName} (${pendingInvite.recipient_email})?`,
          cancelText: 'Annulla',
          confirmText: 'Annulla invito'
        });
        if (!confirmed) return;
        cancelAction.disabled = true;
        const { error } = await supabaseClient.rpc('cancel_event_invite', { p_event_invite_id: pendingInvite.invite_id });
        if (error) {
          console.error('cancel_event_invite failed', { code: error.code, message: error.message, details: error.details, hint: error.hint });
          message.textContent = 'Non è stato possibile annullare l’invito. Riprova.';
          cancelAction.disabled = false;
          return;
        }
        await renderParticipantControls();
        message.textContent = 'Invito annullato.';
      });
      rowActions.append(linkAction, cancelAction);
      row.append(details, rowActions);
      pendingSection.appendChild(row);
    });
    actions.appendChild(pendingSection);
  }
  list.appendChild(actions);
}
function isPersonalOwnerEvent() {
  return isPersonalAccount && canManage && !eventData.area_id && eventData.visibility_source === 'owner';
}

const renderEventView = render;
render = async function () { await renderEventView(); await renderParticipantControls(); };
load();

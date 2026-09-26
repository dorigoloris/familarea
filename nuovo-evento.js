const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const areaId = new URLSearchParams(location.search).get('area_id');
const form = document.getElementById('event-form');
const message = document.getElementById('message');
const participants = document.getElementById('participants');
const startDateInput = document.getElementById('start-date');
const startTimeInput = document.getElementById('start-time');
const endDateInput = document.getElementById('end-date');
const endTimeInput = document.getElementById('end-time');
const allDayInput = document.getElementById('all-day');
const multiDayInput = document.getElementById('multi-day');
const startDates = document.getElementById('event-start-dates');
const startTimeField = document.getElementById('start-time-field');
const endTimeField = document.getElementById('end-time-field');
const normalEndTimeSlot = document.getElementById('end-time-normal-slot');
const multiDayEndTimeSlot = document.getElementById('end-time-multi-day-slot');
const multiDayEndRow = document.getElementById('multi-day-end-row');
let isPersonalAccount = false;

function localIso(date, time = '00:00') { return new Date(`${date}T${time}`).toISOString(); }
function participantIds() { return [...participants.querySelectorAll('input:checked')].map((input) => input.value); }
function recurrence(startDate) {
  if (!document.getElementById('recurrence-enabled').checked) return {};
  const until = document.getElementById('recurrence-until').value;
  if (!until) throw new Error('Indica la fine della ripetizione.');
  if (until < startDate) throw new Error('La fine della ripetizione non può precedere la data iniziale.');
  return { frequency: 'weekly', until, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC' };
}

function syncMultiDayLayout() {
  const multiDay = multiDayInput.checked;
  const allDay = allDayInput.checked;
  if (multiDay && !endDateInput.value) endDateInput.value = startDateInput.value;
  (multiDay ? multiDayEndTimeSlot : normalEndTimeSlot).appendChild(endTimeField);
  normalEndTimeSlot.hidden = multiDay || allDay;
  multiDayEndRow.hidden = !multiDay;
  startDates.classList.toggle('is-multi-day', multiDay);
  startDates.classList.toggle('is-all-day', allDay);
  multiDayEndRow.classList.toggle('is-all-day', allDay);
  startTimeField.hidden = allDay;
  endTimeField.hidden = allDay;
}

function buildInterval() {
  const startDate = startDateInput.value;
  const startTime = startTimeInput.value;
  const endDate = multiDayInput.checked ? endDateInput.value : startDate;
  const endTime = endTimeInput.value;
  const allDay = allDayInput.checked || !startTime;
  if (!startDate) throw new Error('Indica la data dell’evento.');
  if (multiDayInput.checked && !endDate) throw new Error('Indica la data di fine.');
  if (multiDayInput.checked && endDate <= startDate) {
    throw new Error(endDate === startDate
      ? 'Per un’attività di un solo giorno, disattiva Più giorni.'
      : 'La data di fine non può essere precedente alla data iniziale.');
  }
  if (!allDayInput.checked && endTime && !startTime) throw new Error('Indica prima l’ora di inizio.');
  if (multiDayInput.checked && !allDay && !endTime) throw new Error('Indica l’ora di fine.');

  const startsAt = localIso(startDate, allDay ? '00:00' : startTime);
  const endsAt = allDay
    ? (multiDayInput.checked ? localIso(endDate, '00:00') : startsAt)
    : endTime ? localIso(endDate, endTime) : null;
  if (endsAt && new Date(endsAt) <= new Date(startsAt)) {
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

async function loadParticipants() {
  const { data, error } = await supabaseClient.rpc('get_area_members', { p_area_id: areaId });
  if (error) throw error;
  (data || []).forEach((member) => {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.value = member.profile_id;
    label.append(input, ` ${member.first_name || ''} ${member.last_name || ''}`.trim());
    participants.append(label, document.createElement('br'));
  });
}

async function load() {
  const { data } = await supabaseClient.auth.getSession();
  if (!data.session) { location.href = 'login.html'; return; }
  document.getElementById('back-link').href = areaId ? `eventi.html?area_id=${encodeURIComponent(areaId)}` : 'eventi.html';
  document.getElementById('participants-fieldset').hidden = !areaId;
  const { data: account } = await supabaseClient.rpc('get_current_account');
  isPersonalAccount = account?.account_type === 'personal';
  const privateFieldset = document.getElementById('calendar-private-fieldset');
  privateFieldset.hidden = !isPersonalAccount || Boolean(areaId);
  document.getElementById('calendar-private-spacing').hidden = privateFieldset.hidden;
  document.getElementById('calendar-private').checked = false;
  if (areaId) {
    try { await loadParticipants(); }
    catch (_) { message.textContent = 'Impossibile caricare i partecipanti dell’Area.'; return; }
  }
  syncMultiDayLayout();
  form.hidden = false;
  message.textContent = '';
}

document.getElementById('recurrence-enabled').addEventListener('change', (event) => {
  document.getElementById('recurrence-fields').hidden = !event.target.checked;
});
multiDayInput.addEventListener('change', syncMultiDayLayout);
allDayInput.addEventListener('change', syncMultiDayLayout);
startDateInput.addEventListener('change', () => {
  if (multiDayInput.checked && !endDateInput.value) endDateInput.value = startDateInput.value;
});
startDateInput.addEventListener('keydown', focusOnEnter(() => allDayInput.checked ? (multiDayInput.checked ? endDateInput : null) : startTimeInput));
startTimeInput.addEventListener('keydown', focusOnEnter(() => multiDayInput.checked ? endDateInput : endTimeInput));
endDateInput.addEventListener('keydown', focusOnEnter(() => allDayInput.checked ? null : endTimeInput));
endTimeInput.addEventListener('keydown', focusOnEnter(() => null));

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  let interval;
  let recurrencePayload;
  try {
    interval = buildInterval();
    recurrencePayload = recurrence(startDateInput.value);
  } catch (error) {
    message.textContent = error.message;
    return;
  }
  const payload = {
    p_title: document.getElementById('title').value.trim(),
    p_starts_at: interval.startsAt,
    p_ends_at: interval.endsAt,
    p_description: document.getElementById('notes').value.trim() || null,
    p_area_id: areaId || null,
    p_is_all_day: interval.allDay,
    p_location: document.getElementById('location').value.trim() || null,
    p_recurrence: recurrencePayload
  };
  if (isPersonalAccount && !areaId) {
    payload.p_calendar_private = document.getElementById('calendar-private').checked;
  }
  const submit = form.querySelector('[type="submit"]');
  submit.disabled = true;
  const { data, error } = await supabaseClient.rpc('create_event', payload);
  submit.disabled = false;
  if (error || !data) { message.textContent = 'Impossibile creare l’evento.'; return; }
  if (areaId && participantIds().length) {
    const result = await supabaseClient.rpc('set_event_participants', { p_event_id: data, p_profile_ids: participantIds() });
    if (result.error) { message.textContent = 'Evento creato, ma non è stato possibile salvare i partecipanti.'; return; }
  }
  location.href = `evento.html${areaId ? `?area_id=${encodeURIComponent(areaId)}&` : '?'}event_id=${encodeURIComponent(data)}`;
});

load();

const newActivityClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const form = document.getElementById('activity-form');
const backLink = document.getElementById('back-link');
const recurrenceEnabled = document.getElementById('recurrence-enabled');
const recurrenceFields = document.getElementById('recurrence-fields');
const saveButton = document.getElementById('save-button');
const activityQuery = new URLSearchParams(window.location.search);
const calendarPrefillDate = /^\d{4}-\d{2}-\d{2}$/.test(activityQuery.get('date') || '') ? activityQuery.get('date') : '';
const calendarPrefillTime = /^\d{2}:\d{2}$/.test(activityQuery.get('time') || '') ? activityQuery.get('time') : '';

function setMessage(text = '') {
  message.textContent = text;
  message.hidden = !text;
}

function syncRecurrenceFields() {
  recurrenceFields.hidden = !recurrenceEnabled.checked;
}

function combineLocalDateAndTime(dateValue, timeValue) {
  if (!dateValue) return null;
  const [year, month, day] = dateValue.split('-').map(Number);
  const [hours, minutes] = (timeValue || '00:00').split(':').map(Number);
  return new Date(year, month - 1, day, hours, minutes).toISOString();
}

function recurrencePayload() {
  if (!recurrenceEnabled.checked) return {};
  const dateValue = document.getElementById('activity-date').value;
  const until = document.getElementById('recurrence-until').value;
  const weekday = Number(document.getElementById('recurrence-weekday').value);
  if (!dateValue) throw new Error('Per una ricorrenza settimanale è necessaria una data.');
  if (!weekday || weekday < 1 || weekday > 7) throw new Error('Seleziona un giorno della settimana valido.');
  if (until && until < dateValue) throw new Error('La fine della ripetizione non può precedere la data dell’attività.');
  return {
    frequency: 'weekly',
    interval: 1,
    weekdays: [weekday],
    until: until || null,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'Europe/Rome'
  };
}

function schedulePayload() {
  const dateValue = document.getElementById('activity-date').value;
  const startTime = document.getElementById('start-time').value;
  const endTime = document.getElementById('end-time').value;
  if (!dateValue && (startTime || endTime || recurrenceEnabled.checked)) {
    throw new Error('Inserisci una data per specificare orario o ricorrenza.');
  }
  if (startTime && endTime && endTime < startTime) {
    throw new Error('L’ora di fine non può precedere l’ora di inizio.');
  }
  return {
    startsAt: dateValue ? combineLocalDateAndTime(dateValue, startTime) : null,
    dueAt: dateValue ? combineLocalDateAndTime(dateValue, endTime || startTime) : null,
    isAllDay: Boolean(dateValue && !startTime && !endTime)
  };
}

async function load() {
  const accountResult = await newActivityClient.rpc('get_current_account');
  if (accountResult.error || !accountResult.data) {
    setMessage('Impossibile verificare l’account corrente.');
    return;
  }
  backLink.href = 'attivita-globali.html';
  backLink.textContent = 'Torna alle Attività';
  if (calendarPrefillDate) document.getElementById('activity-date').value = calendarPrefillDate;
  if (calendarPrefillTime) document.getElementById('start-time').value = calendarPrefillTime;
  form.hidden = false;
  setMessage();
}

async function createActivity(event) {
  event.preventDefault();
  const title = document.getElementById('title').value.trim();
  if (!title) {
    setMessage('Inserisci un titolo per l’attività.');
    return;
  }
  let schedule;
  let recurrence;
  try {
    schedule = schedulePayload();
    recurrence = recurrencePayload();
  } catch (error) {
    setMessage(error.message);
    return;
  }

  saveButton.disabled = true;
  try {
    const result = await newActivityClient.rpc('create_activity', {
      p_title: title,
      p_description: document.getElementById('notes').value.trim() || null,
      p_area_id: null,
      p_starts_at: schedule.startsAt,
      p_due_at: schedule.dueAt,
      p_is_all_day: schedule.isAllDay,
      p_priority: document.getElementById('priority').value,
      p_recurrence: recurrence,
      p_activity_type: document.getElementById('activity-type').value
    });
    if (result.error || !result.data) throw result.error || new Error('Creazione non riuscita.');
    window.location.assign(`attivita.html?activity_id=${encodeURIComponent(result.data)}`);
  } catch (error) {
    setMessage(error.message || 'Impossibile creare l’attività.');
  } finally {
    saveButton.disabled = false;
  }
}

document.getElementById('cancel-button').addEventListener('click', () => window.location.assign('attivita-globali.html'));
recurrenceEnabled.addEventListener('change', syncRecurrenceFields);
form.addEventListener('submit', createActivity);
load();

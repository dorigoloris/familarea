const activityClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const activityParams = new URLSearchParams(window.location.search);
const activityId = activityParams.get('activity_id');

const message = document.getElementById('message');
const activityView = document.getElementById('activity-view');
const editForm = document.getElementById('edit-form');
const backLink = document.getElementById('back-link');
const activityActions = document.getElementById('activity-actions');
const statusActions = document.getElementById('personal-status-actions');
const recurrenceRow = document.getElementById('activity-recurrence-row');
const recurrenceToggle = document.getElementById('edit-recurrence-enabled');
const recurrenceFields = document.getElementById('edit-recurrence-fields');
const statusSelect = document.getElementById('personal-status');
const saveStatusButton = document.getElementById('save-personal-status');
const saveButton = document.getElementById('save-button');

let activity = null;
let currentAccount = null;
let canManage = false;

const typeLabels = {
  task: 'Da fare',
  reminder: 'Promemoria',
  deadline: 'Scadenza',
  appointment: 'Appuntamento'
};

const priorityLabels = {
  low: 'Bassa',
  normal: 'Normale',
  high: 'Alta'
};

const statusLabels = {
  open: 'Aperta',
  completed: 'Completata',
  cancelled: 'Annullata'
};

const weekdayLabels = {
  1: 'lunedì',
  2: 'martedì',
  3: 'mercoledì',
  4: 'giovedì',
  5: 'venerdì',
  6: 'sabato',
  7: 'domenica'
};

function setMessage(text = '') {
  message.textContent = text;
  message.hidden = !text;
}

function returnUrl() {
  return 'attivita-globali.html';
}

function formatDateTime(value, allDay = false) {
  if (!value) return 'Non indicata';
  return new Intl.DateTimeFormat('it-IT', allDay
    ? { dateStyle: 'long' }
    : { dateStyle: 'medium', timeStyle: 'short' }
  ).format(new Date(value));
}

function formatWhen(record) {
  const start = record.starts_at;
  const due = record.due_at;
  if (!start && !due) return 'Non indicata';
  if (!start || !due || start === due) return formatDateTime(start || due, record.is_all_day);
  return `${formatDateTime(start, record.is_all_day)} – ${formatDateTime(due, record.is_all_day)}`;
}

function dateInputValue(value) {
  if (!value) return '';
  const date = new Date(value);
  const offset = date.getTimezoneOffset();
  return new Date(date.getTime() - offset * 60_000).toISOString().slice(0, 10);
}

function timeInputValue(value) {
  if (!value) return '';
  return new Intl.DateTimeFormat('it-IT', {
    hour: '2-digit',
    minute: '2-digit',
    hour12: false
  }).format(new Date(value));
}

function combineLocalDateAndTime(dateValue, timeValue) {
  if (!dateValue) return null;
  const [year, month, day] = dateValue.split('-').map(Number);
  const [hours, minutes] = (timeValue || '00:00').split(':').map(Number);
  return new Date(year, month - 1, day, hours, minutes).toISOString();
}

function weekdayForDate(dateValue) {
  if (!dateValue) return null;
  const day = new Date(`${dateValue}T12:00:00`).getDay();
  return day === 0 ? 7 : day;
}

function recurrencePayload() {
  if (!recurrenceToggle.checked) return {};

  const dateValue = document.getElementById('edit-activity-date').value;
  const until = document.getElementById('edit-recurrence-until').value;
  const weekday = Number(document.getElementById('edit-recurrence-weekday').value);

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
  const dateValue = document.getElementById('edit-activity-date').value;
  const startTime = document.getElementById('edit-start-time').value;
  const endTime = document.getElementById('edit-end-time').value;

  if (!dateValue && (startTime || endTime || recurrenceToggle.checked)) {
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

function recurrenceSummary(record) {
  if (record.recurrence_frequency !== 'weekly') return '';
  const weekday = Array.isArray(record.recurrence_weekdays)
    ? record.recurrence_weekdays[0]
    : null;
  const day = weekdayLabels[weekday] || 'giorno selezionato';
  return record.recurrence_until
    ? `Ogni ${day}, fino al ${new Intl.DateTimeFormat('it-IT', { dateStyle: 'long' }).format(new Date(`${record.recurrence_until}T12:00:00`))}`
    : `Ogni ${day}`;
}

function renderDetail() {
  document.getElementById('activity-title').textContent = activity.title || 'Attività';
  document.getElementById('activity-type').textContent = typeLabels[activity.activity_type] || activity.activity_type || 'Attività';
  document.getElementById('activity-priority').textContent = priorityLabels[activity.priority] || activity.priority || 'Normale';
  document.getElementById('activity-status').textContent = statusLabels[activity.status] || activity.status || 'Aperta';
  document.getElementById('activity-due').textContent = formatWhen(activity);
  document.getElementById('activity-notes').textContent = activity.description || 'Nessuna nota.';

  const recurrence = recurrenceSummary(activity);
  recurrenceRow.hidden = !recurrence;
  document.getElementById('activity-recurrence').textContent = recurrence;

  activityActions.hidden = !canManage;
  statusActions.hidden = !canManage;
  statusSelect.value = activity.status || 'open';
  backLink.href = returnUrl();
  backLink.textContent = 'Torna alle Attività';
  activityView.hidden = false;
}

async function loadActivity() {
  if (!activityId) {
    setMessage('Attività non identificata.');
    return false;
  }

  setMessage('Caricamento...');
  activityView.hidden = true;
  const result = await activityClient.rpc('get_activity', { p_activity_id: activityId });
  if (result.error || !result.data) {
    setMessage('Attività non disponibile.');
    return false;
  }

  activity = result.data;
  const accountResult = await activityClient.rpc('get_current_account');
  if (accountResult.error || !accountResult.data) {
    setMessage('Impossibile verificare l’account corrente.');
    return false;
  }
  currentAccount = accountResult.data;

  canManage = activity.owner_account_id === currentAccount.account_id;

  renderDetail();
  setMessage();
  return true;
}

function syncRecurrenceFields() {
  recurrenceFields.hidden = !recurrenceToggle.checked;
}

async function openEditForm() {
  if (!canManage || !activity) return;
  try {
    setMessage('');
    document.getElementById('edit-title').value = activity.title || '';
    document.getElementById('edit-type').value = activity.activity_type || 'task';
    document.getElementById('edit-priority').value = activity.priority || 'normal';
    document.getElementById('edit-notes').value = activity.description || '';
    document.getElementById('edit-activity-date').value = dateInputValue(activity.starts_at || activity.due_at);
    document.getElementById('edit-start-time').value = activity.is_all_day ? '' : timeInputValue(activity.starts_at);
    document.getElementById('edit-end-time').value = activity.is_all_day ? '' : timeInputValue(activity.due_at);

    recurrenceToggle.checked = activity.recurrence_frequency === 'weekly';
    document.getElementById('edit-recurrence-weekday').value = String(
      activity.recurrence_weekdays?.[0] || weekdayForDate(document.getElementById('edit-activity-date').value) || 1
    );
    document.getElementById('edit-recurrence-until').value = activity.recurrence_until || '';
    syncRecurrenceFields();

    activityView.hidden = true;
    editForm.hidden = false;
    document.getElementById('edit-title').focus();
  } catch (error) {
    setMessage(error.message || 'Impossibile preparare la modifica.');
  }
}

function closeEditForm() {
  editForm.hidden = true;
  activityView.hidden = false;
  setMessage();
}

async function saveActivity(event) {
  event.preventDefault();
  if (!canManage || !activity) return;

  const title = document.getElementById('edit-title').value.trim();
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
    const updateResult = await activityClient.rpc('update_activity', {
      p_activity_id: activity.id,
      p_title: title,
      p_description: document.getElementById('edit-notes').value.trim() || null,
      p_starts_at: schedule.startsAt,
      p_due_at: schedule.dueAt,
      p_is_all_day: schedule.isAllDay,
      p_priority: document.getElementById('edit-priority').value,
      p_recurrence: recurrence,
      p_activity_type: document.getElementById('edit-type').value
    });
    if (updateResult.error) throw updateResult.error;

    if (await loadActivity()) closeEditForm();
  } catch (error) {
    setMessage(error.message || 'Impossibile salvare l’attività.');
  } finally {
    saveButton.disabled = false;
  }
}

async function saveStatus() {
  if (!canManage || !activity) return;
  saveStatusButton.disabled = true;
  try {
    const result = await activityClient.rpc('set_activity_status', {
      p_activity_id: activity.id,
      p_status: statusSelect.value
    });
    if (result.error) throw result.error;
    await loadActivity();
  } catch (error) {
    setMessage(error.message || 'Impossibile aggiornare lo stato.');
  } finally {
    saveStatusButton.disabled = false;
  }
}

async function deleteActivity() {
  if (!canManage || !activity) return;
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: 'Eliminare l’attività?',
    message: 'L’attività verrà eliminata definitivamente.',
    confirmText: 'Elimina'
  });
  if (!confirmed) return;

  const deleteButton = document.getElementById('delete-button');
  deleteButton.disabled = true;
  try {
    const result = await activityClient.rpc('delete_activity', { p_activity_id: activity.id });
    if (result.error) throw result.error;
    window.location.assign(returnUrl());
  } catch (error) {
    setMessage(error.message || 'Impossibile eliminare l’attività.');
    deleteButton.disabled = false;
  }
}

document.getElementById('edit-button').addEventListener('click', openEditForm);
document.getElementById('delete-button').addEventListener('click', deleteActivity);
document.getElementById('cancel-button').addEventListener('click', closeEditForm);
document.getElementById('save-personal-status').addEventListener('click', saveStatus);
recurrenceToggle.addEventListener('change', syncRecurrenceFields);
editForm.addEventListener('submit', saveActivity);

loadActivity();

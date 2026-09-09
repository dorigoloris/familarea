const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const view = document.getElementById('activity-view');
const editForm = document.getElementById('edit-form');
const backLink = document.getElementById('back-link');
const actions = document.getElementById('activity-actions');
const editButton = document.getElementById('edit-button');
const deleteButton = document.getElementById('delete-button');
const cancelButton = document.getElementById('cancel-button');
const editAssignees = document.getElementById('edit-assignees');
const visibilityInputs = [...document.querySelectorAll('input[name="visibility"]')];
const visibilityHelp = document.getElementById('visibility-help');
const recurrenceEnabled = document.getElementById('edit-recurrence-enabled');
const recurrenceFields = document.getElementById('edit-recurrence-fields');
const recurrenceWeekday = document.getElementById('edit-recurrence-weekday');
const editSubmitButton = editForm.querySelector('button[type="submit"]');
let areaId; let activityId; let ownProfileId; let ownRole; let memberships = []; let activity;
let recurrenceWeekdayManuallySelected = false;

const labels = {
  type: { task: 'Da fare', reminder: 'Promemoria', deadline: 'Scadenza', appointment: 'Appuntamento' },
  priority: { low: 'Bassa', normal: 'Normale', high: 'Alta' },
  status: { open: 'Aperta', completed: 'Completata', cancelled: 'Annullata' },
  visibility: { private: 'Solo tu', creator_assignees: 'Solo tu e gli assegnatari', area: 'Tutti i partecipanti dell’Area' }
};
function label(group, value) { return labels[group][value] || value; }
function formatDate(value, isAllDay) {
  if (!value) return 'Non indicata';
  return new Intl.DateTimeFormat('it-IT', isAllDay ? { dateStyle: 'long' } : { dateStyle: 'long', timeStyle: 'short' }).format(new Date(value));
}
function localDateInput(value) { const d = value && new Date(value); return d ? `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` : ''; }
function localTimeInput(value) { const d = value && new Date(value); return d ? `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}` : ''; }
function localIso(dateValue, timeValue) { const [y, m, d] = dateValue.split('-').map(Number); const [h, min] = timeValue.split(':').map(Number); return new Date(y, m - 1, d, h, min).toISOString(); }
function isoWeekday(dateValue) { const [y, m, d] = dateValue.split('-').map(Number); return ((new Date(y, m - 1, d).getDay() + 6) % 7) + 1; }
function recurrenceTimezone() { return Intl.DateTimeFormat().resolvedOptions().timeZone?.trim() || ''; }
function weeklyDescription(dateValue = localDateInput(activity.starts_at)) { return `Ogni ${new Intl.DateTimeFormat('it-IT', { weekday: 'long' }).format(new Date(`${dateValue}T12:00:00`))}`; }
function recurrenceDescription() {
  if (activity.recurrence_frequency !== 'weekly') return '';
  const interval = activity.starts_at && activity.due_at ? `${localTimeInput(activity.starts_at)}–${localTimeInput(activity.due_at)}` : '';
  return [weeklyDescription(), interval, `Dal ${formatDate(activity.starts_at, true)} al ${new Intl.DateTimeFormat('it-IT', { dateStyle: 'long' }).format(new Date(`${activity.recurrence_until}T12:00:00`))}`].filter(Boolean).join('\n');
}
function suggestWeekdayFromDate() {
  const dateValue = document.getElementById('edit-activity-date').value;
  if (dateValue && !recurrenceWeekdayManuallySelected) recurrenceWeekday.value = String(isoWeekday(dateValue));
}
function toggleRecurrenceFields() { recurrenceFields.hidden = !recurrenceEnabled.checked; if (recurrenceEnabled.checked) suggestWeekdayFromDate(); }
function schedulePayload() {
  const dateValue = document.getElementById('edit-activity-date').value;
  const startTime = document.getElementById('edit-start-time').value;
  const endTime = document.getElementById('edit-end-time').value;
  const recurrenceUntil = document.getElementById('edit-recurrence-until').value;
  if (!dateValue) {
    if (startTime || endTime) throw new Error('Inserisci una data prima di indicare un orario.');
    if (recurrenceEnabled.checked) throw new Error('Per ripetere un’attività, inserisci la data iniziale.');
    return { startsAt: null, dueAt: null, isAllDay: false, recurrence: null, updateRecurrence: Boolean(activity.recurrence_frequency) };
  }
  if (endTime && !startTime) throw new Error('Inserisci l’ora di inizio prima dell’ora di fine.');
  if (startTime && endTime && endTime <= startTime) throw new Error('L’ora di fine deve essere successiva all’ora di inizio.');
  if (recurrenceEnabled.checked) {
    const timezone = recurrenceTimezone();
    if (!startTime || !endTime) throw new Error('Per una ripetizione settimanale indica ora di inizio e ora di fine.');
    if (!recurrenceUntil) throw new Error('Indica la fine della ripetizione.');
    if (recurrenceUntil < dateValue) throw new Error('La fine della ripetizione non può precedere la data iniziale.');
    if (!timezone) throw new Error('Impossibile rilevare la timezone del browser.');
    return { startsAt: localIso(dateValue, startTime), dueAt: localIso(dateValue, endTime), isAllDay: false, recurrence: { p_recurrence_frequency: 'weekly', p_recurrence_interval: 1, p_recurrence_weekdays: [Number(recurrenceWeekday.value)], p_recurrence_until: recurrenceUntil, p_recurrence_timezone: timezone }, updateRecurrence: true };
  }
  const single = !startTime ? { startsAt: null, dueAt: new Date(`${dateValue}T00:00:00`).toISOString(), isAllDay: true } : { startsAt: localIso(dateValue, startTime), dueAt: endTime ? localIso(dateValue, endTime) : localIso(dateValue, startTime), isAllDay: false };
  return { ...single, recurrence: activity.recurrence_frequency ? { p_recurrence_frequency: null, p_recurrence_interval: null, p_recurrence_weekdays: null, p_recurrence_until: null, p_recurrence_timezone: null } : null, updateRecurrence: Boolean(activity.recurrence_frequency) };
}
function currentAssigneeIds() { return [...editAssignees.querySelectorAll('input:checked')].map((input) => input.value); }
function friendlyError(error, fallback) { return /permission denied|non accessibile|not authorized/i.test(error?.message || '') ? 'Non sei autorizzato a eseguire questa operazione.' : fallback; }
function sameIds(left, right) { return [...left].sort().join(',') === [...right].sort().join(','); }
function canEdit() { return activity.created_by_profile_id === ownProfileId || (activity.visibility === 'area' && ownRole === 'admin'); }
function canDelete() { return (activity.visibility === 'area' && ownRole === 'admin') || (activity.created_by_profile_id === ownProfileId && (activity.visibility !== 'area' || activity.status === 'open')); }
function memberName(profileId) { const profile = memberships.find((item) => item.profile_id === profileId)?.profiles; return `${profile?.first_name || ''} ${profile?.last_name || ''}`.trim() || 'Partecipante dell’Area'; }
function renderActivity() {
  document.getElementById('activity-title').textContent = activity.title;
  document.getElementById('activity-type').textContent = label('type', activity.activity_type);
  document.getElementById('activity-priority').textContent = label('priority', activity.priority);
  document.getElementById('activity-status').textContent = label('status', activity.status);
  document.getElementById('activity-visibility').textContent = label('visibility', activity.visibility);
  document.getElementById('activity-due').textContent = activity.starts_at && !activity.is_all_day && activity.due_at ? `${formatDate(activity.starts_at, false)}${localTimeInput(activity.due_at) !== localTimeInput(activity.starts_at) ? `–${localTimeInput(activity.due_at)}` : ''}` : formatDate(activity.due_at, activity.is_all_day);
  const recurrence = recurrenceDescription();
  document.getElementById('activity-recurrence-label').hidden = !recurrence;
  const recurrenceNode = document.getElementById('activity-recurrence'); recurrenceNode.hidden = !recurrence; recurrenceNode.textContent = recurrence;
  document.getElementById('activity-notes').textContent = activity.notes || 'Nessuna nota.';
  const assigneeNames = (activity.assignee_profile_ids || []).map(memberName);
  document.getElementById('activity-assignees').textContent = assigneeNames.length ? assigneeNames.join(', ') : 'Nessun assegnatario.';
  actions.hidden = !canEdit() && !canDelete(); editButton.hidden = !canEdit(); deleteButton.hidden = !canDelete(); view.hidden = false;
}
function updateVisibilityChoices() {
  const hasAssignees = currentAssigneeIds().length > 0;
  const creator = visibilityInputs.find((input) => input.value === 'creator_assignees'); const privateInput = visibilityInputs.find((input) => input.value === 'private'); const areaInput = visibilityInputs.find((input) => input.value === 'area');
  creator.disabled = !hasAssignees; creator.parentElement.hidden = !hasAssignees; privateInput.disabled = hasAssignees; privateInput.parentElement.hidden = hasAssignees;
  if (hasAssignees) { visibilityHelp.textContent = 'Con assegnatari, scegli se condividerla solo con loro o con tutta l’Area.'; if (!creator.checked && !areaInput.checked) creator.checked = true; }
  else { visibilityHelp.textContent = 'Scegli chi può vedere l’attività.'; if (creator.checked) creator.checked = false; if (!privateInput.checked && !areaInput.checked) privateInput.checked = true; }
}
function prepareEditForm() {
  document.getElementById('edit-title').value = activity.title; document.getElementById('edit-type').value = activity.activity_type; document.getElementById('edit-priority').value = activity.priority; document.getElementById('edit-notes').value = activity.notes || '';
  document.getElementById('edit-activity-date').value = localDateInput(activity.starts_at || activity.due_at);
  document.getElementById('edit-start-time').value = activity.is_all_day ? '' : localTimeInput(activity.starts_at || activity.due_at);
  document.getElementById('edit-end-time').value = activity.is_all_day ? '' : localTimeInput(activity.due_at);
  recurrenceEnabled.checked = activity.recurrence_frequency === 'weekly';
  recurrenceWeekdayManuallySelected = recurrenceEnabled.checked;
  recurrenceWeekday.value = String(activity.recurrence_weekdays?.[0] || (document.getElementById('edit-activity-date').value ? isoWeekday(document.getElementById('edit-activity-date').value) : 1));
  document.getElementById('edit-recurrence-until').value = activity.recurrence_until || ''; toggleRecurrenceFields();
  editAssignees.replaceChildren(); const selected = new Set(activity.assignee_profile_ids || []);
  memberships.forEach((membership) => { const labelElement = document.createElement('label'); const input = document.createElement('input'); input.type = 'checkbox'; input.value = membership.profile_id; input.checked = selected.has(membership.profile_id); input.addEventListener('change', updateVisibilityChoices); labelElement.append(input, ` ${memberName(membership.profile_id)}`); editAssignees.append(labelElement, document.createElement('br')); });
  visibilityInputs.forEach((input) => { input.checked = input.value === activity.visibility; }); updateVisibilityChoices();
}
async function loadActivity() { message.textContent = 'Caricamento attività...'; const { data, error } = await supabaseClient.rpc('get_area_activity', { p_area_id: areaId, p_activity_id: activityId }); if (error || !data?.[0]) { message.textContent = friendlyError(error, 'Attività non disponibile.'); return; } activity = data[0]; renderActivity(); message.textContent = ''; }
async function load() {
  const { data: sessionData } = await supabaseClient.auth.getSession(); if (!sessionData.session) { window.location.href = 'login.html'; return; }
  areaId = new URLSearchParams(window.location.search).get('area_id'); activityId = new URLSearchParams(window.location.search).get('activity_id'); if (!areaId || !activityId) { message.textContent = 'Attività non specificata.'; return; }
  backLink.href = `attivita-area.html?area_id=${encodeURIComponent(areaId)}`;
  const { data: ownProfile } = await supabaseClient.from('profiles').select('id').eq('user_id', sessionData.session.user.id).single(); const { data, error } = await supabaseClient.from('area_memberships').select('profile_id,role,profiles(first_name,last_name)').eq('area_id', areaId);
  if (!ownProfile || error || !data) { message.textContent = 'Impossibile preparare la pagina attività.'; return; }
  ownProfileId = ownProfile.id; memberships = data; ownRole = memberships.find((membership) => membership.profile_id === ownProfileId)?.role; if (!ownRole || ownRole === 'managed') { message.textContent = 'Non sei autorizzato a consultare questa attività.'; return; } await loadActivity();
}
editButton.addEventListener('click', () => { prepareEditForm(); view.hidden = true; editForm.hidden = false; });
cancelButton.addEventListener('click', () => { editForm.hidden = true; view.hidden = false; });
document.getElementById('edit-activity-date').addEventListener('change', () => { if (recurrenceEnabled.checked) suggestWeekdayFromDate(); });
recurrenceEnabled.addEventListener('change', () => { if (!recurrenceEnabled.checked) recurrenceWeekdayManuallySelected = false; toggleRecurrenceFields(); });
recurrenceWeekday.addEventListener('change', () => {
  recurrenceWeekdayManuallySelected = true;
  const dateInput = document.getElementById('edit-activity-date');
  if (!dateInput.value) return;
  const current = isoWeekday(dateInput.value);
  const target = Number(recurrenceWeekday.value);
  const [year, month, day] = dateInput.value.split('-').map(Number);
  const next = new Date(year, month - 1, day + ((target - current + 7) % 7));
  dateInput.value = `${next.getFullYear()}-${String(next.getMonth() + 1).padStart(2, '0')}-${String(next.getDate()).padStart(2, '0')}`;
});
editForm.addEventListener('submit', async (event) => {
  event.preventDefault(); const assigneeIds = currentAssigneeIds(); const visibility = visibilityInputs.find((input) => input.checked)?.value; if (!visibility) { message.textContent = 'Scegli la visibilità dell’attività.'; return; }
  let schedule; try { schedule = schedulePayload(); } catch (error) { message.textContent = error.message; return; }
  editSubmitButton.disabled = true; message.textContent = 'Salvataggio in corso...';
  try {
    if (!sameIds(assigneeIds, activity.assignee_profile_ids || []) || visibility !== activity.visibility) { const { error } = await supabaseClient.rpc('set_area_activity_assignees', { p_area_id: areaId, p_activity_id: activityId, p_assignee_profile_ids: assigneeIds, p_visibility: visibility }); if (error) throw error; }
    const { error } = await supabaseClient.rpc('update_area_activity', { p_area_id: areaId, p_activity_id: activityId, p_title: document.getElementById('edit-title').value.trim(), p_notes: document.getElementById('edit-notes').value.trim() || null, p_activity_type: document.getElementById('edit-type').value, p_priority: document.getElementById('edit-priority').value, p_starts_at: schedule.startsAt, p_due_at: schedule.dueAt, p_is_all_day: schedule.isAllDay, p_visibility: visibility, p_update_recurrence: schedule.updateRecurrence, ...(schedule.recurrence || {}) });
    if (error) throw error; editForm.hidden = true; message.textContent = 'Attività aggiornata.'; await loadActivity();
  } catch (error) { message.textContent = friendlyError(error, 'Impossibile salvare le modifiche.'); } finally { editSubmitButton.disabled = false; }
});
deleteButton.addEventListener('click', async () => {
  const confirmed = await FamilAreaConfirm.confirm({ variant: 'danger', title: 'Vuoi eliminare questa attività?', message: activity.recurrence_frequency ? 'Questa operazione eliminerà tutta la serie.' : 'L’attività verrà eliminata definitivamente dall’Area.', warning: 'Questa azione non può essere annullata.', confirmText: 'Elimina attività' });
  if (!confirmed) return; deleteButton.disabled = true; message.textContent = 'Eliminazione in corso...'; const { error } = await supabaseClient.rpc('delete_area_activity', { p_area_id: areaId, p_activity_id: activityId }); deleteButton.disabled = false; if (error) { message.textContent = friendlyError(error, 'Impossibile eliminare l’attività.'); return; } window.location.href = `attivita-area.html?area_id=${encodeURIComponent(areaId)}`;
});
load();

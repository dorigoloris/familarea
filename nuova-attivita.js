const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const form = document.getElementById('activity-form');
const assignees = document.getElementById('assignees');
const backLink = document.getElementById('back-link');
const visibilityInputs = [...document.querySelectorAll('input[name="visibility"]')];
const visibilityHelp = document.getElementById('visibility-help');
const recurrenceEnabled = document.getElementById('recurrence-enabled');
const recurrenceFields = document.getElementById('recurrence-fields');
const recurrenceWeekday = document.getElementById('recurrence-weekday');
const submitButton = form.querySelector('button[type="submit"]');
let areaId;
let ownProfileId;
let isAdmin = false;
let recurrenceWeekdayManuallySelected = false;

function dateParts(dateValue) { return dateValue ? dateValue.split('-').map(Number) : null; }
function localIso(dateValue, timeValue) {
  const [year, month, day] = dateParts(dateValue);
  const [hours, minutes] = timeValue.split(':').map(Number);
  return new Date(year, month - 1, day, hours, minutes).toISOString();
}
function isoWeekday(dateValue) {
  const [year, month, day] = dateParts(dateValue);
  return ((new Date(year, month - 1, day).getDay() + 6) % 7) + 1;
}
function recurrenceTimezone() { return Intl.DateTimeFormat().resolvedOptions().timeZone?.trim() || ''; }
function suggestWeekdayFromDate() {
  const dateValue = document.getElementById('activity-date').value;
  if (dateValue && !recurrenceWeekdayManuallySelected) recurrenceWeekday.value = String(isoWeekday(dateValue));
}
function toggleRecurrenceFields() {
  recurrenceFields.hidden = !recurrenceEnabled.checked;
  if (recurrenceEnabled.checked) suggestWeekdayFromDate();
}

function schedulePayload() {
  const dateValue = document.getElementById('activity-date').value;
  const startTime = document.getElementById('start-time').value;
  const endTime = document.getElementById('end-time').value;
  const recurrenceUntil = document.getElementById('recurrence-until').value;
  if (!dateValue) {
    if (startTime || endTime) throw new Error('Inserisci una data prima di indicare un orario.');
    if (recurrenceEnabled.checked) throw new Error('Per ripetere un’attività, inserisci la data iniziale.');
    return { startsAt: null, dueAt: null, isAllDay: false, recurrence: null };
  }
  if (endTime && !startTime) throw new Error('Inserisci l’ora di inizio prima dell’ora di fine.');
  if (startTime && endTime && endTime <= startTime) throw new Error('L’ora di fine deve essere successiva all’ora di inizio.');
  if (recurrenceEnabled.checked) {
    const timezone = recurrenceTimezone();
    if (!startTime || !endTime) throw new Error('Per una ripetizione settimanale indica ora di inizio e ora di fine.');
    if (!recurrenceUntil) throw new Error('Indica la fine della ripetizione.');
    if (recurrenceUntil < dateValue) throw new Error('La fine della ripetizione non può precedere la data iniziale.');
    if (!timezone) throw new Error('Impossibile rilevare la timezone del browser.');
    return { startsAt: localIso(dateValue, startTime), dueAt: localIso(dateValue, endTime), isAllDay: false, recurrence: { p_recurrence_frequency: 'weekly', p_recurrence_interval: 1, p_recurrence_weekdays: [Number(recurrenceWeekday.value)], p_recurrence_until: recurrenceUntil, p_recurrence_timezone: timezone } };
  }
  if (!startTime) {
    const [year, month, day] = dateParts(dateValue);
    return { startsAt: null, dueAt: new Date(year, month - 1, day).toISOString(), isAllDay: true, recurrence: null };
  }
  return { startsAt: localIso(dateValue, startTime), dueAt: endTime ? localIso(dateValue, endTime) : localIso(dateValue, startTime), isAllDay: false, recurrence: null };
}

function updateVisibilityChoices() {
  const hasAssignees = assignees.querySelectorAll('input:checked').length > 0;
  const creatorAssignees = visibilityInputs.find((input) => input.value === 'creator_assignees');
  const privateInput = visibilityInputs.find((input) => input.value === 'private');
  const areaInput = visibilityInputs.find((input) => input.value === 'area');
  creatorAssignees.disabled = !hasAssignees;
  creatorAssignees.parentElement.hidden = !hasAssignees;
  privateInput.disabled = hasAssignees;
  privateInput.parentElement.hidden = hasAssignees;
  if (hasAssignees) {
    visibilityHelp.textContent = 'Con assegnatari, scegli se condividerla solo con loro o con tutta l’Area.';
    if (!creatorAssignees.checked && !areaInput.checked) creatorAssignees.checked = true;
  } else {
    visibilityHelp.textContent = 'Scegli chi può vedere l’attività.';
    if (creatorAssignees.checked) creatorAssignees.checked = false;
    if (!privateInput.checked && !areaInput.checked) privateInput.checked = true;
  }
}

async function load() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }
  areaId = new URLSearchParams(window.location.search).get('area_id');
  if (!areaId) { message.textContent = 'Area non specificata.'; return; }
  backLink.href = `area.html?area_id=${encodeURIComponent(areaId)}`;
  const { data: ownProfile } = await supabaseClient.from('profiles').select('id').eq('user_id', sessionData.session.user.id).single();
  if (!ownProfile) { message.textContent = 'Impossibile preparare la nuova attività.'; return; }
  ownProfileId = ownProfile.id;
  const { data: memberships, error } = await supabaseClient.from('area_memberships').select('profile_id, role, profiles(first_name,last_name)').eq('area_id', areaId);
  if (error || !memberships) { message.textContent = 'Impossibile caricare i partecipanti.'; return; }
  const ownMembership = memberships.find((membership) => membership.profile_id === ownProfileId);
  if (!ownMembership || ownMembership.role === 'managed') { message.textContent = 'Non sei autorizzato a creare attività in questa Area.'; return; }
  isAdmin = ownMembership.role === 'admin';
  memberships.forEach((membership) => {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'checkbox'; input.value = membership.profile_id;
    input.addEventListener('change', updateVisibilityChoices);
    input.disabled = !isAdmin && membership.profile_id !== ownProfileId;
    label.append(input, ` ${(membership.profiles?.first_name || '')} ${(membership.profiles?.last_name || '')}`.trim());
    assignees.append(label, document.createElement('br'));
  });
  updateVisibilityChoices();
  form.hidden = false; message.textContent = '';
}

document.getElementById('activity-date').addEventListener('change', () => {
  if (recurrenceEnabled.checked) suggestWeekdayFromDate();
});
recurrenceEnabled.addEventListener('change', () => {
  if (!recurrenceEnabled.checked) recurrenceWeekdayManuallySelected = false;
  toggleRecurrenceFields();
});
recurrenceWeekday.addEventListener('change', () => {
  recurrenceWeekdayManuallySelected = true;
  const dateInput = document.getElementById('activity-date');
  if (!dateInput.value) return;
  const current = isoWeekday(dateInput.value);
  const target = Number(recurrenceWeekday.value);
  const [year, month, day] = dateParts(dateInput.value);
  const next = new Date(year, month - 1, day + ((target - current + 7) % 7));
  dateInput.value = `${next.getFullYear()}-${String(next.getMonth() + 1).padStart(2, '0')}-${String(next.getDate()).padStart(2, '0')}`;
});
form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const selected = [...assignees.querySelectorAll('input:checked')].map((input) => input.value);
  const visibility = visibilityInputs.find((input) => input.checked)?.value;
  if (!isAdmin && selected.some((id) => id !== ownProfileId)) { message.textContent = 'Puoi assegnare attività solo a te stesso.'; return; }
  if (!visibility) { message.textContent = 'Scegli la visibilità dell’attività.'; return; }
  let schedule;
  try { schedule = schedulePayload(); } catch (error) { message.textContent = error.message; return; }
  submitButton.disabled = true;
  message.textContent = 'Creazione in corso...';
  try {
    const { error } = await supabaseClient.rpc('create_area_activity', {
      p_area_id: areaId, p_title: document.getElementById('title').value.trim(), p_notes: document.getElementById('notes').value.trim() || null,
      p_activity_type: document.getElementById('activity-type').value, p_priority: document.getElementById('priority').value,
      p_starts_at: schedule.startsAt, p_due_at: schedule.dueAt, p_is_all_day: schedule.isAllDay, p_assignee_profile_ids: selected, p_visibility: visibility, ...(schedule.recurrence || {})
    });
    if (error) throw error;
    window.location.href = `attivita-area.html?area_id=${encodeURIComponent(areaId)}`;
  } catch (error) {
    message.textContent = 'Impossibile creare l’attività. Verifica i dati e riprova.';
  } finally { submitButton.disabled = false; }
});

toggleRecurrenceFields();
load();

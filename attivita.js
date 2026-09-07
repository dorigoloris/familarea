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

let areaId;
let activityId;
let ownProfileId;
let ownRole;
let memberships = [];
let activity;

const labels = {
  type: { task: 'Da fare', reminder: 'Promemoria', deadline: 'Scadenza', appointment: 'Appuntamento' },
  priority: { low: 'Bassa', normal: 'Normale', high: 'Alta' },
  status: { open: 'Aperta', completed: 'Completata', cancelled: 'Annullata' },
  visibility: { private: 'Solo tu', creator_assignees: 'Solo tu e gli assegnatari', area: 'Tutti i partecipanti dell’Area' }
};

function label(group, value) { return labels[group][value] || value; }
function formatDate(value) { return value ? new Date(value).toLocaleString('it-IT') : 'Non indicata'; }
function toDateTimeInput(value) { return value ? new Date(value).toISOString().slice(0, 16) : ''; }
function currentAssigneeIds() { return [...editAssignees.querySelectorAll('input:checked')].map((input) => input.value); }
function friendlyError(error, fallback) { return /permission denied|non accessibile|not authorized/i.test(error?.message || '') ? 'Non sei autorizzato a eseguire questa operazione.' : fallback; }
function sameIds(left, right) { return [...left].sort().join(',') === [...right].sort().join(','); }

function canEdit() {
  return activity.created_by_profile_id === ownProfileId || (activity.visibility === 'area' && ownRole === 'admin');
}

function canDelete() {
  if (activity.visibility === 'area' && ownRole === 'admin') return true;
  if (activity.created_by_profile_id !== ownProfileId) return false;
  return activity.visibility !== 'area' || activity.status === 'open';
}

function memberName(profileId) {
  const membership = memberships.find((item) => item.profile_id === profileId);
  const profile = membership?.profiles;
  return `${profile?.first_name || ''} ${profile?.last_name || ''}`.trim() || 'Partecipante dell’Area';
}

function renderActivity() {
  document.getElementById('activity-title').textContent = activity.title;
  document.getElementById('activity-type').textContent = label('type', activity.activity_type);
  document.getElementById('activity-priority').textContent = label('priority', activity.priority);
  document.getElementById('activity-status').textContent = label('status', activity.status);
  document.getElementById('activity-visibility').textContent = label('visibility', activity.visibility);
  document.getElementById('activity-due').textContent = formatDate(activity.due_at);
  document.getElementById('activity-notes').textContent = activity.notes || 'Nessuna nota.';
  const assigneeNames = (activity.assignee_profile_ids || []).map(memberName);
  document.getElementById('activity-assignees').textContent = assigneeNames.length ? assigneeNames.join(', ') : 'Nessun assegnatario.';
  actions.hidden = !canEdit() && !canDelete();
  editButton.hidden = !canEdit();
  deleteButton.hidden = !canDelete();
  view.hidden = false;
}

function updateVisibilityChoices() {
  const hasAssignees = currentAssigneeIds().length > 0;
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
  }
}

function prepareEditForm() {
  document.getElementById('edit-title').value = activity.title;
  document.getElementById('edit-type').value = activity.activity_type;
  document.getElementById('edit-priority').value = activity.priority;
  document.getElementById('edit-notes').value = activity.notes || '';
  document.getElementById('edit-due-at').value = toDateTimeInput(activity.due_at);
  editAssignees.replaceChildren();
  const selected = new Set(activity.assignee_profile_ids || []);
  memberships.forEach((membership) => {
    const labelElement = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.value = membership.profile_id;
    input.checked = selected.has(membership.profile_id);
    input.addEventListener('change', updateVisibilityChoices);
    labelElement.append(input, ` ${memberName(membership.profile_id)}`);
    editAssignees.append(labelElement, document.createElement('br'));
  });
  visibilityInputs.forEach((input) => { input.checked = input.value === activity.visibility; });
  updateVisibilityChoices();
}

async function loadActivity() {
  message.textContent = 'Caricamento attività...';
  const { data, error } = await supabaseClient.rpc('get_area_activity', { p_area_id: areaId, p_activity_id: activityId });
  if (error || !data?.[0]) { message.textContent = friendlyError(error, 'Attività non disponibile.'); return; }
  activity = data[0];
  renderActivity();
  message.textContent = '';
}

async function load() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }
  areaId = new URLSearchParams(window.location.search).get('area_id');
  activityId = new URLSearchParams(window.location.search).get('activity_id');
  if (!areaId || !activityId) { message.textContent = 'Attività non specificata.'; return; }
  backLink.href = `area.html?area_id=${encodeURIComponent(areaId)}`;
  const { data: ownProfile } = await supabaseClient.from('profiles').select('id').eq('user_id', sessionData.session.user.id).single();
  const { data, error } = await supabaseClient.from('area_memberships').select('profile_id,role,profiles(first_name,last_name)').eq('area_id', areaId);
  if (!ownProfile || error || !data) { message.textContent = 'Impossibile preparare la pagina attività.'; return; }
  ownProfileId = ownProfile.id;
  memberships = data;
  ownRole = memberships.find((membership) => membership.profile_id === ownProfileId)?.role;
  if (!ownRole || ownRole === 'managed') { message.textContent = 'Non sei autorizzato a consultare questa attività.'; return; }
  await loadActivity();
}

editButton.addEventListener('click', () => { prepareEditForm(); view.hidden = true; editForm.hidden = false; });
cancelButton.addEventListener('click', () => { editForm.hidden = true; view.hidden = false; });

editForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const assigneeIds = currentAssigneeIds();
  const visibility = visibilityInputs.find((input) => input.checked)?.value;
  if (!visibility) { message.textContent = 'Scegli la visibilità dell’attività.'; return; }
  message.textContent = 'Salvataggio in corso...';
  if (!sameIds(assigneeIds, activity.assignee_profile_ids || []) || visibility !== activity.visibility) {
    const { error: assigneesError } = await supabaseClient.rpc('set_area_activity_assignees', { p_area_id: areaId, p_activity_id: activityId, p_assignee_profile_ids: assigneeIds, p_visibility: visibility });
    if (assigneesError) { message.textContent = friendlyError(assigneesError, 'Impossibile aggiornare assegnatari e visibilità.'); return; }
  }
  const dueValue = document.getElementById('edit-due-at').value;
  const { error: updateError } = await supabaseClient.rpc('update_area_activity', {
    p_area_id: areaId, p_activity_id: activityId, p_title: document.getElementById('edit-title').value.trim(), p_notes: document.getElementById('edit-notes').value.trim() || null,
    p_activity_type: document.getElementById('edit-type').value, p_priority: document.getElementById('edit-priority').value,
    p_starts_at: activity.starts_at, p_due_at: dueValue ? new Date(dueValue).toISOString() : null, p_is_all_day: activity.is_all_day, p_visibility: visibility
  });
  if (updateError) { message.textContent = friendlyError(updateError, 'Assegnatari aggiornati, ma non è stato possibile salvare gli altri dati.'); return; }
  editForm.hidden = true;
  message.textContent = 'Attività aggiornata.';
  await loadActivity();
});

deleteButton.addEventListener('click', async () => {
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: 'Vuoi eliminare questa attività?',
    message: 'L’attività verrà eliminata definitivamente dall’Area.',
    warning: 'Questa azione non può essere annullata.',
    confirmText: 'Elimina attività'
  });
  if (!confirmed) return;
  deleteButton.disabled = true;
  message.textContent = 'Eliminazione in corso...';
  const { error } = await supabaseClient.rpc('delete_area_activity', { p_area_id: areaId, p_activity_id: activityId });
  deleteButton.disabled = false;
  if (error) { message.textContent = friendlyError(error, 'Impossibile eliminare l’attività.'); return; }
  window.location.href = `area.html?area_id=${encodeURIComponent(areaId)}`;
});

load();

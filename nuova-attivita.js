const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const form = document.getElementById('activity-form');
const assignees = document.getElementById('assignees');
const backLink = document.getElementById('back-link');
const visibilityInputs = [...document.querySelectorAll('input[name="visibility"]')];
const visibilityHelp = document.getElementById('visibility-help');
let areaId;
let ownProfileId;
let isAdmin = false;

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
    visibilityHelp.textContent = 'Con assegnatari, scegli se condividerla solo con loro o con tutta l\'Area.';
    if (!creatorAssignees.checked && !areaInput.checked) creatorAssignees.checked = true;
  } else {
    visibilityHelp.textContent = 'Scegli chi puo vedere l\'attivita.';
    if (creatorAssignees.checked) creatorAssignees.checked = false;
    if (!privateInput.checked && !areaInput.checked) visibilityInputs.forEach((input) => { input.checked = false; });
  }
}

async function load() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }
  areaId = new URLSearchParams(window.location.search).get('area_id');
  if (!areaId) { message.textContent = 'Area non specificata.'; return; }
  backLink.href = `area.html?area_id=${encodeURIComponent(areaId)}`;
  const userId = sessionData.session.user.id;
  const { data: ownProfile } = await supabaseClient.from('profiles').select('id').eq('user_id', userId).single();
  if (!ownProfile) { message.textContent = 'Impossibile preparare la nuova attivitÃ .'; return; }
  ownProfileId = ownProfile.id;
  const { data: memberships, error } = await supabaseClient.from('area_memberships').select('profile_id, role, profiles(first_name,last_name)').eq('area_id', areaId);
  if (error || !memberships) { message.textContent = 'Impossibile caricare i membri.'; return; }
  const ownMembership = memberships.find((membership) => membership.profile_id === ownProfileId);
  if (!ownMembership || ownMembership.role === 'managed') { message.textContent = 'Non sei autorizzato a creare attivitÃ  in questa Area.'; return; }
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

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const selected = [...assignees.querySelectorAll('input:checked')].map((input) => input.value);
  const visibility = visibilityInputs.find((input) => input.checked)?.value;
  if (!isAdmin && selected.some((id) => id !== ownProfileId)) { message.textContent = 'Puoi assegnare attivitÃ  solo a te stesso.'; return; }
  if (!visibility) { message.textContent = 'Scegli la visibilita dell\'attivita.'; return; }
  const dueValue = document.getElementById('due-at').value;
  message.textContent = 'Creazione in corso...';
  const { error } = await supabaseClient.rpc('create_area_activity', {
    p_area_id: areaId, p_title: document.getElementById('title').value.trim(), p_notes: document.getElementById('notes').value.trim() || null,
    p_activity_type: document.getElementById('activity-type').value, p_priority: document.getElementById('priority').value,
    p_starts_at: null, p_due_at: dueValue ? new Date(dueValue).toISOString() : null, p_is_all_day: false, p_assignee_profile_ids: selected, p_visibility: visibility
  });
  if (error) { message.textContent = 'Impossibile creare l\'attivitÃ .'; return; }
  window.location.href = `area.html?area_id=${encodeURIComponent(areaId)}`;
});
load();

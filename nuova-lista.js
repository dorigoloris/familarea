const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const form = document.getElementById('list-form');
const participants = document.getElementById('participants');
const visibilityInputs = [...document.querySelectorAll('input[name="visibility"]')];
const saveButton = document.getElementById('save-button');
let areaId;
let ownProfileId;

function selectedParticipantIds() {
  return [...participants.querySelectorAll('input:checked')].map((input) => input.value);
}

function selectedVisibility() {
  return visibilityInputs.find((input) => input.checked)?.value;
}

function updateVisibilityUi() {
  const isSelective = selectedVisibility() === 'creator_participants';
  document.getElementById('participants-fieldset').hidden = !isSelective;
  if (selectedVisibility() === 'private') {
    participants.querySelectorAll('input').forEach((input) => { input.checked = false; });
  }
}

function participantName(participant) {
  return `${participant.first_name || ''} ${participant.last_name || ''}`.trim() || 'Partecipante';
}

function renderParticipants(items) {
  participants.replaceChildren();
  const selectable = (items || []).filter((participant) => participant.profile_id !== ownProfileId);
  if (!selectable.length) {
    const text = document.createElement('p');
    text.textContent = 'Non ci sono altri partecipanti selezionabili in questa Area.';
    participants.appendChild(text);
    return;
  }
  selectable.forEach((participant) => {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.value = participant.profile_id;
    label.append(input, ` ${participantName(participant)}`);
    participants.append(label);
  });
}

async function load() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }
  areaId = new URLSearchParams(window.location.search).get('area_id');
  if (!areaId) {
    message.textContent = 'Area non specificata.';
    return;
  }
  const backUrl = `liste.html?area_id=${encodeURIComponent(areaId)}`;
  document.getElementById('back-link').href = backUrl;
  document.getElementById('cancel-link').href = backUrl;

  const [{ data: profile }, { data: areaParticipants, error }] = await Promise.all([
    supabaseClient.from('profiles').select('id').eq('user_id', sessionData.session.user.id).single(),
    supabaseClient.rpc('get_area_participants', { p_area_id: areaId })
  ]);
  if (!profile || error || !areaParticipants) {
    message.textContent = 'Non sei autorizzato a creare liste in questa Area.';
    return;
  }
  ownProfileId = profile.id;
  renderParticipants(areaParticipants);
  form.hidden = false;
  message.textContent = '';
}

visibilityInputs.forEach((input) => input.addEventListener('change', updateVisibilityUi));
form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const title = document.getElementById('title').value.trim();
  const visibility = selectedVisibility();
  const participantIds = selectedParticipantIds();
  if (!title) {
    message.textContent = 'Inserisci il titolo della lista.';
    return;
  }
  if (visibility === 'creator_participants' && !participantIds.length) {
    message.textContent = 'Seleziona almeno un partecipante.';
    return;
  }
  saveButton.disabled = true;
  message.textContent = 'Creazione lista in corso...';
  const { data, error } = await supabaseClient.rpc('create_area_list', {
    p_area_id: areaId,
    p_title: title,
    p_description: document.getElementById('description').value.trim() || null,
    p_visibility: visibility,
    p_participant_profile_ids: participantIds
  });
  if (error || !data) {
    message.textContent = 'Impossibile creare la lista.';
    saveButton.disabled = false;
    return;
  }
  window.location.href = `lista.html?area_id=${encodeURIComponent(areaId)}&list_id=${encodeURIComponent(data)}`;
});

updateVisibilityUi();
load();

const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const view = document.getElementById('list-view');
const editForm = document.getElementById('edit-list-form');
const itemsList = document.getElementById('items-list');
const editParticipants = document.getElementById('edit-participants');
const editVisibilityInputs = [...document.querySelectorAll('input[name="edit-visibility"]')];
let areaId;
let listId;
let ownProfileId;
let listData;
let areaParticipants = [];

const visibilityLabels = {
  area: "Tutti i partecipanti dell'Area",
  private: 'Solo io',
  creator_participants: 'Io + partecipanti selezionati'
};

function isListCreator() {
  return listData?.created_by_profile_id === ownProfileId;
}

function selectedEditVisibility() {
  return editVisibilityInputs.find((input) => input.checked)?.value;
}

function selectedEditParticipantIds() {
  return [...editParticipants.querySelectorAll('input:checked')].map((input) => input.value);
}

function participantName(participant) {
  return `${participant.first_name || ''} ${participant.last_name || ''}`.trim() || 'Partecipante';
}

function updateEditVisibilityUi() {
  const visibility = selectedEditVisibility();
  document.getElementById('edit-participants-fieldset').hidden = visibility !== 'creator_participants';
  if (visibility === 'private') {
    editParticipants.querySelectorAll('input').forEach((input) => { input.checked = false; });
  }
  document.getElementById('edit-participants-help').textContent = visibility === 'creator_participants'
    ? 'Seleziona almeno un partecipante.'
    : '';
}

function renderEditParticipants() {
  const selectedIds = new Set(listData.participant_profile_ids || []);
  editParticipants.replaceChildren();
  areaParticipants
    .filter((participant) => participant.profile_id !== ownProfileId)
    .forEach((participant) => {
      const label = document.createElement('label');
      const input = document.createElement('input');
      input.type = 'checkbox';
      input.value = participant.profile_id;
      input.checked = selectedIds.has(participant.profile_id);
      label.append(input, ` ${participantName(participant)}`);
      editParticipants.append(label);
    });
}

function renderItem(item) {
  const row = document.createElement('li');
  row.className = `list-item${item.status === 'completed' ? ' is-completed' : ''}`;
  const check = document.createElement('input');
  check.type = 'checkbox';
  check.checked = item.status === 'completed';
  check.setAttribute('aria-label', `Segna ${item.text} come ${item.status === 'completed' ? 'da fare' : 'completato'}`);
  check.addEventListener('change', async () => {
    check.disabled = true;
    const { error } = await supabaseClient.rpc('set_area_list_item_status', {
      p_area_id: areaId,
      p_list_id: listId,
      p_item_id: item.id,
      p_status: check.checked ? 'completed' : 'open'
    });
    if (error) {
      await loadList();
      message.textContent = 'Impossibile aggiornare lo stato dell’elemento.';
      return;
    }
    await loadList();
  });
  const text = document.createElement('span');
  text.className = 'list-item-text';
  text.textContent = item.text;
  const state = document.createElement('span');
  state.className = 'list-item-state';
  state.textContent = item.status === 'completed' ? 'Completato' : 'Da fare';
  const controls = document.createElement('span');
  controls.className = 'list-item-actions';
  const canEdit = isListCreator() || item.created_by_profile_id === ownProfileId;
  if (canEdit) {
    const edit = document.createElement('button');
    edit.type = 'button';
    edit.textContent = 'Modifica';
    edit.addEventListener('click', () => showItemEditor(row, item));
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'list-item-delete';
    remove.textContent = 'Elimina';
    remove.addEventListener('click', () => deleteItem(item));
    controls.append(edit, remove);
  }
  row.append(check, text, state, controls);
  return row;
}

function render() {
  document.title = `${listData.title} - FamilArea`;
  document.getElementById('list-title').textContent = listData.title;
  const description = document.getElementById('list-description');
  description.textContent = listData.description || '';
  description.hidden = !listData.description;
  document.getElementById('list-visibility').textContent = `Visibilità: ${visibilityLabels[listData.visibility] || 'Lista'}`;
  document.getElementById('list-actions').hidden = !isListCreator();
  itemsList.replaceChildren();
  const items = listData.items || [];
  if (!items.length) {
    const empty = document.createElement('li');
    empty.className = 'empty-state';
    empty.textContent = 'La lista non contiene ancora elementi.';
    itemsList.appendChild(empty);
  } else {
    items.forEach((item) => itemsList.appendChild(renderItem(item)));
  }
  view.hidden = false;
}

async function loadList() {
  const { data, error } = await supabaseClient.rpc('get_area_list', {
    p_area_id: areaId,
    p_list_id: listId
  });
  if (error || !data?.[0]) {
    message.textContent = 'Lista non disponibile.';
    return false;
  }
  listData = data[0];
  render();
  message.textContent = '';
  return true;
}

function showListEditor() {
  document.getElementById('edit-title').value = listData.title || '';
  document.getElementById('edit-description').value = listData.description || '';
  editVisibilityInputs.forEach((input) => { input.checked = input.value === listData.visibility; });
  renderEditParticipants();
  updateEditVisibilityUi();
  view.hidden = true;
  editForm.hidden = false;
}

function showItemEditor(row, item) {
  const editor = document.createElement('form');
  editor.className = 'list-item-editor';
  const input = document.createElement('input');
  input.value = item.text;
  input.required = true;
  const save = document.createElement('button');
  save.type = 'submit';
  save.textContent = 'Salva';
  const cancel = document.createElement('button');
  cancel.type = 'button';
  cancel.className = 'secondary-button';
  cancel.textContent = 'Annulla';
  cancel.addEventListener('click', () => row.replaceWith(renderItem(item)));
  editor.append(input, save, cancel);
  editor.addEventListener('submit', async (event) => {
    event.preventDefault();
    const text = input.value.trim();
    if (!text) return;
    save.disabled = true;
    const { error } = await supabaseClient.rpc('update_area_list_item', {
      p_area_id: areaId,
      p_list_id: listId,
      p_item_id: item.id,
      p_text: text,
      p_position: null
    });
    if (error) {
      await loadList();
      message.textContent = 'Impossibile modificare l’elemento.';
      return;
    }
    await loadList();
  });
  row.replaceWith(editor);
  input.focus();
}

async function deleteItem(item) {
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger', appearance: 'standard', title: 'Eliminare questo elemento?',
    message: item.text, confirmText: 'Elimina'
  });
  if (!confirmed) return;
  const { error } = await supabaseClient.rpc('delete_area_list_item', {
    p_area_id: areaId, p_list_id: listId, p_item_id: item.id
  });
  if (error) {
    message.textContent = 'Impossibile eliminare l’elemento.';
    return;
  }
  await loadList();
}

document.getElementById('add-item-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const input = document.getElementById('item-text');
  const text = input.value.trim();
  if (!text) return;
  const button = document.getElementById('add-item-button');
  button.disabled = true;
  const { error } = await supabaseClient.rpc('add_area_list_item', {
    p_area_id: areaId, p_list_id: listId, p_text: text, p_position: null
  });
  button.disabled = false;
  if (error) {
    message.textContent = 'Impossibile aggiungere l’elemento.';
    return;
  }
  input.value = '';
  await loadList();
});

document.getElementById('edit-list-button').addEventListener('click', showListEditor);
document.getElementById('cancel-edit-button').addEventListener('click', () => {
  editForm.hidden = true;
  view.hidden = false;
});
editVisibilityInputs.forEach((input) => input.addEventListener('change', updateEditVisibilityUi));

editForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const title = document.getElementById('edit-title').value.trim();
  const visibility = selectedEditVisibility();
  const participantIds = selectedEditParticipantIds();
  if (!title) {
    message.textContent = 'Inserisci il titolo della lista.';
    return;
  }
  if (visibility === 'creator_participants' && !participantIds.length) {
    message.textContent = 'Seleziona almeno un partecipante.';
    return;
  }
  const button = document.getElementById('save-list-button');
  button.disabled = true;
  const { error } = await supabaseClient.rpc('update_area_list', {
    p_area_id: areaId,
    p_list_id: listId,
    p_title: title,
    p_description: document.getElementById('edit-description').value.trim() || null,
    p_visibility: visibility,
    p_participant_profile_ids: participantIds
  });
  button.disabled = false;
  if (error) {
    message.textContent = 'Impossibile salvare le modifiche alla lista.';
    return;
  }
  editForm.hidden = true;
  await loadList();
});

document.getElementById('delete-list-button').addEventListener('click', async () => {
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger', appearance: 'standard', title: `Eliminare ${listData.title}?`,
    message: 'La lista e tutti i suoi elementi verranno eliminati definitivamente.', confirmText: 'Elimina lista'
  });
  if (!confirmed) return;
  const button = document.getElementById('delete-list-button');
  button.disabled = true;
  const { error } = await supabaseClient.rpc('delete_area_list', { p_area_id: areaId, p_list_id: listId });
  if (error) {
    message.textContent = 'Impossibile eliminare la lista.';
    button.disabled = false;
    return;
  }
  window.location.href = `liste.html?area_id=${encodeURIComponent(areaId)}`;
});

async function load() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }
  areaId = new URLSearchParams(window.location.search).get('area_id');
  listId = new URLSearchParams(window.location.search).get('list_id');
  if (!areaId || !listId) {
    message.textContent = 'Lista non specificata.';
    return;
  }
  document.getElementById('back-link').href = `liste.html?area_id=${encodeURIComponent(areaId)}`;
  const [{ data: profile }, { data: participants, error: participantsError }, { data: area }] = await Promise.all([
    supabaseClient.from('profiles').select('id').eq('user_id', sessionData.session.user.id).single(),
    supabaseClient.rpc('get_area_participants', { p_area_id: areaId }),
    supabaseClient.from('areas').select('name').eq('id', areaId).single()
  ]);
  if (!profile || participantsError || !participants) {
    message.textContent = 'Non sei autorizzato a visualizzare questa lista.';
    return;
  }
  ownProfileId = profile.id;
  areaParticipants = participants;
  document.getElementById('area-name').textContent = area?.name || 'Area';
  await loadList();
}

load();

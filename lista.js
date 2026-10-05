const c = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const areaId = new URLSearchParams(location.search).get('area_id');
const listId = new URLSearchParams(location.search).get('list_id');
const m = document.getElementById('message');
const itemInput = document.getElementById('item-text');
const backLink = document.querySelector('.account-back-link > a');
const editListButton = document.getElementById('edit-list-button');
const shareListButton = document.getElementById('share-list-button');
const deleteListButton = document.getElementById('delete-list-button');
const listActions = document.getElementById('list-actions');
const sharePanel = document.getElementById('list-share-panel');
const shareState = document.getElementById('list-share-state');
const shareMessage = document.getElementById('list-share-message');
const shareSearch = document.getElementById('list-share-search');
const shareSearchStatus = document.getElementById('list-share-search-status');
const shareSearchResults = document.getElementById('list-share-search-results');
const sharePending = document.getElementById('list-share-pending');
const sharePendingEmpty = document.getElementById('list-share-pending-empty');
const shareParticipants = document.getElementById('list-share-participants');
const shareParticipantsEmpty = document.getElementById('list-share-participants-empty');
const closeShareButton = document.getElementById('close-list-share-button');
let list;
let editable = false;
let canManageList = false;
let canShareList = false;
let editingList = false;
let shareSearchTimer;
let shareSearchRequest = 0;
let shareActionPending = false;

const back = () => areaId ? `liste.html?area_id=${encodeURIComponent(areaId)}` : 'liste.html';

function initials(name) {
  return (name || 'U').trim().split(/\s+/).slice(0, 2).map((part) => part[0]).join('').toLocaleUpperCase('it-IT') || 'U';
}

function renderAvatar(avatar, avatarPath, name) {
  avatar.replaceChildren();
  avatar.textContent = initials(name);
  if (!avatarPath) return;
  c.storage.from('profile-avatars').createSignedUrl(avatarPath, 3600).then(({ data, error }) => {
    if (error || !data?.signedUrl || !avatar.isConnected) return;
    const image = document.createElement('img');
    image.alt = '';
    image.onload = () => { if (avatar.isConnected) avatar.replaceChildren(image); };
    image.src = `${data.signedUrl}${data.signedUrl.includes('?') ? '&' : '?'}v=${Date.now()}`;
  });
}

function setShareMessage(text = '') {
  shareMessage.textContent = text;
}

function shareButton(text, variant, onClick) {
  const button = document.createElement('button');
  button.type = 'button';
  button.textContent = text;
  button.className = `fa-v2-button fa-v2-button--${variant}`;
  button.disabled = shareActionPending;
  button.addEventListener('click', onClick);
  return button;
}

function shareRow(person, status, action) {
  const row = document.createElement('li');
  const identity = document.createElement('div');
  const avatar = document.createElement('span');
  const name = document.createElement('strong');
  const details = document.createElement('div');
  const actions = document.createElement('div');
  row.className = 'fa-v2-list-row fa-v2-contact-summary-row';
  identity.className = 'contact-directory-name';
  avatar.className = 'contact-directory-avatar';
  name.textContent = person.display_name || 'Utente FamilArea';
  renderAvatar(avatar, person.avatar_path, name.textContent);
  identity.append(avatar, name);
  details.className = 'fa-v2-status';
  details.textContent = status;
  actions.className = 'contact-directory-actions';
  actions.appendChild(action);
  row.append(identity, details, actions);
  return row;
}

function renderShareManagement(data) {
  const pending = data?.pending_invites || [];
  const participants = data?.participants || [];
  const shared = data?.list?.sharing_status === 'shared';
  shareState.textContent = shared ? 'Condivisa' : 'Privata';
  sharePending.replaceChildren(...pending.map((invite) => shareRow(invite, 'In attesa', shareButton('Revoca', 'secondary', () => { void revokeInvite(invite); }))));
  shareParticipants.replaceChildren(...participants.map((participant) => shareRow(participant, 'Partecipante', shareButton('Rimuovi', 'danger', () => { void removeParticipant(participant); }))));
  sharePending.hidden = pending.length === 0;
  shareParticipants.hidden = participants.length === 0;
  sharePendingEmpty.hidden = pending.length > 0;
  shareParticipantsEmpty.hidden = participants.length > 0;
}

async function loadShareManagement() {
  if (!canShareList) return false;
  const { data, error } = await c.rpc('get_list_share_management', { p_list_id: listId });
  if (error || !data) {
    setShareMessage('Impossibile caricare la condivisione della lista.');
    return false;
  }
  renderShareManagement(data);
  return true;
}

async function searchShareAccounts() {
  const query = shareSearch.value.trim();
  const request = ++shareSearchRequest;
  shareSearchResults.replaceChildren();
  if (query.length < 3) {
    shareSearchStatus.textContent = 'Inserisci almeno 3 caratteri.';
    return;
  }
  shareSearchStatus.textContent = 'Ricerca in corso...';
  const { data, error } = await c.rpc('search_invitable_list_accounts', { p_list_id: listId, p_query: query });
  if (request !== shareSearchRequest) return;
  if (error) {
    shareSearchStatus.textContent = 'Impossibile cercare una persona. Riprova.';
    return;
  }
  const results = data || [];
  shareSearchResults.replaceChildren(...results.map((person) => shareRow(person, '', shareButton('Invita', 'primary', () => { void invitePerson(person); }))));
  shareSearchStatus.textContent = results.length ? '' : 'Nessuna persona disponibile trovata.';
}

async function invitePerson(person) {
  if (shareActionPending) return;
  shareActionPending = true;
  setShareMessage('Invito in corso...');
  const { error } = await c.rpc('create_list_invite', { p_list_id: listId, p_recipient_account_id: person.account_id });
  shareActionPending = false;
  if (error) {
    setShareMessage('Non è stato possibile inviare l\'invito.');
    return;
  }
  setShareMessage('Invito inviato.');
  await loadShareManagement();
  await searchShareAccounts();
}

async function revokeInvite(invite) {
  if (shareActionPending || !await FamilAreaConfirm.confirm({ variant: 'danger', title: 'Revocare questo invito?', message: 'La persona non potrà più accettare l\'invito.', confirmText: 'Revoca' })) return;
  shareActionPending = true;
  setShareMessage('Revoca in corso...');
  const { error } = await c.rpc('revoke_list_invite', { p_invite_id: invite.invite_id });
  shareActionPending = false;
  if (error) {
    setShareMessage('Non è stato possibile revocare l\'invito.');
    return;
  }
  setShareMessage('Invito revocato.');
  await loadShareManagement();
  await searchShareAccounts();
}

async function removeParticipant(participant) {
  if (shareActionPending || !await FamilAreaConfirm.confirm({ variant: 'danger', title: 'Rimuovere questo partecipante?', message: 'La persona non potrà più accedere alla lista.', confirmText: 'Rimuovi' })) return;
  shareActionPending = true;
  setShareMessage('Rimozione in corso...');
  const { error } = await c.rpc('remove_list_participant', { p_list_id: listId, p_account_id: participant.account_id });
  shareActionPending = false;
  if (error) {
    setShareMessage('Non è stato possibile rimuovere il partecipante.');
    return;
  }
  setShareMessage('Partecipante rimosso.');
  await loadShareManagement();
  await searchShareAccounts();
}

function row(x) {
  const li = document.createElement('li');
  const check = document.createElement('input');
  const text = document.createElement('span');
  const edit = document.createElement('button');
  const del = document.createElement('button');
  li.className = `list-item fa-v2-list-row${x.status === 'completed' ? ' is-completed' : ''}`;
  check.type = 'checkbox';
  check.checked = x.status === 'completed';
  text.className = 'list-item-text';
  text.textContent = x.text;
  edit.type = 'button';
  edit.textContent = 'Modifica';
  edit.className = 'fa-v2-button fa-v2-button--secondary';
  del.type = 'button';
  del.textContent = 'Elimina';
  del.className = 'fa-v2-button fa-v2-button--danger';

  const restoreRow = () => {
    check.disabled = !editable;
    edit.hidden = !editable;
    del.hidden = !editable;
    li.replaceChildren(check, text, edit, del);
  };

  const beginEdit = () => {
    const input = document.createElement('input');
    const save = document.createElement('button');
    const cancel = document.createElement('button');

    input.type = 'text';
    input.value = x.text;
    input.required = true;
    input.className = 'fa-v2-input';
    input.setAttribute('aria-label', 'Modifica elemento');
    save.type = 'button';
    save.textContent = 'Salva';
    save.className = 'fa-v2-button fa-v2-button--primary';
    cancel.type = 'button';
    cancel.textContent = 'Annulla';
    cancel.className = 'fa-v2-button fa-v2-button--secondary';
    const itemDraft = FamilAreaUnsavedChanges.register({
      root: li,
      getState: () => ({ text: input.value }),
      isActive: () => li.isConnected && li.contains(input),
      onDiscard: () => cancel.click()
    });

    const saveItem = async () => {
      const nextText = input.value.trim();
      if (!nextText) {
        input.setCustomValidity('Inserisci un testo per l\'elemento.');
        input.reportValidity();
        return;
      }
      input.setCustomValidity('');
      const saved = await updateItem(x, nextText, x.status || 'open');
      if (saved) {
        FamilAreaUnsavedChanges.markSaved(itemDraft);
        FamilAreaUnsavedChanges.dispose(itemDraft);
      }
    };

    check.disabled = true;
    li.replaceChildren(check, input, save, cancel);
    input.focus();
    input.select();
    save.onclick = saveItem;
    cancel.onclick = () => {
      restoreRow();
      FamilAreaUnsavedChanges.reset(itemDraft);
      FamilAreaUnsavedChanges.dispose(itemDraft);
    };
    input.oninput = () => input.setCustomValidity('');
    input.onkeydown = (event) => {
      if (event.key === 'Enter') {
        event.preventDefault();
        saveItem();
      }
      if (event.key === 'Escape') {
        event.preventDefault();
        cancel.click();
      }
    };
  };

  check.onchange = async () => {
    const saved = await updateItem(x, x.text, check.checked ? 'completed' : 'open');
    if (!saved) check.checked = x.status === 'completed';
  };
  edit.onclick = () => {
    FamilAreaUnsavedChanges.attempt(beginEdit, { discardActive: true });
  };
  del.onclick = async () => {
    if (!await FamilAreaConfirm.confirm({ variant: 'danger', title: 'Eliminare questo elemento?', message: 'L’elemento verrà eliminato definitivamente.', confirmText: 'Elimina' })) return;
    await c.rpc('delete_list_item', { p_item_id: x.id });
    load();
  };
  restoreRow();
  return li;
}

async function updateItem(x, text, status) {
  if (!editable) return;
  const { error } = await c.rpc('update_list_item', {
    p_item_id: x.id,
    p_text: text,
    p_position: x.position || 0,
    p_status: status
  });
  if (error) {
    m.hidden = false;
    m.textContent = 'Impossibile aggiornare l\'elemento.';
    return false;
  }
  await load();
  return true;
}

function restoreListHeader() {
  const title = document.getElementById('list-title');
  const description = document.getElementById('list-description');

  title.textContent = list.title;
  title.hidden = false;
  description.textContent = list.description || '';
  description.hidden = !list.description;
  listActions.replaceChildren(editListButton, shareListButton, deleteListButton);
  editingList = false;
}

function beginListEdit() {
  if (!canManageList || editingList) return;

  const title = document.getElementById('list-title');
  const description = document.getElementById('list-description');
  const titleInput = document.createElement('input');
  const descriptionInput = document.createElement('textarea');
  const save = document.createElement('button');
  const cancel = document.createElement('button');
  const header = title.closest('header');

  titleInput.type = 'text';
  titleInput.value = list.title;
  titleInput.required = true;
  titleInput.className = 'fa-v2-input';
  titleInput.setAttribute('aria-label', 'Titolo lista');
  descriptionInput.value = list.description || '';
  descriptionInput.className = 'fa-v2-textarea';
  descriptionInput.setAttribute('aria-label', 'Descrizione lista');
  save.type = 'button';
  save.textContent = 'Salva modifiche';
  save.className = 'fa-v2-button fa-v2-button--primary';
  cancel.type = 'button';
  cancel.textContent = 'Annulla';
  cancel.className = 'fa-v2-button fa-v2-button--secondary';
  const listDraft = FamilAreaUnsavedChanges.register({
    root: header,
    getState: () => ({ title: titleInput.value, description: descriptionInput.value }),
    isActive: () => editingList,
    onDiscard: () => cancel.click()
  });

  const saveList = async () => {
    const titleValue = titleInput.value.trim();
    if (!titleValue) {
      titleInput.setCustomValidity('Inserisci un titolo per la lista.');
      titleInput.reportValidity();
      return;
    }
    titleInput.setCustomValidity('');
    const { data, error } = await c.rpc('update_list', {
      p_list_id: listId,
      p_title: titleValue,
      p_description: descriptionInput.value.trim() || null
    });
    if (error || !data) {
      m.hidden = false;
      m.textContent = 'Impossibile aggiornare la lista.';
      return;
    }
    list = data;
    m.textContent = '';
    m.hidden = true;
    FamilAreaUnsavedChanges.markSaved(listDraft);
    titleInput.remove();
    descriptionInput.remove();
    restoreListHeader();
    FamilAreaUnsavedChanges.dispose(listDraft);
  };

  title.hidden = true;
  description.hidden = true;
  title.after(titleInput);
  description.after(descriptionInput);
  listActions.replaceChildren(save, cancel);
  editingList = true;
  titleInput.focus();
  titleInput.select();
  titleInput.oninput = () => titleInput.setCustomValidity('');
  save.onclick = saveList;
  cancel.onclick = () => {
    titleInput.remove();
    descriptionInput.remove();
    restoreListHeader();
    FamilAreaUnsavedChanges.reset(listDraft);
    FamilAreaUnsavedChanges.dispose(listDraft);
  };
}

async function load() {
  m.hidden = false;
  m.textContent = 'Caricamento lista...';
  const { data, error } = await c.rpc('get_list', { p_list_id: listId });
  if (error || !data) {
    m.textContent = 'Lista non disponibile.';
    return;
  }
  list = data.list;
  editable = data.can_edit_items === true;
  canManageList = data.can_manage_list === true;
  canShareList = canManageList && list.area_id === null;
  backLink.href = back();
  document.getElementById('list-title').textContent = list.title;
  const description = document.getElementById('list-description');
  description.textContent = list.description || '';
  description.hidden = !list.description;
  listActions.hidden = !canManageList;
  shareListButton.hidden = !canShareList;
  if (!canShareList) sharePanel.hidden = true;
  document.getElementById('add-item-form').hidden = !editable;
  document.getElementById('items-list').replaceChildren(...(data.items || []).map(row));
  document.getElementById('list-view').hidden = false;
  m.textContent = '';
  m.hidden = true;
}

document.getElementById('add-item-form').onsubmit = async (e) => {
  e.preventDefault();
  if (!editable) return;
  const { error } = await c.rpc('create_list_item', { p_list_id: listId, p_text: itemInput.value.trim(), p_position: 0 });
  if (error) {
    m.hidden = false;
    m.textContent = 'Impossibile aggiungere l’elemento.';
    return;
  }
  itemInput.value = '';
  itemInput.focus();
  load();
};

editListButton.onclick = () => {
  FamilAreaUnsavedChanges.attempt(beginListEdit, { discardActive: true });
};

deleteListButton.onclick = async () => {
  if (canManageList && await FamilAreaConfirm.confirm({ variant: 'danger', title: 'Eliminare la lista?', message: 'La lista verrà eliminata definitivamente.', confirmText: 'Elimina' })) {
    await c.rpc('delete_list', { p_list_id: listId });
    location.href = back();
  }
};

shareListButton.onclick = async () => {
  if (!canShareList) return;
  sharePanel.hidden = false;
  setShareMessage('');
  shareSearch.focus();
  await loadShareManagement();
};

closeShareButton.onclick = () => {
  sharePanel.hidden = true;
  shareSearch.value = '';
  shareSearchResults.replaceChildren();
  shareSearchStatus.textContent = 'Inserisci almeno 3 caratteri.';
  shareSearchRequest += 1;
  shareListButton.focus();
};

shareSearch.oninput = () => {
  window.clearTimeout(shareSearchTimer);
  shareSearchTimer = window.setTimeout(() => { void searchShareAccounts(); }, 250);
};

load();

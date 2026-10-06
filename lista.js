const c = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const areaId = new URLSearchParams(location.search).get('area_id');
const listId = new URLSearchParams(location.search).get('list_id');
const m = document.getElementById('message');
const itemInput = document.getElementById('item-text');
const backLink = document.querySelector('.account-back-link > a');
const editListButton = document.getElementById('edit-list-button');
const deleteListButton = document.getElementById('delete-list-button');
const listActions = document.getElementById('list-actions');
const managementPanel = document.getElementById('list-management-panel');
const listEditForm = document.getElementById('list-edit-form');
const listEditTitle = document.getElementById('list-edit-title');
const listEditDescription = document.getElementById('list-edit-description');
const saveListButton = document.getElementById('save-list-button');
const cancelListEditButton = document.getElementById('cancel-list-edit-button');
const sharingManagement = document.getElementById('list-sharing-management');
const shareState = document.getElementById('list-share-state');
const shareMessage = document.getElementById('list-share-message');
const shareSearch = document.getElementById('list-share-search');
const shareSearchStatus = document.getElementById('list-share-search-status');
const shareSearchResults = document.getElementById('list-share-search-results');
const sharePending = document.getElementById('list-share-pending');
const sharePendingEmpty = document.getElementById('list-share-pending-empty');
const shareParticipants = document.getElementById('list-share-participants');
const shareParticipantsEmpty = document.getElementById('list-share-participants-empty');
const sharingSummary = document.getElementById('list-sharing-summary');
const sharingStatus = document.getElementById('list-sharing-status');
const sharingAvatars = document.getElementById('list-sharing-avatars');
let list;
let editable = false;
let canManageList = false;
let canShareList = false;
let editingList = false;
let shareSearchTimer;
let shareSearchRequest = 0;
let shareActionPending = false;
let listDraft;

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

function personName(person) {
  return person?.display_name || [person?.first_name, person?.last_name].filter(Boolean).join(' ') || 'Utente FamilArea';
}

function renderSharingSummary(data) {
  const participants = data.participants || [];
  const people = [data.owner, ...participants].filter((person) => person?.account_id && person.account_id !== data.viewer_account_id);
  const personalList = list.area_id === null;
  const sharedPersonalList = personalList && participants.length > 0;
  sharingSummary.hidden = !personalList;
  sharingStatus.textContent = sharedPersonalList ? 'Condivisa' : 'Personale';
  sharingAvatars.replaceChildren();
  if (!sharedPersonalList || people.length === 0) return;

  const visiblePeople = people.slice(0, people.length > 3 ? 2 : 3);
  visiblePeople.forEach((person) => {
    const avatar = document.createElement('span');
    const name = personName(person);
    avatar.className = 'contact-directory-avatar';
    avatar.title = name;
    avatar.setAttribute('aria-label', name);
    renderAvatar(avatar, person.avatar_path, name);
    sharingAvatars.appendChild(avatar);
  });
  if (people.length > 3) {
    const remainder = document.createElement('span');
    remainder.className = 'contact-directory-avatar';
    remainder.textContent = `+${people.length - 2}`;
    remainder.title = `${people.length - 2} altre persone`;
    remainder.setAttribute('aria-label', remainder.title);
    sharingAvatars.appendChild(remainder);
  }
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

function shareRow(person, status, action, compact = false) {
  const row = document.createElement('div');
  const identity = document.createElement('div');
  const avatar = document.createElement('span');
  const name = document.createElement('strong');
  const actions = document.createElement('div');
  avatar.className = 'contact-directory-avatar';
  name.textContent = person.display_name || 'Utente FamilArea';
  renderAvatar(avatar, person.avatar_path, name.textContent);
  actions.className = status ? 'fa-v2-card-actions contact-directory-actions' : 'contact-directory-actions';
  if (status) {
    const badge = document.createElement('span');
    badge.className = 'fa-status-badge invite-status-pending';
    badge.textContent = status;
    actions.appendChild(badge);
  }
  actions.appendChild(action);
  if (compact) {
    row.className = 'fa-v2-list-row fa-v2-list-row--media';
    row.append(avatar, name, actions);
    return row;
  }
  row.className = 'fa-v2-list-row fa-v2-contact-summary-row';
  identity.className = 'contact-directory-name';
  identity.append(avatar, name);
  row.append(identity, actions);
  return row;
}

function renderShareManagement(data) {
  const pending = data?.pending_invites || [];
  const participants = data?.participants || [];
  const shared = data?.list?.sharing_status === 'shared';
  shareState.textContent = shared ? 'Condivisa' : 'Personale';
  sharePending.replaceChildren(...pending.map((invite) => shareRow(invite, 'In attesa', shareButton('Revoca', 'secondary', () => { void revokeInvite(invite); }), true)));
  shareParticipants.replaceChildren(...participants.map((participant) => shareRow(participant, '', shareButton('Rimuovi', 'danger', () => { void removeParticipant(participant); }), true)));
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
  shareSearchResults.hidden = true;
  if (!query) {
    shareSearchStatus.textContent = '';
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
  shareSearchResults.hidden = results.length === 0;
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

function renderListHeader() {
  const title = document.getElementById('list-title');
  const description = document.getElementById('list-description');
  const note = (list.description || '').trim();
  title.textContent = list.title;
  description.replaceChildren();
  if (!note) {
    description.hidden = true;
    return;
  }
  const label = document.createElement('strong');
  label.textContent = 'Note:';
  description.append(label, document.createTextNode(` ${note}`));
  description.hidden = false;
}

function resetListManagement() {
  listEditTitle.value = list.title;
  listEditDescription.value = list.description || '';
  listEditTitle.setCustomValidity('');
}

function closeListManagement() {
  managementPanel.hidden = true;
  editingList = false;
  shareSearch.value = '';
  shareSearchResults.replaceChildren();
  shareSearchResults.hidden = true;
  shareSearchStatus.textContent = '';
  shareSearchRequest += 1;
  if (listDraft) {
    FamilAreaUnsavedChanges.reset(listDraft);
    FamilAreaUnsavedChanges.dispose(listDraft);
    listDraft = undefined;
  }
  editListButton.focus();
}

async function openListManagement() {
  if (!canManageList || editingList) return;
  editingList = true;
  resetListManagement();
  managementPanel.hidden = false;
  sharingManagement.hidden = !canShareList;
  listDraft = FamilAreaUnsavedChanges.register({
    root: managementPanel,
    getState: () => ({ title: listEditTitle.value, description: listEditDescription.value }),
    isActive: () => editingList,
    onDiscard: closeListManagement
  });
  listEditTitle.focus();
  listEditTitle.select();
  if (canShareList) {
    setShareMessage('');
    await loadShareManagement();
  }
}

async function saveListManagement() {
  if (!listEditForm.reportValidity()) return;
  const titleValue = listEditTitle.value.trim();
  if (!titleValue) {
    listEditTitle.setCustomValidity('Inserisci un titolo per la lista.');
    listEditTitle.reportValidity();
    return;
  }
  listEditTitle.setCustomValidity('');
  const { data, error } = await c.rpc('update_list', {
    p_list_id: listId,
    p_title: titleValue,
    p_description: listEditDescription.value.trim() || null
  });
  if (error || !data) {
    m.hidden = false;
    m.textContent = 'Impossibile aggiornare la lista.';
    return;
  }
  list = data;
  renderListHeader();
  m.textContent = '';
  m.hidden = true;
  FamilAreaUnsavedChanges.markSaved(listDraft);
  closeListManagement();
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
  const areaName = document.getElementById('area-name');
  const isAreaList = Boolean(list.area_id);
  areaName.hidden = !isAreaList;
  if (isAreaList) areaName.textContent = 'Area';
  renderSharingSummary(data);
  editable = data.can_edit_items === true;
  canManageList = data.can_manage_list === true;
  canShareList = canManageList && list.area_id === null;
  backLink.href = back();
  renderListHeader();
  listActions.hidden = !canManageList;
  sharingManagement.hidden = !canShareList;
  if (!canManageList) managementPanel.hidden = true;
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
  FamilAreaUnsavedChanges.attempt(() => { void openListManagement(); }, { discardActive: true });
};

async function deleteList() {
  if (canManageList && await FamilAreaConfirm.confirm({ variant: 'danger', title: 'Eliminare la lista?', message: 'La lista verrà eliminata definitivamente.', confirmText: 'Elimina' })) {
    await c.rpc('delete_list', { p_list_id: listId });
    location.href = back();
  }
}

deleteListButton.onclick = () => {
  FamilAreaUnsavedChanges.attempt(() => { void deleteList(); }, { discardActive: true });
};

listEditForm.onsubmit = (event) => {
  event.preventDefault();
  void saveListManagement();
};
saveListButton.onclick = () => { void saveListManagement(); };
cancelListEditButton.onclick = closeListManagement;
listEditTitle.oninput = () => listEditTitle.setCustomValidity('');

shareSearch.oninput = () => {
  window.clearTimeout(shareSearchTimer);
  shareSearchTimer = window.setTimeout(() => { void searchShareAccounts(); }, 250);
};

load();

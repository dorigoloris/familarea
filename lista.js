const c = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const areaId = new URLSearchParams(location.search).get('area_id');
const listId = new URLSearchParams(location.search).get('list_id');
const m = document.getElementById('message');
const itemInput = document.getElementById('item-text');
const backLink = document.querySelector('.account-back-link > a');
const editListButton = document.getElementById('edit-list-button');
const deleteListButton = document.getElementById('delete-list-button');
const listActions = document.getElementById('list-actions');
let list;
let editable = false;
let editingList = false;

const back = () => areaId ? `liste.html?area_id=${encodeURIComponent(areaId)}` : 'liste.html';

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
  listActions.replaceChildren(editListButton, deleteListButton);
  editingList = false;
}

function beginListEdit() {
  if (!editable || editingList) return;

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
  const [{ data, error }, { data: a }, { data: areas }] = await Promise.all([
    c.rpc('get_list', { p_list_id: listId }),
    c.rpc('get_current_account'),
    c.rpc('get_my_areas')
  ]);
  if (error || !data) {
    m.textContent = 'Lista non disponibile.';
    return;
  }
  list = data.list;
  editable = list.owner_account_id === a?.account_id || !!(list.area_id && (areas || []).some((x) => x.id === list.area_id && ['owner', 'admin'].includes(x.role)));
  backLink.href = back();
  document.getElementById('list-title').textContent = list.title;
  const description = document.getElementById('list-description');
  description.textContent = list.description || '';
  description.hidden = !list.description;
  listActions.hidden = !editable;
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
  if (editable && await FamilAreaConfirm.confirm({ variant: 'danger', title: 'Eliminare la lista?', message: 'La lista verrà eliminata definitivamente.', confirmText: 'Elimina' })) {
    await c.rpc('delete_list', { p_list_id: listId });
    location.href = back();
  }
};

load();

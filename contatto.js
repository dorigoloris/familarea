const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const message = document.getElementById('message');
const view = document.getElementById('contact-view');
const editForm = document.getElementById('edit-form');
const methodForm = document.getElementById('method-form');
const emailList = document.getElementById('email-list');
const phoneList = document.getElementById('phone-list');
const addEmailButton = document.getElementById('add-email-button');
const addPhoneButton = document.getElementById('add-phone-button');
const methodValue = document.getElementById('method-value');
const methodValueLabel = document.getElementById('method-value-label');
const methodFormTitle = document.getElementById('method-form-title');
const methodSaveButton = document.getElementById('method-save-button');
const editSaveButton = document.getElementById('edit-save-button');

let contactId;
let contact;
let editingMethod = null;
let methodType = null;

function fullName(item) {
  return `${item.first_name || ''} ${item.last_name || ''}`.trim() || 'Contatto';
}

function formatBirthDate(value) {
  return value ? new Date(`${value}T00:00:00`).toLocaleDateString('it-IT') : '';
}

function methodsOf(type) {
  return (contact?.methods || []).filter((method) => method.type === type);
}

function primaryMethodOf(type) {
  return methodsOf(type).find((method) => method.is_primary) || null;
}

function showMessage(text) {
  message.textContent = text;
}

function renderMethodList(target, type, emptyText) {
  target.replaceChildren();
  const methods = methodsOf(type);
  if (!methods.length) {
    const item = document.createElement('li');
    item.textContent = emptyText;
    target.appendChild(item);
    return;
  }
  methods.forEach((method) => target.appendChild(createMethodItem(method)));
}

function createMethodItem(method) {
  const item = document.createElement('li');
  item.className = 'contact-method-item';
  const value = document.createElement('span');
  value.textContent = method.value;
  item.appendChild(value);

  if (method.is_primary) {
    const primary = document.createElement('strong');
    primary.textContent = ' Principale';
    item.appendChild(primary);
  }

  const actions = document.createElement('span');
  actions.className = 'contact-method-actions';
  const edit = document.createElement('button');
  edit.type = 'button';
  edit.textContent = 'Modifica';
  edit.addEventListener('click', () => showMethodForm(method.type, method));
  actions.appendChild(edit);

  if (!method.is_primary) {
    const primary = document.createElement('button');
    primary.type = 'button';
    primary.textContent = 'Imposta come principale';
    primary.addEventListener('click', () => setPrimary(method));
    actions.appendChild(primary);
  }

  const remove = document.createElement('button');
  remove.type = 'button';
  remove.textContent = 'Elimina';
  remove.addEventListener('click', () => deleteMethod(method));
  actions.appendChild(remove);
  item.appendChild(actions);
  return item;
}

function render() {
  document.title = `${fullName(contact)} - FamilArea`;
  document.getElementById('contact-name').textContent = fullName(contact);
  const birthDate = document.getElementById('contact-birth-date');
  birthDate.textContent = contact.birth_date ? `Data di nascita: ${formatBirthDate(contact.birth_date)}` : '';
  birthDate.hidden = !contact.birth_date;
  renderMethodList(emailList, 'email', 'Nessuna email.');
  renderMethodList(phoneList, 'phone', 'Nessun cellulare.');
  view.hidden = false;
}

async function loadContact() {
  const { data, error } = await supabaseClient.rpc('get_my_contact', { p_contact_id: contactId });
  if (error || !data?.[0]) {
    showMessage('Contatto non disponibile.');
    return;
  }
  contact = data[0];
  render();
  showMessage('');
}

function hideMethodForm() {
  methodForm.hidden = true;
  methodForm.reset();
  editingMethod = null;
  methodType = null;
}

function showMethodForm(type, method = null) {
  editingMethod = method;
  methodType = type;
  const isEmail = type === 'email';
  const anchor = isEmail ? addEmailButton : addPhoneButton;
  methodFormTitle.textContent = method ? `Modifica ${isEmail ? 'email' : 'cellulare'}` : `Aggiungi ${isEmail ? 'email' : 'cellulare'}`;
  methodValueLabel.textContent = isEmail ? 'Email' : 'Cellulare';
  methodValue.type = isEmail ? 'email' : 'tel';
  methodValue.inputMode = isEmail ? 'email' : 'tel';
  methodValue.autocomplete = isEmail ? 'email' : 'tel';
  methodValue.value = method?.value || '';
  anchor.insertAdjacentElement('afterend', methodForm);
  methodForm.hidden = false;
  methodValue.focus();
}

async function setPrimary(method) {
  showMessage('Aggiornamento in corso...');
  const { error } = await supabaseClient.rpc('set_my_contact_method_primary', { p_method_id: method.id });
  if (error) {
    showMessage('Impossibile impostare il recapito principale.');
    return;
  }
  await loadContact();
}

async function deleteMethod(method) {
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger',
    appearance: 'standard',
    title: `Eliminare ${method.type === 'email' ? 'questa email' : 'questo cellulare'}?`,
    message: method.value,
    confirmText: 'Elimina'
  });
  if (!confirmed) return;

  showMessage('Eliminazione in corso...');
  const { error } = await supabaseClient.rpc('delete_my_contact_method', { p_method_id: method.id });
  if (error) {
    showMessage('Impossibile eliminare il recapito.');
    return;
  }
  hideMethodForm();
  await loadContact();
}

methodForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const value = methodValue.value.trim();
  if (!value) {
    showMessage('Inserisci un recapito valido.');
    return;
  }

  methodSaveButton.disabled = true;
  showMessage('Salvataggio in corso...');
  let error;
  if (editingMethod) {
    ({ error } = await supabaseClient.rpc('update_my_contact_method', {
      p_method_id: editingMethod.id,
      p_type: methodType,
      p_value: value
    }));
  } else {
    ({ error } = await supabaseClient.rpc('add_my_contact_method', {
      p_contact_id: contactId,
      p_type: methodType,
      p_value: value,
      p_is_primary: false
    }));
  }
  methodSaveButton.disabled = false;
  if (error) {
    showMessage('Impossibile salvare il recapito. Verifica che non sia duplicato.');
    return;
  }
  hideMethodForm();
  await loadContact();
});

document.getElementById('method-cancel-button').addEventListener('click', hideMethodForm);
addEmailButton.addEventListener('click', () => showMethodForm('email'));
addPhoneButton.addEventListener('click', () => showMethodForm('phone'));

function showEditForm() {
  const primaryEmail = primaryMethodOf('email');
  const primaryPhone = primaryMethodOf('phone');
  document.getElementById('edit-first-name').value = contact.first_name || '';
  document.getElementById('edit-last-name').value = contact.last_name || '';
  document.getElementById('edit-email').value = primaryEmail?.value || '';
  document.getElementById('edit-phone').value = primaryPhone?.value || '';
  document.getElementById('edit-birth-date').value = contact.birth_date || '';
  hideMethodForm();
  view.hidden = true;
  editForm.hidden = false;
}

document.getElementById('edit-button').addEventListener('click', () => {
  showEditForm();
});

document.getElementById('edit-cancel-button').addEventListener('click', () => {
  editForm.hidden = true;
  view.hidden = false;
});

async function savePrimaryMethod(type, value, currentPrimary) {
  if (!value && currentPrimary) {
    return supabaseClient.rpc('delete_my_contact_method', { p_method_id: currentPrimary.id });
  }
  if (value && currentPrimary) {
    return supabaseClient.rpc('update_my_contact_method', {
      p_method_id: currentPrimary.id,
      p_type: type,
      p_value: value
    });
  }
  if (value) {
    return supabaseClient.rpc('add_my_contact_method', {
      p_contact_id: contactId,
      p_type: type,
      p_value: value,
      p_is_primary: true
    });
  }
  return { error: null };
}

editForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const firstName = document.getElementById('edit-first-name').value.trim();
  if (!firstName) {
    showMessage('Inserisci il nome del contatto.');
    return;
  }
  editSaveButton.disabled = true;
  showMessage('Salvataggio in corso...');
  const primaryEmail = primaryMethodOf('email');
  const primaryPhone = primaryMethodOf('phone');
  const { error } = await supabaseClient.rpc('update_my_contact', {
    p_contact_id: contactId,
    p_first_name: firstName,
    p_last_name: document.getElementById('edit-last-name').value.trim() || null,
    p_birth_date: document.getElementById('edit-birth-date').value || null
  });
  editSaveButton.disabled = false;
  if (error) {
    showMessage('Impossibile salvare il contatto.');
    return;
  }

  const updates = [
    { label: 'email', result: await savePrimaryMethod('email', document.getElementById('edit-email').value.trim(), primaryEmail) },
    { label: 'cellulare', result: await savePrimaryMethod('phone', document.getElementById('edit-phone').value.trim(), primaryPhone) }
  ];
  const failedUpdates = updates.filter((update) => update.result.error).map((update) => update.label);
  await loadContact();
  if (failedUpdates.length) {
    showEditForm();
    showMessage(`Dati anagrafici aggiornati, ma non è stato possibile salvare: ${failedUpdates.join(', ')}. Verifica i valori e riprova.`);
    return;
  }
  editForm.hidden = true;
});

document.getElementById('delete-button').addEventListener('click', async () => {
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger',
    appearance: 'standard',
    title: `Eliminare ${fullName(contact)}?`,
    message: 'Il contatto e tutti i suoi recapiti verranno eliminati definitivamente.',
    confirmText: 'Elimina contatto'
  });
  if (!confirmed) return;

  const button = document.getElementById('delete-button');
  button.disabled = true;
  showMessage('Eliminazione in corso...');
  const { error } = await supabaseClient.rpc('delete_my_contact', { p_contact_id: contactId });
  if (error) {
    showMessage('Impossibile eliminare il contatto.');
    button.disabled = false;
    return;
  }
  window.location.href = 'contatti.html';
});

async function load() {
  const { data } = await supabaseClient.auth.getSession();
  if (!data.session) {
    window.location.href = 'login.html';
    return;
  }
  contactId = new URLSearchParams(window.location.search).get('contact_id');
  if (!contactId) {
    showMessage('Contatto non specificato.');
    return;
  }
  await loadContact();
}

load();

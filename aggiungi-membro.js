const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const contactsPanel = document.getElementById('contacts-panel');
const createContactPanel = document.getElementById('create-contact-panel');
const showContactsButton = document.getElementById('show-contacts-button');
const showCreateButton = document.getElementById('show-create-button');
const emptyCreateContactButton = document.getElementById('empty-create-contact-button');
const cancelCreateButton = document.getElementById('cancel-create-button');
const contactsMessage = document.getElementById('contacts-message');
const createMessage = document.getElementById('create-message');
const contactsList = document.getElementById('contacts-list');
const contactsEmptyState = document.getElementById('contacts-empty-state');
const contactForm = document.getElementById('contact-form');
const createContactButton = document.getElementById('create-contact-button');
const backToAreaLink = document.getElementById('back-to-area-link');

let currentAreaId = null;
const RPC_TIMEOUT_MS = 15000;

async function rpcWithTimeout(name, parameters) {
  let timeoutId;
  try {
    return await Promise.race([
      supabaseClient.rpc(name, parameters),
      new Promise((_, reject) => {
        timeoutId = window.setTimeout(() => reject(new Error('rpc_timeout')), RPC_TIMEOUT_MS);
      })
    ]);
  } finally {
    window.clearTimeout(timeoutId);
  }
}

function contactName(contact) {
  return `${contact.first_name || ''} ${contact.last_name || ''}`.trim() || 'Contatto senza nome';
}

function setPanel(panel) {
  const showContacts = panel === 'contacts';
  contactsPanel.hidden = !showContacts;
  createContactPanel.hidden = showContacts;
  showContactsButton.setAttribute('aria-selected', String(showContacts));
  showCreateButton.setAttribute('aria-selected', String(!showContacts));
}

function returnToArea() {
  window.location.href = `area.html?area_id=${encodeURIComponent(currentAreaId)}#members-list`;
}

function createContactRow(contact) {
  const article = document.createElement('article');
  article.className = 'participant-contact-card';

  const details = document.createElement('div');
  const name = document.createElement('h3');
  name.textContent = contactName(contact);
  details.appendChild(name);

  if (contact.is_already_participant) {
    const status = document.createElement('p');
    status.className = 'participant-contact-status';
    status.textContent = 'Già partecipante';
    details.appendChild(status);
  }

  const action = document.createElement('button');
  action.type = 'button';
  action.textContent = contact.is_already_participant ? 'Già partecipante' : 'Aggiungi all’Area';
  action.disabled = Boolean(contact.is_already_participant);

  if (!contact.is_already_participant) {
    action.addEventListener('click', async () => {
      action.disabled = true;
      action.textContent = 'Aggiunta in corso...';
      contactsMessage.textContent = '';

      const { error } = await supabaseClient.rpc('add_my_contact_to_area', {
        p_area_id: currentAreaId,
        p_contact_id: contact.id
      });

      if (error) {
        action.disabled = false;
        action.textContent = 'Aggiungi all’Area';
        await loadContacts();
        contactsMessage.textContent = 'Non è stato possibile aggiungere il Contatto all’Area. Riprova.';
        return;
      }

      returnToArea();
    });
  }

  article.append(details, action);
  return article;
}

function renderContacts(contacts) {
  contactsList.replaceChildren();
  contactsEmptyState.hidden = Boolean(contacts?.length);
  if (!contacts?.length) return;
  contacts.forEach((contact) => contactsList.appendChild(createContactRow(contact)));
}

async function loadContacts() {
  contactsMessage.textContent = 'Caricamento Contatti...';
  try {
    const { data, error } = await rpcWithTimeout('get_my_contacts_for_area', {
      p_area_id: currentAreaId
    });

    if (error || !Array.isArray(data)) {
      throw error || new Error('invalid_rpc_response');
    }

    renderContacts(data);
    contactsMessage.textContent = '';
  } catch (error) {
    contactsList.replaceChildren();
    contactsEmptyState.hidden = true;
    contactsMessage.textContent = error?.message === 'rpc_timeout'
      ? 'Il caricamento dei Contatti sta richiedendo troppo tempo. Riprova.'
      : 'Impossibile caricare i tuoi Contatti per questa Area.';
    showCreateButton.disabled = true;
    emptyCreateContactButton.disabled = true;
  }
}

async function initialise() {
  try {
    const { data: sessionData } = await supabaseClient.auth.getSession();
    if (!sessionData?.session) {
      window.location.href = 'login.html';
      return;
    }

    currentAreaId = new URLSearchParams(window.location.search).get('area_id');
    if (!currentAreaId) {
      contactsMessage.textContent = 'Area non specificata.';
      showContactsButton.disabled = true;
      showCreateButton.disabled = true;
      return;
    }

    backToAreaLink.href = `area.html?area_id=${encodeURIComponent(currentAreaId)}#members-list`;
    await loadContacts();
  } catch {
    contactsMessage.textContent = 'Impossibile inizializzare la pagina. Riprova.';
    showContactsButton.disabled = true;
    showCreateButton.disabled = true;
  }
}

showContactsButton.addEventListener('click', () => setPanel('contacts'));
showCreateButton.addEventListener('click', () => setPanel('create'));
emptyCreateContactButton.addEventListener('click', () => setPanel('create'));
cancelCreateButton.addEventListener('click', () => {
  contactForm.reset();
  createMessage.textContent = '';
  setPanel('contacts');
});

contactForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!currentAreaId) {
    createMessage.textContent = 'Area non specificata.';
    return;
  }
  const firstName = document.getElementById('first-name').value.trim();
  const lastName = document.getElementById('last-name').value.trim() || null;
  const birthDate = document.getElementById('birth-date').value || null;

  if (!firstName) {
    createMessage.textContent = 'Inserisci il nome del Contatto.';
    return;
  }

  createContactButton.disabled = true;
  createMessage.textContent = 'Creazione Contatto in corso...';
  const { data: contactId, error: createError } = await supabaseClient.rpc('create_my_contact', {
    p_first_name: firstName,
    p_last_name: lastName,
    p_birth_date: birthDate
  });

  if (createError || !contactId) {
    createMessage.textContent = 'Impossibile creare il Contatto. Riprova.';
    createContactButton.disabled = false;
    return;
  }

  createMessage.textContent = 'Aggiunta all’Area in corso...';
  const { error: addError } = await supabaseClient.rpc('add_my_contact_to_area', {
    p_area_id: currentAreaId,
    p_contact_id: contactId
  });

  if (addError) {
    createMessage.textContent = 'Il Contatto è stato creato, ma non è stato possibile aggiungerlo all’Area. Puoi riprovare dalla lista dei tuoi Contatti.';
    createContactButton.disabled = false;
    await loadContacts();
    return;
  }

  returnToArea();
});

initialise();

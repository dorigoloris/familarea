const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const message = document.getElementById('message');
const list = document.getElementById('contacts-list');
const emptyState = document.getElementById('empty-state');

function fullName(contact) {
  return `${contact.first_name || ''} ${contact.last_name || ''}`.trim() || 'Contatto senza nome';
}

function formatBirthDate(value) {
  if (!value) return '';
  return new Date(`${value}T00:00:00`).toLocaleDateString('it-IT');
}

function createDirectoryField(label, value, className = '') {
  const field = document.createElement('div');
  field.className = `contact-directory-field ${className}`.trim();
  field.dataset.label = label;
  const text = document.createElement('span');
  text.textContent = value || '—';
  field.appendChild(text);
  return field;
}

function friendlyBirthdayError(error) {
  const details = String(error?.message || error || '');
  if (details.includes('data di nascita')) {
    return 'Aggiungi una data di nascita prima di mostrare il compleanno nel Calendario.';
  }
  return 'Non è stato possibile aggiornare il compleanno nel Calendario. Riprova.';
}

async function updateBirthdayCalendar(contact, checkbox) {
  const enabled = checkbox.checked;
  checkbox.disabled = true;
  const { error } = await supabaseClient.rpc('set_my_contact_birthday_calendar', {
    p_contact_id: contact.id,
    p_enabled: enabled
  });

  if (error) {
    checkbox.checked = !enabled;
    message.textContent = friendlyBirthdayError(error);
  } else {
    contact.show_birthday_in_calendar = enabled;
    message.textContent = enabled
      ? 'Compleanno aggiunto al Calendario.'
      : 'Compleanno rimosso dal Calendario.';
  }

  checkbox.disabled = !contact.birth_date;
}

function createContactCard(contact) {
  const article = document.createElement('article');
  article.className = 'contact-card contact-directory-row';

  const nameField = document.createElement('div');
  nameField.className = 'contact-directory-field contact-directory-name';
  nameField.dataset.label = 'Nome e cognome';
  const name = document.createElement('h2');
  name.textContent = fullName(contact);
  nameField.appendChild(name);

  const pendingInvitesCount = Number(contact.pending_invites_count || 0);
  if (pendingInvitesCount > 0) {
    const pendingInvites = document.createElement('span');
    pendingInvites.className = 'contact-pending-invites';
    pendingInvites.textContent = pendingInvitesCount === 1
      ? 'Invito in attesa'
      : `${pendingInvitesCount} inviti in attesa`;
    nameField.appendChild(pendingInvites);
  }

  const email = createDirectoryField('Email', contact.primary_email);
  const phone = createDirectoryField('Cellulare', contact.primary_phone);
  const birthDate = createDirectoryField('Data di nascita', formatBirthDate(contact.birth_date));

  const calendar = document.createElement('label');
  calendar.className = 'contact-directory-field contact-directory-calendar';
  calendar.dataset.label = 'Calendario';
  const checkbox = document.createElement('input');
  checkbox.type = 'checkbox';
  checkbox.checked = contact.show_birthday_in_calendar === true;
  checkbox.disabled = !contact.birth_date;
  checkbox.setAttribute('aria-label', `Mostra il compleanno di ${fullName(contact)} nel Calendario`);
  const calendarText = document.createElement('span');
  calendarText.textContent = contact.birth_date ? 'Compleanno' : 'Senza data di nascita';
  calendar.append(checkbox, calendarText);
  checkbox.addEventListener('change', () => updateBirthdayCalendar(contact, checkbox));

  const open = document.createElement('a');
  open.className = 'btn contact-directory-open';
  open.textContent = 'Apri';
  open.href = `contatto.html?contact_id=${encodeURIComponent(contact.id)}`;
  article.append(nameField, email, phone, birthDate, calendar, open);
  return article;
}

async function loadContacts() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }

  const { data, error } = await supabaseClient.rpc('get_my_contacts');
  if (error) {
    message.textContent = 'Impossibile caricare i contatti. Riprova.';
    return;
  }

  list.replaceChildren();
  if (!data?.length) {
    message.textContent = '';
    emptyState.hidden = false;
    return;
  }

  emptyState.hidden = true;
  data.forEach((contact) => list.appendChild(createContactCard(contact)));
  message.textContent = '';
}

loadContacts();

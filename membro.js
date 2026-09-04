const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const memberNameElement = document.getElementById('member-name');
const message = document.getElementById('message');
const firstNameElement = document.getElementById('member-first-name');
const lastNameElement = document.getElementById('member-last-name');
const birthDateElement = document.getElementById('member-birth-date');
const roleElement = document.getElementById('member-role');
const backToAreaLink = document.getElementById('back-to-area-link');

const viewMode = document.getElementById('view-mode');
const editButton = document.getElementById('edit-button');
const editForm = document.getElementById('edit-form');
const cancelButton = document.getElementById('cancel-button');
const editFirstNameInput = document.getElementById('edit-first-name');
const editLastNameInput = document.getElementById('edit-last-name');
const editBirthDateInput = document.getElementById('edit-birth-date');

const contactsSection = document.getElementById('contacts-section');
const contactsMessage = document.getElementById('contacts-message');
const emailContactsList = document.getElementById('email-contacts-list');
const phoneContactsList = document.getElementById('phone-contacts-list');
const addEmailButton = document.getElementById('add-email-button');
const addPhoneButton = document.getElementById('add-phone-button');
const contactForm = document.getElementById('contact-form');
const contactFormTitle = document.getElementById('contact-form-title');
const contactEmailField = document.getElementById('contact-email-field');
const contactPhoneField = document.getElementById('contact-phone-field');
const contactEmailInput = document.getElementById('contact-email-input');
const contactPhoneInput = document.getElementById('contact-phone-input');
const contactCancelButton = document.getElementById('contact-cancel-button');

let currentAreaId = null;
let currentProfileId = null;
let currentProfile = null;
let editingContact = null;

function renderProfile(profile, roleLabel) {
  const fullName = `${profile.first_name || ''} ${profile.last_name || ''}`.trim();

  memberNameElement.textContent = fullName || 'Scheda membro';
  firstNameElement.textContent = profile.first_name || '';
  lastNameElement.textContent = profile.last_name || '';
  birthDateElement.textContent = profile.birth_date || 'Non indicata';
  roleElement.textContent = roleLabel;
}

function roleToLabel(role) {
  if (role === 'admin') return 'Amministratore';
  if (role === 'member') return 'Membro';
  if (role === 'managed') return 'Profilo gestito';
  return role;
}

function showEditForm() {
  editFirstNameInput.value = currentProfile.first_name || '';
  editLastNameInput.value = currentProfile.last_name || '';
  editBirthDateInput.value = currentProfile.birth_date || '';

  viewMode.hidden = true;
  editForm.hidden = false;
}

function showViewMode() {
  editForm.hidden = true;
  viewMode.hidden = false;
}

function showContactsMessage(text) {
  contactsMessage.textContent = text;
}

function clearContactForm() {
  editingContact = null;
  contactEmailInput.value = '';
  contactPhoneInput.value = '';
  contactEmailInput.required = false;
  contactPhoneInput.required = false;
}

function showContactForm(contactType, contact = null) {
  editingContact = contact;
  const isEmail = contactType === 'email';

  contactFormTitle.textContent = contact ? `Modifica ${isEmail ? 'email' : 'cellulare'}` : `Aggiungi ${isEmail ? 'email' : 'cellulare'}`;
  contactEmailField.hidden = !isEmail;
  contactPhoneField.hidden = isEmail;
  contactEmailInput.required = isEmail;
  contactPhoneInput.required = !isEmail;
  contactEmailInput.value = isEmail && contact ? contact.contact_value : '';
  contactPhoneInput.value = !isEmail && contact ? contact.contact_value.replace(/^\+39/, '') : '';
  contactForm.hidden = false;
}

function hideContactForm() {
  contactForm.hidden = true;
  clearContactForm();
}

function toItalianE164(value) {
  let digits = value.replace(/\D/g, '');

  if (digits.startsWith('00')) {
    digits = digits.slice(2);
  }

  return digits.startsWith('39') ? `+${digits}` : `+39${digits}`;
}

function createContactListItem(contact) {
  const item = document.createElement('li');
  const value = document.createElement('span');
  value.textContent = contact.contact_value;
  item.appendChild(value);

  if (contact.is_primary) {
    const primary = document.createElement('strong');
    primary.textContent = ' Principale';
    item.appendChild(primary);
  }

  const actions = document.createElement('span');
  actions.appendChild(document.createTextNode(' '));

  const edit = document.createElement('button');
  edit.type = 'button';
  edit.textContent = 'Modifica';
  edit.addEventListener('click', () => showContactForm(contact.contact_type, contact));
  actions.appendChild(edit);

  if (!contact.is_primary) {
    const setPrimary = document.createElement('button');
    setPrimary.type = 'button';
    setPrimary.textContent = 'Imposta come principale';
    setPrimary.addEventListener('click', () => setContactPrimary(contact));
    actions.appendChild(document.createTextNode(' '));
    actions.appendChild(setPrimary);
  }

  const remove = document.createElement('button');
  remove.type = 'button';
  remove.textContent = 'Elimina';
  remove.addEventListener('click', () => deleteContact(contact));
  actions.appendChild(document.createTextNode(' '));
  actions.appendChild(remove);
  item.appendChild(actions);
  return item;
}

function renderContacts(contacts) {
  emailContactsList.replaceChildren();
  phoneContactsList.replaceChildren();

  const emails = contacts.filter((contact) => contact.contact_type === 'email');
  const phones = contacts.filter((contact) => contact.contact_type === 'phone');

  if (emails.length === 0) {
    const item = document.createElement('li');
    item.textContent = 'Nessuna email.';
    emailContactsList.appendChild(item);
  } else {
    emails.forEach((contact) => emailContactsList.appendChild(createContactListItem(contact)));
  }

  if (phones.length === 0) {
    const item = document.createElement('li');
    item.textContent = 'Nessun cellulare.';
    phoneContactsList.appendChild(item);
  } else {
    phones.forEach((contact) => phoneContactsList.appendChild(createContactListItem(contact)));
  }
}

async function loadContacts() {
  showContactsMessage('Caricamento contatti...');
  const { data, error } = await supabaseClient.rpc('get_area_member_contacts', {
    p_area_id: currentAreaId,
    p_profile_id: currentProfileId
  });

  if (error) {
    showContactsMessage('Impossibile caricare i contatti.');
    return;
  }

  renderContacts(data || []);
  showContactsMessage('');
}

async function setContactPrimary(contact) {
  showContactsMessage('Aggiornamento in corso...');
  const { error } = await supabaseClient.rpc('set_area_member_contact_primary', {
    p_area_id: currentAreaId,
    p_profile_id: currentProfileId,
    p_contact_id: contact.id
  });

  if (error) {
    showContactsMessage('Impossibile impostare il contatto principale.');
    return;
  }

  await loadContacts();
  showContactsMessage('Contatto principale aggiornato.');
}

async function deleteContact(contact) {
  if (!window.confirm(`Eliminare ${contact.contact_value}?`)) return;

  showContactsMessage('Eliminazione in corso...');
  const { error } = await supabaseClient.rpc('delete_area_member_contact', {
    p_area_id: currentAreaId,
    p_profile_id: currentProfileId,
    p_contact_id: contact.id
  });

  if (error) {
    showContactsMessage('Impossibile eliminare il contatto.');
    return;
  }

  await loadContacts();
  showContactsMessage('Contatto eliminato.');
}

async function loadMember() {
  const { data: sessionData } = await supabaseClient.auth.getSession();

  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }

  const userId = sessionData.session.user.id;

  const params = new URLSearchParams(window.location.search);
  const areaId = params.get('area_id');
  const profileId = params.get('profile_id');

  if (!areaId || !profileId) {
    message.textContent = 'Scheda membro non disponibile.';
    return;
  }

  currentAreaId = areaId;
  currentProfileId = profileId;

  backToAreaLink.href = `area.html?area_id=${encodeURIComponent(areaId)}`;

  // la RLS su area_memberships consente di leggere solo le membership della propria Area
  const { data: membership, error: membershipError } = await supabaseClient
    .from('area_memberships')
    .select('role')
    .eq('area_id', areaId)
    .eq('profile_id', profileId)
    .single();

  if (membershipError || !membership) {
    message.textContent = 'Impossibile caricare la scheda membro.';
    return;
  }

  // la RLS su profiles consente di leggere solo i profili delle proprie Aree
  const { data: profile, error: profileError } = await supabaseClient
    .from('profiles')
    .select('first_name, last_name, birth_date')
    .eq('id', profileId)
    .single();

  if (profileError || !profile) {
    message.textContent = 'Impossibile caricare la scheda membro.';
    return;
  }

  currentProfile = profile;
  renderProfile(profile, roleToLabel(membership.role));

  // il pulsante "Modifica" è solo un aiuto di interfaccia: il permesso reale
  // viene verificato lato server dalla RPC update_area_member
  const { data: ownProfile } = await supabaseClient
    .from('profiles')
    .select('id')
    .eq('user_id', userId)
    .single();

  if (ownProfile) {
    const { data: ownMembership } = await supabaseClient
      .from('area_memberships')
      .select('role')
      .eq('area_id', areaId)
      .eq('profile_id', ownProfile.id)
      .single();

    if (ownMembership && ownMembership.role === 'admin') {
      editButton.hidden = false;
      contactsSection.hidden = false;
      await loadContacts();
    }
  }

  message.textContent = '';
}

editButton.addEventListener('click', () => {
  showEditForm();
});

cancelButton.addEventListener('click', () => {
  showViewMode();
});

editForm.addEventListener('submit', async (event) => {
  event.preventDefault();

  const firstName = editFirstNameInput.value.trim();
  const lastName = editLastNameInput.value.trim();
  const birthDate = editBirthDateInput.value || null;

  message.textContent = 'Salvataggio in corso...';

  const { error } = await supabaseClient.rpc('update_area_member', {
    p_area_id: currentAreaId,
    p_profile_id: currentProfileId,
    p_first_name: firstName,
    p_last_name: lastName,
    p_birth_date: birthDate
  });

  if (error) {
    message.textContent = 'Impossibile salvare le modifiche.';
    return;
  }

  currentProfile = {
    first_name: firstName,
    last_name: lastName,
    birth_date: birthDate
  };

  renderProfile(currentProfile, roleElement.textContent);
  showViewMode();
  message.textContent = 'Dati aggiornati correttamente.';
});

addEmailButton.addEventListener('click', () => {
  showContactsMessage('');
  showContactForm('email');
});

addPhoneButton.addEventListener('click', () => {
  showContactsMessage('');
  showContactForm('phone');
});

contactCancelButton.addEventListener('click', () => {
  hideContactForm();
  showContactsMessage('');
});

contactForm.addEventListener('submit', async (event) => {
  event.preventDefault();

  const contactType = editingContact ? editingContact.contact_type : (contactEmailField.hidden ? 'phone' : 'email');
  const contactValue = contactType === 'email'
    ? contactEmailInput.value.trim()
    : toItalianE164(contactPhoneInput.value.trim());

  if (!contactValue || (contactType === 'phone' && contactValue === '+39')) {
    showContactsMessage('Inserisci un contatto valido.');
    return;
  }

  showContactsMessage('Salvataggio in corso...');
  let error;

  if (editingContact) {
    ({ error } = await supabaseClient.rpc('update_area_member_contact', {
      p_area_id: currentAreaId,
      p_profile_id: currentProfileId,
      p_contact_id: editingContact.id,
      p_contact_value: contactValue
    }));
  } else {
    ({ error } = await supabaseClient.rpc('add_area_member_contact', {
      p_area_id: currentAreaId,
      p_profile_id: currentProfileId,
      p_contact_type: contactType,
      p_contact_value: contactValue,
      p_is_primary: false
    }));
  }

  if (error) {
    showContactsMessage('Impossibile salvare il contatto.');
    return;
  }

  hideContactForm();
  await loadContacts();
  showContactsMessage('Contatto salvato correttamente.');
});

loadMember();

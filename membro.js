const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const memberNameElement = document.getElementById('member-name');
const message = document.getElementById('message');
const firstNameElement = document.getElementById('member-first-name');
const lastNameElement = document.getElementById('member-last-name');
const birthDateElement = document.getElementById('member-birth-date');
const roleElement = document.getElementById('member-role');
const backToAreaLink = document.getElementById('back-to-area-link');
const backToMembersLink = document.getElementById('back-to-members-link');

const viewMode = document.getElementById('view-mode');
const editButton = document.getElementById('edit-button');
const editForm = document.getElementById('edit-form');
const cancelButton = document.getElementById('cancel-button');
const editFirstNameInput = document.getElementById('edit-first-name');
const editLastNameInput = document.getElementById('edit-last-name');
const editBirthDateInput = document.getElementById('edit-birth-date');
const removeMemberActions = document.getElementById('remove-member-actions');
const removeMemberButton = document.getElementById('remove-member-button');

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
let currentAreaName = 'questa Area';
let editingContact = null;

function renderProfile(profile, roleLabel) {
  const fullName = `${profile.first_name || ''} ${profile.last_name || ''}`.trim();

  memberNameElement.textContent = fullName || 'Scheda partecipante';
  firstNameElement.textContent = profile.first_name || '';
  lastNameElement.textContent = profile.last_name || '';
  birthDateElement.textContent = profile.birth_date || 'Non indicata';
  roleElement.textContent = roleLabel;
}

function roleToLabel(role, isPersonalContactParticipant = false) {
  if (isPersonalContactParticipant) return 'Partecipante';
  if (role === 'admin') return 'Amministratore';
  if (role === 'member') return 'Partecipante';
  if (role === 'managed') return 'Profilo gestito';
  return role;
}

function setEditButtonVisibility(canEdit) {
  editButton.hidden = !canEdit;
  editButton.disabled = !canEdit;
  editButton.setAttribute('aria-hidden', String(!canEdit));
  editButton.style.display = canEdit ? '' : 'none';
}

function memberDisplayName() {
  const name = `${currentProfile?.first_name || ''} ${currentProfile?.last_name || ''}`.trim();
  return name || 'questa persona';
}

function removeMemberErrorMessage(error) {
  const text = `${error?.message || ''} ${error?.details || ''}`.toLowerCase();

  if (text.includes('ultimo amministratore')) return "Non puoi rimuovere l'ultimo amministratore dell'Area.";
  if (text.includes('creatore di attività') || text.includes('creatore di attivita')) return "Non puoi rimuovere questa persona perché ha creato attività nell'Area.";
  if (text.includes('creatore di eventi')) return "Non puoi rimuovere questa persona perché ha creato eventi nell'Area.";
  if (text.includes('ultimo assegnatario di attività selettiva') || text.includes('ultimo assegnatario di attivita selettiva')) return "Prima assegna l'attività a un'altra persona oppure modifica la sua visibilità.";
  if (text.includes('ultimo partecipante di evento selettivo')) return "Prima aggiungi un altro partecipante oppure modifica la visibilità dell'evento.";
  if (text.includes('non autorizzato') || text.includes('permission denied')) return 'Non sei autorizzato a rimuovere partecipanti da questa Area.';
  if (text.includes('membership del membro non trovata')) return 'Questa persona non fa più parte dell’Area.';
  return 'Non è stato possibile rimuovere la persona dall’Area. Riprova.';
}

async function removeMemberFromArea() {
  const name = memberDisplayName();
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger',
    appearance: 'standard',
    title: `Vuoi rimuovere ${name} da ${currentAreaName}?`,
    message: 'La persona non farà più parte di questa Area. Il suo profilo globale non verrà eliminato.',
    warning: '',
    confirmText: 'Rimuovi'
  });
  if (!confirmed) return;

  removeMemberButton.disabled = true;
  removeMemberButton.textContent = 'Rimozione in corso...';
  message.textContent = '';

  const { error } = await supabaseClient.rpc('remove_area_member', {
    p_area_id: currentAreaId,
    p_profile_id: currentProfileId
  });

  if (error) {
    message.textContent = removeMemberErrorMessage(error);
    removeMemberButton.disabled = false;
    removeMemberButton.textContent = "Rimuovi dall'Area";
    return;
  }

  window.location.href = `area.html?area_id=${encodeURIComponent(currentAreaId)}#members-list`;
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
  const triggerButton = isEmail ? addEmailButton : addPhoneButton;

  contactFormTitle.textContent = contact ? `Modifica ${isEmail ? 'email' : 'cellulare'}` : `Aggiungi ${isEmail ? 'email' : 'cellulare'}`;
  contactEmailField.hidden = !isEmail;
  contactPhoneField.hidden = isEmail;
  contactEmailInput.required = isEmail;
  contactPhoneInput.required = !isEmail;
  contactEmailInput.value = isEmail && contact ? contact.contact_value : '';
  contactPhoneInput.value = !isEmail && contact ? contact.contact_value.replace(/^\+39/, '') : '';
  triggerButton.insertAdjacentElement('afterend', contactForm);
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
  showContactsMessage('Caricamento email e cellulari...');
  const { data, error } = await supabaseClient.rpc('get_area_member_contacts', {
    p_area_id: currentAreaId,
    p_profile_id: currentProfileId
  });

  if (error) {
    showContactsMessage('Impossibile caricare email e cellulari.');
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
    message.textContent = 'Scheda partecipante non disponibile.';
    return;
  }

  currentAreaId = areaId;
  currentProfileId = profileId;

  backToAreaLink.href = `area.html?area_id=${encodeURIComponent(areaId)}`;
  backToMembersLink.href = `area.html?area_id=${encodeURIComponent(areaId)}#members-list`;

  const { data: participants, error: participantsError } = await supabaseClient.rpc('get_area_participants', {
    p_area_id: areaId
  });
  const participant = participants?.find((item) => item.profile_id === profileId);

  if (participantsError || !participant) {
    message.textContent = 'Impossibile caricare la scheda partecipante.';
    return;
  }

  const { data: area } = await supabaseClient
    .from('areas')
    .select('name')
    .eq('id', areaId)
    .single();

  if (area?.name) currentAreaName = area.name;

  const isPersonalContactParticipant = participant.is_personal_contact_participant === true;
  setEditButtonVisibility(false);
  contactsSection.hidden = true;
  removeMemberActions.hidden = true;
  removeMemberButton.hidden = true;

  currentProfile = participant;
  renderProfile(participant, roleToLabel(participant.role, isPersonalContactParticipant));

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
      removeMemberActions.hidden = false;
      removeMemberButton.hidden = false;
      if (!isPersonalContactParticipant) {
        setEditButtonVisibility(true);
        contactsSection.hidden = false;
        await loadContacts();
      }
    }
  }

  message.textContent = '';
}

editButton.addEventListener('click', () => {
  showEditForm();
});

removeMemberButton.addEventListener('click', removeMemberFromArea);

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

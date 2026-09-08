const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const pageMessage = document.getElementById('page-message');
const areaDescription = document.getElementById('area-description');
const backToAreaLink = document.getElementById('back-to-area-link');
const inviteFormSection = document.getElementById('invite-form-section');
const inviteForm = document.getElementById('invite-form');
const contactsModeButton = document.getElementById('contacts-mode-button');
const manualModeButton = document.getElementById('manual-mode-button');
const contactInvitePanel = document.getElementById('contact-invite-panel');
const manualInvitePanel = document.getElementById('manual-invite-panel');
const contactSearch = document.getElementById('contact-search');
const contactInviteMessage = document.getElementById('contact-invite-message');
const contactInviteList = document.getElementById('contact-invite-list');
const selectedContactInvite = document.getElementById('selected-contact-invite');
const selectedContactName = document.getElementById('selected-contact-name');
const sendContactInviteButton = document.getElementById('send-contact-invite-button');
const inviteEmail = document.getElementById('invite-email');
const inviteFirstName = document.getElementById('invite-first-name');
const inviteLastName = document.getElementById('invite-last-name');
const sendInviteButton = document.getElementById('send-invite-button');
const resetInviteButton = document.getElementById('reset-invite-button');
const inviteFormMessage = document.getElementById('invite-form-message');
const invitesSection = document.getElementById('invites-section');
const invitesList = document.getElementById('invites-list');
const invitesEmpty = document.getElementById('invites-empty');

let currentAreaId = null;
let isAreaAdmin = false;
let invitableContacts = [];
let selectedContact = null;

function fullName(firstName, lastName, fallback = '') {
  return `${firstName || ''} ${lastName || ''}`.trim() || fallback;
}

function inviteStatusLabel(status) {
  return ({ pending: 'In attesa', accepted: 'Accettato', declined: 'Rifiutato', revoked: 'Revocato', expired: 'Scaduto' })[status] || status;
}

function inviteErrorMessage(error) {
  const text = `${error?.message || ''} ${error?.details || ''}`.toLowerCase();
  if (text.includes('impossibile creare l') || text.includes('gia') && text.includes('partecipante')) return 'Questo destinatario è già partecipante dell’Area oppure non può essere invitato.';
  if (text.includes('nome del destinatario') && text.includes('obbligatorio')) return 'Inserisci il nome del destinatario.';
  if (text.includes('email dell') && text.includes('non verificata')) return 'Il destinatario dovrà verificare la propria email prima di poter accettare l’invito.';
  if (text.includes('invito in attesa')) return 'Esiste già un invito in attesa per questo indirizzo.';
  if (text.includes('permission denied') || text.includes('non autorizzato')) return 'Non sei autorizzato a gestire gli inviti di questa Area.';
  if (text.includes('non accettabile') || text.includes('gia concluso')) return 'Questo invito non può più essere modificato.';
  return 'Non è stato possibile completare l’operazione. Riprova.';
}

function resetInviteForm() {
  inviteForm.reset();
  inviteFormMessage.textContent = '';
}

function contactMethods(contact) {
  if (Array.isArray(contact.methods)) return contact.methods;
  try { return JSON.parse(contact.methods || '[]'); } catch { return []; }
}

function primaryEmail(contact) {
  const emails = contactMethods(contact).filter((method) => method.type === 'email' && method.value);
  return emails.find((method) => method.is_primary)?.value || emails[0]?.value || null;
}

function setInviteMode(mode) {
  const contactsMode = mode === 'contacts';
  contactInvitePanel.hidden = !contactsMode;
  manualInvitePanel.hidden = contactsMode;
  contactsModeButton.classList.toggle('is-active', contactsMode);
  manualModeButton.classList.toggle('is-active', !contactsMode);
  contactsModeButton.setAttribute('aria-pressed', String(contactsMode));
  manualModeButton.setAttribute('aria-pressed', String(!contactsMode));
  inviteFormMessage.textContent = '';
}

function renderContacts() {
  const search = contactSearch.value.trim().toLocaleLowerCase('it-IT');
  const visibleContacts = invitableContacts.filter((contact) => {
    const searchable = `${fullName(contact)} ${contact.email}`.toLocaleLowerCase('it-IT');
    return !search || searchable.includes(search);
  });
  contactInviteList.replaceChildren();

  if (!visibleContacts.length) {
    const empty = document.createElement('p');
    empty.className = 'empty-state';
    empty.textContent = search ? 'Nessun Contatto corrisponde alla ricerca.' : 'Non hai Contatti con un’email utilizzabile.';
    contactInviteList.appendChild(empty);
    return;
  }

  visibleContacts.forEach((contact) => {
    const card = document.createElement('article');
    card.className = 'invite-contact-card';
    const details = document.createElement('div');
    const name = document.createElement('h3');
    const email = document.createElement('p');
    const select = document.createElement('button');
    name.textContent = fullName(contact.first_name, contact.last_name, 'Contatto');
    email.textContent = contact.email;
    select.type = 'button';
    select.className = 'secondary-button';
    select.textContent = selectedContact?.id === contact.id ? 'Selezionato' : 'Seleziona';
    select.disabled = selectedContact?.id === contact.id;
    select.addEventListener('click', () => {
      selectedContact = contact;
      selectedContactName.textContent = `${fullName(contact.first_name, contact.last_name, 'Contatto')} — ${contact.email}`;
      selectedContactInvite.hidden = false;
      sendContactInviteButton.disabled = false;
      inviteFormMessage.textContent = '';
      renderContacts();
    });
    details.append(name, email);
    card.append(details, select);
    contactInviteList.appendChild(card);
  });
}

async function loadInvitableContacts() {
  const { data: contacts, error } = await supabaseClient.rpc('get_my_contacts');
  if (error) {
    contactInviteMessage.textContent = 'I Contatti non sono disponibili al momento. Puoi inserire l’invito manualmente.';
    setInviteMode('manual');
    return;
  }

  const details = await Promise.all((contacts || []).map(async (contact) => {
    const { data } = await supabaseClient.rpc('get_my_contact', { p_contact_id: contact.id });
    const detailedContact = data?.[0];
    const email = detailedContact ? primaryEmail(detailedContact) : null;
    return email ? { ...contact, email } : null;
  }));
  invitableContacts = details.filter(Boolean);
  if (invitableContacts.length) {
    setInviteMode('contacts');
    renderContacts();
  } else {
    contactInviteMessage.textContent = 'Non hai Contatti con un’email utilizzabile. Inserisci l’invito manualmente.';
    setInviteMode('manual');
  }
}

async function createInvite({ email, firstName, lastName }, button) {
  button.disabled = true;
  const originalText = button.textContent;
  button.textContent = 'Creazione in corso…';
  inviteFormMessage.textContent = '';
  const { error } = await supabaseClient.rpc('create_area_invite', {
    p_area_id: currentAreaId,
    p_email: email,
    p_first_name: firstName,
    p_last_name: lastName || null,
    p_target_managed_profile_id: null
  });
  button.disabled = false;
  button.textContent = originalText;
  if (error) {
    inviteFormMessage.textContent = inviteErrorMessage(error);
    return;
  }
  resetInviteForm();
  selectedContact = null;
  selectedContactInvite.hidden = true;
  sendContactInviteButton.disabled = true;
  renderContacts();
  pageMessage.textContent = 'Invito creato correttamente.';
  await loadInvites();
}

function createInviteCard(invite) {
  const article = document.createElement('article');
  article.className = 'invite-card';
  const details = document.createElement('div');
  const email = document.createElement('h3');
  const name = document.createElement('p');
  const metadata = document.createElement('p');
  const status = document.createElement('span');

  email.textContent = invite.recipient_email;
  const recipientName = fullName(invite.first_name, invite.last_name);
  name.textContent = recipientName || 'Nome non indicato';
  status.className = `invite-status invite-status-${invite.status}`;
  status.textContent = inviteStatusLabel(invite.status);
  metadata.textContent = 'Invito partecipante';
  details.append(email, name, status, metadata);
  article.appendChild(details);

  if (invite.status === 'pending') {
    const revoke = document.createElement('button');
    revoke.type = 'button';
    revoke.className = 'secondary-button invite-revoke-button';
    revoke.textContent = 'Revoca';
    revoke.addEventListener('click', async () => {
      revoke.disabled = true;
      revoke.textContent = 'Revoca in corso…';
      pageMessage.textContent = '';
      const { error } = await supabaseClient.rpc('revoke_area_invite', {
        p_area_id: currentAreaId,
        p_invite_id: invite.invite_id
      });
      if (error) {
        revoke.disabled = false;
        revoke.textContent = 'Revoca';
        pageMessage.textContent = inviteErrorMessage(error);
        return;
      }
      pageMessage.textContent = 'Invito revocato.';
      await loadInvites();
    });
    article.appendChild(revoke);
  }
  return article;
}

async function loadInvites() {
  const { data, error } = await supabaseClient.rpc('get_area_invites', { p_area_id: currentAreaId });
  if (error) {
    pageMessage.textContent = inviteErrorMessage(error);
    return false;
  }
  isAreaAdmin = true;
  inviteFormSection.hidden = false;
  invitesSection.hidden = false;
  invitesList.replaceChildren();
  invitesEmpty.hidden = Boolean(data?.length);
  (data || []).forEach((invite) => invitesList.appendChild(createInviteCard(invite)));
  return true;
}

async function loadPage() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }
  currentAreaId = new URLSearchParams(window.location.search).get('area_id');
  if (!currentAreaId) {
    pageMessage.textContent = 'Area non specificata.';
    return;
  }
  backToAreaLink.href = `area.html?area_id=${encodeURIComponent(currentAreaId)}`;
  const { data: area } = await supabaseClient.from('areas').select('name').eq('id', currentAreaId).single();
  if (area?.name) areaDescription.textContent = `Gestisci gli inviti per ${area.name}.`;

  const canLoadInvites = await loadInvites();
  if (!canLoadInvites) return;
  await loadInvitableContacts();
  pageMessage.textContent = '';
}

inviteForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!isAreaAdmin) return;
  const email = inviteEmail.value.trim();
  const firstName = inviteFirstName.value.trim();
  if (!email) {
    inviteFormMessage.textContent = 'Inserisci l’email del destinatario.';
    return;
  }
  if (!firstName) {
    inviteFormMessage.textContent = 'Inserisci il nome del destinatario.';
    return;
  }
  await createInvite({ email, firstName, lastName: inviteLastName.value.trim() }, sendInviteButton);
});

resetInviteButton.addEventListener('click', resetInviteForm);
contactsModeButton.addEventListener('click', () => setInviteMode('contacts'));
manualModeButton.addEventListener('click', () => setInviteMode('manual'));
contactSearch.addEventListener('input', renderContacts);
sendContactInviteButton.addEventListener('click', async () => {
  if (!selectedContact || !isAreaAdmin) return;
  await createInvite({
    email: selectedContact.email,
    firstName: selectedContact.first_name,
    lastName: selectedContact.last_name
  }, sendContactInviteButton);
});
loadPage();

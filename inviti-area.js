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
const selectedContactSummary = document.getElementById('selected-contact-summary');
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
const selectedContactIds = new Set();

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

function selectedContacts() {
  return invitableContacts.filter((contact) => selectedContactIds.has(contact.id));
}

function updateSelectedContactsUi() {
  const count = selectedContactIds.size;
  selectedContactSummary.textContent = `${count} selezionat${count === 1 ? 'o' : 'i'}`;
  sendContactInviteButton.disabled = count === 0;
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
    const select = document.createElement('label');
    const checkbox = document.createElement('input');
    name.textContent = fullName(contact.first_name, contact.last_name, 'Contatto');
    email.textContent = contact.email;
    select.className = 'invite-contact-checkbox';
    checkbox.type = 'checkbox';
    checkbox.checked = selectedContactIds.has(contact.id);
    checkbox.setAttribute('aria-label', `Seleziona ${fullName(contact.first_name, contact.last_name, 'Contatto')}`);
    checkbox.addEventListener('change', () => {
      if (checkbox.checked) selectedContactIds.add(contact.id);
      else selectedContactIds.delete(contact.id);
      inviteFormMessage.textContent = '';
      updateSelectedContactsUi();
    });
    select.append(checkbox, document.createTextNode('Seleziona'));
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
    updateSelectedContactsUi();
  } else {
    contactInviteMessage.textContent = 'Non hai Contatti con un’email utilizzabile. Inserisci l’invito manualmente.';
    setInviteMode('manual');
  }
}

async function requestInvite({ email, firstName, lastName }) {
  return supabaseClient.rpc('create_area_invite', {
    p_area_id: currentAreaId,
    p_email: email,
    p_first_name: firstName,
    p_last_name: lastName || null,
    p_target_managed_profile_id: null
  });
}

async function createInvite({ email, firstName, lastName }, button) {
  button.disabled = true;
  const originalText = button.textContent;
  button.textContent = 'Creazione in corso…';
  inviteFormMessage.textContent = '';
  const { error } = await requestInvite({ email, firstName, lastName });
  button.disabled = false;
  button.textContent = originalText;
  if (error) {
    inviteFormMessage.textContent = inviteErrorMessage(error);
    return;
  }
  resetInviteForm();
  pageMessage.textContent = 'Invito creato correttamente.';
  await loadInvites();
}

async function sendSelectedContactInvites() {
  const contacts = selectedContacts();
  if (!contacts.length || !isAreaAdmin) return;

  sendContactInviteButton.disabled = true;
  const originalText = sendContactInviteButton.textContent;
  sendContactInviteButton.textContent = 'Invio in corso…';
  inviteFormMessage.textContent = '';

  const results = await Promise.all(contacts.map(async (contact) => {
    try {
      const { error } = await requestInvite({
        email: contact.email,
        firstName: contact.first_name,
        lastName: contact.last_name
      });
      return { contact, error };
    } catch (error) {
      return { contact, error };
    }
  }));

  const successes = results.filter((result) => !result.error);
  const failures = results.filter((result) => result.error);
  successes.forEach((result) => selectedContactIds.delete(result.contact.id));
  renderContacts();
  updateSelectedContactsUi();
  sendContactInviteButton.textContent = originalText;

  const createdText = `${successes.length} invit${successes.length === 1 ? 'o creato' : 'i creati'}.`;
  const failuresText = failures.map((result) => `${fullName(result.contact.first_name, result.contact.last_name, 'Contatto')} — ${inviteErrorMessage(result.error)}`).join(' ');
  inviteFormMessage.textContent = failures.length ? `${createdText} ${failures.length} non creat${failures.length === 1 ? 'o' : 'i'}: ${failuresText}` : createdText;
  pageMessage.textContent = successes.length ? 'Elenco inviti aggiornato.' : '';
  if (successes.length) await loadInvites();
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
  await sendSelectedContactInvites();
});
loadPage();

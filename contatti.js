const supabaseClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const list = document.getElementById('contacts-list');
const empty = document.getElementById('empty-state');
const contactsGrid = document.querySelector('.fa-contacts-grid');
const myContact = document.getElementById('my-contact');
const myContactName = document.getElementById('my-contact-name');
const myContactAvatar = document.getElementById('my-contact-avatar');
function fullName(contact) { return [contact.first_name, contact.last_name].filter(Boolean).join(' ') || 'Contatto'; }
function initials(name) { return name.trim().split(/\s+/).slice(0, 2).map((part) => part[0]).join('').toLocaleUpperCase('it-IT') || 'C'; }
function formatBirthDate(value) { return value ? new Intl.DateTimeFormat('it-IT', { dateStyle: 'medium' }).format(new Date(`${value}T00:00:00`)) : '—'; }
function field(label, value) { const element = document.createElement('div'); element.className = 'contact-directory-field'; element.dataset.label = label; element.textContent = value || '—'; return element; }
function showAvatarFallback(avatar, name) { avatar.replaceChildren(); avatar.textContent = initials(name); }
async function renderProfileAvatar(avatar, avatarPath, name) {
  if (!avatarPath) return;
  const { data, error } = await supabaseClient.storage.from('profile-avatars').createSignedUrl(avatarPath, 3600);
  if (error || !data?.signedUrl) return;
  const image = document.createElement('img'); image.alt = '';
  image.onload = () => { if (avatar.isConnected) avatar.replaceChildren(image); };
  image.onerror = () => { if (avatar.isConnected) showAvatarFallback(avatar, name); };
  image.src = `${data.signedUrl}${data.signedUrl.includes('?') ? '&' : '?'}v=${Date.now()}`;
}
async function renderMyContact(expectedAccountId) {
  const { data: profile, error } = await supabaseClient.rpc('get_my_profile');
  if (error || !profile) return;
  const { data: currentAccount, error: currentAccountError } = await supabaseClient.rpc('get_current_account');
  if (currentAccountError || !currentAccount || currentAccount.account_id !== expectedAccountId) {
    window.location.reload();
    return;
  }
  const name = fullName(profile);
  myContactName.textContent = name;
  showAvatarFallback(myContactAvatar, name);
  myContact.hidden = false;
  await renderProfileAvatar(myContactAvatar, profile.avatar_path, name);
}
async function suggestContact(contact) {
  const recipientEmail = await FamilAreaConfirm.prompt({
    title: `Condividi ${fullName(contact)}`,
    message: 'Inserisci l’email della persona a cui vuoi suggerire questo contatto.',
    confirmText: 'Condividi',
    input: { label: 'Email destinatario', type: 'email', autocomplete: 'email', required: true }
  });
  if (!recipientEmail) return;
  const { error } = await supabaseClient.rpc('create_contact_suggestion', {
    p_contact_id: contact.id,
    p_recipient_email: recipientEmail.trim()
  });
  message.textContent = error
    ? 'Non è stato possibile inviare il suggerimento. Riprova.'
    : 'Suggerimento inviato.';
}
function contactRow(contact, isOrganization) {
  const name = fullName(contact); const row = document.createElement('article'); row.className = 'contact-card contact-directory-row';
  const nameField = document.createElement('div'); nameField.className = 'contact-directory-field contact-directory-name';
  const avatar = document.createElement('span'); avatar.className = 'contact-directory-avatar'; showAvatarFallback(avatar, name);
  const open = document.createElement('a'); open.className = 'contact-directory-open'; open.href = `contatto.html?contact_id=${encodeURIComponent(contact.id)}`;
  const heading = document.createElement('h2'); heading.textContent = name; open.append(avatar, heading); nameField.append(open);
  const actions = document.createElement('div'); actions.className = 'contact-directory-actions';
  const share = document.createElement('button'); share.type = 'button'; share.className = 'fa-button fa-button-primary fa-button-compact'; share.textContent = 'Condividi';
  share.addEventListener('click', () => { void suggestContact(contact); }); actions.append(share);
  const fields = [nameField, field('Email', contact.primary_email), field('Cellulare', contact.primary_phone)];
  if (!isOrganization) fields.push(field('Data di nascita', formatBirthDate(contact.birth_date)));
  row.append(...fields, actions); return { row, avatar, name, avatarPath: contact.profile_avatar_path };
}
async function load() {
  const { data: session } = await supabaseClient.auth.getSession(); if (!session.session) { location.href = 'login.html'; return; }
  const initialAccount = window.FamilAreaCurrentAccount
    ? await window.FamilAreaCurrentAccount
    : (await supabaseClient.rpc('get_current_account')).data;
  if (!initialAccount?.account_id) { message.textContent = 'Impossibile caricare i contatti.'; return; }
  const isOrganization = initialAccount.account_type === 'organization';
  contactsGrid.classList.toggle('fa-contacts-grid--organization', isOrganization);
  const { data, error } = await supabaseClient.rpc('get_my_contacts');
  if (error) { console.error('get_my_contacts failed', error); message.textContent = 'Impossibile caricare i contatti.'; return; }
  const { data: currentAccount, error: currentAccountError } = await supabaseClient.rpc('get_current_account');
  if (currentAccountError || !currentAccount || currentAccount.account_id !== initialAccount.account_id) {
    window.location.reload();
    return;
  }
  const contacts = (data || []).map((contact) => contactRow(contact, isOrganization)); list.replaceChildren(...contacts.map((contact) => contact.row));
  void Promise.all(contacts.map((contact) => renderProfileAvatar(contact.avatar, contact.avatarPath, contact.name)));
  if (isOrganization) myContact.hidden = true;
  else void renderMyContact(initialAccount.account_id);
  empty.hidden = contacts.length > 0; message.textContent = '';
}
load();

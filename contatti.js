const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const list = document.getElementById('contacts-list');
const empty = document.getElementById('empty-state');
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
function contactRow(contact) {
  const name = fullName(contact); const row = document.createElement('a'); row.className = 'contact-card contact-directory-row'; row.href = `contatto.html?contact_id=${encodeURIComponent(contact.id)}`;
  const nameField = document.createElement('div'); nameField.className = 'contact-directory-field contact-directory-name';
  const avatar = document.createElement('span'); avatar.className = 'contact-directory-avatar'; showAvatarFallback(avatar, name);
  const heading = document.createElement('h2'); heading.textContent = name; nameField.append(avatar, heading);
  row.append(nameField, field('Email', contact.primary_email), field('Cellulare', contact.primary_phone), field('Data di nascita', formatBirthDate(contact.birth_date))); return { row, avatar, name, avatarPath: contact.profile_avatar_path };
}
async function load() {
  const { data: session } = await supabaseClient.auth.getSession(); if (!session.session) { location.href = 'login.html'; return; }
  const { data, error } = await supabaseClient.rpc('get_my_contacts');
  if (error) { console.error('get_my_contacts failed', error); message.textContent = 'Impossibile caricare i contatti.'; return; }
  const contacts = (data || []).map(contactRow); list.replaceChildren(...contacts.map((contact) => contact.row));
  void Promise.all(contacts.map((contact) => renderProfileAvatar(contact.avatar, contact.avatarPath, contact.name)));
  empty.hidden = contacts.length > 0; message.textContent = '';
}
load();

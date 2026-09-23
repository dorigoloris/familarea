const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const list = document.getElementById('contacts-list');
const empty = document.getElementById('empty-state');
function fullName(contact) { return [contact.first_name, contact.last_name].filter(Boolean).join(' ') || 'Contatto'; }
function initials(name) { return name.trim().split(/\s+/).slice(0, 2).map((part) => part[0]).join('').toLocaleUpperCase('it-IT') || 'C'; }
function formatBirthDate(value) { return value ? new Intl.DateTimeFormat('it-IT', { dateStyle: 'medium' }).format(new Date(`${value}T00:00:00`)) : '—'; }
function field(label, value) { const element = document.createElement('div'); element.className = 'contact-directory-field'; element.dataset.label = label; element.textContent = value || '—'; return element; }
function contactRow(contact) {
  const name = fullName(contact); const row = document.createElement('a'); row.className = 'contact-card contact-directory-row'; row.href = `contatto.html?contact_id=${encodeURIComponent(contact.id)}`;
  const nameField = document.createElement('div'); nameField.className = 'contact-directory-field contact-directory-name';
  const avatar = document.createElement('span'); avatar.className = 'contact-directory-avatar'; avatar.textContent = initials(name);
  if (contact.avatar_path) { const image = document.createElement('img'); image.src = contact.avatar_path; image.alt = ''; avatar.replaceChildren(image); }
  const heading = document.createElement('h2'); heading.textContent = name; nameField.append(avatar, heading);
  row.append(nameField, field('Email', contact.primary_email), field('Cellulare', contact.primary_phone), field('Data di nascita', formatBirthDate(contact.birth_date))); return row;
}
async function load() {
  const { data: session } = await supabaseClient.auth.getSession(); if (!session.session) { location.href = 'login.html'; return; }
  const { data, error } = await supabaseClient.rpc('get_my_contacts');
  if (error) { console.error('get_my_contacts failed', error); message.textContent = 'Impossibile caricare i contatti.'; return; }
  list.replaceChildren(...(data || []).map(contactRow)); empty.hidden = (data || []).length > 0; message.textContent = '';
}
load();

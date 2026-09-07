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

function createContactCard(contact) {
  const article = document.createElement('article');
  article.className = 'contact-card';

  const name = document.createElement('h2');
  name.textContent = fullName(contact);
  article.appendChild(name);

  if (contact.birth_date) {
    const details = document.createElement('p');
    details.textContent = `Data di nascita: ${formatBirthDate(contact.birth_date)}`;
    article.appendChild(details);
  }

  const open = document.createElement('a');
  open.className = 'btn';
  open.textContent = 'Apri';
  open.href = `contatto.html?contact_id=${encodeURIComponent(contact.id)}`;
  article.appendChild(open);
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

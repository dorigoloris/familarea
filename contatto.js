const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const contactId = new URLSearchParams(location.search).get('contact_id');
const $ = (id) => document.getElementById(id);
let contact;
let methods = [];

function methodType(method) {
  return method.method_type || method.type || '';
}

function validEmailMethod() {
  const email = methods
    .filter((method) => methodType(method) === 'email')
    .map((method) => method.value?.trim() || '')
    .find((value) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value));
  return email || '';
}

function renderMethods() {
  [['email', 'email-list'], ['phone', 'phone-list']].forEach(([type, id]) => {
    const entries = methods
      .filter((method) => methodType(method) === type)
      .map((method) => {
        const item = document.createElement('li');
        item.textContent = method.value;
        return item;
      });
    $(id).replaceChildren(...entries);
  });
}

function renderInvitation(email) {
  const section = $('contact-invite-section');
  section.hidden = !email;
  if (!email) return;

  const invited = Boolean(contact.registration_invited_at);
  $('contact-invite-title').textContent = invited ? 'Invito inviato' : 'Invita in FamilArea';
  $('contact-invite-description').textContent = invited
    ? `Abbiamo inviato un'email a ${email} con l'invito ad iscriversi a FamilArea.`
    : `Invia un'email a ${email} con l'invito ad iscriversi a FamilArea.`;
  $('send-contact-invite-button').hidden = invited;
  $('send-contact-invite-button').disabled = invited;
  $('contact-invite-feedback').hidden = true;
  $('contact-invite-feedback').classList.remove('is-error');
}

function render() {
  const name = [contact.first_name, contact.last_name].filter(Boolean).join(' ') || 'Contatto';
  $('contact-name').textContent = name;
  $('contact-birth-date').textContent = contact.birth_date || '';
  $('contact-birth-date').hidden = !contact.birth_date;
  renderMethods();
  renderInvitation(validEmailMethod());
  $('contact-view').hidden = false;
  $('message').textContent = '';
}

async function load() {
  if (!contactId) {
    $('message').textContent = 'Contatto non specificato.';
    return;
  }

  const { data, error } = await supabaseClient.rpc('get_contact', { p_contact_id: contactId });
  if (error || !data) {
    $('message').textContent = 'Contatto non disponibile.';
    return;
  }

  contact = data.contact;
  methods = data.methods || [];
  render();
}

function openEdit() {
  $('edit-first-name').value = contact.first_name || '';
  $('edit-last-name').value = contact.last_name || '';
  $('edit-birth-date').value = contact.birth_date || '';
  $('edit-email').value = methods.find((method) => methodType(method) === 'email')?.value || '';
  $('edit-phone').value = methods.find((method) => methodType(method) === 'phone')?.value || '';
  $('contact-view').hidden = true;
  $('edit-form').hidden = false;
}

async function sendInvitation() {
  const button = $('send-contact-invite-button');
  const feedback = $('contact-invite-feedback');
  const email = validEmailMethod();
  if (!email) return;

  button.disabled = true;
  feedback.hidden = false;
  feedback.classList.remove('is-error');
  $('contact-invite-status').textContent = 'Invio in corso…';
  $('contact-invite-message').textContent = '';

  const { error } = await supabaseClient.functions.invoke('send-contact-registration-invite', {
    body: { contact_id: contactId }
  });

  if (error) {
    console.error(error);
    feedback.classList.add('is-error');
    $('contact-invite-status').textContent = 'Non è stato possibile inviare l’invito.';
    $('contact-invite-message').textContent = 'Riprova tra poco.';
    button.disabled = false;
    return;
  }

  contact.registration_invited_at = new Date().toISOString();
  renderInvitation(email);
}

$('edit-button').onclick = openEdit;
$('send-contact-invite-button').onclick = sendInvitation;
$('edit-cancel-button').onclick = () => {
  $('edit-form').hidden = true;
  $('contact-view').hidden = false;
};

$('edit-form').onsubmit = async (event) => {
  event.preventDefault();
  const payload = {
    p_contact_id: contactId,
    p_first_name: $('edit-first-name').value.trim(),
    p_last_name: $('edit-last-name').value.trim() || null,
    p_birth_date: $('edit-birth-date').value || null
  };
  const values = [
    ['email', $('edit-email').value.trim()],
    ['phone', $('edit-phone').value.trim()]
  ]
    .filter(([, value]) => value)
    .map(([type, value], index) => ({ type, value, is_primary: index === 0 }));

  const contactUpdate = await supabaseClient.rpc('update_contact', payload);
  if (contactUpdate.error) {
    $('message').textContent = 'Impossibile salvare il contatto.';
    return;
  }

  const methodsUpdate = await supabaseClient.rpc('replace_contact_methods', {
    p_contact_id: contactId,
    p_methods: values
  });
  if (methodsUpdate.error) {
    $('message').textContent = 'Dati salvati, ma metodi non aggiornati.';
    return;
  }

  $('edit-form').hidden = true;
  await load();
};

$('delete-button').onclick = async () => {
  const button = $('delete-button');
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: 'Eliminare il contatto?',
    message: 'Il contatto verrà rimosso dalla tua rubrica.',
    confirmText: 'Elimina'
  });
  if (!confirmed) return;

  button.disabled = true;
  const { error } = await supabaseClient.rpc('delete_contact', { p_contact_id: contactId });
  if (error) {
    $('message').textContent = 'Impossibile eliminare il contatto.';
    button.disabled = false;
    return;
  }

  location.href = 'contatti.html';
};

load();

const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const form = document.getElementById('contact-form');
const message = document.getElementById('message');
const saveButton = document.getElementById('save-button');
const partialSaveMessage = document.getElementById('partial-save-message');
const openContactLink = document.getElementById('open-contact-link');

async function requireSession() {
  const { data } = await supabaseClient.auth.getSession();
  if (!data.session) {
    window.location.href = 'login.html';
    return false;
  }
  return true;
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const firstName = document.getElementById('first-name').value.trim();
  if (!firstName) {
    message.textContent = 'Inserisci il nome del contatto.';
    return;
  }

  saveButton.disabled = true;
  message.textContent = 'Creazione contatto in corso...';
  partialSaveMessage.hidden = true;
  openContactLink.hidden = true;
  const { data, error } = await supabaseClient.rpc('create_my_contact', {
    p_first_name: firstName,
    p_last_name: document.getElementById('last-name').value.trim() || null,
    p_birth_date: document.getElementById('birth-date').value || null
  });

  if (error || !data) {
    message.textContent = 'Impossibile creare il contatto. Riprova.';
    saveButton.disabled = false;
    return;
  }

  const methods = [
    { type: 'email', value: document.getElementById('email').value.trim(), label: 'email' },
    { type: 'phone', value: document.getElementById('phone').value.trim(), label: 'cellulare' }
  ].filter((method) => method.value);
  const failedMethods = [];

  for (const method of methods) {
    const { error: methodError } = await supabaseClient.rpc('add_my_contact_method', {
      p_contact_id: data,
      p_type: method.type,
      p_value: method.value,
      p_is_primary: true
    });
    if (methodError) failedMethods.push(method.label);
  }

  if (failedMethods.length) {
    message.textContent = 'Il contatto è stato creato, ma alcuni recapiti non sono stati salvati.';
    partialSaveMessage.textContent = `Non è stato possibile salvare: ${failedMethods.join(', ')}. Puoi aggiungerli dalla scheda del contatto.`;
    partialSaveMessage.hidden = false;
    openContactLink.href = `contatto.html?contact_id=${encodeURIComponent(data)}`;
    openContactLink.hidden = false;
    return;
  }

  window.location.href = `contatto.html?contact_id=${encodeURIComponent(data)}`;
});

requireSession();

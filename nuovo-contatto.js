const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const form = document.getElementById('contact-form');
const message = document.getElementById('message');
const saveButton = document.getElementById('save-button');

function contactMethods(email, phone) {
  return [
    email ? { type: 'email', value: email, is_primary: true } : null,
    phone ? { type: 'phone', value: phone, is_primary: !email } : null
  ].filter(Boolean);
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const firstName = document.getElementById('first-name').value.trim();
  const lastName = document.getElementById('last-name').value.trim();
  const birthDate = document.getElementById('birth-date').value || null;
  const email = document.getElementById('email').value.trim();
  const phone = document.getElementById('phone').value.trim();

  if (!firstName) {
    message.textContent = 'Inserisci almeno il nome.';
    return;
  }

  saveButton.disabled = true;
  message.textContent = 'Salvataggio…';

  try {
    const { data: contactId, error: contactError } = await supabaseClient.rpc('create_contact', {
      p_first_name: firstName,
      p_last_name: lastName || null,
      p_birth_date: birthDate
    });
    if (contactError) throw contactError;

    const methods = contactMethods(email, phone);
    if (methods.length) {
      const { error: methodsError } = await supabaseClient.rpc('replace_contact_methods', {
        p_contact_id: contactId,
        p_methods: methods
      });
      if (methodsError) {
        message.textContent = 'Contatto creato, ma non è stato possibile salvare i recapiti.';
        return;
      }
    }

    location.href = `contatto.html?contact_id=${encodeURIComponent(contactId)}`;
  } catch (error) {
    console.error(error);
    message.textContent = 'Non è stato possibile salvare il contatto. Riprova.';
  } finally {
    saveButton.disabled = false;
  }
});

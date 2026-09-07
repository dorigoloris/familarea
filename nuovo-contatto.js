const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const form = document.getElementById('contact-form');
const message = document.getElementById('message');
const saveButton = document.getElementById('save-button');

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

  window.location.href = `contatto.html?contact_id=${encodeURIComponent(data)}`;
});

requireSession();

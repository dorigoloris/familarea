const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const form = document.getElementById('change-password-form');
const message = document.getElementById('password-message');
const passwordInput = document.getElementById('new-password');
const confirmationInput = document.getElementById('new-password-confirmation');
const saveButton = document.getElementById('change-password-button');

function showMessage(text, isError = false) {
  message.textContent = text;
  message.classList.toggle('is-error', isError);
  message.classList.toggle('is-success', Boolean(text) && !isError);
}

async function requireAuthenticatedUser() {
  const { data, error } = await supabaseClient.auth.getUser();
  if (error || !data?.user) {
    window.location.href = 'login.html';
    return;
  }
  form.hidden = false;
  passwordInput.focus();
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const password = passwordInput.value;
  const confirmation = confirmationInput.value;
  if (password.length < 8) {
    showMessage('La password deve contenere almeno 8 caratteri.', true);
    passwordInput.focus();
    return;
  }
  if (password !== confirmation) {
    showMessage('Le password non coincidono.', true);
    confirmationInput.focus();
    return;
  }

  saveButton.disabled = true;
  showMessage('Salvataggio in corso...');
  const { error } = await supabaseClient.auth.updateUser({ password });
  saveButton.disabled = false;
  if (error) {
    showMessage('Impossibile aggiornare la password. Riprova più tardi.', true);
    return;
  }
  form.reset();
  showMessage('Password aggiornata correttamente.');
});

requireAuthenticatedUser();

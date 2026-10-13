const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const form = document.getElementById('new-password-form');
const message = document.getElementById('message');
const passwordInput = document.getElementById('password');
const confirmationInput = document.getElementById('password-confirmation');
const submitButton = document.getElementById('new-password-submit');
const returnTo = window.FamilAreaAuthUtils.returnToFromLocation();
let recoverySessionReady = false;

document.getElementById('new-password-login-link').href = window.FamilAreaAuthUtils.loginUrl(returnTo);

function enableRecoveryForm() {
  recoverySessionReady = true;
  form.hidden = false;
  message.textContent = '';
  passwordInput.focus();
}

function recoveryUrlPresent() {
  return window.location.hash.includes('type=recovery') || new URLSearchParams(window.location.search).has('code');
}

supabaseClient.auth.onAuthStateChange((event, session) => {
  if (event === 'PASSWORD_RECOVERY' && session) enableRecoveryForm();
});

(async () => {
  const { data, error } = await supabaseClient.auth.getSession();
  if (!error && data.session && recoveryUrlPresent()) enableRecoveryForm();
  else if (!recoverySessionReady) message.textContent = 'Il link di recupero non è valido o è scaduto.';
})();

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (submitButton.disabled) return;
  if (!recoverySessionReady) {
    message.textContent = 'Il link di recupero non è valido o è scaduto.';
    return;
  }
  const password = passwordInput.value;
  const confirmation = confirmationInput.value;
  if (password.length < 8) {
    message.textContent = 'La password deve contenere almeno 8 caratteri.';
    passwordInput.focus();
    return;
  }
  if (password !== confirmation) {
    message.textContent = 'Le password non coincidono.';
    confirmationInput.focus();
    return;
  }
  submitButton.disabled = true;
  message.textContent = 'Salvataggio in corso...';
  const { error } = await supabaseClient.auth.updateUser({ password });
  if (error) {
    submitButton.disabled = false;
    message.textContent = 'Impossibile salvare la nuova password. Richiedi un nuovo link di recupero.';
    return;
  }
  form.reset();
  form.hidden = true;
  message.textContent = 'Password aggiornata correttamente. Verrai reindirizzato ad Accedi.';
  window.setTimeout(() => { window.location.replace(window.FamilAreaAuthUtils.loginUrl(returnTo)); }, 1800);
});

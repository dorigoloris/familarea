const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const form = document.getElementById('new-password-form');
const message = document.getElementById('message');
let recoverySessionReady = false;
function enableRecoveryForm() { recoverySessionReady = true; form.hidden = false; message.textContent = ''; }
function recoveryUrlPresent() { return window.location.hash.includes('type=recovery') || new URLSearchParams(window.location.search).has('code'); }
supabaseClient.auth.onAuthStateChange((event, session) => { if (event === 'PASSWORD_RECOVERY' && session) enableRecoveryForm(); });
(async () => {
  const { data } = await supabaseClient.auth.getSession();
  if (data.session && recoveryUrlPresent()) enableRecoveryForm();
  else if (!recoverySessionReady) message.textContent = 'Il link di recupero non \u00e8 valido o \u00e8 scaduto.';
})();
form.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!recoverySessionReady) { message.textContent = 'Il link di recupero non \u00e8 valido o \u00e8 scaduto.'; return; }
  const password = document.getElementById('password').value;
  const confirmation = document.getElementById('password-confirmation').value;
  if (password.length < 8) { message.textContent = 'La password deve contenere almeno 8 caratteri.'; return; }
  if (password !== confirmation) { message.textContent = 'Le password non coincidono.'; return; }
  message.textContent = 'Salvataggio in corso...';
  const { error } = await supabaseClient.auth.updateUser({ password });
  if (error) { message.textContent = 'Impossibile salvare la nuova password. Richiedi un nuovo link di recupero.'; return; }
  form.hidden = true;
  message.textContent = 'Password aggiornata correttamente. Verrai reindirizzato ad Accedi.';
  window.setTimeout(() => { window.location.href = 'login.html'; }, 1800);
});

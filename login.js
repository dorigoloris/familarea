const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const form = document.getElementById('login-form');
const message = document.getElementById('message');
const submitButton = document.getElementById('login-submit');
const googleSignInButton = document.getElementById('google-sign-in');
const returnTo = window.FamilAreaAuthUtils.returnToFromLocation();

document.getElementById('register-link').href = `registrati.html?return_to=${encodeURIComponent(returnTo)}`;
document.getElementById('forgot-password-link').href = `recupera-password.html?return_to=${encodeURIComponent(returnTo)}`;

function setBusy(isBusy, text = '') {
  submitButton.disabled = isBusy;
  googleSignInButton.disabled = isBusy;
  if (text) message.textContent = text;
}

(async () => {
  const { data, error } = await supabaseClient.auth.getSession();
  if (!error && data.session) window.location.replace(returnTo);
})().catch(() => {});

googleSignInButton.addEventListener('click', async () => {
  setBusy(true, 'Reindirizzamento a Google...');
  const redirectTo = new URL(window.FamilAreaAuthUtils.loginUrl(returnTo), window.location.origin).toString();
  const { error } = await supabaseClient.auth.signInWithOAuth({ provider: 'google', options: { redirectTo } });
  if (!error) return;
  setBusy(false, 'Non è stato possibile avviare l’accesso con Google. Riprova.');
});

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (submitButton.disabled) return;
  const email = document.getElementById('email').value.trim();
  const password = document.getElementById('password').value;
  setBusy(true, 'Accesso in corso...');
  const { error } = await supabaseClient.auth.signInWithPassword({ email, password });
  if (error) {
    setBusy(false, `Impossibile accedere: ${error.message}`);
    return;
  }
  window.location.replace(returnTo);
});

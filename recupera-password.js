const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const form = document.getElementById('recovery-form');
const message = document.getElementById('message');
const submitButton = document.getElementById('recovery-submit');
const returnTo = window.FamilAreaAuthUtils.returnToFromLocation();
const captcha = window.FamilAreaCaptcha.create(document.getElementById('recovery-captcha'), (state) => {
  if (state === 'expired') message.textContent = 'La verifica anti-bot è scaduta. Ripeti la verifica.';
  if (state === 'error') message.textContent = 'Impossibile completare la verifica anti-bot. Riprova.';
});

document.getElementById('back-to-login-link').href = window.FamilAreaAuthUtils.loginUrl(returnTo);

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (submitButton.disabled) return;
  const email = document.getElementById('email').value.trim();
  if (!email) {
    message.textContent = 'Inserisci un indirizzo email valido.';
    return;
  }
  const captchaError = captcha.validate();
  if (captchaError) {
    message.textContent = captchaError;
    return;
  }
  submitButton.disabled = true;
  message.textContent = 'Invio in corso...';
  const redirectTo = new URL(`nuova-password.html?return_to=${encodeURIComponent(returnTo)}`, window.location.origin).toString();
  const options = { redirectTo };
  if (captcha.enabled) options.captchaToken = captcha.getToken();
  const { error } = await supabaseClient.auth.resetPasswordForEmail(email, options);
  if (error) {
    captcha.reset();
    submitButton.disabled = false;
    message.textContent = 'Impossibile inviare il link di recupero. Riprova.';
    return;
  }
  message.textContent = 'Se l’indirizzo è associato a un account, riceverai un’email con le istruzioni per reimpostare la password.';
  form.reset();
});

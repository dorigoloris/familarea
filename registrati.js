const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const form = document.getElementById('signup-form');
const message = document.getElementById('message');
const submitButton = document.getElementById('signup-submit');
const googleSignInButton = document.getElementById('google-sign-in');
const googleSignInSection = document.getElementById('google-sign-in-section');
const accountTypeInputs = document.querySelectorAll('input[name="account-type"]');
const personalFields = document.getElementById('personal-signup-fields');
const organizationFields = document.getElementById('organization-signup-fields');
const firstNameInput = document.getElementById('first-name');
const lastNameInput = document.getElementById('last-name');
const organizationNameInput = document.getElementById('organization-name');
const organizationTypeInput = document.getElementById('organization-type');
const returnTo = window.FamilAreaAuthUtils.returnToFromLocation();
const captcha = window.FamilAreaCaptcha.create(document.getElementById('signup-captcha'), (state) => {
  if (state === 'expired') message.textContent = 'La verifica anti-bot è scaduta. Ripeti la verifica.';
  if (state === 'error') message.textContent = 'Impossibile completare la verifica anti-bot. Riprova.';
});

document.getElementById('login-link').href = window.FamilAreaAuthUtils.loginUrl(returnTo);

function selectedAccountType() {
  return document.querySelector('input[name="account-type"]:checked').value;
}

function setBusy(isBusy, text = '') {
  submitButton.disabled = isBusy;
  googleSignInButton.disabled = isBusy;
  accountTypeInputs.forEach((input) => { input.disabled = isBusy; });
  if (text) message.textContent = text;
}

function updateAccountTypeFields() {
  const personal = selectedAccountType() === 'personal';
  personalFields.hidden = !personal;
  organizationFields.hidden = personal;
  googleSignInSection.hidden = !personal;
  firstNameInput.required = personal;
  firstNameInput.disabled = !personal;
  lastNameInput.disabled = !personal;
  organizationNameInput.required = !personal;
  organizationNameInput.disabled = personal;
  organizationTypeInput.required = !personal;
  organizationTypeInput.disabled = personal;
}

accountTypeInputs.forEach((input) => input.addEventListener('change', updateAccountTypeFields));
updateAccountTypeFields();

(async () => {
  const { data, error } = await supabaseClient.auth.getSession();
  if (!error && data.session) window.location.replace(returnTo);
})().catch(() => {});

googleSignInButton.addEventListener('click', async () => {
  if (selectedAccountType() !== 'personal') return;
  setBusy(true, 'Reindirizzamento a Google...');
  const redirectTo = new URL(window.FamilAreaAuthUtils.loginUrl(returnTo), window.location.origin).toString();
  const { error } = await supabaseClient.auth.signInWithOAuth({ provider: 'google', options: { redirectTo } });
  if (!error) return;
  setBusy(false, 'Non è stato possibile avviare l’accesso con Google. Riprova.');
});

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (submitButton.disabled) return;
  const accountType = selectedAccountType();
  const email = document.getElementById('email').value.trim();
  const password = document.getElementById('password').value;
  const metadata = accountType === 'personal'
    ? { account_type: 'personal', first_name: firstNameInput.value.trim(), last_name: lastNameInput.value.trim() }
    : { account_type: 'organization', organization_name: organizationNameInput.value.trim(), organization_type: organizationTypeInput.value };

  if (password.length < 8) {
    message.textContent = 'La password deve contenere almeno 8 caratteri.';
    return;
  }
  if (accountType === 'organization' && (!metadata.organization_name || !metadata.organization_type)) {
    message.textContent = 'Inserisci nome e tipo dell’organizzazione.';
    return;
  }

  const captchaError = captcha.validate();
  if (captchaError) {
    message.textContent = captchaError;
    return;
  }

  setBusy(true, 'Registrazione in corso...');
  const redirectTo = new URL(window.FamilAreaAuthUtils.loginUrl(returnTo), window.location.origin).toString();
  const options = { data: metadata, emailRedirectTo: redirectTo };
  if (captcha.enabled) options.captchaToken = captcha.getToken();
  const { data, error } = await supabaseClient.auth.signUp({ email, password, options });
  if (error) {
    captcha.reset();
    setBusy(false, `Impossibile completare la registrazione: ${error.message}`);
    return;
  }
  if (data.session) {
    window.location.replace(returnTo);
    return;
  }
  message.textContent = 'Registrazione completata. Controlla la tua email per confermare l’account.';
  form.reset();
  setBusy(true);
});

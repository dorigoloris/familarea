const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const form = document.getElementById('signup-form');
const message = document.getElementById('message');
const googleSignInButton = document.getElementById('google-sign-in');
const googleSignInSection = document.getElementById('google-sign-in-section');
const accountTypeInputs = document.querySelectorAll('input[name="account-type"]');
const personalFields = document.getElementById('personal-signup-fields');
const organizationFields = document.getElementById('organization-signup-fields');
const firstNameInput = document.getElementById('first-name');
const lastNameInput = document.getElementById('last-name');
const organizationNameInput = document.getElementById('organization-name');
const organizationTypeInput = document.getElementById('organization-type');

function selectedAccountType() {
  return document.querySelector('input[name="account-type"]:checked').value;
}

function updateAccountTypeFields() {
  const isPersonal = selectedAccountType() === 'personal';

  personalFields.hidden = !isPersonal;
  organizationFields.hidden = isPersonal;
  googleSignInSection.hidden = !isPersonal;

  firstNameInput.required = isPersonal;
  firstNameInput.disabled = !isPersonal;
  lastNameInput.disabled = !isPersonal;
  organizationNameInput.required = !isPersonal;
  organizationNameInput.disabled = isPersonal;
  organizationTypeInput.required = !isPersonal;
  organizationTypeInput.disabled = isPersonal;
}

accountTypeInputs.forEach((input) => input.addEventListener('change', updateAccountTypeFields));
updateAccountTypeFields();

googleSignInButton.addEventListener('click', async () => {
  if (selectedAccountType() !== 'personal') {
    return;
  }

  googleSignInButton.disabled = true;
  message.textContent = 'Reindirizzamento a Google...';

  const { error } = await supabaseClient.auth.signInWithOAuth({
    provider: 'google',
    options: {
      redirectTo: new URL('dashboard.html', window.location.origin).toString()
    }
  });

  if (error) {
    message.textContent = 'Non è stato possibile avviare l’accesso con Google. Riprova.';
    googleSignInButton.disabled = false;
  }
});

form.addEventListener('submit', async (event) => {
  event.preventDefault();

  const accountType = selectedAccountType();
  const firstName = firstNameInput.value.trim();
  const lastName = lastNameInput.value.trim();
  const organizationName = organizationNameInput.value.trim();
  const organizationType = organizationTypeInput.value;
  const email = document.getElementById('email').value.trim();
  const password = document.getElementById('password').value;

  if (accountType === 'organization' && (!organizationName || !organizationType)) {
    message.textContent = 'Inserisci nome e tipo dell\'organizzazione.';
    return;
  }

  message.textContent = 'Registrazione in corso...';

  const metadata = accountType === 'personal'
    ? {
        account_type: 'personal',
        first_name: firstName,
        last_name: lastName
      }
    : {
        account_type: 'organization',
        organization_name: organizationName,
        organization_type: organizationType
      };

  const { error } = await supabaseClient.auth.signUp({
    email,
    password,
    options: {
      data: {
        ...metadata
      }
    }
  });

  if (error) {
    message.textContent = `Errore: ${error.message}`;
    return;
  }

  message.textContent =
    'Registrazione completata. Controlla la tua email se è richiesta la conferma.';
});

const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const form = document.getElementById('login-form');
const message = document.getElementById('message');
const googleSignInButton = document.getElementById('google-sign-in');

googleSignInButton.addEventListener('click', async () => {
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

  const email = document.getElementById('email').value.trim();
  const password = document.getElementById('password').value;

  message.textContent = 'Accesso in corso...';

  const { data, error } = await supabaseClient.auth.signInWithPassword({
    email,
    password
  });

  if (error) {
    message.textContent = `Errore: ${error.message}`;
    return;
  }

  message.textContent = 'Accesso effettuato correttamente.';

  window.location.href = 'dashboard.html';
});

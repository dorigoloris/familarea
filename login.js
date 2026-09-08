const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const form = document.getElementById('login-form');
const message = document.getElementById('message');

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

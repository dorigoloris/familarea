const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const form = document.getElementById('recovery-form');
const message = document.getElementById('message');
form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const email = document.getElementById('email').value.trim();
  if (!email || !email.includes('@')) { message.textContent = 'Inserisci un indirizzo email valido.'; return; }
  message.textContent = 'Invio in corso...';
  await supabaseClient.auth.resetPasswordForEmail(email, { redirectTo: 'https://familarea.com/nuova-password.html' });
  message.textContent = "Se l'indirizzo \u00e8 associato a un account, riceverai un'email con le istruzioni per reimpostare la password.";
  form.reset();
});

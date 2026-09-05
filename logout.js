(() => {
  const button = document.querySelector('[data-logout]');
  const message = document.getElementById('logout-message');
  if (!button || !message) return;

  button.addEventListener('click', async () => {
    button.disabled = true;
    message.textContent = 'Uscita in corso...';
    const client = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
    const { error } = await client.auth.signOut();
    if (error) {
      message.textContent = 'Non è stato possibile uscire. Riprova.';
      button.disabled = false;
      return;
    }
    window.location.href = 'index.html';
  });
})();

(() => {
  const loginUrl = `login.html?return_to=${encodeURIComponent('impostazioni.html')}`;

  async function redirect() {
    if (!window.supabase || !window.SUPABASE_URL || !window.SUPABASE_KEY) {
      window.location.replace(loginUrl);
      return;
    }
    const client = window.supabase.createClient(window.SUPABASE_URL, window.SUPABASE_KEY);
    const { data, error } = await client.auth.getSession();
    window.location.replace(!error && data.session ? 'impostazioni.html' : loginUrl);
  }

  redirect().catch(() => window.location.replace(loginUrl));
})();

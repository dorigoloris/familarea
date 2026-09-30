const homeClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

async function initialiseHome() {
  if (!await window.FamilAreaDeadlineManagementReady) return;
  const message = document.getElementById('home-message');
  const { data, error } = await homeClient.rpc('ensure_my_home_item');
  if (error || !data?.id) {
    message.textContent = 'Impossibile preparare Casa.';
    message.classList.add('is-error');
    document.getElementById('home-redirect-content').hidden = false;
    return;
  }
  location.replace(`gestione-scadenza-item.html?item_id=${encodeURIComponent(data.id)}`);
}

void initialiseHome();

const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const form = document.getElementById('area-form');
const message = document.getElementById('message');
const areaType = document.getElementById('area-type');

async function configureAreaTypes() {
  const { data: account, error } = await supabaseClient.rpc('get_current_account');
  if (error) {
    console.error('get_current_account failed while configuring area types', error);
    return;
  }
  if (account?.account_type !== 'organization') return;
  areaType.querySelector('option[value="family"]')?.remove();
  if (areaType.value === 'family') areaType.value = areaType.options[0]?.value || '';
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }
  const areaName = document.getElementById('area-name').value.trim();
  message.textContent = 'Creazione Area in corso...';
  const { data, error } = await supabaseClient.rpc('create_area', { p_name: areaName, p_area_type: areaType.value });
  if (error) { message.textContent = `Errore: ${error.message}`; return; }
  message.textContent = 'Area creata correttamente.';
  window.location.href = `area.html?area_id=${encodeURIComponent(data)}`;
});

configureAreaTypes();

const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const form = document.getElementById('area-form');
const message = document.getElementById('message');

form.addEventListener('submit', async (event) => {
  event.preventDefault();

  const { data: sessionData } = await supabaseClient.auth.getSession();

  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }

  const areaName = document.getElementById('area-name').value.trim();
  const areaType = document.getElementById('area-type').value;

  message.textContent = 'Creazione Area in corso...';

  const { data, error } = await supabaseClient.rpc('create_area', {
    p_name: areaName,
    p_area_type: areaType
  });

  if (error) {
    message.textContent = `Errore: ${error.message}`;
    return;
  }

  message.textContent = 'Area creata correttamente.';

  window.location.href = `area.html?area_id=${encodeURIComponent(data)}`;
});
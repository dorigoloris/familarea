const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

const form = document.getElementById('member-form');
const message = document.getElementById('message');

form.addEventListener('submit', async (event) => {
  event.preventDefault();

  const { data: sessionData } = await supabaseClient.auth.getSession();

  if (!sessionData.session) {
    window.location.href = 'login.html';
    return;
  }

  const params = new URLSearchParams(window.location.search);
  const areaId = params.get('area_id');

  if (!areaId) {
    message.textContent = 'Area non specificata.';
    return;
  }

  const firstName = document.getElementById('first-name').value.trim();
  const lastName = document.getElementById('last-name').value.trim();
  const birthDate = document.getElementById('birth-date').value || null;
  const role = document.getElementById('role').value;

  message.textContent = 'Aggiunta membro in corso...';

  const { data, error } = await supabaseClient.rpc('add_area_member', {
    p_area_id: areaId,
    p_first_name: firstName,
    p_last_name: lastName,
    p_birth_date: birthDate,
    p_role: role
  });

  if (error) {
    message.textContent = `Errore: ${error.message}`;
    return;
  }

  message.textContent = 'Membro aggiunto correttamente.';
  form.reset();

  window.location.href = `area.html?area_id=${encodeURIComponent(areaId)}`;
});
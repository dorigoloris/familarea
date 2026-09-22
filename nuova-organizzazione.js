const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const form = document.getElementById('organization-form');
const message = document.getElementById('organization-message');
const submit = document.getElementById('organization-submit');

async function requireSession() {
  const { data } = await supabaseClient.auth.getSession();
  if (!data.session) { location.href = 'login.html'; return false; }
  return true;
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!(await requireSession())) return;
  const name = document.getElementById('organization-name').value.trim();
  const type = document.getElementById('organization-type').value;
  const description = document.getElementById('organization-description').value.trim();
  if (!name) { message.textContent = 'Il nome è obbligatorio.'; message.classList.add('is-error'); return; }
  submit.disabled = true;
  message.classList.remove('is-error');
  message.textContent = 'Creazione in corso...';
  const { data, error } = await supabaseClient.rpc('create_organization', { p_name: name, p_organization_type: type, p_description: description || null });
  if (error || !data) { message.textContent = 'Impossibile creare l’Organizzazione. Verifica i dati e riprova.'; message.classList.add('is-error'); submit.disabled = false; return; }
  location.href = `organizzazione.html?organization_id=${encodeURIComponent(data)}`;
});

requireSession();

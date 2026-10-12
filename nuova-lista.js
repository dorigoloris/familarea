const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const form = document.getElementById('list-form');
const message = document.getElementById('message');
const backLink = document.querySelector('.account-back-link > a');
const listDraft = FamilAreaUnsavedChanges.register({
  root: form,
  getState: () => ({ title: document.getElementById('title').value, description: document.getElementById('description').value }),
  isActive: () => !form.hidden
});

async function load() {
  const { data: s } = await supabaseClient.auth.getSession();
  if (!s.session) {
    location.href = 'login.html';
    return;
  }
  backLink.href = 'liste.html';
  document.querySelector('#list-form .form-actions > a').href = backLink.href;
  form.hidden = false;
  FamilAreaUnsavedChanges.capture(listDraft);
  message.textContent = '';
}

form.onsubmit = async (event) => {
  event.preventDefault();
  const { data, error } = await supabaseClient.rpc('create_list', {
    p_title: document.getElementById('title').value.trim(),
    p_description: document.getElementById('description').value.trim() || null,
    p_area_id: null
  });
  if (error || !data) {
    message.textContent = 'Impossibile creare la lista.';
    return;
  }
  FamilAreaUnsavedChanges.markSaved(listDraft);
  location.href = `lista.html?list_id=${encodeURIComponent(data)}`;
};

load();

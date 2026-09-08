const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const message = document.getElementById('message');
const form = document.getElementById('area-form');
const save = document.getElementById('save-button');
const deleteSection = document.getElementById('delete-area-section');
const deleteDialog = document.getElementById('delete-area-dialog');
const deleteForm = document.getElementById('delete-area-form');
const deleteInput = document.getElementById('delete-area-confirmation');
const deleteConfirm = document.getElementById('confirm-delete-area');
const deleteMessage = document.getElementById('delete-area-message');
let areaId;
let areaName = '';

function back() {
  location.href = `area.html?area_id=${encodeURIComponent(areaId)}`;
}

function closeDeleteDialog() {
  deleteDialog.close();
}

function updateDeleteConfirmationState() {
  deleteConfirm.disabled = deleteInput.value !== areaName;
}

async function load() {
  const { data: sessionData } = await supabaseClient.auth.getSession();
  if (!sessionData.session) {
    location.href = 'login.html';
    return;
  }

  areaId = new URLSearchParams(location.search).get('area_id');
  if (!areaId) {
    message.textContent = 'Area non specificata.';
    return;
  }
  document.getElementById('back-link').href = `area.html?area_id=${encodeURIComponent(areaId)}`;

  const { data: me, error: profileError } = await supabaseClient
    .from('profiles').select('id').eq('user_id', sessionData.session.user.id).single();
  if (profileError || !me) {
    message.textContent = 'Impossibile verificare le autorizzazioni.';
    return;
  }

  const { data: members, error: membersError } = await supabaseClient
    .from('area_memberships').select('profile_id,role').eq('area_id', areaId);
  const currentMembership = members?.find((member) => member.profile_id === me.id);
  if (membersError || currentMembership?.role !== 'admin') {
    message.textContent = 'Non sei autorizzato a modificare questa Area.';
    return;
  }

  const { data: area, error } = await supabaseClient
    .from('areas').select('name,area_type').eq('id', areaId).single();
  if (error || !area) {
    message.textContent = 'Impossibile caricare i dati dell’Area.';
    return;
  }

  areaName = area.name;
  document.getElementById('area-name').value = area.name;
  document.getElementById('area-type').value = area.area_type;
  document.getElementById('delete-area-name').textContent = area.name;
  document.getElementById('delete-area-confirmation-name').textContent = area.name;
  form.hidden = false;
  deleteSection.hidden = false;
  message.textContent = '';
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const name = document.getElementById('area-name').value.trim();
  const type = document.getElementById('area-type').value;
  if (!name) {
    message.textContent = "Il nome dell'Area è obbligatorio.";
    return;
  }

  save.disabled = true;
  message.textContent = 'Salvataggio in corso...';
  const { error } = await supabaseClient.rpc('update_area', {
    p_area_id: areaId,
    p_name: name,
    p_area_type: type
  });
  if (error) {
    message.textContent = 'Impossibile salvare le modifiche. Verifica i dati e riprova.';
    save.disabled = false;
    return;
  }
  back();
});

document.getElementById('cancel-button').addEventListener('click', back);
document.getElementById('open-delete-area-dialog').addEventListener('click', () => {
  deleteInput.value = '';
  deleteMessage.textContent = '';
  updateDeleteConfirmationState();
  deleteDialog.showModal();
  deleteInput.focus();
});
document.getElementById('close-delete-area-dialog').addEventListener('click', closeDeleteDialog);
document.getElementById('cancel-delete-area').addEventListener('click', closeDeleteDialog);
deleteInput.addEventListener('input', updateDeleteConfirmationState);

deleteForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (deleteInput.value !== areaName) {
    updateDeleteConfirmationState();
    return;
  }

  deleteConfirm.disabled = true;
  deleteMessage.textContent = 'Eliminazione in corso...';
  const { error } = await supabaseClient.rpc('delete_area', { p_area_id: areaId });
  if (error) {
    deleteMessage.textContent = 'Impossibile eliminare l’Area. Verifica le autorizzazioni e riprova.';
    updateDeleteConfirmationState();
    return;
  }
  location.href = 'mie-aree.html';
});

load();

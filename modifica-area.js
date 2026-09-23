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
const areaImagePreview = document.getElementById('area-image-preview');
const areaImage = document.getElementById('area-image');
const areaImageInput = document.getElementById('area-image-file-input');
const areaImageUpload = document.getElementById('area-image-upload-label');
const areaImageRemove = document.getElementById('area-image-remove-button');
const areaImageMessage = document.getElementById('area-image-message');
const allowedImageTypes = new Set(['image/jpeg', 'image/png', 'image/webp']);
const areaImageBucket = 'area-images';
const maxAreaImageSize = 5 * 1024 * 1024;

let areaId;
let areaName = '';
let areaDescription = null;
let areaImagePath = null;
let canDelete = false;

function back() { location.href = `area.html?area_id=${encodeURIComponent(areaId)}`; }
function closeDeleteDialog() { deleteDialog.close(); }
function updateDeleteConfirmationState() { deleteConfirm.disabled = deleteInput.value !== areaName; }
function showAreaImageMessage(text, isError = false) {
  areaImageMessage.textContent = text;
  areaImageMessage.classList.toggle('is-error', isError);
  areaImageMessage.classList.toggle('is-success', Boolean(text) && !isError);
}
function setAreaImageBusy(busy, label) {
  areaImageInput.disabled = busy;
  areaImageUpload.classList.toggle('is-disabled', busy);
  areaImageRemove.disabled = busy;
  if (label) areaImageUpload.textContent = label;
}
function renderAreaImageFallback() {
  areaImagePreview.hidden = true;
  areaImage.removeAttribute('src');
  areaImageUpload.textContent = areaImagePath ? 'Cambia immagine' : 'Carica immagine';
  areaImageRemove.hidden = !areaImagePath;
}
async function renderAreaImage() {
  if (!areaImagePath) { renderAreaImageFallback(); return; }
  const { data, error } = await supabaseClient.storage.from(areaImageBucket).createSignedUrl(areaImagePath, 3600);
  if (error || !data?.signedUrl) { renderAreaImageFallback(); return; }
  areaImage.src = `${data.signedUrl}${data.signedUrl.includes('?') ? '&' : '?'}v=${Date.now()}`;
  areaImage.alt = `Immagine dell'Area ${areaName}`;
  areaImagePreview.hidden = false;
  areaImageUpload.textContent = 'Cambia immagine';
  areaImageRemove.hidden = false;
}
async function uploadAreaImage() {
  const file = areaImageInput.files?.[0];
  areaImageInput.value = '';
  if (!file) return;
  if (!allowedImageTypes.has(file.type)) { showAreaImageMessage('Scegli un’immagine JPG, PNG o WebP.', true); return; }
  if (file.size > maxAreaImageSize) { showAreaImageMessage('L’immagine deve pesare al massimo 5 MB.', true); return; }
  const path = `${areaId}/cover`;
  setAreaImageBusy(true, 'Caricamento...');
  showAreaImageMessage('Caricamento immagine in corso...');
  const { error: uploadError } = await supabaseClient.storage.from(areaImageBucket).upload(path, file, { upsert: true, contentType: file.type });
  if (uploadError) {
    console.error('area image upload failed', uploadError);
    setAreaImageBusy(false);
    await renderAreaImage();
    showAreaImageMessage('Impossibile caricare l’immagine. Riprova.', true);
    return;
  }
  const { data, error } = await supabaseClient.rpc('update_area_image', { p_area_id: areaId, p_image_path: path });
  setAreaImageBusy(false);
  if (error || !data) {
    console.error('update_area_image failed', error);
    await renderAreaImage();
    showAreaImageMessage('Immagine caricata, ma non è stato possibile associarla all’Area.', true);
    return;
  }
  areaImagePath = data.image_path || path;
  await renderAreaImage();
  showAreaImageMessage('Immagine Area aggiornata.');
}
async function removeAreaImage() {
  const confirmed = await FamilAreaConfirm.confirm({ variant: 'standard', title: 'Rimuovere l’immagine dell’Area?', message: 'L’Area tornerà al suo aspetto FamilArea senza immagine di copertina.', confirmText: 'Rimuovi immagine' });
  if (!confirmed) return;
  const path = areaImagePath;
  setAreaImageBusy(true, 'Rimozione...');
  showAreaImageMessage('Rimozione immagine in corso...');
  if (path) {
    const { error: removeError } = await supabaseClient.storage.from(areaImageBucket).remove([path]);
    if (removeError) {
      console.error('area image removal failed', removeError);
      setAreaImageBusy(false);
      showAreaImageMessage('Impossibile rimuovere l’immagine. Riprova.', true);
      return;
    }
  }
  const { data, error } = await supabaseClient.rpc('update_area_image', { p_area_id: areaId, p_image_path: null });
  setAreaImageBusy(false);
  if (error || !data) {
    console.error('update_area_image failed', error);
    showAreaImageMessage('Immagine rimossa, ma non è stato possibile aggiornare l’Area.', true);
    return;
  }
  areaImagePath = null;
  await renderAreaImage();
  showAreaImageMessage('Immagine Area rimossa.');
}
async function load() {
  const { data: session } = await supabaseClient.auth.getSession();
  if (!session.session) { location.href = 'login.html'; return; }
  areaId = new URLSearchParams(location.search).get('area_id');
  if (!areaId) { message.textContent = 'Area non specificata.'; return; }
  document.getElementById('back-link').href = `area.html?area_id=${encodeURIComponent(areaId)}`;
  const [{ data: area, error }, { data: areas, error: rolesError }] = await Promise.all([
    supabaseClient.rpc('get_area', { p_area_id: areaId }),
    supabaseClient.rpc('get_my_areas')
  ]);
  const role = (areas || []).find((item) => item.id === areaId)?.role;
  if (error || rolesError || !area || !['owner', 'admin'].includes(role)) { message.textContent = 'Non sei autorizzato a modificare questa Area.'; return; }
  areaName = area.name;
  areaDescription = area.description || null;
  areaImagePath = area.image_path || null;
  canDelete = role === 'owner';
  document.getElementById('area-name').value = area.name;
  document.getElementById('area-type').value = area.area_type;
  document.getElementById('delete-area-name').textContent = area.name;
  document.getElementById('delete-area-confirmation-name').textContent = area.name;
  form.hidden = false;
  deleteSection.hidden = !canDelete;
  message.textContent = '';
  await renderAreaImage();
}
form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const name = document.getElementById('area-name').value.trim();
  const type = document.getElementById('area-type').value;
  if (!name) { message.textContent = "Il nome dell'Area è obbligatorio."; return; }
  save.disabled = true;
  message.textContent = 'Salvataggio in corso…';
  const { error } = await supabaseClient.rpc('update_area', { p_area_id: areaId, p_name: name, p_area_type: type, p_description: areaDescription });
  if (error) { message.textContent = 'Impossibile salvare le modifiche.'; save.disabled = false; return; }
  back();
});
document.getElementById('cancel-button').addEventListener('click', back);
areaImageInput.addEventListener('change', () => void uploadAreaImage());
areaImageRemove.addEventListener('click', () => void removeAreaImage());
document.getElementById('open-delete-area-dialog').addEventListener('click', () => {
  if (!canDelete) return;
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
  if (!canDelete || deleteInput.value !== areaName) return;
  deleteConfirm.disabled = true;
  deleteMessage.textContent = 'Eliminazione in corso…';
  const { error } = await supabaseClient.rpc('delete_area', { p_area_id: areaId });
  if (error) { deleteMessage.textContent = 'Impossibile eliminare l’Area.'; updateDeleteConfirmationState(); return; }
  location.href = 'mie-aree.html';
});
load();

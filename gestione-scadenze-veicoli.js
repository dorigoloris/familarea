const vehiclesClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const vehiclesMessage = document.getElementById('vehicles-message');
const vehiclesList = document.getElementById('vehicles-list');
const vehiclesEmpty = document.getElementById('vehicles-empty');
const vehicleForm = document.getElementById('vehicle-form');
const vehicleFormTitle = document.getElementById('vehicle-form-title');
const vehicleName = document.getElementById('vehicle-name');
const vehicleType = document.getElementById('vehicle-type');
const vehiclePlate = document.getElementById('vehicle-plate');
const vehicleImageInput = document.getElementById('vehicle-image-input');
const vehicleImagePreview = document.getElementById('vehicle-image-preview');
const vehicleImageUpload = document.getElementById('vehicle-image-upload');
const vehicleImageRemove = document.getElementById('vehicle-image-remove');
const vehicleImageMessage = document.getElementById('vehicle-image-message');
const vehicleImageService = window.FamilAreaDeadlineItemImage;
let editingVehicle = null;
let pendingImageFile = null;
let imageRemovalRequested = false;
let previewObjectUrl = '';

const vehicleTypeLabels = { car: 'Auto', motorcycle: 'Moto', other: 'Altro' };

function setMessage(text = '', isError = false) { vehiclesMessage.textContent = text; vehiclesMessage.classList.toggle('is-error', isError); }
function setImageMessage(text = '', isError = false) { vehicleImageMessage.textContent = text; vehicleImageMessage.hidden = !text; vehicleImageMessage.classList.toggle('is-error', isError); }
function vehicleInitial() { return (vehicleName.value.trim().charAt(0) || 'V').toLocaleUpperCase('it-IT'); }
function clearPreviewObjectUrl() { if (previewObjectUrl) URL.revokeObjectURL(previewObjectUrl); previewObjectUrl = ''; }
function renderImageFallback() { clearPreviewObjectUrl(); vehicleImagePreview.replaceChildren(); vehicleImagePreview.textContent = vehicleInitial(); }
function renderImageUrl(url, isObjectUrl = false) { if (!isObjectUrl) clearPreviewObjectUrl(); vehicleImagePreview.replaceChildren(); const image = document.createElement('img'); image.alt = ''; image.src = url; image.onerror = renderImageFallback; vehicleImagePreview.append(image); }
async function renderVehicleImage() {
  const imagePath = editingVehicle?.image_path;
  vehicleImageUpload.textContent = imagePath || pendingImageFile ? 'Sostituisci foto' : 'Carica foto';
  vehicleImageRemove.hidden = !imagePath && !pendingImageFile;
  if (pendingImageFile) { clearPreviewObjectUrl(); previewObjectUrl = URL.createObjectURL(pendingImageFile); renderImageUrl(previewObjectUrl, true); return; }
  renderImageFallback();
  if (!imagePath) return;
  const vehicleId = editingVehicle?.id;
  const url = await vehicleImageService.resolve(imagePath);
  if (vehicleId !== editingVehicle?.id || pendingImageFile || !url) return;
  renderImageUrl(url);
}
function resetImageState() { pendingImageFile = null; imageRemovalRequested = false; vehicleImageInput.value = ''; setImageMessage(''); renderImageFallback(); vehicleImageRemove.hidden = true; vehicleImageUpload.textContent = 'Carica foto'; }
function resetForm() { editingVehicle = null; vehicleForm.reset(); vehicleType.value = 'car'; vehicleFormTitle.textContent = 'Nuovo veicolo'; resetImageState(); vehicleForm.hidden = true; }
function openForm(vehicle = null) { editingVehicle = vehicle; pendingImageFile = null; imageRemovalRequested = false; vehicleFormTitle.textContent = vehicle ? 'Modifica veicolo' : 'Nuovo veicolo'; vehicleName.value = vehicle?.name || ''; vehicleType.value = vehicle?.item_type || 'car'; vehiclePlate.value = vehicle?.plate || ''; setImageMessage(''); void renderVehicleImage(); vehicleForm.hidden = false; vehicleName.focus(); }
async function saveVehicleImage(vehicle, previousImagePath) {
  if (imageRemovalRequested && previousImagePath) {
    const { error: removeError } = await vehiclesClient.storage.from(vehicleImageService.bucket).remove([previousImagePath]);
    if (removeError) throw new Error('Impossibile rimuovere la foto precedente.');
    const { error } = await vehiclesClient.rpc('set_my_deadline_item_image', { p_item_id: vehicle.id, p_image_path: null });
    if (error) throw error;
  }
  if (!pendingImageFile) return;
  if (!vehicle.owner_account_id) throw new Error('Impossibile verificare il proprietario del veicolo.');
  const path = vehicleImageService.storagePath(vehicle.owner_account_id, vehicle.id);
  const { error: uploadError } = await vehiclesClient.storage.from(vehicleImageService.bucket).upload(path, pendingImageFile, { upsert: true, contentType: pendingImageFile.type });
  if (uploadError) {
    console.error('vehicle image upload failed', { path, file: { type: pendingImageFile.type, size: pendingImageFile.size }, error: uploadError, message: uploadError.message, statusCode: uploadError.statusCode });
    throw uploadError;
  }
  const { error } = await vehiclesClient.rpc('set_my_deadline_item_image', { p_item_id: vehicle.id, p_image_path: path });
  if (error) throw error;
}
async function removeVehicle(vehicle) {
  const confirmed = await FamilAreaConfirm.confirm({ variant: 'danger', title: `Eliminare ${vehicle.name}?`, message: 'Il veicolo e le relative immagini verranno eliminati.', confirmText: 'Elimina' });
  if (!confirmed) return;
  if (vehicle.image_path) {
    const { error: clearError } = await vehiclesClient.rpc('set_my_deadline_item_image', { p_item_id: vehicle.id, p_image_path: null });
    if (clearError) { setMessage('Impossibile preparare la rimozione della foto del veicolo.', true); return; }
    const { error: imageError } = await vehiclesClient.storage.from(vehicleImageService.bucket).remove([vehicle.image_path]);
    if (imageError) { setMessage('Impossibile eliminare la foto del veicolo.', true); return; }
  }
  const { error } = await vehiclesClient.rpc('delete_my_deadline_item', { p_item_id: vehicle.id });
  if (error) { setMessage('Impossibile eliminare il veicolo.', true); return; }
  setMessage('Veicolo eliminato.'); await loadVehicles();
}
function vehicleRow(vehicle) {
  const row = document.createElement('article'); row.className = 'deadline-management-row deadline-management-row--vehicle deadline-management-row--clickable fa-surface'; row.tabIndex = 0; row.setAttribute('role', 'group'); row.setAttribute('aria-label', `Apri veicolo ${vehicle.name}`);
  const openVehicle = () => { location.href = `gestione-scadenza-item.html?item_id=${encodeURIComponent(vehicle.id)}`; };
  row.addEventListener('click', openVehicle); row.addEventListener('keydown', (event) => { if (event.key !== 'Enter' && event.key !== ' ') return; event.preventDefault(); openVehicle(); });
  const image = document.createElement('span'); image.className = 'deadline-management-item-image deadline-management-item-image--list'; image.setAttribute('aria-label', `Foto di ${vehicle.name}`); image.textContent = (vehicle.name.trim().charAt(0) || 'V').toLocaleUpperCase('it-IT');
  if (vehicle.image_path) void vehicleImageService.render(image, vehicle.image_path, `Foto di ${vehicle.name}`);
  const type = document.createElement('p'); type.className = 'deadline-management-vehicle-type'; type.textContent = vehicleTypeLabels[vehicle.item_type] || 'Altro';
  const title = document.createElement('h2'); title.className = 'deadline-management-vehicle-title'; title.textContent = vehicle.name;
  const plate = document.createElement('span'); plate.className = 'deadline-management-vehicle-plate'; plate.textContent = vehicle.plate || '';
  const actions = document.createElement('div'); actions.className = 'deadline-management-row-actions';
  const edit = document.createElement('button'); edit.className = 'fa-button fa-button-secondary fa-button-compact'; edit.type = 'button'; edit.textContent = 'Modifica'; edit.addEventListener('click', (event) => { event.stopPropagation(); openForm(vehicle); });
  const remove = document.createElement('button'); remove.className = 'fa-button fa-button-danger fa-button-compact'; remove.type = 'button'; remove.textContent = 'Elimina'; remove.addEventListener('click', (event) => { event.stopPropagation(); void removeVehicle(vehicle); });
  actions.append(edit, remove); row.append(image, type, title, plate, actions); return row;
}
async function loadVehicles() { const { data, error } = await vehiclesClient.rpc('get_my_deadline_items', { p_category: 'vehicle' }); if (error) { setMessage('Impossibile caricare i veicoli.', true); return; } const vehicles = data || []; vehiclesList.replaceChildren(...vehicles.map(vehicleRow)); vehiclesEmpty.hidden = vehicles.length > 0; }
vehicleForm.addEventListener('submit', async (event) => {
  event.preventDefault(); const name = vehicleName.value.trim();
  if (!name) { setMessage('Inserisci il nome del veicolo.', true); vehicleName.focus(); return; }
  const editedVehicle = editingVehicle;
  const params = editedVehicle ? { p_item_id: editedVehicle.id, p_item_type: vehicleType.value, p_name: name, p_plate: vehiclePlate.value } : { p_category: 'vehicle', p_item_type: vehicleType.value, p_name: name, p_plate: vehiclePlate.value };
  const rpc = editedVehicle ? 'update_my_deadline_item' : 'create_my_deadline_item';
  const { data, error } = await vehiclesClient.rpc(rpc, params);
  if (error || !data) { setMessage('Impossibile salvare il veicolo.', true); return; }
  try { await saveVehicleImage(data, editedVehicle?.image_path); } catch (imageError) { console.error('vehicle image save failed', imageError); setMessage('Veicolo salvato, ma non è stato possibile aggiornare la foto.', true); return; }
  setMessage(editedVehicle ? 'Veicolo aggiornato.' : 'Veicolo aggiunto.'); resetForm(); await loadVehicles();
});
vehicleImageInput.addEventListener('change', () => {
  const file = vehicleImageInput.files?.[0]; vehicleImageInput.value = ''; if (!file) return;
  if (!vehicleImageService.allowedTypes.has(file.type)) { setImageMessage('Scegli un’immagine JPG, PNG o WebP.', true); return; }
  if (file.size > vehicleImageService.maxBytes) { setImageMessage('L’immagine deve pesare al massimo 2 MB.', true); return; }
  pendingImageFile = file; imageRemovalRequested = false; setImageMessage('Foto pronta per il salvataggio.'); void renderVehicleImage();
});
vehicleImageRemove.addEventListener('click', () => { pendingImageFile = null; imageRemovalRequested = Boolean(editingVehicle?.image_path); setImageMessage('La foto verrà rimossa al salvataggio.'); renderImageFallback(); vehicleImageRemove.hidden = true; vehicleImageUpload.textContent = 'Carica foto'; });
async function initialiseVehicles() { if (!await window.FamilAreaDeadlineManagementReady) return; document.getElementById('vehicle-create').addEventListener('click', () => openForm()); document.getElementById('vehicle-cancel').addEventListener('click', resetForm); await loadVehicles(); }
void initialiseVehicles();

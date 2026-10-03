const vehiclesClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const vehiclesMessage = document.getElementById('vehicles-message');
const vehiclesList = document.getElementById('vehicles-list');
const vehiclesEmpty = document.getElementById('vehicles-empty');
const vehicleForm = document.getElementById('vehicle-form');
const vehicleFormModal = document.getElementById('vehicle-form-modal');
const vehicleFormMessage = document.getElementById('vehicle-form-message');
const vehicleFormTitle = document.getElementById('vehicle-form-title');
const vehicleName = document.getElementById('vehicle-name');
const vehicleType = document.getElementById('vehicle-type');
const vehiclePlate = document.getElementById('vehicle-plate');
const vehicleDelete = document.getElementById('vehicle-delete');
const vehicleSave = document.getElementById('vehicle-save');
const vehicleImageService = window.FamilAreaDeadlineItemImage;
const vehicleTypeLabels = { car: 'Auto', motorcycle: 'Moto', other: 'Altro' };
const vehicleAnnualCalendarGrid = document.getElementById('vehicle-annual-calendar-grid');
const vehicleAnnualCalendarYear = document.getElementById('vehicle-calendar-year');
const vehicleAnnualCalendarMessage = document.getElementById('vehicle-calendar-message');
let editingVehicle = null;
let vehicleFormPreviousFocus = null;
let currentVehicles = [];
let vehicleAnnualCalendar = null;
const vehicleImageEditor = vehicleImageService.createEditor({ client: vehiclesClient, input: document.getElementById('vehicle-image-input'), preview: document.getElementById('vehicle-image-preview'), upload: document.getElementById('vehicle-image-upload'), remove: document.getElementById('vehicle-image-remove'), message: document.getElementById('vehicle-image-message'), getItem: () => editingVehicle, fallback: () => vehicleName.value || 'V', noun: 'foto' });

function setMessage(text = '', isError = false) {
  vehiclesMessage.textContent = text;
  vehiclesMessage.classList.toggle('is-error', isError);
  vehicleFormMessage.textContent = isError ? text : '';
  vehicleFormMessage.classList.toggle('is-error', isError);
}

function resetForm() {
  editingVehicle = null;
  vehicleForm.reset();
  vehicleType.value = 'car';
  vehicleFormTitle.textContent = 'Aggiungi veicolo';
  vehicleSave.textContent = 'Aggiungi veicolo';
  vehicleDelete.hidden = true;
  vehicleImageEditor.reset();
}

function closeForm() {
  vehicleFormModal.hidden = true;
  document.body.classList.remove('confirm-modal-open');
  resetForm();
  vehicleFormPreviousFocus?.focus();
  vehicleFormPreviousFocus = null;
}

function openForm(vehicle = null) {
  vehicleFormPreviousFocus = document.activeElement;
  editingVehicle = vehicle;
  vehicleFormTitle.textContent = vehicle ? 'Modifica veicolo' : 'Aggiungi veicolo';
  vehicleSave.textContent = vehicle ? 'Salva modifiche' : 'Aggiungi veicolo';
  vehicleDelete.hidden = !vehicle;
  vehicleName.value = vehicle?.name || '';
  vehicleType.value = vehicle?.item_type || 'car';
  vehiclePlate.value = vehicle?.plate || '';
  vehicleImageEditor.reset();
  void vehicleImageEditor.refresh();
  vehicleFormModal.hidden = false;
  document.body.classList.add('confirm-modal-open');
  vehicleName.focus();
}

async function removeVehicle(vehicle) {
  const confirmed = await FamilAreaConfirm.confirm({ variant: 'danger', title: `Eliminare ${vehicle.name}?`, message: 'Il veicolo e le relative immagini verranno eliminati.', confirmText: 'Elimina' });
  if (!confirmed) return false;
  if (vehicle.image_path) {
    const { error: clearError } = await vehiclesClient.rpc('set_my_deadline_item_image', { p_item_id: vehicle.id, p_image_path: null });
    if (clearError) {
      setMessage('Impossibile preparare la rimozione della foto del veicolo.', true);
      return false;
    }
    const { error: imageError } = await vehiclesClient.storage.from(vehicleImageService.bucket).remove([vehicle.image_path]);
    if (imageError) {
      setMessage('Impossibile eliminare la foto del veicolo.', true);
      return false;
    }
  }
  const { error } = await vehiclesClient.rpc('delete_my_deadline_item', { p_item_id: vehicle.id });
  if (error) {
    setMessage('Impossibile eliminare il veicolo.', true);
    return false;
  }
  setMessage('Veicolo eliminato.');
  return true;
}

function vehicleRow(vehicle) {
  const row = document.createElement('article');
  row.className = 'deadline-item-summary-card deadline-item-summary-card--clickable fa-v2-list-row';
  row.tabIndex = 0;
  row.setAttribute('role', 'group');
  row.setAttribute('aria-label', `Apri veicolo ${vehicle.name}`);
  const openVehicle = () => { location.href = `gestione-scadenza-item.html?item_id=${encodeURIComponent(vehicle.id)}`; };
  row.addEventListener('click', openVehicle);
  row.addEventListener('keydown', (event) => {
    if (event.key !== 'Enter' && event.key !== ' ') return;
    event.preventDefault();
    openVehicle();
  });
  const image = document.createElement('span');
  image.className = 'deadline-management-item-image deadline-item-summary-image';
  image.setAttribute('aria-label', `Foto di ${vehicle.name}`);
  image.textContent = (vehicle.name.trim().charAt(0) || 'V').toLocaleUpperCase('it-IT');
  if (vehicle.image_path) void vehicleImageService.render(image, vehicle.image_path, `Foto di ${vehicle.name}`);
  const type = document.createElement('p');
  type.className = 'deadline-item-summary-type';
  type.textContent = vehicleTypeLabels[vehicle.item_type] || 'Altro';
  const title = document.createElement('h2');
  title.className = 'deadline-item-summary-name';
  title.textContent = vehicle.name;
  const plate = document.createElement('span');
  plate.className = 'deadline-item-summary-plate';
  plate.textContent = vehicle.plate || '';
  const edit = document.createElement('button');
  edit.className = 'fa-button fa-button-secondary fa-button-compact deadline-item-summary-action';
  edit.type = 'button';
  edit.textContent = 'Modifica';
  edit.addEventListener('click', (event) => {
    event.stopPropagation();
    openForm(vehicle);
  });
  row.append(image, type, title, plate, edit);
  return row;
}

async function loadVehicles() {
  const { data, error } = await vehiclesClient.rpc('get_my_deadline_items', { p_category: 'vehicle' });
  if (error) {
    setMessage('Impossibile caricare i veicoli.', true);
    return;
  }
  currentVehicles = data || [];
  vehiclesList.replaceChildren(...currentVehicles.map(vehicleRow));
  vehiclesEmpty.hidden = currentVehicles.length > 0;
  await vehicleAnnualCalendar?.load();
}

vehicleForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const name = vehicleName.value.trim();
  if (!name) {
    setMessage('Inserisci il nome del veicolo.', true);
    vehicleName.focus();
    return;
  }
  const editedVehicle = editingVehicle;
  const params = editedVehicle
    ? { p_item_id: editedVehicle.id, p_item_type: vehicleType.value, p_name: name, p_plate: vehiclePlate.value }
    : { p_category: 'vehicle', p_item_type: vehicleType.value, p_name: name, p_plate: vehiclePlate.value };
  const { data, error } = await vehiclesClient.rpc(editedVehicle ? 'update_my_deadline_item' : 'create_my_deadline_item', params);
  if (error || !data) {
    setMessage('Impossibile salvare il veicolo.', true);
    return;
  }
  try {
    await vehicleImageEditor.save(data, editedVehicle?.image_path);
  } catch (imageError) {
    console.error('vehicle image save failed', imageError);
    setMessage('Veicolo salvato, ma non è stato possibile aggiornare la foto.', true);
    return;
  }
  setMessage(editedVehicle ? 'Veicolo aggiornato.' : 'Veicolo aggiunto.');
  await loadVehicles();
  closeForm();
});

vehicleName.addEventListener('input', () => {
  if (!editingVehicle) void vehicleImageEditor.refresh();
});

async function initialiseVehicles() {
  if (!await window.FamilAreaDeadlineManagementReady) return;
  vehicleAnnualCalendar = window.FamilAreaAnnualDeadlineCalendar.create({
    client: vehiclesClient,
    gridElement: vehicleAnnualCalendarGrid,
    yearElement: vehicleAnnualCalendarYear,
    messageElement: vehicleAnnualCalendarMessage,
    previousButton: document.getElementById('vehicle-calendar-previous-year'),
    nextButton: document.getElementById('vehicle-calendar-next-year'),
    getItems: () => currentVehicles,
    itemFallback: 'Veicolo',
    imageService: vehicleImageService,
    idPrefix: 'vehicle-calendar',
    isOccurrence: (occurrence) => occurrence.deadline_id && occurrence.deadline_item_category === 'vehicle'
  });
  document.getElementById('vehicle-create').addEventListener('click', () => openForm());
  document.getElementById('vehicle-cancel').addEventListener('click', closeForm);
  document.getElementById('vehicle-modal-close').addEventListener('click', closeForm);
  vehicleFormModal.addEventListener('click', (event) => {
    if (event.target === vehicleFormModal) closeForm();
  });
  vehicleDelete.addEventListener('click', async () => {
    const vehicle = editingVehicle;
    if (vehicle && await removeVehicle(vehicle)) {
      closeForm();
      await loadVehicles();
    }
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !vehicleFormModal.hidden) {
      event.preventDefault();
      closeForm();
    }
  });
  await loadVehicles();
}

void initialiseVehicles();

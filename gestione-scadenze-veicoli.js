const vehiclesClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const vehiclesMessage = document.getElementById('vehicles-message');
const vehiclesList = document.getElementById('vehicles-list');
const vehiclesEmpty = document.getElementById('vehicles-empty');
const vehicleForm = document.getElementById('vehicle-form');
const vehicleFormTitle = document.getElementById('vehicle-form-title');
const vehicleName = document.getElementById('vehicle-name');
const vehicleType = document.getElementById('vehicle-type');
let editingVehicleId = null;

const vehicleTypeLabels = { car: 'Auto', motorcycle: 'Moto', other: 'Altro' };

function setMessage(text = '', isError = false) {
  vehiclesMessage.textContent = text;
  vehiclesMessage.classList.toggle('is-error', isError);
}

function resetForm() {
  editingVehicleId = null;
  vehicleForm.reset();
  vehicleType.value = 'car';
  vehicleFormTitle.textContent = 'Nuovo veicolo';
  vehicleForm.hidden = true;
}

function openForm(vehicle = null) {
  editingVehicleId = vehicle?.id || null;
  vehicleFormTitle.textContent = vehicle ? 'Modifica veicolo' : 'Nuovo veicolo';
  vehicleName.value = vehicle?.name || '';
  vehicleType.value = vehicle?.item_type || 'car';
  vehicleForm.hidden = false;
  vehicleName.focus();
}

async function removeVehicle(vehicle) {
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: `Eliminare ${vehicle.name}?`,
    message: 'Il veicolo verrà eliminato. In questo step non sono ancora presenti Scadenze collegate.',
    confirmText: 'Elimina'
  });
  if (!confirmed) return;

  const { error } = await vehiclesClient.rpc('delete_my_deadline_item', { p_item_id: vehicle.id });
  if (error) {
    setMessage('Impossibile eliminare il veicolo.', true);
    return;
  }
  setMessage('Veicolo eliminato.');
  await loadVehicles();
}

function vehicleRow(vehicle) {
  const row = document.createElement('article');
  row.className = 'deadline-management-row fa-surface';
  const identity = document.createElement('div');
  identity.className = 'deadline-management-row-copy';
  const title = document.createElement('h2');
  title.textContent = vehicle.name;
  const type = document.createElement('p');
  type.textContent = vehicleTypeLabels[vehicle.item_type] || 'Altro';
  identity.append(title, type);

  const actions = document.createElement('div');
  actions.className = 'deadline-management-row-actions';
  const open = document.createElement('a');
  open.className = 'fa-button fa-button-secondary fa-button-compact';
  open.href = `gestione-scadenza-item.html?item_id=${encodeURIComponent(vehicle.id)}`;
  open.textContent = 'Apri';
  const edit = document.createElement('button');
  edit.className = 'fa-button fa-button-secondary fa-button-compact';
  edit.type = 'button';
  edit.textContent = 'Modifica';
  edit.addEventListener('click', () => openForm(vehicle));
  const remove = document.createElement('button');
  remove.className = 'fa-button fa-button-danger fa-button-compact';
  remove.type = 'button';
  remove.textContent = 'Elimina';
  remove.addEventListener('click', () => { void removeVehicle(vehicle); });
  actions.append(open, edit, remove);
  row.append(identity, actions);
  return row;
}

async function loadVehicles() {
  const { data, error } = await vehiclesClient.rpc('get_my_deadline_items', { p_category: 'vehicle' });
  if (error) {
    setMessage('Impossibile caricare i veicoli.', true);
    return;
  }
  const vehicles = data || [];
  vehiclesList.replaceChildren(...vehicles.map(vehicleRow));
  vehiclesEmpty.hidden = vehicles.length > 0;
}

vehicleForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const name = vehicleName.value.trim();
  if (!name) {
    setMessage('Inserisci il nome del veicolo.', true);
    vehicleName.focus();
    return;
  }

  const params = editingVehicleId
    ? { p_item_id: editingVehicleId, p_item_type: vehicleType.value, p_name: name }
    : { p_category: 'vehicle', p_item_type: vehicleType.value, p_name: name };
  const rpc = editingVehicleId ? 'update_my_deadline_item' : 'create_my_deadline_item';
  const { error } = await vehiclesClient.rpc(rpc, params);
  if (error) {
    setMessage('Impossibile salvare il veicolo.', true);
    return;
  }

  setMessage(editingVehicleId ? 'Veicolo aggiornato.' : 'Veicolo aggiunto.');
  resetForm();
  await loadVehicles();
});

document.getElementById('vehicle-create').addEventListener('click', () => openForm());
document.getElementById('vehicle-cancel').addEventListener('click', resetForm);
void loadVehicles();

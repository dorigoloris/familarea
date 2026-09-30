const vehicleDeadlineClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const vehicleDeadlineId = new URLSearchParams(window.location.search).get('deadline_id');
const vehicleDeadlineMessage = document.getElementById('vehicle-deadline-message');
const vehicleDeadlineTitles = {
  vehicle_insurance: 'Gestione Assicurazione RCA',
  vehicle_tax: 'Gestione Bollo',
  vehicle_inspection: 'Gestione Collaudo / Revisione'
};

function recurrenceLabel(months) {
  if (!months) return 'Nessuna ricorrenza';
  if (months === 1) return 'Ogni mese';
  return `Ogni ${months} mesi`;
}

async function initialiseVehicleDeadline() {
  if (!await window.FamilAreaDeadlineManagementReady) return;
  if (!vehicleDeadlineId) {
    vehicleDeadlineMessage.textContent = 'Scadenza non disponibile.';
    return;
  }

  const { data: deadline, error: deadlineError } = await vehicleDeadlineClient.rpc('get_deadline', {
    p_deadline_id: vehicleDeadlineId
  });
  const heading = vehicleDeadlineTitles[deadline?.deadline_kind];
  if (deadlineError || !deadline || !deadline.deadline_item_id || !heading) {
    vehicleDeadlineMessage.textContent = 'Gestione scadenza non disponibile.';
    return;
  }

  const { data: item, error: itemError } = await vehicleDeadlineClient.rpc('get_my_deadline_item', {
    p_item_id: deadline.deadline_item_id
  });
  if (itemError || !item || item.category !== 'vehicle') {
    vehicleDeadlineMessage.textContent = 'Veicolo non disponibile.';
    return;
  }

  document.getElementById('vehicle-deadline-title').textContent = heading;
  document.getElementById('vehicle-deadline-vehicle').textContent = item.name;
  document.getElementById('vehicle-deadline-next-date').textContent = window.FamilAreaDateUtils.formatDateDisplay(deadline.first_due_on);
  document.getElementById('vehicle-deadline-meta').textContent = `${recurrenceLabel(deadline.recurrence_months)} · Promemoria ${deadline.reminder_days} giorni prima`;
  document.getElementById('vehicle-deadline-back-link').href = `gestione-scadenza-item.html?item_id=${encodeURIComponent(item.id)}`;
  document.getElementById('vehicle-deadline-edit').href = `nuova-scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}`;

  const attachments = window.FamilAreaDeadlineAttachments.create({
    client: vehicleDeadlineClient,
    deadlineId: deadline.id,
    input: document.getElementById('deadline-attachment-input'),
    uploadControl: document.getElementById('deadline-attachment-upload'),
    message: document.getElementById('deadline-attachments-message'),
    empty: document.getElementById('deadline-attachments-empty'),
    list: document.getElementById('deadline-attachments-list')
  });
  await attachments.load();
  document.getElementById('vehicle-deadline-content').hidden = false;
  vehicleDeadlineMessage.textContent = '';
}

void initialiseVehicleDeadline();

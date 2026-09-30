const itemDeadlineClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const itemDeadlineId = new URLSearchParams(location.search).get('deadline_id');
const itemDeadlineMessage = document.getElementById('vehicle-deadline-message');
const itemDeadlineConfigurations = {
  vehicle_insurance: { title: 'Gestione Assicurazione RCA', category: 'vehicle', label: 'Veicolo' }, vehicle_tax: { title: 'Gestione Bollo', category: 'vehicle', label: 'Veicolo' }, vehicle_inspection: { title: 'Gestione Collaudo / Revisione', category: 'vehicle', label: 'Veicolo' },
  home_heating: { title: 'Gestione Caldaia / Impianto termico', category: 'home', label: 'Casa' }, home_insurance: { title: 'Gestione Assicurazione casa', category: 'home', label: 'Casa' }, home_taxes: { title: 'Gestione Imposte e tributi', category: 'home', label: 'Casa' }, home_waste: { title: 'Gestione Rifiuti', category: 'home', label: 'Casa' }
};
function recurrenceLabel(months) { return !months ? 'Nessuna ricorrenza' : months === 1 ? 'Ogni mese' : `Ogni ${months} mesi`; }
async function initialiseItemDeadline() {
  if (!await window.FamilAreaDeadlineManagementReady) return;
  if (!itemDeadlineId) { itemDeadlineMessage.textContent = 'Scadenza non disponibile.'; return; }
  const { data: deadline, error: deadlineError } = await itemDeadlineClient.rpc('get_deadline', { p_deadline_id: itemDeadlineId }); const configuration = itemDeadlineConfigurations[deadline?.deadline_kind];
  if (deadlineError || !deadline || !deadline.deadline_item_id || !configuration) { itemDeadlineMessage.textContent = 'Gestione scadenza non disponibile.'; return; }
  const { data: item, error: itemError } = await itemDeadlineClient.rpc('get_my_deadline_item', { p_item_id: deadline.deadline_item_id });
  if (itemError || !item || item.category !== configuration.category) { itemDeadlineMessage.textContent = 'Elemento non disponibile.'; return; }
  document.title = `${configuration.title} - FamilArea`; document.getElementById('item-deadline-category').textContent = configuration.label.toLocaleUpperCase('it-IT'); document.getElementById('vehicle-deadline-title').textContent = configuration.title; document.getElementById('vehicle-deadline-vehicle').textContent = item.name;
  document.getElementById('vehicle-deadline-next-date').textContent = window.FamilAreaDateUtils.formatDateDisplay(deadline.first_due_on); document.getElementById('vehicle-deadline-meta').textContent = `${recurrenceLabel(deadline.recurrence_months)} · Promemoria ${deadline.reminder_days} giorni prima`; document.getElementById('vehicle-deadline-back-link').href = `gestione-scadenza-item.html?item_id=${encodeURIComponent(item.id)}`; document.getElementById('vehicle-deadline-edit').href = `nuova-scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}`;
  const attachments = window.FamilAreaDeadlineAttachments.create({ client: itemDeadlineClient, deadlineId: deadline.id, input: document.getElementById('deadline-attachment-input'), uploadControl: document.getElementById('deadline-attachment-upload'), message: document.getElementById('deadline-attachments-message'), empty: document.getElementById('deadline-attachments-empty'), list: document.getElementById('deadline-attachments-list') }); await attachments.load(); document.getElementById('vehicle-deadline-content').hidden = false; itemDeadlineMessage.textContent = '';
}
void initialiseItemDeadline();

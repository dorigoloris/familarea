const deadlineItemClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const deadlineItemId = new URLSearchParams(window.location.search).get('item_id');
const deadlineItemMessage = document.getElementById('deadline-item-message');
const deadlineItemTypeLabels = { car: 'Auto', motorcycle: 'Moto', other: 'Altro' };

async function loadDeadlineItem() {
  if (!deadlineItemId) {
    deadlineItemMessage.textContent = 'Veicolo non disponibile.';
    return;
  }
  const { data, error } = await deadlineItemClient.rpc('get_my_deadline_item', { p_item_id: deadlineItemId });
  if (error || !data || data.category !== 'vehicle') {
    deadlineItemMessage.textContent = 'Veicolo non disponibile.';
    return;
  }
  document.getElementById('deadline-item-title').textContent = data.name;
  document.getElementById('deadline-item-type').textContent = deadlineItemTypeLabels[data.item_type] || 'Altro';
  document.getElementById('deadline-item-content').hidden = false;
  deadlineItemMessage.textContent = '';
}

async function initialiseDeadlineItem() {
  if (!await window.FamilAreaDeadlineManagementReady) return;
  await loadDeadlineItem();
}

void initialiseDeadlineItem();

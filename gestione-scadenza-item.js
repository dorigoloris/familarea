const deadlineItemClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const deadlineItemId = new URLSearchParams(window.location.search).get('item_id');
const deadlineItemMessage = document.getElementById('deadline-item-message');
const deadlineItemTypeLabels = { car: 'Auto', motorcycle: 'Moto', other: 'Altro' };
const deadlineItemDeadlinesEmpty = document.getElementById('deadline-item-deadlines-empty');
const deadlineItemDeadlinesList = document.getElementById('deadline-item-deadlines-list');
const deadlineItemAddDeadline = document.getElementById('deadline-item-add-deadline');

function itemDeadlineHref(path) {
  const url = new URL(path, window.location.href);
  url.searchParams.set('deadline_item_id', deadlineItemId);
  return `${url.pathname.split('/').pop()}${url.search}`;
}

function renderItemDeadlines(rows, itemName) {
  deadlineItemDeadlinesEmpty.hidden = rows.length > 0;
  deadlineItemDeadlinesList.hidden = rows.length === 0;
  deadlineItemDeadlinesList.replaceChildren(...rows.map((deadline) => {
    const row = document.createElement('a');
    row.className = 'deadline-card';
    row.href = `scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}`;
    row.textContent = `${deadline.title} — ${window.FamilAreaDateUtils.formatDateDisplay(deadline.first_due_on)}`;
    return row;
  }));

  if (!rows.length) {
    deadlineItemDeadlinesEmpty.textContent = `Nessuna scadenza collegata a ${itemName}.`;
  }
}

async function loadItemDeadlines(item) {
  const { data, error } = await deadlineItemClient.rpc('get_my_deadlines_for_item', {
    p_item_id: deadlineItemId
  });
  if (error) {
    deadlineItemDeadlinesEmpty.textContent = 'Impossibile caricare le scadenze del veicolo.';
    return;
  }
  renderItemDeadlines(data || [], item.name);
}

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
  deadlineItemAddDeadline.href = itemDeadlineHref('nuova-scadenza.html');
  document.getElementById('deadline-item-content').hidden = false;
  deadlineItemMessage.textContent = '';
  await loadItemDeadlines(data);
}

async function initialiseDeadlineItem() {
  if (!await window.FamilAreaDeadlineManagementReady) return;
  await loadDeadlineItem();
}

void initialiseDeadlineItem();

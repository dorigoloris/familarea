const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const areaId = new URLSearchParams(location.search).get('area_id');
const eventId = new URLSearchParams(location.search).get('event_id');
const isArea = Boolean(areaId);
const message = document.getElementById('message');
let eventData;
let canManage = false;

const statusLabels = { active: 'Attivo', cancelled: 'Annullato' };

function localDate(value) {
  const date = new Date(value);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

function localTime(value) {
  return new Date(value).toTimeString().slice(0, 5);
}

function localIso(date, time = '00:00') {
  return new Date(`${date}T${time}`).toISOString();
}

function formatWhen(value, isAllDay) {
  if (!value) return '—';
  return new Intl.DateTimeFormat('it-IT', isAllDay
    ? { dateStyle: 'long' }
    : { dateStyle: 'long', timeStyle: 'short' }).format(new Date(value));
}

function statusLabel(status) {
  return statusLabels[status] || status || '—';
}

function recurrenceOf(event) {
  return {
    frequency: event.recurrence_frequency || '',
    until: event.recurrence_until || ''
  };
}

function formRecurrence() {
  if (!document.getElementById('edit-recurrence-enabled').checked) return {};
  const until = document.getElementById('edit-recurrence-until').value;
  if (!until) throw new Error('Indica la fine della ripetizione.');
  return { frequency: 'weekly', until };
}

async function renderParticipants(container, selected = []) {
  if (!isArea) return;
  const { data, error } = await supabaseClient.rpc('get_area_members', { p_area_id: areaId });
  if (error) throw error;

  container.replaceChildren();
  (data || []).forEach((member) => {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.value = member.profile_id;
    input.checked = selected.includes(member.profile_id);
    label.append(input, ` ${member.first_name || ''} ${member.last_name || ''}`.trim());
    container.append(label, document.createElement('br'));
  });
}

function renderStatus() {
  const select = document.getElementById('status-select');
  const save = document.getElementById('save-status');
  document.getElementById('status').textContent = statusLabel(eventData.status);
  select.value = statusLabels[eventData.status] ? eventData.status : 'active';
  save.disabled = select.value === eventData.status;
}

async function render() {
  document.getElementById('event-title').textContent = eventData.title;
  document.getElementById('when').textContent = formatWhen(eventData.starts_at, eventData.is_all_day);
  document.getElementById('location').textContent = eventData.location || '—';
  document.getElementById('notes').textContent = eventData.description || '—';
  renderStatus();

  const recurrence = recurrenceOf(eventData);
  document.getElementById('recurrence-label').hidden = !recurrence.frequency;
  document.getElementById('recurrence').hidden = !recurrence.frequency;
  document.getElementById('recurrence').textContent = recurrence.frequency === 'weekly'
    ? `Ogni settimana fino al ${recurrence.until}`
    : recurrence.frequency;

  document.getElementById('participants-label').hidden = !isArea;
  document.getElementById('participant-list').hidden = !isArea;
  if (isArea) {
    const { data, error } = await supabaseClient.rpc('get_event_participants', { p_event_id: eventId });
    document.getElementById('participant-list').textContent = error
      ? 'Non disponibili.'
      : (data || []).map((person) => `${person.first_name || ''} ${person.last_name || ''}`.trim()).join(', ') || 'Nessuno';
  }

  document.getElementById('event-view').hidden = false;
  document.getElementById('creator-actions').hidden = !canManage;
  message.textContent = '';
}

async function load() {
  const { data: session } = await supabaseClient.auth.getSession();
  if (!session.session) {
    location.href = 'login.html';
    return;
  }
  if (!eventId) {
    message.textContent = 'Evento non specificato.';
    return;
  }

  document.getElementById('back-link').href = isArea
    ? `eventi.html?area_id=${encodeURIComponent(areaId)}`
    : 'eventi.html';
  const [{ data: event, error }, { data: account }, { data: areas }] = await Promise.all([
    supabaseClient.rpc('get_event', { p_event_id: eventId }),
    supabaseClient.rpc('get_current_account'),
    supabaseClient.rpc('get_my_areas')
  ]);
  if (error || !event) {
    message.textContent = 'Evento non disponibile.';
    return;
  }
  eventData = event;
  canManage = !event.area_id
    ? event.owner_account_id === account?.account_id
    : (areas || []).some((area) => area.id === event.area_id && ['owner', 'admin'].includes(area.role));
  await render();
}

async function openEdit() {
  const form = document.getElementById('edit-form');
  const recurrence = recurrenceOf(eventData);
  document.getElementById('edit-title').value = eventData.title || '';
  document.getElementById('edit-notes').value = eventData.description || '';
  document.getElementById('edit-date').value = localDate(eventData.starts_at);
  document.getElementById('edit-start').value = eventData.is_all_day ? '' : localTime(eventData.starts_at);
  document.getElementById('edit-end').value = eventData.is_all_day || !eventData.ends_at ? '' : localTime(eventData.ends_at);
  document.getElementById('edit-all-day').checked = Boolean(eventData.is_all_day);
  document.getElementById('edit-location').value = eventData.location || '';
  document.getElementById('edit-recurrence-enabled').checked = Boolean(recurrence.frequency);
  document.getElementById('edit-recurrence-fields').hidden = !recurrence.frequency;
  document.getElementById('edit-recurrence-until').value = recurrence.until || '';
  document.getElementById('edit-participants-fieldset').hidden = !isArea;

  if (isArea) {
    const { data } = await supabaseClient.rpc('get_event_participants', { p_event_id: eventId });
    await renderParticipants(
      document.getElementById('edit-participants'),
      (data || []).map((person) => person.profile_id)
    );
  }

  document.getElementById('event-view').hidden = true;
  form.hidden = false;
}

async function saveStatus() {
  const select = document.getElementById('status-select');
  const save = document.getElementById('save-status');
  if (select.value === eventData.status) return;
  save.disabled = true;
  const { error } = await supabaseClient.rpc('set_event_status', {
    p_event_id: eventId,
    p_status: select.value
  });
  if (error) {
    message.textContent = 'Impossibile aggiornare lo stato.';
    save.disabled = false;
    return;
  }
  eventData.status = select.value;
  renderStatus();
  message.textContent = '';
}

document.getElementById('edit-button').addEventListener('click', () => void openEdit());
document.getElementById('close-edit').addEventListener('click', () => {
  document.getElementById('edit-form').hidden = true;
  document.getElementById('event-view').hidden = false;
  message.textContent = '';
});
document.getElementById('status-select').addEventListener('change', (event) => {
  document.getElementById('save-status').disabled = event.target.value === eventData.status;
});
document.getElementById('save-status').addEventListener('click', () => void saveStatus());
document.getElementById('edit-recurrence-enabled').addEventListener('change', (event) => {
  document.getElementById('edit-recurrence-fields').hidden = !event.target.checked;
});

document.getElementById('edit-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const date = document.getElementById('edit-date').value;
  const start = document.getElementById('edit-start').value;
  const end = document.getElementById('edit-end').value;
  if (!date || (end && !start)) {
    message.textContent = !date ? 'Indica la data dell’evento.' : 'Indica prima l’ora di inizio.';
    return;
  }

  let recurrence;
  try {
    recurrence = formRecurrence();
  } catch (error) {
    message.textContent = error.message;
    return;
  }

  const allDay = document.getElementById('edit-all-day').checked || !start;
  const startsAt = localIso(date, allDay ? '00:00' : start);
  const { error } = await supabaseClient.rpc('update_event', {
    p_event_id: eventId,
    p_title: document.getElementById('edit-title').value.trim(),
    p_starts_at: startsAt,
    p_ends_at: allDay ? startsAt : end ? localIso(date, end) : null,
    p_description: document.getElementById('edit-notes').value.trim() || null,
    p_is_all_day: allDay,
    p_location: document.getElementById('edit-location').value.trim() || null,
    p_recurrence: recurrence
  });
  if (error) {
    message.textContent = 'Impossibile salvare le modifiche.';
    return;
  }

  if (isArea) {
    const result = await supabaseClient.rpc('set_event_participants', {
      p_event_id: eventId,
      p_profile_ids: [...document.querySelectorAll('#edit-participants input:checked')].map((input) => input.value)
    });
    if (result.error) {
      message.textContent = 'Dati salvati, ma partecipanti non aggiornati.';
      return;
    }
  }

  document.getElementById('edit-form').hidden = true;
  document.getElementById('event-view').hidden = false;
  await load();
});

document.getElementById('delete-button').addEventListener('click', async () => {
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: 'Eliminare l’evento?',
    message: 'L’evento verrà eliminato definitivamente.',
    confirmText: 'Elimina'
  });
  if (!confirmed) return;
  const { error } = await supabaseClient.rpc('delete_event', { p_event_id: eventId });
  if (error) {
    message.textContent = 'Impossibile eliminare l’evento.';
    return;
  }
  location.href = isArea ? `eventi.html?area_id=${encodeURIComponent(areaId)}` : 'eventi.html';
});

load();

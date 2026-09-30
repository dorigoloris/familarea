const c = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const id = new URLSearchParams(location.search).get('deadline_id');
const m = document.getElementById('deadline-message');
const formatDateDisplay = window.FamilAreaDateUtils.formatDateDisplay;
const contextContainer = document.getElementById('managed-context');
const backLink = document.getElementById('deadline-back-link');
const terminateButton = document.getElementById('terminate-deadline');
const deleteButton = document.getElementById('delete-deadline');
const attachmentsSection = document.querySelector('.deadline-attachments-section');
const deadlineAttachments = window.FamilAreaDeadlineAttachments.create({
  client: c,
  deadlineId: id,
  input: document.getElementById('deadline-attachment-input'),
  uploadControl: document.getElementById('deadline-attachment-upload'),
  message: document.getElementById('deadline-attachments-message'),
  empty: document.getElementById('deadline-attachments-empty'),
  list: document.getElementById('deadline-attachments-list')
});
let d;
let managedMember = null;

function isManaged() {
  return Boolean(managedMember);
}

function managedHref(path) {
  return isManaged()
    ? window.FamilAreaManagedContext.withMember(path, managedMember.id)
    : path;
}

async function renderDeadlineItemReference() {
  document.getElementById('deadline-item-reference')?.remove();
  if (isManaged() || !d.deadline_item_id) return;

  const { data: item, error } = await c.rpc('get_my_deadline_item', {
    p_item_id: d.deadline_item_id
  });
  if (error || !item) return;

  const row = document.createElement('div');
  row.id = 'deadline-item-reference';
  const term = document.createElement('dt');
  const definition = document.createElement('dd');
  const link = document.createElement('a');
  term.textContent = item.category === 'home' ? 'Casa' : 'Veicolo';
  link.href = `gestione-scadenza-item.html?item_id=${encodeURIComponent(item.id)}`;
  link.textContent = item.name;
  definition.append(link);
  row.append(term, definition);
  document.getElementById('deadline-details-list').append(row);
}

async function load() {
  const context = await window.FamilAreaManagedContext.load();
  managedMember = context.member || null;
  const contextWarning = context.requested && !managedMember
    ? 'Il membro selezionato non è gestibile dalla tua Famiglia. Stai visualizzando una scadenza personale.'
    : '';

  if (isManaged()) {
    contextContainer.hidden = false;
    window.FamilAreaManagedContext.renderBar(contextContainer, managedMember);
    backLink.href = managedHref('scadenze.html');
    terminateButton.hidden = true;
    attachmentsSection.hidden = true;
  }

  const { data, error } = isManaged()
    ? await c.rpc('get_my_managed_deadline', { p_member_id: managedMember.id, p_deadline_id: id })
    : await c.rpc('get_deadline', { p_deadline_id: id });
  if (error || !data) {
    m.textContent = isManaged()
      ? 'Scadenza non disponibile nel contesto gestito.'
      : 'Scadenza non disponibile.';
    return;
  }

  d = data;
  document.getElementById('deadline-title').textContent = d.title;
  document.getElementById('deadline-subtitle').textContent = formatDateDisplay(d.first_due_on);
  document.getElementById('deadline-content').hidden = false;
  m.textContent = contextWarning;
  await renderDeadlineItemReference();
  await occurrence();
  if (!isManaged()) await deadlineAttachments.load();
}

async function occurrence() {
  const { data, error } = await c.rpc('get_deadline_occurrence', {
    p_deadline_id: id,
    p_occurrence_on: d.first_due_on
  });
  const box = document.getElementById('deadline-occurrences-list');
  box.replaceChildren();
  if (error || !data) return;

  box.append(document.createTextNode(`${formatDateDisplay(data.occurrence_on)} `));
  const button = document.createElement('button');
  button.textContent = data.completed ? 'Annulla completamento' : 'Completa occorrenza';
  button.onclick = async () => {
    const result = isManaged()
      ? await c.rpc('complete_my_managed_deadline_occurrence', {
        p_deadline_id: id,
        p_managed_member_id: managedMember.id,
        p_occurrence_on: data.occurrence_on,
        p_completed: !data.completed
      })
      : await c.rpc('complete_deadline_occurrence', {
        p_deadline_id: id,
        p_occurrence_on: data.occurrence_on,
        p_completed: !data.completed
      });
    if (result.error) {
      m.textContent = 'Impossibile aggiornare l’occorrenza.';
      return;
    }
    load();
  };
  box.append(button);
}

document.getElementById('edit-deadline').onclick = async (event) => {
  event.preventDefault();
  if (!isManaged()) {
    location.href = `nuova-scadenza.html?deadline_id=${encodeURIComponent(id)}`;
    return;
  }

  const title = await FamilAreaConfirm.prompt({
    title: 'Modifica scadenza',
    message: 'Aggiorna il titolo della scadenza.',
    confirmText: 'Continua',
    input: { label: 'Titolo', value: d.title, required: true }
  });
  if (title === null) return;
  const notes = await FamilAreaConfirm.prompt({
    title: 'Modifica scadenza',
    message: 'Aggiorna le note della scadenza.',
    confirmText: 'Salva',
    input: { label: 'Note', value: d.notes || '' }
  });
  if (notes === null) return;

  const result = await c.rpc('update_my_managed_deadline', {
    p_member_id: managedMember.id,
    p_deadline_id: id,
    p_title: title,
    p_category: d.category,
    p_first_due_on: d.first_due_on,
    p_recurrence_months: d.recurrence_months,
    p_reminder_days: d.reminder_days,
    p_notes: notes || null
  });
  if (result.error) {
    m.textContent = 'Impossibile aggiornare la scadenza.';
    return;
  }
  load();
};

terminateButton.onclick = () => {
  if (isManaged()) return;
  c.rpc('update_deadline', {
    p_deadline_id: id,
    p_title: d.title,
    p_category: d.category,
    p_first_due_on: d.first_due_on,
    p_recurrence_months: d.recurrence_months,
    p_reminder_days: d.reminder_days,
    p_notes: d.notes,
    p_family_member_id: d.family_member_id || null,
    p_status: 'archived'
  }).then(load);
};

deleteButton.onclick = async () => {
  if (await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: 'Eliminare la scadenza?',
    message: 'L’attività verrà eliminata definitivamente.',
    confirmText: 'Elimina'
  })) {
    if (isManaged()) {
      const result = await c.rpc('delete_my_managed_deadline', {
        p_deadline_id: id,
        p_managed_member_id: managedMember.id
      });
      if (result.error) {
        m.textContent = 'Impossibile eliminare la scadenza.';
        return;
      }
      location.href = managedHref('scadenze.html');
      return;
    }
    await c.rpc('delete_deadline', { p_deadline_id: id });
    location.href = 'scadenze.html';
  }
};

load();

const c = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const id = new URLSearchParams(location.search).get('deadline_id');
const m = document.getElementById('deadline-message');
const formatDateDisplay = window.FamilAreaDateUtils.formatDateDisplay;
let d;

async function load() {
  const { data, error } = await c.rpc('get_deadline', { p_deadline_id: id });
  if (error || !data) {
    m.textContent = 'Scadenza non disponibile.';
    return;
  }
  d = data;
  document.getElementById('deadline-title').textContent = d.title;
  document.getElementById('deadline-subtitle').textContent = formatDateDisplay(d.first_due_on);
  document.getElementById('deadline-status').textContent = d.status;
  document.getElementById('deadline-content').hidden = false;
  m.textContent = '';
  await occurrence();
  await attachments();
}

async function occurrence() {
  const day = d.first_due_on;
  const { data } = await c.rpc('get_deadline_occurrences', { p_from: day, p_to: day });
  const x = (data || [])[0];
  const box = document.getElementById('deadline-occurrences-list');
  box.replaceChildren();
  if (!x) return;
  const b = document.createElement('button');
  b.textContent = x.completed ? 'Annulla completamento' : 'Completa occorrenza';
  b.onclick = async () => {
    const r = await c.rpc('complete_deadline_occurrence', {
      p_deadline_id: id,
      p_occurrence_on: x.occurrence_on,
      p_completed: !x.completed
    });
    if (r.error) {
      m.textContent = 'Impossibile aggiornare l’occorrenza.';
      return;
    }
    load();
  };
  box.append(document.createTextNode(`${formatDateDisplay(x.occurrence_on)} `), b);
}

async function attachments() {
  const { data } = await c.rpc('get_attachments', { p_target_type: 'deadline', p_target_id: id });
  const box = document.getElementById('deadline-attachments-list');
  box.replaceChildren(...(data || []).map((attachment) => {
    const wrap = document.createElement('div');
    const open = document.createElement('button');
    const del = document.createElement('button');
    open.textContent = attachment.original_filename;
    open.onclick = async () => {
      const { data: signed } = await c.storage.from('familarea-attachments').createSignedUrl(attachment.storage_path, 60);
      if (signed?.signedUrl) window.open(signed.signedUrl, '_blank', 'noopener');
    };
    del.textContent = 'Elimina';
    del.onclick = async () => {
      const result = await c.rpc('delete_attachment', { p_attachment_id: attachment.id });
      if (result.error) {
        m.textContent = 'Impossibile eliminare l’allegato.';
        return;
      }
      await c.storage.from('familarea-attachments').remove([attachment.storage_path]);
      attachments();
    };
    wrap.append(open, del);
    return wrap;
  }));
  document.getElementById('deadline-attachments-empty').hidden = (data || []).length > 0;
}

document.getElementById('edit-deadline').onclick = async (event) => {
  event.preventDefault();
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
  c.rpc('update_deadline', {
    p_deadline_id: id,
    p_title: title,
    p_category: d.category,
    p_first_due_on: d.first_due_on,
    p_recurrence_months: d.recurrence_months,
    p_reminder_days: d.reminder_days,
    p_notes: notes || null,
    p_family_member_id: d.family_member_id || null,
    p_status: d.status
  }).then(load);
};

document.getElementById('terminate-deadline').onclick = () => c.rpc('update_deadline', {
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

document.getElementById('delete-deadline').onclick = async () => {
  if (await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: 'Eliminare la scadenza?',
    message: 'L’attività verrà eliminata definitivamente.',
    confirmText: 'Elimina'
  })) {
    await c.rpc('delete_deadline', { p_deadline_id: id });
    location.href = 'scadenze.html';
  }
};

document.getElementById('deadline-attachment-input').onchange = async (event) => {
  const file = event.target.files[0];
  if (!file) return;
  const { data: account } = await c.rpc('get_current_account');
  const path = `attachments/${account.account_id}/deadline/${id}/${crypto.randomUUID()}-${file.name}`;
  const upload = await c.storage.from('familarea-attachments').upload(path, file, { contentType: file.type });
  if (upload.error) return;
  const result = await c.rpc('register_attachment', {
    p_target_type: 'deadline',
    p_target_id: id,
    p_storage_path: path,
    p_original_filename: file.name,
    p_mime_type: file.type,
    p_byte_size: file.size
  });
  if (result.error) await c.storage.from('familarea-attachments').remove([path]);
  attachments();
};

load();

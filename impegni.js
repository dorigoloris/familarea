const commitmentsClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const commitmentsMessage = document.getElementById('commitments-message');
const commitmentsList = document.getElementById('commitments-list');
const commitmentsEmpty = document.getElementById('commitments-empty');

function formatDate(value) {
  if (!value) return 'Data non indicata';
  const [year, month, day] = value.slice(0, 10).split('-').map(Number);
  return new Date(year, month - 1, day).toLocaleDateString('it-IT');
}

function formatEventWhen(event) {
  const start = new Date(event.starts_at);
  const date = start.toLocaleDateString('it-IT');
  if (event.ends_at && formatDate(event.starts_at) !== formatDate(event.ends_at)) {
    return `${date} → ${formatDate(event.ends_at)}`;
  }
  if (event.is_all_day) return date;
  const startTime = start.toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' });
  const endTime = event.ends_at
    ? ` – ${new Date(event.ends_at).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' })}`
    : '';
  return `${date}, ${startTime}${endTime}`;
}

function createCommitmentRow({ title, when, detail, href, label }) {
  const row = document.createElement('a');
  row.className = 'deadline-card deadline-card--with-item-thumbnail';
  row.href = href;
  row.setAttribute('aria-label', label);

  const thumbnail = document.createElement('span');
  thumbnail.className = 'deadline-item-thumbnail';
  thumbnail.setAttribute('aria-hidden', 'true');
  thumbnail.textContent = (title || '').trim().charAt(0).toLocaleUpperCase('it-IT') || 'I';
  const copy = document.createElement('span');
  copy.className = 'deadline-card-main deadline-card-item-copy';
  const heading = document.createElement('span');
  heading.className = 'deadline-card-title';
  heading.textContent = `${when} — ${title}`;
  copy.append(heading);
  if (detail) {
    const metadata = document.createElement('span');
    metadata.className = 'deadline-card-meta';
    metadata.textContent = detail;
    copy.append(metadata);
  }

  const action = document.createElement('span');
  action.className = 'fa-button fa-button-secondary fa-button-compact';
  action.textContent = 'Apri';
  row.append(thumbnail, copy, action);
  return row;
}

function standaloneDeadlineCard(deadline) {
  return createCommitmentRow({
    title: deadline.title,
    when: formatDate(deadline.first_due_on),
    detail: 'Da ricordare',
    href: `scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}`,
    label: `Apri impegno da ricordare ${deadline.title}`
  });
}

function commitmentEventCard(event) {
  return createCommitmentRow({
    title: event.title,
    when: formatEventWhen(event),
    detail: 'Impegno',
    href: `evento.html?event_id=${encodeURIComponent(event.id || event.event_id)}`,
    label: `Apri impegno ${event.title}`
  });
}

function sortByWhen(first, second) {
  return new Date(first.when) - new Date(second.when);
}

async function loadCommitments() {
  const { data: sessionData } = await commitmentsClient.auth.getSession();
  if (!sessionData.session) { window.location.href = 'login.html'; return; }

  const [deadlinesResult, eventsResult] = await Promise.all([
    commitmentsClient.rpc('get_my_deadlines'),
    commitmentsClient.rpc('get_visible_events')
  ]);
  if (deadlinesResult.error || eventsResult.error) {
    commitmentsMessage.textContent = 'Impossibile caricare gli impegni.';
    return;
  }

  // Le deadline storiche restano visibili finché non verranno trattate separatamente.
  // Nuovi Impegni sono invece sempre eventi con event_kind = commitment.
  const standaloneDeadlines = (deadlinesResult.data || []).filter((deadline) => (
    !deadline.deadline_item_id
    && !deadline.family_member_id
    && deadline.category !== 'personal_document'
  ));
  const commitmentEvents = (eventsResult.data || []).filter((event) => event.event_kind === 'commitment');
  const commitments = [
    ...standaloneDeadlines.map((deadline) => ({ when: `${deadline.first_due_on}T00:00:00`, card: standaloneDeadlineCard(deadline) })),
    ...commitmentEvents.map((event) => ({ when: event.starts_at, card: commitmentEventCard(event) }))
  ].sort(sortByWhen);

  commitmentsList.replaceChildren(...commitments.map((commitment) => commitment.card));
  commitmentsEmpty.hidden = commitments.length > 0;
  commitmentsMessage.textContent = '';
}

void loadCommitments();

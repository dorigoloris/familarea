const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const list = document.getElementById('proposals-list');
const empty = document.getElementById('proposals-empty');
const message = document.getElementById('proposals-message');

function formatDate(item) {
  if (!item.starts_at) return 'Data da definire';
  const date = new Date(item.starts_at);
  return item.is_all_day
    ? new Intl.DateTimeFormat('it-IT', { dateStyle: 'long' }).format(date)
    : new Intl.DateTimeFormat('it-IT', { dateStyle: 'long', timeStyle: 'short' }).format(date);
}

function eventLink(item) {
  return `evento.html?event_id=${encodeURIComponent(item.event_id)}&source=suggestion`;
}

function createCard(item) {
  const card = document.createElement('article');
  card.className = 'fa-v2-list-row proposal-row';
  const details = document.createElement('div');
  details.className = 'proposal-details';
  const title = document.createElement('h2');
  title.textContent = item.title;
  const date = document.createElement('p');
  date.textContent = formatDate(item);
  const organizer = document.createElement('p');
  organizer.className = 'proposal-organizer';
  organizer.textContent = item.organizer_name || 'Organizzatore';
  details.append(title, date, organizer);
  if (item.area_name) {
    const area = document.createElement('p');
    area.textContent = item.area_name;
    details.appendChild(area);
  }
  const reasons = document.createElement('p');
  reasons.className = 'proposal-reasons';
  const reasonLabel = document.createElement('strong');
  reasonLabel.textContent = 'Ti interessa perché: ';
  reasons.append(reasonLabel, document.createTextNode((item.matching_interests || []).map((interest) => interest.display_name).join(' · ')));
  details.appendChild(reasons);

  const actions = document.createElement('div');
  actions.className = 'proposal-actions';
  const view = document.createElement('a');
  view.className = 'fa-button fa-button-secondary fa-button-compact';
  view.href = eventLink(item);
  view.textContent = 'Vedi evento';
  const join = document.createElement('button');
  join.type = 'button';
  join.className = 'fa-button fa-button-primary fa-button-compact';
  join.textContent = 'Partecipa';
  join.addEventListener('click', async () => {
    join.disabled = true;
    message.textContent = 'Registrazione della partecipazione...';
    const { error } = await supabaseClient.rpc('join_suggested_event', { p_event_id: item.event_id });
    if (error) {
      message.textContent = error.message?.includes('Contact')
        ? 'Per partecipare serve un Contatto già collegato dall’organizzatore. Chiedigli di invitarti direttamente.'
        : 'Non è stato possibile registrare la partecipazione. Aggiorna la pagina e riprova.';
      join.disabled = false;
      return;
    }
    await loadProposals('Partecipazione registrata.');
  });
  actions.append(view, join);
  card.append(details, actions);
  return card;
}

async function loadProposals(successMessage = '') {
  const { data: session } = await supabaseClient.auth.getSession();
  if (!session.session) { location.href = 'login.html'; return; }
  const { data, error } = await supabaseClient.rpc('get_my_event_suggestions');
  if (error) {
    message.textContent = 'Impossibile caricare le proposte. Riprova più tardi.';
    return;
  }
  const proposals = data || [];
  list.replaceChildren(...proposals.map(createCard));
  list.hidden = proposals.length === 0;
  empty.hidden = proposals.length > 0;
  message.textContent = successMessage;
}

loadProposals();

const c = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const m = document.getElementById('deadlines-message');
const list = document.getElementById('active-deadlines-list');
const contextContainer = document.getElementById('managed-context');
const formatDateDisplay = window.FamilAreaDateUtils.formatDateDisplay;
const deadlineItemImageService = window.FamilAreaDeadlineItemImage;
const deadlineListToggle = document.getElementById('deadline-list-toggle');
const deadlineListToggleButton = document.getElementById('deadline-list-toggle-button');
const initialDeadlineLimit = 5;
let loadedDeadlines = [];
let loadedDeadlineContext = { isManaged: false, member: null };

async function openHomeItem(event) {
  event.preventDefault();
  const { data, error } = await c.rpc('ensure_my_home_item');
  if (error || !data?.id) { m.textContent = 'Impossibile aprire Casa.'; return; }
  location.href = `gestione-scadenza-item.html?item_id=${encodeURIComponent(data.id)}`;
}

function deadlineRow(deadline, isManaged, member) {
  const item = document.createElement('a');
  item.href = isManaged ? window.FamilAreaManagedContext.withMember(`scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}`, member.id) : `scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}`;
  item.className = 'deadline-card deadline-card--with-item-thumbnail';
  const thumbnail = document.createElement('span');
  thumbnail.className = 'deadline-item-thumbnail';
  const thumbnailName = deadline.deadline_item_name || deadline.title || 'Scadenza';
  thumbnail.setAttribute('aria-label', `Miniatura di ${thumbnailName}`);
  thumbnail.textContent = thumbnailName.trim().charAt(0).toLocaleUpperCase('it-IT');
  if (deadline.deadline_item_image_path) void deadlineItemImageService.render(thumbnail, deadline.deadline_item_image_path, `Foto di ${thumbnailName}`);
  const copy = document.createElement('span'); copy.className = 'deadline-card-item-copy'; copy.textContent = `${formatDateDisplay(deadline.first_due_on)} — ${deadline.title}`;
  item.append(thumbnail, copy);
  return item;
}

function renderDeadlineRows() {
  const isExpanded = deadlineListToggleButton.getAttribute('aria-expanded') === 'true';
  const visibleRows = isExpanded ? loadedDeadlines : loadedDeadlines.slice(0, initialDeadlineLimit);
  list.replaceChildren(...visibleRows.map((deadline) => deadlineRow(
    deadline,
    loadedDeadlineContext.isManaged,
    loadedDeadlineContext.member
  )));
  deadlineListToggle.hidden = loadedDeadlines.length <= initialDeadlineLimit;
  deadlineListToggleButton.replaceChildren(
    document.createTextNode(isExpanded ? 'Mostra meno ' : 'Vedi tutte '),
    Object.assign(document.createElement('span'), { textContent: isExpanded ? '↑' : '↓', ariaHidden: 'true' })
  );
}

deadlineListToggleButton.addEventListener('click', () => {
  const isExpanded = deadlineListToggleButton.getAttribute('aria-expanded') === 'true';
  deadlineListToggleButton.setAttribute('aria-expanded', String(!isExpanded));
  renderDeadlineRows();
});

async function load() {
  if (window.FamilAreaDeadlineManagementReady && !await window.FamilAreaDeadlineManagementReady) return;
  document.getElementById('home-category-link').addEventListener('click', openHomeItem);
  const context = await window.FamilAreaManagedContext.load();
  const isManaged = Boolean(context.member);
  if (context.requested && !isManaged) m.textContent = 'Il membro selezionato non è gestibile dalla tua Famiglia. Stai visualizzando le tue scadenze personali.';
  if (isManaged) {
    contextContainer.hidden = false; window.FamilAreaManagedContext.renderBar(contextContainer, context.member);
    document.getElementById('documents-category-link').href = window.FamilAreaManagedContext.withMember('gestione-scadenze-documenti.html', context.member.id);
  }
  const { data, error } = isManaged ? await c.rpc('get_my_deadlines_for_managed_member', { p_member_id: context.member.id }) : await c.rpc('get_my_deadlines');
  if (error) { m.textContent = 'Impossibile caricare le scadenze.'; return; }
  loadedDeadlines = data || [];
  loadedDeadlineContext = { isManaged, member: context.member };
  deadlineListToggleButton.setAttribute('aria-expanded', 'false');
  const empty = document.getElementById('deadlines-empty'); empty.hidden = loadedDeadlines.length > 0; empty.replaceChildren();
  if (!loadedDeadlines.length) { const strong = document.createElement('strong'); strong.textContent = isManaged ? `Nessuna scadenza per ${window.FamilAreaManagedContext.memberName(context.member)}.` : 'Nessuna scadenza ancora.'; empty.append(strong); }
  document.getElementById('active-deadlines-section').hidden = !loadedDeadlines.length;
  renderDeadlineRows();
  if (!context.requested || isManaged) m.textContent = '';
}
load();

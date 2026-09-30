const c = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const m = document.getElementById('deadlines-message');
const list = document.getElementById('active-deadlines-list');
const contextContainer = document.getElementById('managed-context');
const formatDateDisplay = window.FamilAreaDateUtils.formatDateDisplay;
const deadlineItemImageService = window.FamilAreaDeadlineItemImage;

async function openHomeItem(event) {
  event.preventDefault();
  const { data, error } = await c.rpc('ensure_my_home_item');
  if (error || !data?.id) { m.textContent = 'Impossibile aprire Casa.'; return; }
  location.href = `gestione-scadenza-item.html?item_id=${encodeURIComponent(data.id)}`;
}

function deadlineRow(deadline, isManaged, member) {
  const item = document.createElement('a');
  item.href = isManaged ? window.FamilAreaManagedContext.withMember(`scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}`, member.id) : `scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}`;
  item.className = 'deadline-card';
  if (!deadline.deadline_item_id) { item.textContent = `${deadline.title} — ${formatDateDisplay(deadline.first_due_on)}`; return item; }
  item.classList.add('deadline-card--with-item-thumbnail');
  const thumbnail = document.createElement('span');
  thumbnail.className = 'deadline-item-thumbnail';
  const itemName = deadline.deadline_item_name || 'Elemento';
  thumbnail.setAttribute('aria-label', `Foto di ${itemName}`);
  thumbnail.textContent = itemName.trim().charAt(0).toLocaleUpperCase('it-IT');
  if (deadline.deadline_item_image_path) void deadlineItemImageService.render(thumbnail, deadline.deadline_item_image_path, `Foto di ${itemName}`);
  const copy = document.createElement('span'); copy.className = 'deadline-card-item-copy'; copy.textContent = `${deadline.title} — ${formatDateDisplay(deadline.first_due_on)}`;
  item.append(thumbnail, copy);
  return item;
}

async function load() {
  if (window.FamilAreaDeadlineManagementReady && !await window.FamilAreaDeadlineManagementReady) return;
  document.getElementById('home-category-link').addEventListener('click', openHomeItem);
  const context = await window.FamilAreaManagedContext.load();
  const isManaged = Boolean(context.member);
  if (context.requested && !isManaged) m.textContent = 'Il membro selezionato non è gestibile dalla tua Famiglia. Stai visualizzando le tue scadenze personali.';
  if (isManaged) {
    contextContainer.hidden = false; window.FamilAreaManagedContext.renderBar(contextContainer, context.member);
    const newDeadline = document.getElementById('new-deadline-link'); newDeadline.href = window.FamilAreaManagedContext.withMember('nuova-scadenza.html', context.member.id); newDeadline.hidden = false;
  }
  const { data, error } = isManaged ? await c.rpc('get_my_deadlines_for_managed_member', { p_member_id: context.member.id }) : await c.rpc('get_my_deadlines');
  if (error) { m.textContent = 'Impossibile caricare le scadenze.'; return; }
  const rows = data || []; const empty = document.getElementById('deadlines-empty'); empty.hidden = rows.length > 0; empty.replaceChildren();
  if (!rows.length) { const strong = document.createElement('strong'); strong.textContent = isManaged ? `Nessuna scadenza per ${window.FamilAreaManagedContext.memberName(context.member)}.` : 'Nessuna scadenza ancora.'; empty.append(strong); }
  document.getElementById('active-deadlines-section').hidden = !rows.length;
  list.replaceChildren(...rows.map((deadline) => deadlineRow(deadline, isManaged, context.member)));
  if (!context.requested || isManaged) m.textContent = '';
}
load();

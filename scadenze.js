const c = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const m = document.getElementById('deadlines-message');
const list = document.getElementById('active-deadlines-list');
const contextContainer = document.getElementById('managed-context');
const formatDateDisplay = window.FamilAreaDateUtils.formatDateDisplay;

async function load() {
  const context = await window.FamilAreaManagedContext.load();
  const isManaged = Boolean(context.member);

  if (context.requested && !isManaged) {
    m.textContent = 'Il membro selezionato non è gestibile dalla tua Famiglia. Stai visualizzando le tue scadenze personali.';
  }

  if (isManaged) {
    contextContainer.hidden = false;
    window.FamilAreaManagedContext.renderBar(contextContainer, context.member);
    const newDeadline = document.querySelector('.fa-section-hero-action');
    newDeadline.href = window.FamilAreaManagedContext.withMember('nuova-scadenza.html', context.member.id);
    newDeadline.hidden = false;
  }

  const { data, error } = isManaged
    ? await c.rpc('get_my_deadlines_for_managed_member', { p_member_id: context.member.id })
    : await c.rpc('get_my_deadlines');
  if (error) {
    m.textContent = 'Impossibile caricare le scadenze.';
    return;
  }

  const rows = data || [];
  const empty = document.getElementById('deadlines-empty');
  empty.hidden = rows.length > 0;
  empty.replaceChildren();
  if (!rows.length) {
    const strong = document.createElement('strong');
    strong.textContent = isManaged
      ? `Nessuna scadenza per ${window.FamilAreaManagedContext.memberName(context.member)}.`
      : 'Nessuna scadenza ancora.';
    empty.append(strong);
  }

  document.getElementById('active-deadlines-section').hidden = !rows.length;
  list.replaceChildren(...rows.map((deadline) => {
    const item = document.createElement(isManaged ? 'span' : 'a');
    if (!isManaged) item.href = `scadenza.html?deadline_id=${encodeURIComponent(deadline.id)}`;
    item.className = 'deadline-card';
    item.textContent = `${deadline.title} — ${formatDateDisplay(deadline.first_due_on)}`;
    return item;
  }));

  if (!context.requested || isManaged) m.textContent = '';
}

load();

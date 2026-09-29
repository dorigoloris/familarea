const c = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const f = document.getElementById('deadline-form');
const m = document.getElementById('deadline-form-message');
const familyMemberField = document.getElementById('deadline-family-member-field');
const managedMemberField = document.getElementById('deadline-managed-member');
const deadlineItemField = document.getElementById('deadline-item-context');
const referenceField = document.getElementById('deadline-reference-field');
const contextContainer = document.getElementById('managed-context');
const backLink = document.getElementById('deadline-back-link');
const cancelLink = document.getElementById('deadline-cancel-link');
let managedMember = null;
let deadlineItem = null;
const requestedDeadlineItemId = new URLSearchParams(window.location.search).get('deadline_item_id');

function managedHref(path) {
  return managedMember
    ? window.FamilAreaManagedContext.withMember(path, managedMember.id)
    : path;
}

function deadlineItemHref(itemId) {
  return `gestione-scadenza-item.html?item_id=${encodeURIComponent(itemId)}`;
}

async function init() {
  const context = await window.FamilAreaManagedContext.load();
  if (context.requested && !context.member) {
    m.textContent = 'Il membro selezionato non è gestibile dalla tua Famiglia. Stai creando una scadenza personale.';
  }

  const { data: account, error } = await c.rpc('get_current_account');
  if (error) {
    console.error('get_current_account failed while configuring deadline form', error);
    m.textContent = 'Impossibile preparare il modulo.';
    return;
  }

  if (context.member) {
    managedMember = context.member;
    contextContainer.hidden = false;
    window.FamilAreaManagedContext.renderBar(contextContainer, managedMember);
    managedMemberField.hidden = false;
    managedMemberField.textContent = `Riferita a: ${window.FamilAreaManagedContext.memberName(managedMember)}`;
    familyMemberField.hidden = true;
    backLink.href = managedHref('scadenze.html');
    cancelLink.href = managedHref('scadenze.html');
  } else {
    familyMemberField.hidden = account?.account_type === 'organization';

    if (requestedDeadlineItemId) {
      const { data: item, error: itemError } = await c.rpc('get_my_deadline_item', {
        p_item_id: requestedDeadlineItemId
      });
      if (itemError || !item || item.category !== 'vehicle') {
        m.textContent = 'Veicolo non disponibile. Stai creando una scadenza normale.';
      } else {
        deadlineItem = item;
        deadlineItemField.hidden = false;
        deadlineItemField.textContent = `Veicolo: ${item.name}`;
        referenceField.hidden = true;
        familyMemberField.hidden = true;
        document.getElementById('deadline-title').setAttribute('list', 'vehicle-deadline-suggestions');
        backLink.href = deadlineItemHref(item.id);
        cancelLink.href = backLink.href;
      }
    }
  }

  f.hidden = false;
  if (context.member || (!context.requested && !requestedDeadlineItemId) || deadlineItem) m.textContent = '';
}

f.onsubmit = async (event) => {
  event.preventDefault();
  const commonParams = {
    p_title: document.getElementById('deadline-title').value.trim(),
    p_category: document.getElementById('deadline-category').value,
    p_first_due_on: document.getElementById('deadline-first-due-on').value,
    p_recurrence_months: Number(document.getElementById('deadline-recurrence').value) || null,
    p_reminder_days: Number(document.getElementById('deadline-reminder').value),
    p_notes: document.getElementById('deadline-notes').value.trim() || null
  };
  const { data, error } = deadlineItem
    ? await c.rpc('create_deadline_for_item', { p_item_id: deadlineItem.id, ...commonParams })
    : await c.rpc('create_deadline', {
      ...commonParams,
      p_family_member_id: managedMember
        ? managedMember.id
        : (familyMemberField.hidden ? null : (document.getElementById('deadline-family-member').value || null))
    });
  if (error) {
    m.textContent = 'Impossibile creare la scadenza.';
    return;
  }

  location.href = deadlineItem
    ? deadlineItemHref(deadlineItem.id)
    : (managedMember
      ? managedHref('scadenze.html')
      : `scadenza.html?deadline_id=${encodeURIComponent(data)}`);
};

init();

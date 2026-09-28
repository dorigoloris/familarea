const c = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const f = document.getElementById('deadline-form');
const m = document.getElementById('deadline-form-message');
const familyMemberField = document.getElementById('deadline-family-member-field');
const managedMemberField = document.getElementById('deadline-managed-member');
const contextContainer = document.getElementById('managed-context');
const backLink = document.getElementById('deadline-back-link');
const cancelLink = document.getElementById('deadline-cancel-link');
let managedMember = null;

function managedHref(path) {
  return managedMember
    ? window.FamilAreaManagedContext.withMember(path, managedMember.id)
    : path;
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
  }

  f.hidden = false;
  if (!context.requested || context.member) m.textContent = '';
}

f.onsubmit = async (event) => {
  event.preventDefault();
  const { data, error } = await c.rpc('create_deadline', {
    p_title: document.getElementById('deadline-title').value.trim(),
    p_category: document.getElementById('deadline-category').value,
    p_first_due_on: document.getElementById('deadline-first-due-on').value,
    p_recurrence_months: Number(document.getElementById('deadline-recurrence').value) || null,
    p_reminder_days: Number(document.getElementById('deadline-reminder').value),
    p_notes: document.getElementById('deadline-notes').value.trim() || null,
    p_family_member_id: managedMember
      ? managedMember.id
      : (familyMemberField.hidden ? null : (document.getElementById('deadline-family-member').value || null))
  });
  if (error) {
    m.textContent = 'Impossibile creare la scadenza.';
    return;
  }

  location.href = managedMember
    ? managedHref('scadenze.html')
    : `scadenza.html?deadline_id=${encodeURIComponent(data)}`;
};

init();

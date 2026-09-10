const deadlineFormClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const deadlineForm = document.getElementById('deadline-form');
const deadlineFormMessage = document.getElementById('deadline-form-message');
const deadlineSubmit = document.getElementById('deadline-submit');
const deadlineId = new URLSearchParams(window.location.search).get('deadline_id');
let isTerminatedDeadline = false;
const input = (id) => document.getElementById(id);
function memberName(member) { return `${member.first_name || ''} ${member.last_name || ''}`.trim() || (member.member_type === 'pet' ? 'Animale domestico' : 'Membro Famiglia'); }
function readableError(error, fallback) { const text = String(error?.message || ''); if (text.includes('data base o ricorrenza')) return 'Non puoi modificare data o ricorrenza dopo una conferma. Termina la serie e crea una nuova scadenza.'; if (text.includes('Famiglia')) return 'Il membro Famiglia selezionato non è disponibile.'; return fallback; }
function payload() { return { p_title: input('deadline-title').value.trim(), p_category: input('deadline-category').value, p_first_due_on: input('deadline-first-due-on').value || null, p_reference: input('deadline-reference').value.trim() || null, p_family_member_id: input('deadline-family-member').value || null, p_recurrence_months: input('deadline-recurrence').value ? Number(input('deadline-recurrence').value) : null, p_reminder_days: Number(input('deadline-reminder').value), p_notes: input('deadline-notes').value.trim() || null }; }
async function load() {
  const { data: sessionData } = await deadlineFormClient.auth.getSession(); if (!sessionData.session) { window.location.href = 'login.html'; return; }
  const { data: members, error: membersError } = await deadlineFormClient.rpc('get_my_family_members');
  if (!membersError) (members || []).forEach((member) => { const option = document.createElement('option'); option.value = member.id; option.textContent = memberName(member); input('deadline-family-member').appendChild(option); });
  if (deadlineId) {
    document.title = 'Modifica scadenza - FamilArea'; input('deadline-form-title').textContent = 'Modifica scadenza'; input('deadline-form-intro').textContent = 'Aggiorna le informazioni della tua scadenza.'; deadlineSubmit.textContent = 'Salva modifiche';
    const { data, error } = await deadlineFormClient.rpc('get_my_deadline', { p_deadline_id: deadlineId }); const deadline = data?.[0];
    if (error || !deadline) { deadlineFormMessage.textContent = 'Scadenza non trovata o non accessibile.'; return; }
    input('deadline-title').value = deadline.title || ''; input('deadline-category').value = deadline.category; input('deadline-reference').value = deadline.reference || ''; input('deadline-family-member').value = deadline.family_member_id || ''; input('deadline-first-due-on').value = deadline.first_due_on; input('deadline-recurrence').value = deadline.recurrence_months || ''; input('deadline-reminder').value = String(deadline.reminder_days); input('deadline-notes').value = deadline.notes || '';
    isTerminatedDeadline = deadline.status === 'terminated';
    if (isTerminatedDeadline) { Array.from(deadlineForm.elements).forEach((element) => { element.disabled = true; }); deadlineFormMessage.textContent = 'Le scadenze terminate restano consultabili ma non possono essere modificate.'; }
  }
  deadlineForm.hidden = false; if (!isTerminatedDeadline) deadlineFormMessage.textContent = membersError ? 'I membri Famiglia non sono disponibili al momento.' : '';
}
deadlineForm.addEventListener('submit', async (event) => { event.preventDefault(); if (isTerminatedDeadline) return; const values = payload(); if (!values.p_title || !values.p_first_due_on) { deadlineFormMessage.textContent = 'Compila titolo, categoria e data della prima scadenza.'; return; } deadlineSubmit.disabled = true; deadlineFormMessage.textContent = deadlineId ? 'Salvataggio...' : 'Creazione...'; try { const result = deadlineId ? await deadlineFormClient.rpc('update_my_deadline', { p_deadline_id: deadlineId, ...values }) : await deadlineFormClient.rpc('create_my_deadline', values); if (result.error) throw result.error; const target = deadlineId || result.data; window.location.href = `scadenza.html?deadline_id=${encodeURIComponent(target)}`; } catch (error) { deadlineFormMessage.textContent = readableError(error, deadlineId ? 'Non è stato possibile salvare le modifiche. Riprova.' : 'Non è stato possibile creare la scadenza. Riprova.'); } finally { deadlineSubmit.disabled = false; } });
load().catch(() => { deadlineFormMessage.textContent = 'Non è stato possibile preparare il modulo. Riprova.'; });

const eventInviteClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const eventInviteToken = new URLSearchParams(location.search).get('token');
const eventInviteMessage = document.getElementById('event-invite-message');
const eventInviteActions = document.getElementById('event-invite-actions');

async function respondEventInvite(rpc) {
  const { error } = await eventInviteClient.rpc(rpc, { p_token: eventInviteToken });
  if (error) { eventInviteMessage.textContent = error.message || 'Impossibile completare l’invito.'; return; }
  eventInviteActions.hidden = true;
  eventInviteMessage.textContent = rpc === 'accept_event_invite' ? 'Invito accettato.' : 'Invito rifiutato.';
}

(async () => {
  const { data: { session } } = await eventInviteClient.auth.getSession();
  if (!eventInviteToken) { eventInviteMessage.textContent = 'Invito non valido.'; return; }
  if (!session) { location.href = `login.html?return_to=${encodeURIComponent(location.pathname + location.search)}`; return; }
  eventInviteMessage.textContent = 'Vuoi partecipare a questa attività?';
  eventInviteActions.hidden = false;
})();
document.getElementById('accept-event-invite').addEventListener('click', () => void respondEventInvite('accept_event_invite'));
document.getElementById('decline-event-invite').addEventListener('click', () => void respondEventInvite('decline_event_invite'));

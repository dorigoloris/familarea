const c = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const m = document.getElementById('message');
const pending = document.getElementById('pending');
const backLink = document.getElementById('share-contact-back');
const description = document.getElementById('share-contact-description');

const msg = (error) => {
  const text = (error?.message || '').toLowerCase();
  return text.includes('verified')
    ? 'Devi prima verificare l’email del tuo account.'
    : text.includes('own email')
      ? 'Non puoi inviare un invito alla tua stessa email.'
      : 'Non è stato possibile inviare l’invito.';
};

function renderPendingEmpty() {
  const empty = document.createElement('p');
  empty.className = 'fa-v2-empty-state';
  const text = document.createElement('strong');
  text.textContent = 'Nessun invito inviato.';
  empty.appendChild(text);
  pending.replaceChildren(empty);
}

function createPendingShareRow(share) {
  const row = document.createElement('div');
  row.className = 'fa-v2-list-row fa-v2-content-action-row';
  const details = document.createElement('span');
  details.textContent = `${share.recipient_email} — scade ${new Date(share.expires_at).toLocaleDateString('it-IT')}`;
  const revoke = document.createElement('button');
  revoke.type = 'button';
  revoke.className = 'fa-v2-button fa-v2-button--danger';
  revoke.textContent = 'Annulla invito';
  revoke.onclick = async () => {
    revoke.disabled = true;
    const result = await c.rpc('revoke_contact_share', { p_share_id: share.share_id });
    if (result.error) {
      revoke.disabled = false;
      m.textContent = 'Impossibile annullare l’invito.';
      return;
    }
    m.textContent = 'Invito annullato.';
    await load();
  };
  row.append(details, revoke);
  return row;
}

async function load() {
  const { data: { session } } = await c.auth.getSession();
  if (!session) {
    location.href = `login.html?return_to=${encodeURIComponent('condividi-contatto.html')}`;
    return;
  }
  const { data: account, error: accountError } = await c.rpc('get_current_account');
  if (accountError || !account?.account_id) {
    pending.textContent = 'Impossibile caricare gli inviti inviati.';
    return;
  }
  if (account.account_type === 'organization') {
    backLink.href = 'impostazioni.html';
    backLink.textContent = 'Torna alle Impostazioni';
  }
  const { data: identity, error: identityError } = await c.rpc('get_my_contact_share_identity');
  if (identityError || !identity?.display_name || !identity?.email) {
    pending.textContent = 'Impossibile caricare il tuo contatto.';
    return;
  }
  description.textContent = `Stai condividendo: ${identity.display_name} — ${identity.email}.`;
  const { data, error } = await c.rpc('get_my_pending_contact_shares');
  if (error) {
    pending.textContent = 'Impossibile caricare gli inviti inviati.';
    return;
  }
  const shares = data || [];
  if (!shares.length) {
    renderPendingEmpty();
    return;
  }
  pending.replaceChildren(...shares.map(createPendingShareRow));
}

document.getElementById('share-form').onsubmit = async (event) => {
  event.preventDefault();
  const submit = event.submitter;
  if (submit) submit.disabled = true;
  m.textContent = 'Invio invito…';
  const { error } = await c.rpc('create_contact_share', {
    p_recipient_email: document.getElementById('recipient-email').value.trim()
  });
  if (error) {
    if (submit) submit.disabled = false;
    m.textContent = msg(error);
    return;
  }
  document.getElementById('recipient-email').value = '';
  m.textContent = 'Invito inviato.';
  await load();
  if (submit) submit.disabled = false;
};

load();

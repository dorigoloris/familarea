const c = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const m = document.getElementById('message');
const pending = document.getElementById('pending');

const msg = (error) => {
  const text = (error?.message || '').toLowerCase();
  return text.includes('verified')
    ? 'Devi prima verificare l’email del tuo account.'
    : text.includes('own email')
      ? 'Non puoi condividere il contatto con la tua stessa email.'
      : 'Non è stato possibile creare il link.';
};

function renderPendingEmpty() {
  const empty = document.createElement('p');
  empty.className = 'fa-v2-empty-state';
  const text = document.createElement('strong');
  text.textContent = 'Nessun link in attesa.';
  empty.appendChild(text);
  pending.replaceChildren(empty);
}

function createPendingShareRow(share) {
  const row = document.createElement('div');
  row.className = 'fa-v2-list-row';
  const details = document.createElement('span');
  details.textContent = `${share.recipient_email} — scade ${new Date(share.expires_at).toLocaleDateString('it-IT')} `;
  const revoke = document.createElement('button');
  revoke.type = 'button';
  revoke.className = 'fa-v2-button fa-v2-button--danger';
  revoke.textContent = 'Revoca';
  revoke.onclick = async () => {
    const result = await c.rpc('revoke_contact_share', { p_share_id: share.share_id });
    if (result.error) m.textContent = 'Impossibile revocare il link.';
    else load();
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
  const { data, error } = await c.rpc('get_my_pending_contact_shares');
  if (error) {
    pending.textContent = 'Impossibile caricare i link.';
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
  m.textContent = 'Creazione link…';
  const { data, error } = await c.rpc('create_contact_share', {
    p_recipient_email: document.getElementById('recipient-email').value.trim()
  });
  if (error) {
    m.textContent = msg(error);
    return;
  }
  const url = new URL('contatto-condiviso.html', location.href);
  url.searchParams.set('token', data.token);
  document.getElementById('share-link').value = url.toString();
  document.getElementById('created').hidden = false;
  m.textContent = '';
  load();
};

document.getElementById('copy-link').onclick = async () => {
  const value = document.getElementById('share-link').value;
  try {
    await navigator.clipboard.writeText(value);
    m.textContent = 'Link copiato.';
  } catch {
    document.getElementById('share-link').select();
    document.execCommand('copy');
    m.textContent = 'Link copiato.';
  }
};

load();

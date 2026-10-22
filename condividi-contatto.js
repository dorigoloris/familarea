const c = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const m = document.getElementById('message');
const backLink = document.getElementById('share-contact-back');
const description = document.getElementById('share-contact-description');
const form = document.getElementById('share-form');
const nameInput = document.getElementById('recipient-name');
const emailInput = document.getElementById('recipient-email');

const msg = (error) => {
  const text = (error?.message || '').toLowerCase();
  return text.includes('verified')
    ? 'Devi prima verificare l email del tuo account.'
    : text.includes('own email')
      ? 'Non puoi inviare un invito alla tua stessa email.'
      : 'Non e stato possibile completare l invito.';
};

function normalizeEmail(value) {
  return value.trim().toLowerCase();
}

async function findContactByEmail(email) {
  const { data: contacts, error } = await c.rpc('get_my_contacts');
  if (error) throw error;

  const target = normalizeEmail(email);
  for (const contact of contacts || []) {
    const { data, error: contactError } = await c.rpc('get_contact', { p_contact_id: contact.id });
    if (contactError) throw contactError;
    const hasEmail = (data?.methods || []).some((method) => (
      (method.method_type || method.type) === 'email'
      && normalizeEmail(method.value || '') === target
    ));
    if (hasEmail) return contact.id;
  }
  return null;
}

async function createContact(name, email) {
  const { data: contactId, error: contactError } = await c.rpc('create_contact', {
    p_first_name: name,
    p_last_name: null,
    p_birth_date: null
  });
  if (contactError) throw contactError;

  const { error: methodsError } = await c.rpc('replace_contact_methods', {
    p_contact_id: contactId,
    p_methods: [{ type: 'email', value: email, is_primary: true }]
  });
  if (methodsError) throw methodsError;
  return contactId;
}

async function load() {
  const { data: { session } } = await c.auth.getSession();
  if (!session) {
    location.href = `login.html?return_to=${encodeURIComponent('condividi-contatto.html')}`;
    return;
  }

  const { data: account, error: accountError } = await c.rpc('get_current_account');
  if (accountError || !account?.account_id) {
    m.textContent = 'Impossibile caricare il tuo account.';
    return;
  }
  if (account.account_type === 'organization') {
    backLink.href = 'impostazioni.html';
    backLink.textContent = 'Torna alle Impostazioni';
    form.hidden = true;
    m.textContent = 'Gli inviti dalla rubrica sono disponibili per gli account personali.';
    return;
  }

  const { data: identity, error: identityError } = await c.rpc('get_my_contact_share_identity');
  if (identityError || !identity?.display_name || !identity?.email) {
    m.textContent = 'Impossibile caricare il tuo account.';
    return;
  }
  description.textContent = `Invia un invito a FamilArea a nome di ${identity.display_name}. L amico verra aggiunto alla tua rubrica.`;
}

form.onsubmit = async (event) => {
  event.preventDefault();
  const submit = event.submitter;
  if (submit) submit.disabled = true;

  const name = nameInput.value.trim();
  const email = normalizeEmail(emailInput.value);
  try {
    m.textContent = 'Verifica del contatto...';
    let contactId = await findContactByEmail(email);
    const contactWasCreated = !contactId;
    if (!contactId) {
      m.textContent = 'Aggiunta del contatto alla rubrica...';
      contactId = await createContact(name, email);
    }

    m.textContent = 'Invio invito...';
    const { error } = await c.functions.invoke('send-contact-connection-invite', {
      body: { contact_id: contactId }
    });
    if (error) {
      m.textContent = contactWasCreated
        ? 'Contatto aggiunto alla rubrica, ma non e stato possibile inviare l email. Riprova tra poco.'
        : 'Non e stato possibile inviare l email. Riprova tra poco.';
      return;
    }

    form.reset();
    m.textContent = contactWasCreated
      ? 'Contatto aggiunto alla rubrica e richiesta di invio accettata dal servizio email.'
      : 'Contatto gia presente: richiesta di invio accettata dal servizio email.';
  } catch (error) {
    console.error(error);
    m.textContent = msg(error);
  } finally {
    if (submit) submit.disabled = false;
  }
};

load();

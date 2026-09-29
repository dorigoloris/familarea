const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const form = document.getElementById('contact-form');
const message = document.getElementById('message');
const emailInput = document.getElementById('email');
const saveButton = document.getElementById('save-button');
const saveAndInviteButton = document.getElementById('save-and-invite-button');

function canInvite() {
  return Boolean(emailInput.value.trim()) && emailInput.validity.valid;
}

function syncInviteAvailability() {
  saveAndInviteButton.disabled = !canInvite();
}

function contactMethods(email, phone) {
  return [
    email && { type: 'email', value: email, is_primary: true },
    phone && { type: 'phone', value: phone, is_primary: !email }
  ].filter(Boolean);
}

async function createContact() {
  const firstName = document.getElementById('first-name').value.trim();
  const lastName = document.getElementById('last-name').value.trim() || null;
  const birthDate = document.getElementById('birth-date').value || null;
  const email = emailInput.value.trim();
  const phone = document.getElementById('phone').value.trim();

  if (!firstName) throw new Error('missing-first-name');

  const { data: contactId, error: contactError } = await supabaseClient.rpc('create_contact', {
    p_first_name: firstName,
    p_last_name: lastName,
    p_birth_date: birthDate
  });
  if (contactError) throw contactError;

  const methods = contactMethods(email, phone);
  if (methods.length) {
    const { error: methodsError } = await supabaseClient.rpc('replace_contact_methods', {
      p_contact_id: contactId,
      p_methods: methods
    });
    if (methodsError) throw Object.assign(methodsError, { contactId, methodsError: true });
  }
  return { contactId };
}

async function requestInvitation(contactId) {
  const { error } = await supabaseClient.functions.invoke('send-contact-registration-invite', {
    body: { contact_id: contactId }
  });
  if (error) throw error;
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const invite = event.submitter === saveAndInviteButton;
  if (invite && !canInvite()) return;

  saveButton.disabled = true;
  saveAndInviteButton.disabled = true;
  message.textContent = invite ? 'Salvataggio e invio invito in corso…' : 'Salvataggio in corso…';

  try {
    const { contactId } = await createContact();
    if (!invite) {
      location.href = `contatto.html?contact_id=${encodeURIComponent(contactId)}`;
      return;
    }

    try {
      await requestInvitation(contactId);
      location.href = `contatto.html?contact_id=${encodeURIComponent(contactId)}`;
    } catch (inviteError) {
      console.error('send-contact-registration-invite failed', inviteError);
      message.textContent = 'Contatto salvato, ma non è stato possibile inviare l’invito.';
      const link = document.getElementById('open-contact-link');
      link.href = `contatto.html?contact_id=${encodeURIComponent(contactId)}`;
      link.hidden = false;
    }
  } catch (error) {
    console.error('create contact failed', error);
    message.textContent = error?.methodsError
      ? 'Contatto creato, ma metodi non salvati.'
      : error?.message === 'missing-first-name'
        ? 'Inserisci il nome.'
        : 'Impossibile creare il contatto. Riprova.';
  } finally {
    saveButton.disabled = false;
    syncInviteAvailability();
  }
});

emailInput.addEventListener('input', syncInviteAvailability);
emailInput.addEventListener('change', syncInviteAvailability);
syncInviteAvailability();

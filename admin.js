(function () {
  const client = window.FamilAreaSupabaseClient;
  const message = document.getElementById('admin-message');
  const content = document.getElementById('admin-content');
  const metrics = document.getElementById('admin-metrics');
  const accountsList = document.getElementById('admin-accounts-list');
  const accountsSummary = document.getElementById('admin-accounts-summary');
  const searchForm = document.getElementById('admin-search-form');
  const searchInput = document.getElementById('admin-search');
  const detail = document.getElementById('admin-account-detail');
  const detailTitle = document.getElementById('admin-account-detail-title');
  const detailSummary = document.getElementById('admin-account-summary');
  const accountEditor = document.getElementById('admin-account-editor');
  const accountDelete = document.getElementById('admin-account-delete');
  const dependencies = document.getElementById('admin-account-dependencies');
  const closeDetail = document.getElementById('admin-detail-close');
  let currentAccountId = null;
  let currentAdminUserId = null;

  if (!client) {
    message.textContent = 'Impossibile inizializzare l’area amministrativa.';
    return;
  }

  const metricLabels = [
    ['accounts', 'Account'], ['profiles', 'Profili'], ['organizations', 'Organizzazioni'],
    ['areas', 'Aree'], ['activities', 'Attività'], ['events', 'Eventi'],
    ['contacts', 'Contatti'], ['area_memberships', 'Area Membership'],
    ['event_participants', 'Event Participants'], ['area_invites', 'Area Invites']
  ];

  function setMessage(text, isError = false) {
    message.textContent = text || '';
    message.classList.toggle('is-error', isError);
  }

  function getRpcErrorMessage(error, fallback) {
    const fields = [
      ['message', error?.message],
      ['details', error?.details],
      ['hint', error?.hint],
      ['code', error?.code]
    ].filter(([, value]) => String(value || '').trim() !== '');
    return fields.length
      ? `${fallback}. ${fields.map(([label, value]) => `${label}: ${String(value).trim()}`).join(' · ')}`
      : fallback;
  }

  function showDeletionError(error) {
    let errorBox = accountDelete.querySelector('.admin-account-delete-error');
    if (!errorBox) {
      errorBox = document.createElement('div');
      errorBox.className = 'admin-account-delete-error';
      errorBox.setAttribute('role', 'alert');
      accountDelete.appendChild(errorBox);
    }
    errorBox.replaceChildren();
    errorBox.append(makeText('strong', 'Eliminazione non completata'));
    [
      ['Message', error?.message],
      ['Details', error?.details],
      ['Hint', error?.hint],
      ['Code', error?.code]
    ].forEach(([label, value]) => {
      if (String(value || '').trim()) errorBox.append(makeText('p', `${label}: ${String(value).trim()}`));
    });
  }

  function formatDate(value) {
    if (!value) return '—';
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? '—' : new Intl.DateTimeFormat('it-IT', {
      day: '2-digit', month: '2-digit', year: 'numeric'
    }).format(date);
  }

  function makeText(tag, text, className) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    element.textContent = text;
    return element;
  }

  function renderMetrics(data) {
    metrics.replaceChildren();
    metricLabels.forEach(([key, label]) => {
      const card = document.createElement('article');
      card.className = 'admin-metric-card';
      card.append(makeText('span', label), makeText('strong', String(data?.[key] ?? 0)));
      metrics.appendChild(card);
    });
  }

  function renderAccounts(result) {
    accountsList.replaceChildren();
    const items = result?.items || [];
    accountsSummary.textContent = `${result?.total ?? 0} account trovati.`;
    if (!items.length) {
      accountsList.append(makeText('p', 'Nessun account corrisponde alla ricerca.', 'admin-empty'));
      return;
    }
    items.forEach((account) => {
      const row = document.createElement('article');
      row.className = 'admin-account-row';
      const identity = document.createElement('div');
      identity.className = 'admin-account-identity';
      identity.append(
        makeText('h3', account.name || 'Account'),
        makeText('p', `${account.account_type === 'organization' ? 'Organizzazione' : 'Personale'} · ${account.email || 'Email non disponibile'}`)
      );
      if (account.organization_name && account.account_type !== 'organization') {
        identity.append(makeText('p', `Organizzazione: ${account.organization_name}`, 'admin-subtle'));
      }
      const metadata = makeText('p', `Creato il ${formatDate(account.created_at)}`, 'admin-subtle');
      const counts = document.createElement('div');
      counts.className = 'admin-counts';
      const countData = account.counts || {};
      [['owned_areas', 'Aree'], ['activities', 'Attività'], ['events', 'Eventi'], ['contacts', 'Contatti'], ['area_memberships', 'Membership']].forEach(([key, label]) => {
        counts.append(makeText('span', `${label}: ${countData[key] ?? 0}`));
      });
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'fa-button fa-button-secondary';
      button.textContent = 'Apri dettaglio';
      button.addEventListener('click', () => {
        loadDetail(account.account_id).catch((error) => setMessage(getRpcErrorMessage(error, 'Impossibile caricare la diagnostica'), true));
      });
      row.append(identity, metadata, counts, button);
      accountsList.appendChild(row);
    });
  }

  function appendDependencySection(label, entries, formatter) {
    const section = document.createElement('section');
    section.className = 'admin-dependency-section';
    section.append(makeText('h3', label));
    const list = entries || [];
    if (!list.length) {
      section.append(makeText('p', 'Nessun elemento.', 'admin-subtle'));
    } else {
      const ul = document.createElement('ul');
      list.forEach((entry) => ul.append(makeText('li', formatter(entry))));
      section.append(ul);
    }
    dependencies.appendChild(section);
  }

  function getDeleteBlockers(plan) {
    const blockers = plan?.blockers || {};
    const labels = [
      ['organization', 'è un account Organizzazione'], ['owned_areas', 'possiede Aree'],
      ['activities', 'possiede Attività'], ['events', 'possiede Eventi'], ['lists', 'possiede Liste'],
      ['contacts', 'possiede Contatti'], ['families', 'possiede una Famiglia'],
      ['deadlines', 'possiede Scadenze'], ['attachments_owned', 'possiede Allegati'],
      ['attachments_uploaded', 'ha caricato Allegati'], ['profile_avatar', 'ha un avatar da rimuovere prima']
    ];
    return labels.filter(([key]) => Boolean(blockers[key])).map(([, label]) => label);
  }

  function renderDeleteControl(summary, plan) {
    const account = plan?.account || summary.account || {};
    const subject = summary.profile || summary.organization || {};
    const name = subject.first_name ? `${subject.first_name} ${subject.last_name || ''}`.trim() : subject.name || 'questo account';
    accountDelete.replaceChildren();
    accountDelete.hidden = false;

    if (plan?.is_self) {
      accountDelete.append(
        makeText('h3', 'Eliminazione account'),
        makeText('p', 'Non puoi eliminare il tuo stesso account System Admin dall’Amministrazione.')
      );
      return;
    }

    if (!plan?.can_delete) {
      accountDelete.append(
        makeText('h3', 'Eliminazione non disponibile'),
        makeText('p', 'Non è possibile preparare la cancellazione in sicurezza.')
      );
      return;
    }
    const deleteCounts = plan.delete || {};
    const planText = [['areas', 'Aree'], ['activities', 'Attività'], ['events', 'Eventi'], ['lists', 'Liste'], ['contacts', 'Contatti'], ['attachments', 'Allegati'], ['storage_objects', 'File Storage']]
      .map(([key, label]) => `${label}: ${deleteCounts[key] ?? 0}`).join(' · ');

    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'area-delete-button';
    button.textContent = 'Elimina account e dati';
    button.addEventListener('click', () => deleteAccount(account.account_id, name, account.email, button));
    accountDelete.append(
      makeText('h3', 'Eliminazione account'),
      makeText('p', `Purge definitiva di ${name}${account.email ? ` (${account.email})` : ''}. ${planText}.`),
      button
    );
  }

  async function saveAccountDetails(accountId, values, button) {
    button.disabled = true;
    try {
      const { error } = await client.rpc('admin_update_account_details', {
        p_account_id: accountId,
        p_first_name: values.firstName ?? null,
        p_last_name: values.lastName ?? null,
        p_organization_name: values.organizationName ?? null
      });
      if (error) throw error;
      await Promise.all([loadDetail(accountId), loadAccounts(searchInput.value.trim())]);
      setMessage('Dati account aggiornati.');
    } catch (error) {
      setMessage(getRpcErrorMessage(error, 'Non è stato possibile aggiornare i dati account'), true);
    } finally {
      button.disabled = false;
    }
  }

  async function changeAccountEmail(accountId, currentEmail, button) {
    if (!window.FamilAreaConfirm || !currentEmail) {
      setMessage('Non è possibile avviare la modifica email.', true);
      return;
    }
    const newEmail = await window.FamilAreaConfirm.prompt({
      title: 'Modifica email di accesso',
      message: `L’email attuale è ${currentEmail}. Inserisci il nuovo indirizzo di accesso.`,
      warning: 'L’email verrà aggiornata direttamente nell’identità di accesso dell’account.',
      confirmText: 'Aggiorna email',
      input: { label: 'Nuova email di accesso', type: 'email', required: true, autocomplete: 'email' }
    });
    if (newEmail === null) return;

    button.disabled = true;
    try {
      const { error } = await client.rpc('admin_update_account_email', {
        p_account_id: accountId,
        p_email: String(newEmail).trim().toLowerCase()
      });
      if (error) throw error;
      await Promise.all([loadDetail(accountId), loadAccounts(searchInput.value.trim())]);
      setMessage('Email di accesso aggiornata.');
    } catch (error) {
      setMessage(getRpcErrorMessage(error, 'Non è stato possibile aggiornare l’email di accesso'), true);
    } finally {
      button.disabled = false;
    }
  }

  function renderAccountEditor(summary, editing = false) {
    const account = summary.account || {};
    const isOrganization = account.account_type === 'organization';
    const subject = isOrganization ? (summary.organization || {}) : (summary.profile || {});
    accountEditor.replaceChildren();
    accountEditor.hidden = false;

    const heading = document.createElement('div');
    heading.className = 'admin-editor-heading';
    heading.append(makeText('h3', isOrganization ? 'Dati organizzazione' : 'Dati account'));
    const editButton = document.createElement('button');
    editButton.type = 'button';
    editButton.className = 'fa-button fa-button-secondary';
    editButton.textContent = 'Modifica';
    editButton.addEventListener('click', () => renderAccountEditor(summary, true));
    if (!editing) heading.appendChild(editButton);

    let detailsContent;
    if (editing) {
      const form = document.createElement('form');
      form.className = 'admin-account-form';
      const fields = [];
      const addField = (labelText, value, name, required = false) => {
        const field = document.createElement('div');
        const label = document.createElement('label'); label.textContent = labelText;
        const input = document.createElement('input'); input.name = name; input.value = value || ''; input.required = required;
        label.htmlFor = `admin-${name}`; input.id = label.htmlFor;
        field.append(label, input); form.appendChild(field); fields.push(input);
      };
      if (isOrganization) addField('Nome organizzazione', subject.name, 'organization-name', true);
      else {
        addField('Nome', subject.first_name, 'first-name', true);
        addField('Cognome', subject.last_name, 'last-name');
      }
      const actions = document.createElement('div');
      actions.className = 'admin-account-form-actions';
      const save = document.createElement('button'); save.type = 'submit'; save.className = 'fa-button fa-button-primary'; save.textContent = 'Salva';
      const cancel = document.createElement('button'); cancel.type = 'button'; cancel.className = 'fa-button fa-button-secondary'; cancel.textContent = 'Annulla';
      cancel.addEventListener('click', () => renderAccountEditor(summary));
      actions.append(save, cancel); form.appendChild(actions);
      form.addEventListener('submit', (event) => {
        event.preventDefault();
        if (!form.reportValidity()) return;
        void saveAccountDetails(account.id, isOrganization
          ? { organizationName: fields[0].value.trim() }
          : { firstName: fields[0].value.trim(), lastName: fields[1].value.trim() }, save);
      });
      detailsContent = form;
    } else {
      const data = document.createElement('div');
      data.className = 'admin-account-data';
      const appendValue = (label, value) => {
        const row = document.createElement('p');
        row.className = 'admin-account-data-row';
        row.append(makeText('strong', `${label}:`), makeText('span', value || '—'));
        data.appendChild(row);
      };
      if (isOrganization) appendValue('Nome organizzazione', subject.name);
      else {
        appendValue('Nome', subject.first_name);
        appendValue('Cognome', subject.last_name);
      }
      detailsContent = data;
    }

    const emailSection = document.createElement('section');
    emailSection.className = 'admin-account-email';
    emailSection.append(makeText('h3', 'Email di accesso'), makeText('p', account.email || 'Email non disponibile.'));
    const emailButton = document.createElement('button'); emailButton.type = 'button'; emailButton.className = 'fa-button fa-button-secondary'; emailButton.textContent = 'Modifica email';
    const isCurrentAdminAccount = account.id === currentAccountId;
    emailButton.disabled = !account.email || isCurrentAdminAccount;
    emailButton.addEventListener('click', () => void changeAccountEmail(account.id, account.email, emailButton));
    emailSection.appendChild(emailButton);
    if (isCurrentAdminAccount) {
      emailSection.append(makeText('p', 'Non puoi modificare l’email del tuo account System Admin da questa pagina.'));
    }
    accountEditor.append(heading, detailsContent, emailSection);
  }

  function renderDetail(summary, data, plan) {
    const account = summary.account || {};
    const subject = summary.profile || summary.organization || {};
    detailTitle.textContent = `Dettaglio: ${subject.first_name ? `${subject.first_name} ${subject.last_name || ''}`.trim() : subject.name || 'Account'}`;
    detailSummary.replaceChildren(
      makeText('p', `Tipo account: ${account.account_type || '—'}`),
      makeText('p', `Email: ${account.email || 'Non disponibile'}`),
      makeText('p', `Creato il: ${formatDate(account.created_at)}`)
    );
    renderAccountEditor(summary);
    renderDeleteControl(summary, plan);
    dependencies.replaceChildren();
    appendDependencySection('Aree possedute', data.owned_areas, (item) => `${item.name} · ${item.area_type}`);
    appendDependencySection('Membership Area', data.area_memberships, (item) => `${item.area_name} · ${item.role}`);
    appendDependencySection('Attività', data.activities, (item) => `${item.title} · ${item.status}`);
    appendDependencySection('Eventi', data.events, (item) => `${item.title} · ${item.status}`);
    appendDependencySection('Partecipazioni', data.event_participations, (item) => `${item.event_title} · ${item.status}`);
    appendDependencySection('Inviti inviati', data.area_invites?.sent, (item) => `${item.status} · ${formatDate(item.created_at)}`);
    appendDependencySection('Inviti accettati', data.area_invites?.accepted, (item) => `${item.status} · ${formatDate(item.created_at)}`);
    const contactInfo = data.contacts || {};
    const other = data.other_dependencies || {};
    const counters = document.createElement('section');
    counters.className = 'admin-dependency-section';
    counters.append(makeText('h3', 'Altre dipendenze'));
    const values = [
      ['Contatti', contactInfo.count], ['Metodi di contatto', contactInfo.contact_methods_count],
      ['Liste', other.lists], ['Elementi lista', other.list_items], ['Famiglie', other.families],
      ['Membri Famiglia', other.family_members], ['Accessi Famiglia', other.family_access],
      ['Scadenze', other.deadlines], ['Allegati posseduti', other.attachments_owned]
    ];
    const list = document.createElement('ul');
    values.forEach(([label, value]) => list.append(makeText('li', `${label}: ${value ?? 0}`)));
    counters.append(list);
    dependencies.appendChild(counters);
    detail.hidden = false;
    detail.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  async function loadAccounts(query = '') {
    accountsList.replaceChildren(makeText('p', 'Caricamento account…', 'admin-subtle'));
    const { data, error } = await client.rpc('admin_list_accounts', {
      p_limit: 50, p_offset: 0, p_query: query || null
    });
    if (error) throw error;
    renderAccounts(data);
  }

  async function loadDetail(accountId) {
    setMessage('Caricamento diagnostica…');
    const [summaryResult, dependencyResult, deletePlanResult] = await Promise.all([
      client.rpc('admin_get_account_summary', { p_account_id: accountId }),
      client.rpc('admin_get_account_dependencies', { p_account_id: accountId }),
      client.rpc('admin_get_account_delete_plan', { p_account_id: accountId })
    ]);
    if (summaryResult.error) throw summaryResult.error;
    if (dependencyResult.error) throw dependencyResult.error;
    if (deletePlanResult.error) throw deletePlanResult.error;
    renderDetail(summaryResult.data, dependencyResult.data, deletePlanResult.data);
    setMessage('');
  }

  async function loadDashboard() {
    const { data: dashboard, error: dashboardError } = await client.rpc('admin_get_dashboard');
    if (dashboardError) throw dashboardError;
    renderMetrics(dashboard);
  }

  async function deleteAccount(accountId, name, email, button) {
    if (!window.FamilAreaConfirm || !email) {
      setMessage('Non è possibile avviare la cancellazione account.', true);
      return;
    }
    const normalizedEmail = String(email).trim().toLowerCase();
    const confirmation = await window.FamilAreaConfirm.prompt({
      variant: 'danger',
      title: 'Elimina definitivamente account',
      message: `Stai per eliminare ${name} (${email}). L’operazione elimina anche l’utente di autenticazione e non è reversibile.`,
      warning: 'Questa operazione elimina definitivamente l’account e tutti i dati di sua proprietà, incluse Aree, Eventi, Contatti, allegati e file. I dati appartenenti ad altri account non verranno eliminati: saranno rimossi soltanto gli eventuali collegamenti con questo account.',
      confirmText: 'Elimina definitivamente',
      input: {
        label: 'Per confermare, digita l’indirizzo email dell’account:',
        placeholder: email,
        required: true,
        validate: (value) => String(value).trim().toLowerCase() === normalizedEmail
      }
    });
    if (confirmation === null) return;

    button.disabled = true;
    try {
      const { data: sessionData, error: sessionError } = await client.auth.getSession();
      const session = sessionData?.session;
      if (sessionError || !session?.access_token || !session.user?.id) {
        throw new Error('Sessione autenticata non disponibile per la rimozione dei file Storage.');
      }
      if (!currentAdminUserId || session.user.id !== currentAdminUserId) {
        throw new Error('La sessione Storage non corrisponde al System Admin autenticato. Ricarica la pagina e riprova.');
      }
      const { data: prepared, error: prepareError } = await client.rpc('admin_prepare_account_purge', {
        p_account_id: accountId,
        p_confirmation: confirmation
      });
      if (prepareError) throw prepareError;
      const byBucket = new Map();
      (prepared?.storage_objects || []).forEach(({ bucket_id: bucketId, name: path }) => {
        if (!byBucket.has(bucketId)) byBucket.set(bucketId, []);
        byBucket.get(bucketId).push(path);
      });
      for (const [bucketId, paths] of byBucket) {
        for (let index = 0; index < paths.length; index += 100) {
          const { data: storageData, error: storageError } = await client.storage.from(bucketId).remove(paths.slice(index, index + 100));
          if (storageError) throw new Error(`Storage ${bucketId}/${paths.slice(index, index + 100).join(', ')}: ${storageError.message || storageError}`);
          if (storageData?.error) throw new Error(`Storage ${bucketId}/${paths.slice(index, index + 100).join(', ')}: ${storageData.error.message || storageData.error}`);
        }
      }
      const { data: verification, error: verificationError } = await client.rpc('admin_verify_account_purge_storage', {
        p_account_id: accountId, p_confirmation: confirmation
      });
      if (verificationError) throw verificationError;
      if (!verification?.complete) {
        const remaining = (verification?.remaining || []).map(({ bucket_id: bucketId, name: path }) => `${bucketId}/${path}`).join(', ');
        throw new Error(`Storage API non ha rimosso: ${remaining || 'file del manifest non identificato'}`);
      }
      const { error } = await client.rpc('admin_delete_account', {
        p_account_id: accountId,
        p_confirmation: confirmation
      });
      if (error) throw error;
      detail.hidden = true;
      setMessage(`Account ${name} eliminato definitivamente.`);
      await Promise.all([loadDashboard(), loadAccounts(searchInput.value.trim())]);
    } catch (error) {
      setMessage(getRpcErrorMessage(error, 'Non è stato possibile eliminare l’account'), true);
      showDeletionError(error);
    } finally {
      button.disabled = false;
    }
  }

  async function initialize() {
    const [{ data: access, error: accessError }, { data: currentAccount, error: currentAccountError }, { data: adminUser, error: adminUserError }] = await Promise.all([
      client.rpc('get_my_system_admin_access'),
      client.rpc('get_current_account'),
      client.auth.getUser()
    ]);
    if (accessError || !access?.is_system_admin) {
      setMessage('Non sei autorizzato ad accedere all’amministrazione.', true);
      return;
    }
    if (currentAccountError || !currentAccount?.account_id) throw currentAccountError || new Error('Account corrente non disponibile.');
    if (adminUserError || !adminUser?.user?.id) throw adminUserError || new Error('Utente autenticato non disponibile.');
    currentAccountId = currentAccount.account_id;
    currentAdminUserId = adminUser.user.id;
    await loadDashboard();
    content.hidden = false;
    setMessage('');
    await loadAccounts();
  }

  searchForm.addEventListener('submit', (event) => {
    event.preventDefault();
    loadAccounts(searchInput.value.trim()).catch((error) => setMessage(getRpcErrorMessage(error, 'Impossibile caricare gli account'), true));
  });
  closeDetail.addEventListener('click', () => { detail.hidden = true; });
  initialize().catch((error) => setMessage(getRpcErrorMessage(error, 'Impossibile caricare l’amministrazione'), true));
}());

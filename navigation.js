(function () {
  const body = document.body;
  const params = new URLSearchParams(window.location.search);
  const path = window.location.pathname.split('/').pop() || 'dashboard.html';
  const primarySectionByPage = {
    'dashboard.html': 'dashboard',
    'timeline.html': 'memories',
    'ricordo.html': 'memories',
    'famiglia.html': 'family',
    'interessi.html': 'interests',
    'attivita-globali.html': 'activities',
    'attivita.html': 'activities',
    'nuova-attivita.html': 'activities',
    'impegni.html': 'commitments',
    'eventi.html': 'commitments',
    'proposte.html': 'suggestions',
    'evento.html': 'events',
    'nuovo-evento.html': 'events',
    'liste.html': 'lists',
    'lista.html': 'lists',
    'nuova-lista.html': 'lists',
    'calendario.html': 'calendar',
    'scadenze.html': 'deadlines',
    'nuova-scadenza.html': 'deadlines',
    'gestione-scadenze.html': 'deadlines',
    'gestione-scadenze-veicoli.html': 'deadlines',
    'gestione-scadenze-casa.html': 'deadlines',
    'gestione-scadenza-item.html': 'deadlines',
    'gestione-scadenza-veicolo.html': 'deadlines',
    'contatti.html': 'contacts',
    'nuovo-contatto.html': 'contacts',
    'contatto.html': 'contacts',
    'condividi-contatto.html': 'contacts',
    'inviti.html': 'invites',
    'admin.html': 'admin'
  };
  // Eventi e Liste fanno parte del flusso Impegni.
  const isCommitmentFlow = [
    'nuovo-evento.html',
    'evento.html',
    'liste.html',
    'lista.html',
    'nuova-lista.html'
  ].includes(path);
  const primarySection = isCommitmentFlow
    ? 'commitments'
    : primarySectionByPage[path] || null;
  const isPrimaryNavActive = (section) => primarySection === section ? ' is-active' : '';

  if (!body.classList.contains('fa-v2-app')) body.classList.add('protected-page');
  const header = document.createElement('header');
  header.className = 'shared-header fa-v2-app-header';
  const brand = document.createElement('div');
  brand.className = 'fa-v2-brand';
  const brandMain = document.createElement('a');
  brandMain.className = 'app-brand fa-v2-brand-main';
  brandMain.href = 'dashboard.html';
  brandMain.setAttribute('aria-label', 'FamilArea, Dashboard');
  brandMain.append(document.createTextNode('Famil'), Object.assign(document.createElement('span'), { textContent: 'Area' }));
  const brandRound = document.createElement('span');
  brandRound.className = 'fa-v2-brand-round';
  brandRound.setAttribute('aria-hidden', 'true');
  brand.append(brandMain, brandRound);
  const actions = document.createElement('div');
  actions.className = 'header-actions';
  const existingLogout = document.querySelector('[data-logout]');
  const logoutMessage = document.getElementById('logout-message');
  if (existingLogout) actions.appendChild(existingLogout);
  header.append(brand, actions);
  if (logoutMessage) header.appendChild(logoutMessage);
  body.prepend(header);
  if (!header || !actions || !window.supabase || typeof SUPABASE_URL === 'undefined' || typeof SUPABASE_KEY === 'undefined') return;

  const topNav = document.createElement('nav');
  topNav.className = 'shared-top-nav fa-v2-top-nav';
  topNav.setAttribute('aria-label', 'Navigazione principale');
  let invitesLink;
  function renderNavigation(accountType) {
    invitesLink = null;
    topNav.replaceChildren();
    const sharedItems = [
      { label: 'Dashboard', href: 'dashboard.html', active: isPrimaryNavActive('dashboard') },
      { label: 'Timeline', href: 'timeline.html', active: isPrimaryNavActive('memories') },
      { label: 'Attività', href: 'attivita-globali.html', active: isPrimaryNavActive('activities') },
      { label: 'Calendario', href: 'calendario.html', active: isPrimaryNavActive('calendar') },
      { label: 'Scadenze', href: 'scadenze.html', active: isPrimaryNavActive('deadlines') },
      { label: 'Impegni', href: 'impegni.html', active: isPrimaryNavActive('commitments') },
      { label: 'Contatti', href: 'contatti.html', active: isPrimaryNavActive('contacts') }
    ];
    const sharingItem = { id: 'invites', label: 'Condivisioni', href: 'inviti.html', active: isPrimaryNavActive('invites') };
    const items = accountType === 'personal'
      ? [
        sharedItems[0],
        { label: 'Famiglia', href: 'famiglia.html', active: isPrimaryNavActive('family') },
        sharedItems[3],
        sharedItems[4],
        sharedItems[2],
        sharedItems[5],
        sharedItems[1],
        sharingItem,
        sharedItems[6]
      ]
      : [sharedItems[0], sharedItems[3], sharedItems[4], sharedItems[2], sharedItems[5], sharedItems[1], sharingItem, sharedItems[6]];
    items.forEach((item) => {
      const link = document.createElement('a');
      link.className = `top-nav-link${item.active}`;
      link.href = item.href;
      link.textContent = item.label;
      if (item.active) link.setAttribute('aria-current', 'page');
      if (item.id === 'invites') {
        link.classList.add('top-nav-invites-link');
        invitesLink = link;
      }
      topNav.appendChild(link);
    });
  }

  async function renderSystemAdministrationLink() {
    topNav.querySelector('.top-nav-admin-link')?.remove();
    const { data, error } = await client.rpc('get_my_system_admin_access');
    if (error || !data?.is_system_admin) return;
    const link = document.createElement('a');
    link.className = `top-nav-link top-nav-admin-link fa-nav-admin${isPrimaryNavActive('admin')}`;
    link.href = 'admin.html';
    link.textContent = 'Admin';
    if (isPrimaryNavActive('admin')) link.setAttribute('aria-current', 'page');
    topNav.appendChild(link);
  }

  header.insertBefore(topNav, actions);

  const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
  window.FamilAreaSupabaseClient = client;
  let observedAuthUserId = null;
  let authIdentityInitialized = false;
  let authNavigationPending = false;

  // Tutte le pagine che caricano questa navigazione sono protette. Se un'altra
  // scheda sostituisce o rimuove la sessione condivisa, ricarichiamo l'intera
  // pagina per non lasciare visibili dati o comandi del precedente account.
  client.auth.onAuthStateChange((event, session) => {
    const nextUserId = session?.user?.id || null;

    if (!authIdentityInitialized || event === 'INITIAL_SESSION') {
      observedAuthUserId = nextUserId;
      authIdentityInitialized = true;
      return;
    }

    if (authNavigationPending || observedAuthUserId === nextUserId) return;

    observedAuthUserId = nextUserId;
    authNavigationPending = true;
    if (!nextUserId) {
      window.location.replace('login.html');
      return;
    }
    window.location.reload();
  });

  actions.querySelector('.header-user-name')?.remove();
  const logoutButton = actions.querySelector('[data-logout]');

  const accountMenu = document.createElement('div');
  accountMenu.className = 'account-menu';
  const accountTrigger = document.createElement('button');
  accountTrigger.type = 'button';
  accountTrigger.className = 'account-menu-trigger';
  accountTrigger.setAttribute('aria-haspopup', 'menu');
  accountTrigger.setAttribute('aria-expanded', 'false');
  accountTrigger.setAttribute('aria-label', 'Apri menu account');
  const avatarFallback = document.createElement('span');
  avatarFallback.className = 'account-menu-avatar account-menu-avatar-fallback';
  avatarFallback.setAttribute('aria-hidden', 'true');
  const avatarImage = document.createElement('img');
  avatarImage.className = 'account-menu-avatar account-menu-avatar-image';
  avatarImage.alt = '';
  avatarImage.hidden = true;
  const accountName = document.createElement('span');
  accountName.className = 'account-menu-name';
  accountName.textContent = 'Account';
  const caret = document.createElement('span');
  caret.className = 'account-menu-caret';
  caret.setAttribute('aria-hidden', 'true');
  caret.textContent = '▾';
  accountTrigger.append(avatarFallback, avatarImage, accountName, caret);

  const accountPanel = document.createElement('div');
  accountPanel.className = 'account-menu-panel';
  accountPanel.setAttribute('role', 'menu');
  accountPanel.hidden = true;
  const profileLink = document.createElement('a');
  profileLink.href = 'profilo.html';
  profileLink.textContent = 'Il mio profilo';
  profileLink.setAttribute('role', 'menuitem');
  const preferencesLink = document.createElement('a');
  preferencesLink.href = 'impostazioni.html';
  preferencesLink.textContent = 'Impostazioni';
  preferencesLink.setAttribute('role', 'menuitem');
  const myContactLink = document.createElement('a');
  myContactLink.href = 'condividi-contatto.html';
  myContactLink.textContent = 'Il mio contatto';
  myContactLink.setAttribute('role', 'menuitem');
  accountPanel.append(profileLink, myContactLink, preferencesLink);
  if (logoutButton) {
    logoutButton.classList.add('account-menu-logout');
    logoutButton.setAttribute('role', 'menuitem');
    accountPanel.appendChild(logoutButton);
  }
  accountMenu.append(accountTrigger, accountPanel);
  actions.appendChild(accountMenu);

  function closeAccountMenu(returnFocus = false) {
    accountPanel.hidden = true;
    accountTrigger.setAttribute('aria-expanded', 'false');
    if (returnFocus) accountTrigger.focus();
  }

  function toggleAccountMenu() {
    const willOpen = accountPanel.hidden;
    accountPanel.hidden = !willOpen;
    accountTrigger.setAttribute('aria-expanded', String(willOpen));
    if (willOpen) accountPanel.querySelector('[role="menuitem"]')?.focus();
  }

  accountTrigger.addEventListener('click', toggleAccountMenu);
  document.addEventListener('pointerdown', (event) => {
    if (!accountMenu.contains(event.target)) closeAccountMenu();
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !accountPanel.hidden) {
      event.preventDefault();
      closeAccountMenu(true);
    }
  });

  function fullName(profile) {
    return `${profile?.first_name || ''} ${profile?.last_name || ''}`.trim() || 'Account';
  }

  function initials(profile) {
    const parts = [profile?.first_name, profile?.last_name]
      .map((value) => (value || '').trim())
      .filter(Boolean);
    return parts.map((part) => part.charAt(0).toLocaleUpperCase('it-IT')).join('').slice(0, 2) || 'U';
  }

  async function renderAccountIdentity(profile) {
    accountName.textContent = fullName(profile);
    accountTrigger.setAttribute('aria-label', `Apri menu account di ${fullName(profile)}`);
    avatarFallback.textContent = initials(profile);
    avatarFallback.hidden = false;
    avatarImage.hidden = true;
    avatarImage.removeAttribute('src');
    if (!profile.avatar_path) return;

    const { data, error } = await client.storage.from('profile-avatars').createSignedUrl(profile.avatar_path, 60 * 60);
    if (error || !data?.signedUrl) return;
    const imageLoaded = await new Promise((resolve) => {
      avatarImage.onload = () => resolve(true);
      avatarImage.onerror = () => resolve(false);
      avatarImage.src = `${data.signedUrl}${data.signedUrl.includes('?') ? '&' : '?'}v=${Date.now()}`;
    });
    if (!imageLoaded) {
      avatarImage.removeAttribute('src');
      return;
    }
    avatarImage.alt = `Foto profilo di ${fullName(profile)}`;
    avatarImage.hidden = false;
    avatarFallback.hidden = true;
  }

  async function renderOrganizationIdentity(organization) {
    const name = organization?.name || 'Organizzazione';
    accountName.textContent = name;
    accountTrigger.setAttribute('aria-label', `Apri menu account di ${name}`);
    avatarFallback.textContent = name.trim().charAt(0).toLocaleUpperCase('it-IT') || 'O';
    avatarFallback.hidden = false;
    avatarImage.hidden = true;
    avatarImage.removeAttribute('src');
    if (!organization?.avatar_path) return;

    const { data, error } = await client.storage.from('organization-avatars').createSignedUrl(organization.avatar_path, 60 * 60);
    if (error || !data?.signedUrl) return;
    const imageLoaded = await new Promise((resolve) => {
      avatarImage.onload = () => resolve(true);
      avatarImage.onerror = () => resolve(false);
      avatarImage.src = `${data.signedUrl}${data.signedUrl.includes('?') ? '&' : '?'}v=${Date.now()}`;
    });
    if (!imageLoaded) {
      avatarImage.removeAttribute('src');
      return;
    }
    avatarImage.alt = `Immagine di ${name}`;
    avatarImage.hidden = false;
    avatarFallback.hidden = true;
  }

  const accountPromise = client.rpc('get_current_account').then(({ data, error }) => (error || !data ? null : data));
  window.FamilAreaCurrentAccount = accountPromise;
  window.FamilAreaRequirePersonal = async () => {
    const account = await accountPromise;
    if (account?.account_type === 'personal') return account;
    if (account?.account_type === 'organization') window.location.replace('dashboard.html');
    return null;
  };

  async function loadAccountIdentity() {
    const account = await accountPromise;
    if (!account) return;
    renderNavigation(account.account_type);
    renderSystemAdministrationLink().catch(() => {});

    if (account.account_type !== 'personal') {
      profileLink.remove();
      const { data: organization, error: organizationError } = await client.rpc('get_my_organization');
      if (!organizationError && organization) await renderOrganizationIdentity(organization);
      else await renderOrganizationIdentity({ name: account.display_name });
      return;
    }

    const { data: profile, error: profileError } = await client.rpc('get_my_profile');
    if (!profileError && profile) await renderAccountIdentity(profile);
  }

  loadAccountIdentity().catch(() => {});
  const personalOnlyPages = new Set(['profilo.html', 'famiglia.html', 'interessi.html', 'proposte.html']);
  if (personalOnlyPages.has(path)) window.FamilAreaRequirePersonal().catch(() => {});
  window.addEventListener('familarea:profile-avatar-changed', (event) => {
    const profile = event.detail?.profile;
    if (profile) renderAccountIdentity(profile).catch(() => {});
    else loadAccountIdentity().catch(() => {});
  });
  window.addEventListener('familarea:organization-changed', (event) => {
    const organization = event.detail?.organization;
    if (organization) renderOrganizationIdentity(organization).catch(() => {});
    else loadAccountIdentity().catch(() => {});
  });

  let invitesBadgeRequestVersion = 0;

  async function refreshInvitesBadge() {
    if (!invitesLink) return;
    const requestVersion = ++invitesBadgeRequestVersion;
    const { data, error } = await client.rpc('get_my_pending_invites_count');
    if (requestVersion !== invitesBadgeRequestVersion) return;

    if (error) {
      console.error('get_my_pending_invites_count badge failed', error);
      return;
    }

    const pendingCount = Math.max(0, Number(data) || 0);

    invitesLink.querySelectorAll('.top-nav-invites-badge').forEach((badge) => badge.remove());
    if (pendingCount === 0) {
      invitesLink.removeAttribute('aria-label');
      return;
    }

    const badge = document.createElement('span');
    badge.className = 'top-nav-invites-badge fa-v2-pending-count';
    badge.textContent = pendingCount >= 10 ? '9+' : String(pendingCount);
    badge.setAttribute('aria-hidden', 'true');
    invitesLink.appendChild(badge);
    invitesLink.setAttribute('aria-label', `Condivisioni, ${pendingCount} in attesa`);
  }

  accountPromise.then((account) => {
    if (account?.account_id) refreshInvitesBadge().catch(() => {});
  }).catch(() => {});
  window.addEventListener('familarea:invites-changed', () => {
    refreshInvitesBadge().catch(() => {});
  });

  const footer = document.createElement('footer');
  footer.className = 'shared-site-footer';
  const identity = document.createElement('div');
  identity.className = 'shared-site-footer-identity';
  const name = document.createElement('strong');
  name.textContent = 'FamilArea';
  const tagline = document.createElement('p');
  tagline.textContent = 'Organizza. Partecipa. Collabora.';
  identity.append(name, tagline);
  const links = document.createElement('nav');
  links.className = 'shared-site-footer-links';
  links.setAttribute('aria-label', 'Link informativi');
  [
    { label: 'Privacy', href: 'privacy.html' },
    { label: 'Termini', href: 'termini.html' },
    { label: 'Assistenza', href: 'assistenza.html' }
  ].forEach(({ label, href }, index) => {
    if (index > 0) links.appendChild(document.createTextNode(' · '));
    const link = document.createElement('a');
    link.href = href;
    link.textContent = label;
    links.appendChild(link);
  });
  const copyright = document.createElement('p');
  copyright.className = 'shared-site-footer-copyright';
  copyright.textContent = `© ${new Date().getFullYear()} FamilArea`;
  links.appendChild(copyright);
  footer.append(identity, links);
  document.body.appendChild(footer);

}());

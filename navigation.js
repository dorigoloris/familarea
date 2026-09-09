(function () {
  const body = document.body;
  const isDashboard = body.classList.contains('dashboard-page');
  const params = new URLSearchParams(window.location.search);
  const areaId = params.get('area_id');
  const path = window.location.pathname.split('/').pop() || 'dashboard.html';
  const isActive = (names) => names.includes(path) ? ' is-active' : '';
  const areaHref = (anchor) => areaId ? `area.html?area_id=${encodeURIComponent(areaId)}${anchor || ''}` : 'mie-aree.html#areas-title';
  const activitiesHref = areaId ? `attivita-area.html?area_id=${encodeURIComponent(areaId)}` : 'mie-aree.html#areas-title';
  const eventsHref = areaId ? `eventi.html?area_id=${encodeURIComponent(areaId)}` : 'mie-aree.html#areas-title';
  const listsHref = areaId ? `liste.html?area_id=${encodeURIComponent(areaId)}` : 'mie-aree.html#areas-title';

  let header;
  let actions;
  if (isDashboard) {
    header = document.querySelector('.app-header');
    actions = header?.querySelector('.header-actions');
    document.querySelector('.dashboard-sidebar')?.remove();
  } else {
    body.classList.add('protected-page');
    header = document.createElement('header');
    header.className = 'shared-header';
    const brand = document.createElement('a');
    brand.className = 'app-brand';
    brand.href = 'dashboard.html';
    brand.setAttribute('aria-label', 'FamilArea, Dashboard');
    brand.append(document.createTextNode('Famil'), Object.assign(document.createElement('span'), { textContent: 'Area' }));
    actions = document.createElement('div');
    actions.className = 'header-actions';
    const existingLogout = document.querySelector('[data-logout]');
    const logoutMessage = document.getElementById('logout-message');
    if (existingLogout) actions.appendChild(existingLogout);
    header.append(brand, actions);
    if (logoutMessage) header.appendChild(logoutMessage);
    body.prepend(header);
  }
  if (!header || !actions || !window.supabase || typeof SUPABASE_URL === 'undefined' || typeof SUPABASE_KEY === 'undefined') return;

  const topNav = document.createElement('nav');
  topNav.className = 'shared-top-nav';
  topNav.setAttribute('aria-label', 'Navigazione principale');
  let personalInvitesLink;
  [
    { label: 'Dashboard', href: 'dashboard.html', active: isActive(['dashboard.html']) },
    { label: 'Famiglia', href: 'famiglia.html', active: isActive(['famiglia.html']) },
    { label: 'Aree', href: 'mie-aree.html', active: isActive(['mie-aree.html']) },
    { label: 'Calendario', href: 'calendario.html', active: isActive(['calendario.html']) },
    { label: 'Contatti', href: 'contatti.html', active: isActive(['contatti.html', 'nuovo-contatto.html', 'contatto.html']) },
    { label: 'Inviti', href: 'inviti.html', active: isActive(['inviti.html']) }
  ].forEach((item) => {
    const link = document.createElement('a');
    link.className = `top-nav-link${item.active}`;
    link.href = item.href;
    link.textContent = item.label;
    if (item.active) link.setAttribute('aria-current', 'page');
    if (item.label === 'Inviti') {
      link.classList.add('top-nav-invites-link');
      personalInvitesLink = link;
    }
    topNav.appendChild(link);
  });
  header.insertBefore(topNav, actions);

  const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
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
  accountPanel.append(profileLink, preferencesLink);
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
    if (willOpen) profileLink.focus();
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

  async function loadAccountIdentity() {
    const { data } = await client.auth.getUser();
    const user = data?.user;
    if (!user) return;
    const { data: profile, error } = await client
      .from('profiles')
      .select('first_name, last_name, avatar_path')
      .eq('user_id', user.id)
      .single();
    if (!error && profile) await renderAccountIdentity(profile);
  }

  loadAccountIdentity().catch(() => {});

  let invitesBadgeRequestVersion = 0;

  async function refreshInvitesBadge() {
    if (!personalInvitesLink) return;
    const requestVersion = ++invitesBadgeRequestVersion;
    const { data, error } = await client.rpc('get_my_area_invites');
    if (error || requestVersion !== invitesBadgeRequestVersion) return;

    personalInvitesLink.querySelectorAll('.top-nav-invites-badge').forEach((badge) => badge.remove());
    const pendingCount = (data || []).filter((invite) => invite.status === 'pending').length;
    if (pendingCount === 0) {
      personalInvitesLink.removeAttribute('aria-label');
      return;
    }

    const badge = document.createElement('span');
    badge.className = 'top-nav-invites-badge';
    badge.textContent = pendingCount >= 10 ? '9+' : String(pendingCount);
    badge.setAttribute('aria-hidden', 'true');
    personalInvitesLink.appendChild(badge);
    personalInvitesLink.setAttribute('aria-label', `Inviti, ${pendingCount} in attesa`);
  }

  refreshInvitesBadge().catch(() => {});
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
  links.append(document.createTextNode(' · '), copyright);
  footer.append(identity, links);
  body.classList.add('has-shared-footer');
  document.body.appendChild(footer);

  if (!areaId) return;
  body.classList.add('has-area-context');
  const areaNav = document.createElement('nav');
  areaNav.className = 'shared-area-nav';
  areaNav.setAttribute('aria-label', 'Navigazione Area');
  areaNav.innerHTML = `<p class="shared-nav-label">AREA <span id="nav-area-name">in caricamento…</span></p>
    <a class="sidebar-link${isActive(['area.html', 'modifica-area.html'])}" href="${areaHref()}">Panoramica Area</a>
    <a class="sidebar-link${isActive(['membro.html', 'aggiungi-membro.html'])}" href="${areaHref('#members-list')}">Partecipanti</a>
    <a class="sidebar-link${isActive(['attivita-area.html', 'attivita.html', 'nuova-attivita.html'])}" href="${activitiesHref}">Attività</a>
    <a class="sidebar-link${isActive(['eventi.html', 'evento.html', 'nuovo-evento.html'])}" href="${eventsHref}">Eventi</a>
    <a class="sidebar-link${isActive(['liste.html', 'lista.html', 'nuova-lista.html'])}" href="${listsHref}">Liste</a>`;
  body.prepend(areaNav);

  const areaNavIcons = {
    'Panoramica Area': 'M4 10.5 12 4l8 6.5V20a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1v-9.5ZM9 21v-6h6v6',
    Partecipanti: 'M16 20v-1.5a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4V20M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8M17 8a3 3 0 1 1 0 6M22 20v-1.5a4 4 0 0 0-3-3.8',
    Attività: 'm5 12 4 4L19 6M3 4h18v16H3z',
    Eventi: 'M7 3v4M17 3v4M3 10h18M8 14h3M8 17h6M5 5h14a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2Z',
    Liste: 'M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01',
    Inviti: 'M3 6.5 12 12l9-5.5M4 5h16a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1Z'
  };
  const createAreaNavIcon = (pathData) => {
    const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    icon.classList.add('area-nav-icon');
    icon.setAttribute('viewBox', '0 0 24 24');
    icon.setAttribute('aria-hidden', 'true');
    const pathElement = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    pathElement.setAttribute('d', pathData);
    icon.appendChild(pathElement);
    return icon;
  };
  areaNav.querySelectorAll('.sidebar-link').forEach((link) => {
    const iconPath = areaNavIcons[link.textContent.trim()];
    if (iconPath) link.prepend(createAreaNavIcon(iconPath));
  });

  client.from('areas').select('name').eq('id', areaId).single().then(({ data }) => {
    const target = document.getElementById('nav-area-name');
    if (target) target.textContent = data?.name || 'Area';
  });
  client.auth.getUser().then(async ({ data }) => {
    const userId = data?.user?.id;
    if (!userId) return;
    const { data: profile } = await client.from('profiles').select('id').eq('user_id', userId).single();
    const { data: membership } = await client.from('area_memberships').select('role').eq('area_id', areaId).eq('profile_id', profile?.id).single();
    if (membership?.role !== 'admin') return;
    const link = document.createElement('a');
    link.className = `sidebar-link${isActive(['inviti-area.html'])}`;
    link.href = `inviti-area.html?area_id=${encodeURIComponent(areaId)}`;
    link.textContent = 'Inviti';
    link.prepend(createAreaNavIcon(areaNavIcons.Inviti));
    areaNav.appendChild(link);
  });
}());

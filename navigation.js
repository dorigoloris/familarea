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
    const account = document.createElement('span');
    account.className = 'header-user-name';
    account.hidden = true;
    actions.appendChild(account);
    const existingLogout = document.querySelector('[data-logout]');
    const logoutMessage = document.getElementById('logout-message');
    if (existingLogout) actions.appendChild(existingLogout);
    header.append(brand, actions);
    if (logoutMessage) header.appendChild(logoutMessage);
    body.prepend(header);
  }
  if (!header || !actions) return;

  const topNav = document.createElement('nav');
  topNav.className = 'shared-top-nav';
  topNav.setAttribute('aria-label', 'Navigazione principale');
  let personalInvitesLink;
  [
    { label: 'Dashboard', href: 'dashboard.html', active: isActive(['dashboard.html']) },
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

  const account = actions.querySelector('.header-user-name');
  let client;
  if (account && window.supabase && typeof SUPABASE_URL !== 'undefined' && typeof SUPABASE_KEY !== 'undefined') {
    client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
    client.auth.getUser().then(({ data }) => {
      const user = data?.user;
      const name = user?.user_metadata?.full_name || user?.user_metadata?.name || user?.email;
      if (name) { account.textContent = name; account.hidden = false; }
    });
  }

  if (client && personalInvitesLink) {
    client.rpc('get_my_area_invites').then(({ data, error }) => {
      if (error) return;
      const pendingCount = (data || []).filter((invite) => invite.status === 'pending').length;
      if (pendingCount > 0) {
        const badge = document.createElement('span');
        badge.className = 'top-nav-invites-badge';
        badge.textContent = pendingCount >= 10 ? '9+' : String(pendingCount);
        badge.setAttribute('aria-hidden', 'true');
        personalInvitesLink.appendChild(badge);
        personalInvitesLink.setAttribute('aria-label', `Inviti, ${pendingCount} in attesa`);
      }
    }).catch(() => {});
  }

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

  if (window.supabase && typeof SUPABASE_URL !== 'undefined' && typeof SUPABASE_KEY !== 'undefined') {
    const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
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
      areaNav.appendChild(link);
    });
  }
}());

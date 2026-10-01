(function () {
  const memberIdParam = 'managed_member_id';

  function requestedMemberId() {
    return new URLSearchParams(window.location.search).get(memberIdParam);
  }

  function client() {
    return window.FamilAreaSupabaseClient || window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
  }

  function memberName(member) {
    return [member?.first_name, member?.last_name].filter(Boolean).join(' ') || 'Membro della Famiglia';
  }

  async function load() {
    const memberId = requestedMemberId();
    if (!memberId) return { requested: false, member: null };

    const { data, error } = await client().rpc('get_my_managed_family_member', {
      p_member_id: memberId
    });
    const member = Array.isArray(data) ? data[0] : data;
    if (error || !member) {
      const url = new URL(window.location.href);
      url.searchParams.delete(memberIdParam);
      window.history.replaceState({}, '', `${url.pathname}${url.search}${url.hash}`);
      return { requested: true, member: null, error: error || new Error('family member unavailable') };
    }

    const { data: familyData } = await client().rpc('get_my_family');
    member.owner_account_id = familyData?.family?.owner_account_id || null;

    const { data: avatarPath } = await client().rpc('get_my_managed_family_member_avatar_path', {
      p_member_id: memberId
    });
    member.avatar_path = avatarPath || null;

    return { requested: true, member };
  }

  function withMember(path, memberId) {
    const url = new URL(path, window.location.href);
    url.searchParams.set(memberIdParam, memberId);
    return `${url.pathname.split('/').pop()}${url.search}${url.hash}`;
  }

  function renderBar(container, member, options = {}) {
    if (!container || !member) return;
    const bar = document.createElement('section');
    bar.className = 'managed-context-bar';
    bar.setAttribute('aria-label', `Contesto gestito: ${memberName(member)}`);

    const identity = document.createElement('div');
    identity.className = 'managed-context-identity';
    const avatar = document.createElement('span');
    avatar.className = 'managed-context-avatar';
    avatar.setAttribute('aria-hidden', 'true');
    avatar.textContent = memberName(member).trim().charAt(0).toLocaleUpperCase('it-IT') || '?';
    if (member.avatar_path && window.FamilAreaFamilyMemberAvatar) {
      void window.FamilAreaFamilyMemberAvatar.render(avatar, member.avatar_path);
    }
    const text = document.createElement('span');
    text.textContent = 'Stai gestendo: ';
    const name = document.createElement('strong');
    name.textContent = memberName(member);
    text.append(name);
    identity.append(avatar, text);

    const back = document.createElement('a');
    back.className = 'fa-button fa-button-secondary fa-button-compact managed-context-back';
    back.href = options.backHref || 'scadenze.html';
    back.textContent = 'Torna a Loris';
    bar.append(identity, back);
    container.replaceChildren(bar);
  }

  window.FamilAreaManagedContext = { load, renderBar, withMember, memberName };
}());

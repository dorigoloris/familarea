(function attachFamilyMemberAvatar(global) {
  const bucket = 'family-member-avatars';
  const allowedTypes = new Set(['image/jpeg', 'image/png', 'image/webp']);
  const maxBytes = 2 * 1024 * 1024;

  function client() {
    return global.FamilAreaSupabaseClient || global.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
  }

  async function resolve(path) {
    if (!path) return '';
    const { data, error } = await client().storage.from(bucket).createSignedUrl(path, 3600);
    return error || !data?.signedUrl ? '' : data.signedUrl;
  }

  async function render(target, path) {
    if (!target || !path) return false;
    const fallback = target.textContent;
    const url = await resolve(path);
    if (!url || !target.isConnected) return false;
    const image = document.createElement('img');
    image.alt = '';
    image.onload = () => { if (target.isConnected) target.replaceChildren(image); };
    image.onerror = () => { if (target.isConnected) { target.replaceChildren(); target.textContent = fallback; } };
    image.src = `${url}${url.includes('?') ? '&' : '?'}v=${Date.now()}`;
    return true;
  }

  function storagePath(accountId, memberId) {
    return `${accountId}/${memberId}/avatar`;
  }

  global.FamilAreaFamilyMemberAvatar = { bucket, allowedTypes, maxBytes, resolve, render, storagePath };
}(window));

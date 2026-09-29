(function attachDeadlineItemImage(global) {
  const bucket = 'deadline-item-images';
  const allowedTypes = new Set(['image/jpeg', 'image/png', 'image/webp']);
  const maxBytes = 2 * 1024 * 1024;
  const signedUrlCache = new Map();

  function client() {
    return global.FamilAreaSupabaseClient || global.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
  }

  async function resolve(path) {
    if (!path) return '';
    if (!signedUrlCache.has(path)) {
      signedUrlCache.set(path, client().storage.from(bucket).createSignedUrl(path, 3600).then(({ data, error }) => {
        if (error || !data?.signedUrl) { signedUrlCache.delete(path); return ''; }
        return data.signedUrl;
      }));
    }
    return signedUrlCache.get(path);
  }

  function storagePath(accountId, itemId) {
    return `${accountId}/${itemId}/image`;
  }

  async function render(target, path, alt = '') {
    if (!target || !path) return false;
    const fallback = target.textContent;
    const url = await resolve(path);
    if (!url || !target.isConnected) return false;
    const image = document.createElement('img');
    image.alt = alt;
    image.onload = () => { if (target.isConnected) target.replaceChildren(image); };
    image.onerror = () => { if (target.isConnected) { target.replaceChildren(); target.textContent = fallback; } };
    image.src = `${url}${url.includes('?') ? '&' : '?'}v=${Date.now()}`;
    return true;
  }

  global.FamilAreaDeadlineItemImage = { bucket, allowedTypes, maxBytes, resolve, storagePath, render };
}(window));

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

  function createEditor({ client: suppliedClient, input, preview, upload, remove, message, getItem, fallback = () => 'E', noun = 'foto' }) {
    let pendingFile = null;
    let removalRequested = false;
    let previewObjectUrl = '';
    const serviceClient = suppliedClient || client();
    function clearPreviewObjectUrl() { if (previewObjectUrl) URL.revokeObjectURL(previewObjectUrl); previewObjectUrl = ''; }
    function item() { return getItem?.() || null; }
    function fallbackText() { return (fallback(item()) || 'E').trim().charAt(0).toLocaleUpperCase('it-IT'); }
    function setMessage(text = '', isError = false) { message.textContent = text; message.hidden = !text; message.classList.toggle('is-error', isError); }
    function renderFallback() { clearPreviewObjectUrl(); preview.replaceChildren(); preview.textContent = fallbackText(); }
    function renderUrl(url, isObjectUrl = false) { if (!isObjectUrl) clearPreviewObjectUrl(); preview.replaceChildren(); const image = document.createElement('img'); image.alt = ''; image.src = url; image.onerror = renderFallback; preview.append(image); }
    async function refresh() {
      const currentItem = item(); const imagePath = currentItem?.image_path;
      upload.textContent = imagePath || pendingFile ? 'Sostituisci foto' : 'Carica foto'; remove.hidden = !imagePath && !pendingFile;
      if (pendingFile) { clearPreviewObjectUrl(); previewObjectUrl = URL.createObjectURL(pendingFile); renderUrl(previewObjectUrl, true); return; }
      renderFallback(); if (!imagePath) return;
      const itemId = currentItem.id; const url = await resolve(imagePath);
      if (itemId !== item()?.id || pendingFile || !url) return; renderUrl(url);
    }
    function reset() { pendingFile = null; removalRequested = false; input.value = ''; setMessage(''); renderFallback(); remove.hidden = true; upload.textContent = 'Carica foto'; }
    async function save(currentItem, previousImagePath) {
      if (removalRequested && previousImagePath) {
        const { error: removeError } = await serviceClient.storage.from(bucket).remove([previousImagePath]);
        if (removeError) throw new Error(`Impossibile rimuovere la ${noun} precedente.`);
        const { error } = await serviceClient.rpc('set_my_deadline_item_image', { p_item_id: currentItem.id, p_image_path: null }); if (error) throw error;
      }
      if (!pendingFile) return;
      if (!currentItem.owner_account_id) throw new Error(`Impossibile verificare il proprietario della ${noun}.`);
      const path = storagePath(currentItem.owner_account_id, currentItem.id);
      const { error: uploadError } = await serviceClient.storage.from(bucket).upload(path, pendingFile, { upsert: true, contentType: pendingFile.type }); if (uploadError) throw uploadError;
      const { error } = await serviceClient.rpc('set_my_deadline_item_image', { p_item_id: currentItem.id, p_image_path: path }); if (error) throw error;
    }
    input.addEventListener('change', () => { const file = input.files?.[0]; input.value = ''; if (!file) return; if (!allowedTypes.has(file.type)) { setMessage('Scegli un’immagine JPG, PNG o WebP.', true); return; } if (file.size > maxBytes) { setMessage('L’immagine deve pesare al massimo 2 MB.', true); return; } pendingFile = file; removalRequested = false; setMessage('Foto pronta per il salvataggio.'); void refresh(); });
    remove.addEventListener('click', () => { pendingFile = null; removalRequested = Boolean(item()?.image_path); setMessage('La foto verrà rimossa al salvataggio.'); renderFallback(); remove.hidden = true; upload.textContent = 'Carica foto'; });
    return { refresh, reset, save, setMessage };
  }

  global.FamilAreaDeadlineItemImage = { bucket, allowedTypes, maxBytes, resolve, storagePath, render, createEditor };
}(window));

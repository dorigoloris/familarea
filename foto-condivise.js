const sharedPhotosClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const sharedPhotosMessage = document.getElementById('shared-photos-message');
const sharedPhotosLogin = document.getElementById('shared-photos-login');
const sharedPhotosLoginLink = document.getElementById('shared-photos-login-link');
const sharedPhotosContent = document.getElementById('shared-photos-content');
const sharedPhotosGrid = document.getElementById('shared-photos-grid');
const sharedPhotosEmpty = document.getElementById('shared-photos-empty');
const sharedPhotoViewer = document.getElementById('shared-photo-viewer');
const sharedPhotoViewerImage = document.getElementById('shared-photo-viewer-image');
const sharedPhotoViewerClose = document.getElementById('shared-photo-viewer-close');

const sharedPhotoObjectUrls = new Map();
const sharedPhotoMimeTypes = new Set(['image/jpeg', 'image/png', 'image/webp']);
const sharedPhotoDownloadConcurrency = 3;
const sharedPhotoUuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const sharedPhotoShareId = new URLSearchParams(window.location.search).get('share') || '';

function isUuid(value) {
  return typeof value === 'string' && sharedPhotoUuidPattern.test(value);
}

function setSharedPhotosMessage(message, isError = false) {
  sharedPhotosMessage.textContent = message;
  sharedPhotosMessage.classList.toggle('fa-v2-status--error', isError);
}

function galleryReturnTo() {
  return `foto-condivise.html?share=${encodeURIComponent(sharedPhotoShareId)}`;
}

function showLogin() {
  sharedPhotosContent.hidden = true;
  sharedPhotosLogin.hidden = false;
  sharedPhotosLoginLink.href = FamilAreaAuthUtils.loginUrl(galleryReturnTo());
  setSharedPhotosMessage('Accedi per visualizzare le fotografie condivise.');
}

function showUnavailable() {
  sharedPhotosLogin.hidden = true;
  sharedPhotosContent.hidden = true;
  setSharedPhotosMessage('Questa condivisione non Ã¨ disponibile.', true);
}

function revokeSharedPhotoObjectUrls() {
  for (const objectUrl of sharedPhotoObjectUrls.values()) URL.revokeObjectURL(objectUrl);
  sharedPhotoObjectUrls.clear();
}

function closeSharedPhotoViewer() {
  sharedPhotoViewer.hidden = true;
  sharedPhotoViewerImage.removeAttribute('src');
}

function openSharedPhotoViewer(attachmentId) {
  const objectUrl = sharedPhotoObjectUrls.get(attachmentId);
  if (!objectUrl) return;
  sharedPhotoViewerImage.src = objectUrl;
  sharedPhotoViewer.hidden = false;
  sharedPhotoViewerClose.focus();
}

function proxyUrl(attachmentId) {
  const parameters = new URLSearchParams({ share_id: sharedPhotoShareId, attachment_id: attachmentId });
  return `${SUPABASE_URL}/functions/v1/shared-memory-photo-image?${parameters}`;
}

async function downloadSharedPhoto(photo, accessToken) {
  const response = await fetch(proxyUrl(photo.attachment_id), {
    headers: { Authorization: `Bearer ${accessToken}` },
    cache: 'no-store',
  });
  if (response.status === 401) throw new Error('shared_photo_unauthenticated');
  if (!response.ok) throw new Error('shared_photo_unavailable');

  const responseMimeType = (response.headers.get('Content-Type') || '').split(';', 1)[0].trim().toLowerCase();
  if (!sharedPhotoMimeTypes.has(responseMimeType) || responseMimeType !== photo.mime_type) {
    throw new Error('shared_photo_invalid_response');
  }

  const image = await response.blob();
  if (!image.size || image.type.toLowerCase() !== responseMimeType) throw new Error('shared_photo_invalid_response');
  const objectUrl = URL.createObjectURL(image);
  sharedPhotoObjectUrls.set(photo.attachment_id, objectUrl);
  return objectUrl;
}

function sharedPhotoTile(photo) {
  const tile = document.createElement('button');
  tile.type = 'button';
  tile.className = 'shared-photo-tile';
  tile.dataset.attachmentId = photo.attachment_id;
  tile.setAttribute('aria-label', 'Apri fotografia condivisa');
  tile.textContent = 'Caricamento...';
  tile.addEventListener('click', () => openSharedPhotoViewer(photo.attachment_id));
  return tile;
}

async function loadPhotoTile(photo, tile, accessToken) {
  try {
    const objectUrl = await downloadSharedPhoto(photo, accessToken);
    const image = document.createElement('img');
    image.src = objectUrl;
    image.alt = 'Fotografia condivisa';
    tile.replaceChildren(image);
    return 'loaded';
  } catch (error) {
    tile.disabled = true;
    tile.removeAttribute('aria-label');
    tile.textContent = 'Non disponibile';
    return error?.message === 'shared_photo_unauthenticated' ? 'unauthenticated' : 'unavailable';
  }
}

async function loadPhotoTiles(photos, accessToken) {
  const tiles = photos.map((photo) => ({ photo, tile: sharedPhotoTile(photo) }));
  sharedPhotosGrid.replaceChildren(...tiles.map(({ tile }) => tile));

  let nextIndex = 0;
  const outcomes = [];
  async function worker() {
    while (nextIndex < tiles.length) {
      const currentIndex = nextIndex;
      nextIndex += 1;
      const { photo, tile } = tiles[currentIndex];
      outcomes.push(await loadPhotoTile(photo, tile, accessToken));
    }
  }

  await Promise.all(Array.from({ length: Math.min(sharedPhotoDownloadConcurrency, tiles.length) }, worker));
  return outcomes;
}

function validGalleryPhoto(photo) {
  return photo
    && typeof photo === 'object'
    && isUuid(photo.attachment_id)
    && typeof photo.mime_type === 'string'
    && sharedPhotoMimeTypes.has(photo.mime_type);
}

async function loadSharedPhotos() {
  closeSharedPhotoViewer();
  revokeSharedPhotoObjectUrls();
  sharedPhotosGrid.replaceChildren();

  if (!isUuid(sharedPhotoShareId)) {
    showUnavailable();
    return;
  }

  const mfaResult = window.FamilAreaMfaGuard ? await window.FamilAreaMfaGuard.ready : null;
  if (mfaResult && !mfaResult.passed) return;

  const { data: sessionData, error: sessionError } = await sharedPhotosClient.auth.getSession();
  const session = sessionData?.session;
  if (sessionError || !session?.access_token) {
    showLogin();
    return;
  }

  const { data, error } = await sharedPhotosClient.rpc('get_my_memory_photo_share_gallery', {
    p_share_id: sharedPhotoShareId,
  });
  if (error || !data || data.share_id !== sharedPhotoShareId || !Array.isArray(data.photos)) {
    showUnavailable();
    return;
  }

  const photos = data.photos.filter(validGalleryPhoto);
  sharedPhotosLogin.hidden = true;
  sharedPhotosContent.hidden = false;
  sharedPhotosEmpty.hidden = photos.length !== 0;
  if (photos.length === 0) {
    setSharedPhotosMessage('');
    return;
  }

  setSharedPhotosMessage('Caricamento fotografie...');
  const outcomes = await loadPhotoTiles(photos, session.access_token);
  if (outcomes.includes('unauthenticated')) {
    revokeSharedPhotoObjectUrls();
    showLogin();
    return;
  }
  if (!outcomes.includes('loaded')) {
    revokeSharedPhotoObjectUrls();
    showUnavailable();
    return;
  }
  setSharedPhotosMessage('');
}

sharedPhotoViewerClose.addEventListener('click', closeSharedPhotoViewer);
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && !sharedPhotoViewer.hidden) closeSharedPhotoViewer();
});
window.addEventListener('pagehide', revokeSharedPhotoObjectUrls, { once: true });

void loadSharedPhotos();
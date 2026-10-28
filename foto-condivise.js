const sharedPhotosClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const sharedPhotosMain = document.getElementById('shared-photos-main');
const sharedPhotosMessage = document.getElementById('shared-photos-message');
const sharedPhotosTitle = document.getElementById('shared-photos-title');
const sharedPhotosDate = document.getElementById('shared-photos-date');
const sharedPhotosDescription = document.getElementById('shared-photos-description');
const sharedPhotosLogin = document.getElementById('shared-photos-login');
const sharedPhotosLoginLink = document.getElementById('shared-photos-login-link');
const sharedPhotosContent = document.getElementById('shared-photos-content');
const sharedPhotosGrid = document.getElementById('shared-photos-grid');
const sharedPhotosEmpty = document.getElementById('shared-photos-empty');
const sharedPhotoViewer = document.getElementById('shared-photo-viewer');
const sharedPhotoViewerImage = document.getElementById('shared-photo-viewer-image');
const sharedPhotoViewerClose = document.getElementById('shared-photo-viewer-close');
const sharedPhotoViewerPrevious = document.getElementById('shared-photo-viewer-previous');
const sharedPhotoViewerNext = document.getElementById('shared-photo-viewer-next');
const sharedPhotoViewerPosition = document.getElementById('shared-photo-viewer-position');
const sharedPhotosLogoutButton = document.querySelector('[data-logout]');
const sharedPhotosLogoutMessage = document.getElementById('logout-message');

const sharedPhotoObjectUrls = new Map();
const sharedPhotoMimeTypes = new Set(['image/jpeg', 'image/png', 'image/webp']);
const sharedPhotoDownloadConcurrency = 3;
const sharedPhotoUuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const sharedPhotoDatePattern = /^\d{4}-\d{2}-\d{2}$/;
const sharedPhotoShareId = new URLSearchParams(window.location.search).get('share') || '';

let sharedViewerPhotos = [];
let sharedPhotoViewerIndex = -1;
let sharedPhotoViewerTrigger = null;
const sharedPhotoViewerBackgroundState = new Map();

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

function resetAlbumContext() {
  sharedPhotosTitle.textContent = 'Fotografie condivise';
  sharedPhotosDate.textContent = '';
  sharedPhotosDate.hidden = true;
  sharedPhotosDescription.textContent = '';
  sharedPhotosDescription.hidden = true;
  document.title = 'Fotografie condivise - FamilArea';
}

function formatAlbumDate(value) {
  if (typeof value !== 'string' || !sharedPhotoDatePattern.test(value)) return '';
  const date = new Date(`${value}T12:00:00`);
  if (Number.isNaN(date.getTime())) return '';
  return new Intl.DateTimeFormat('it-IT', {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  }).format(date);
}

function validAlbumContext(album) {
  return album
    && typeof album === 'object'
    && !Array.isArray(album)
    && typeof album.title === 'string'
    && album.title.trim().length > 0
    && typeof album.occurred_on === 'string'
    && Boolean(formatAlbumDate(album.occurred_on))
    && (album.description === null || typeof album.description === 'string');
}

function renderAlbumContext(album) {
  const formattedDate = formatAlbumDate(album.occurred_on);
  const description = typeof album.description === 'string' ? album.description.trim() : '';

  sharedPhotosTitle.textContent = album.title;
  sharedPhotosDate.textContent = formattedDate;
  sharedPhotosDate.hidden = false;
  sharedPhotosDescription.textContent = description;
  sharedPhotosDescription.hidden = !description;
  document.title = `${album.title} - FamilArea`;
}

function showLogin() {
  closeSharedPhotoViewer({ restoreFocus: false });
  resetAlbumContext();
  sharedPhotosContent.hidden = true;
  sharedPhotosLogin.hidden = false;
  sharedPhotosLoginLink.href = FamilAreaAuthUtils.loginUrl(galleryReturnTo());
  setSharedPhotosMessage('Accedi per visualizzare le fotografie condivise.');
}

function showUnavailable() {
  closeSharedPhotoViewer({ restoreFocus: false });
  resetAlbumContext();
  sharedPhotosLogin.hidden = true;
  sharedPhotosContent.hidden = true;
  setSharedPhotosMessage('Questa condivisione non è disponibile.', true);
}

function revokeSharedPhotoObjectUrls() {
  for (const objectUrl of sharedPhotoObjectUrls.values()) URL.revokeObjectURL(objectUrl);
  sharedPhotoObjectUrls.clear();
  sharedViewerPhotos = [];
  sharedPhotoViewerIndex = -1;
}

function setSharedPhotoViewerIsolation(isolated) {
  const elements = [sharedPhotosMain, sharedPhotosLogoutButton, sharedPhotosLogoutMessage].filter(Boolean);

  if (isolated) {
    sharedPhotoViewerBackgroundState.clear();
    elements.forEach((element) => {
      sharedPhotoViewerBackgroundState.set(element, {
        inert: element.inert,
        ariaHidden: element.getAttribute('aria-hidden'),
      });
      element.inert = true;
      element.setAttribute('aria-hidden', 'true');
    });
    document.body.classList.add('confirm-modal-open');
    return;
  }

  elements.forEach((element) => {
    const previous = sharedPhotoViewerBackgroundState.get(element);
    if (!previous) return;
    element.inert = previous.inert;
    if (previous.ariaHidden === null) element.removeAttribute('aria-hidden');
    else element.setAttribute('aria-hidden', previous.ariaHidden);
  });
  sharedPhotoViewerBackgroundState.clear();
  document.body.classList.remove('confirm-modal-open');
}

function closeSharedPhotoViewer({ restoreFocus = true } = {}) {
  const wasOpen = !sharedPhotoViewer.hidden;
  sharedPhotoViewer.hidden = true;
  sharedPhotoViewerImage.removeAttribute('src');
  sharedPhotoViewerImage.alt = '';
  sharedPhotoViewerPosition.textContent = '';
  sharedPhotoViewerIndex = -1;
  if (!wasOpen) return;

  setSharedPhotoViewerIsolation(false);
  if (restoreFocus && sharedPhotoViewerTrigger?.isConnected) sharedPhotoViewerTrigger.focus();
  sharedPhotoViewerTrigger = null;
}

function renderSharedPhotoViewer() {
  const photo = sharedViewerPhotos[sharedPhotoViewerIndex];
  const objectUrl = photo && sharedPhotoObjectUrls.get(photo.attachment_id);
  if (!photo || !objectUrl) {
    closeSharedPhotoViewer();
    return;
  }

  sharedPhotoViewerImage.src = objectUrl;
  sharedPhotoViewerImage.alt = `Fotografia condivisa ${sharedPhotoViewerIndex + 1} di ${sharedViewerPhotos.length}`;
  sharedPhotoViewerPosition.textContent = `${sharedPhotoViewerIndex + 1} di ${sharedViewerPhotos.length}`;
  sharedPhotoViewerPrevious.disabled = sharedPhotoViewerIndex === 0;
  sharedPhotoViewerNext.disabled = sharedPhotoViewerIndex === sharedViewerPhotos.length - 1;
}

function openSharedPhotoViewer(attachmentId, trigger) {
  const photoIndex = sharedViewerPhotos.findIndex((photo) => photo.attachment_id === attachmentId);
  if (photoIndex < 0 || !sharedPhotoObjectUrls.has(attachmentId)) return;

  sharedPhotoViewerIndex = photoIndex;
  sharedPhotoViewerTrigger = trigger || null;
  sharedPhotoViewer.hidden = false;
  setSharedPhotoViewerIsolation(true);
  renderSharedPhotoViewer();
  sharedPhotoViewerClose.focus();
}

function moveSharedPhotoViewer(step) {
  const nextIndex = sharedPhotoViewerIndex + step;
  if (nextIndex < 0 || nextIndex >= sharedViewerPhotos.length) return;
  sharedPhotoViewerIndex = nextIndex;
  renderSharedPhotoViewer();
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

function sharedPhotoTile(photo, position) {
  const tile = document.createElement('button');
  tile.type = 'button';
  tile.className = 'shared-photo-tile';
  tile.dataset.attachmentId = photo.attachment_id;
  tile.setAttribute('aria-label', `Apri fotografia condivisa ${position}`);
  tile.textContent = 'Caricamento...';
  tile.addEventListener('click', () => openSharedPhotoViewer(photo.attachment_id, tile));
  return tile;
}

async function loadPhotoTile(photo, tile, accessToken) {
  try {
    const objectUrl = await downloadSharedPhoto(photo, accessToken);
    const image = document.createElement('img');
    image.src = objectUrl;
    image.alt = '';
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
  const tiles = photos.map((photo, index) => ({ photo, tile: sharedPhotoTile(photo, index + 1) }));
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
  sharedViewerPhotos = photos.filter((photo) => sharedPhotoObjectUrls.has(photo.attachment_id));
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
  closeSharedPhotoViewer({ restoreFocus: false });
  revokeSharedPhotoObjectUrls();
  resetAlbumContext();
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
  if (
    error
    || !data
    || typeof data !== 'object'
    || Array.isArray(data)
    || data.share_id !== sharedPhotoShareId
    || !validAlbumContext(data.album)
    || !Array.isArray(data.photos)
  ) {
    showUnavailable();
    return;
  }

  const photos = data.photos.filter(validGalleryPhoto);
  renderAlbumContext(data.album);
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

sharedPhotoViewerClose.addEventListener('click', () => closeSharedPhotoViewer());
sharedPhotoViewerPrevious.addEventListener('click', () => moveSharedPhotoViewer(-1));
sharedPhotoViewerNext.addEventListener('click', () => moveSharedPhotoViewer(1));
sharedPhotoViewer.addEventListener('click', (event) => {
  if (event.target === sharedPhotoViewer) closeSharedPhotoViewer();
});
document.addEventListener('keydown', (event) => {
  if (sharedPhotoViewer.hidden) return;
  if (event.key === 'Escape') {
    event.preventDefault();
    closeSharedPhotoViewer();
  } else if (event.key === 'Tab') {
    const focusable = [sharedPhotoViewerClose, sharedPhotoViewerPrevious, sharedPhotoViewerNext]
      .filter((element) => !element.disabled);
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && (document.activeElement === first || !sharedPhotoViewer.contains(document.activeElement))) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && (document.activeElement === last || !sharedPhotoViewer.contains(document.activeElement))) {
      event.preventDefault();
      first.focus();
    }
  } else if (event.key === 'ArrowLeft') {
    event.preventDefault();
    moveSharedPhotoViewer(-1);
  } else if (event.key === 'ArrowRight') {
    event.preventDefault();
    moveSharedPhotoViewer(1);
  }
});
window.addEventListener('pagehide', () => {
  closeSharedPhotoViewer({ restoreFocus: false });
  revokeSharedPhotoObjectUrls();
}, { once: true });

void loadSharedPhotos();

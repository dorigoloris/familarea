const timelineClient = window.FamilAreaSupabaseClient || supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const timelineMessage = document.getElementById('timeline-message');
const timelineTitle = document.getElementById('timeline-title');
const timelineIntro = document.getElementById('timeline-intro');
const timelineHome = document.getElementById('timeline-home');
const timelineBackContainer = document.getElementById('timeline-back-container');
const timelineReturn = document.getElementById('timeline-return');
const timelineCollection = document.getElementById('timeline-collection');
const timelineCollectionList = document.getElementById('timeline-collection-list');
const timelineCollectionEmpty = document.getElementById('timeline-collection-empty');
const timelineCollectionTitle = document.getElementById('timeline-list-title');
const timelineCollectionIntro = document.getElementById('timeline-list-intro');
const timelineCreate = document.getElementById('timeline-create');
const sharedMemoriesCollection = document.getElementById('shared-memories-collection');
const sharedMemoriesList = document.getElementById('shared-memories-list');
const sharedMemoriesEmpty = document.getElementById('shared-memories-empty');
const sharedMemoriesMessage = document.getElementById('shared-memories-message');
const timelineDetail = document.getElementById('timeline-detail');
const timelineDetailTitle = document.getElementById('timeline-detail-title');
const timelineDetailDescription = document.getElementById('timeline-detail-description');
const timelineOptions = document.getElementById('timeline-options');
const memoriesTimeline = document.getElementById('memories-timeline');
const memoriesEmpty = document.getElementById('memories-empty');
const timelineManage = document.getElementById('timeline-manage');
const timelineDelete = document.getElementById('timeline-delete');
const memoryCreateLink = document.getElementById('memory-create-link');
const timelineDocumentCreateLink = document.getElementById('timeline-document-create-action');
const timelineListTitle = document.getElementById('timeline-list-title');
const timelineDocumentsList = document.getElementById('timeline-documents-list');
const galleryModal = document.getElementById('memory-gallery-modal');
const galleryDialog = document.getElementById('memory-gallery-dialog');
const galleryClose = document.getElementById('memory-gallery-close');
const galleryDate = document.getElementById('memory-gallery-date');
const galleryTitle = document.getElementById('memory-gallery-title');
const galleryDescription = document.getElementById('memory-gallery-description');
const galleryShare = document.getElementById('memory-gallery-share');
const galleryMessage = document.getElementById('memory-gallery-message');
const galleryPhotos = document.getElementById('memory-gallery-photos');
const galleryPhotoStage = document.getElementById('memory-gallery-photo-stage');
const galleryPrevious = document.getElementById('memory-gallery-previous');
const galleryNext = document.getElementById('memory-gallery-next');
const galleryPosition = document.getElementById('memory-gallery-position');
const galleryThumbnails = document.getElementById('memory-gallery-thumbnails');
const galleryDocumentsSection = document.getElementById('memory-gallery-documents-section');
const galleryDocuments = document.getElementById('memory-gallery-documents');
const lightbox = document.getElementById('memory-lightbox');
const lightboxClose = document.getElementById('memory-lightbox-close');
const lightboxImage = document.getElementById('memory-lightbox-image');
const lightboxPrevious = document.getElementById('memory-lightbox-previous');
const lightboxNext = document.getElementById('memory-lightbox-next');
const lightboxPosition = document.getElementById('memory-lightbox-position');

const memoryPhotoMimeTypes = new Set(['image/jpeg', 'image/png', 'image/webp']);
const memoryDocumentMimeTypes = new Set(['application/pdf']);
let galleryPhotosData = [];
let galleryPhotoIndex = 0;
let galleryPreviousFocus = null;
let lightboxHistoryEntry = false;
let selectedTimelines = [];
const lightboxGesture = {
  scale: 1,
  x: 0,
  y: 0,
  baseWidth: 0,
  baseHeight: 0,
  pointers: new Map(),
  panOrigin: null,
  pinchOrigin: null,
  moved: false,
  lastTapAt: 0
};
const timelineParams = new URLSearchParams(window.location.search);
const requestedTimelineType = timelineParams.get('type');
const selectedTimelineType = ['memory', 'document'].includes(requestedTimelineType)
  ? requestedTimelineType
  : (timelineParams.get('memory_id') ? 'memory' : '');
let selectedTimelineId = timelineParams.get('timeline_id') || '';

function memoryInitial(title) {
  return (title || '').trim().charAt(0).toLocaleUpperCase('it-IT') || 'R';
}

function formatMemoryDate(value) {
  if (typeof value !== 'string' || !value) return 'Data non disponibile';
  if (window.FamilAreaDateUtils?.formatDateDisplay) {
    const formatted = window.FamilAreaDateUtils.formatDateDisplay(value);
    if (formatted) return formatted;
  }
  const date = new Date(`${value}T12:00:00`);
  return Number.isNaN(date.getTime()) ? 'Data non disponibile' : date.toLocaleDateString('it-IT');
}

function timelineRpcMessage(subject, error) {
  console.error(`[FamilArea timeline] ${subject}`, error);
  const code = error?.code ? ` (${error.code})` : '';
  const reason = error?.message || error?.details || 'Risposta non disponibile.';
  return `Impossibile ${subject}${code}: ${reason}`;
}

function timelineHref(type = selectedTimelineType, timelineId = selectedTimelineId) {
  const params = new URLSearchParams();
  if (type) params.set('type', type);
  if (timelineId) params.set('timeline_id', timelineId);
  return `timeline.html${params.size ? `?${params}` : ''}`;
}

function memoryHref(memory) {
  const params = new URLSearchParams({ memory_id: memory.id });
  const timelineId = selectedTimelineId || memory.timeline_id;
  if (timelineId) params.set('timeline_id', timelineId);
  return `ricordo.html?${params}`;
}

function timelineDocumentHref(timelineDocument) {
  const params = new URLSearchParams({
    timeline_document_id: timelineDocument.id,
    timeline_id: selectedTimelineId || timelineDocument.timeline_id
  });
  return `documento-timeline.html?${params}`;
}

function activeTimeline() {
  return selectedTimelines.find((timeline) => timeline.id === selectedTimelineId) || null;
}

function timelineLabel(type = selectedTimelineType) {
  return type === 'document' ? 'Documenti' : 'Ricordi';
}

function setRouteView(view) {
  timelineHome.hidden = view !== 'home';
  timelineBackContainer.hidden = view === 'home';
  timelineCollection.hidden = view !== 'collection';
  timelineDetail.hidden = view !== 'detail';
  if (view !== 'collection') sharedMemoriesCollection.hidden = true;
}

async function fetchTimelines() {
  const { data, error } = await timelineClient.rpc('get_my_timelines', { p_timeline_type: selectedTimelineType });
  if (error) throw error;
  if (!Array.isArray(data)) throw new Error('Risposta RPC Timeline incompatibile');
  selectedTimelines = data;
}

function createTimelineCard(timeline) {
  const card = document.createElement('a');
  card.className = 'fa-v2-deadline-card fa-v2-deadline-card--interactive fa-v2-card-media-layout';
  card.href = timelineHref(selectedTimelineType, timeline.id);
  const visual = document.createElement('span');
  visual.className = 'fa-v2-card-visual';
  visual.setAttribute('aria-hidden', 'true');
  visual.textContent = memoryInitial(timeline.name);
  const content = document.createElement('span');
  content.className = 'fa-v2-card-content';
  const title = document.createElement('strong');
  title.className = 'fa-v2-card-title';
  title.textContent = timeline.name;
  const description = document.createElement('span');
  description.className = 'fa-v2-card-description';
  description.textContent = timeline.description || (timeline.is_default ? 'Timeline predefinita.' : 'Nessuna descrizione.');
  content.append(title, description);
  const actions = document.createElement('span');
  actions.className = 'fa-v2-card-actions';
  const open = document.createElement('span');
  open.className = 'fa-v2-button fa-v2-button--secondary';
  open.textContent = 'Apri';
  actions.append(open);
  card.append(visual, content, actions);
  return card;
}

function renderTimelineCollection() {
  setRouteView('collection');
  timelineReturn.href = 'timeline.html';
  timelineReturn.textContent = 'Torna alla Timeline';
  timelineTitle.textContent = `Timeline ${timelineLabel()}`;
  timelineIntro.textContent = selectedTimelineType === 'memory'
    ? 'Scegli un archivio di ricordi.'
    : 'Scegli un archivio di documenti.';
  timelineCollectionTitle.textContent = `Le tue Timeline ${timelineLabel()}`;
  timelineCollectionIntro.textContent = selectedTimelineType === 'memory'
    ? 'Apri una Timeline per consultare i suoi ricordi.'
    : 'Apri una Timeline per consultare i suoi documenti cronologici.';
  timelineCreate.textContent = '+ Crea nuova Timeline';
  timelineCollectionList.replaceChildren(...selectedTimelines.map(createTimelineCard));
  timelineCollectionEmpty.hidden = selectedTimelines.length > 0;
  timelineCollectionEmpty.replaceChildren();
  if (!selectedTimelines.length) {
    const heading = document.createElement('strong');
    heading.textContent = `Nessuna Timeline ${timelineLabel()}.`;
    const text = document.createElement('span');
    text.textContent = 'Crea la prima Timeline per iniziare.';
    timelineCollectionEmpty.append(heading, text);
  }
  sharedMemoriesCollection.hidden = true;
  sharedMemoriesList.replaceChildren();
  sharedMemoriesMessage.textContent = '';
  sharedMemoriesEmpty.hidden = true;
}

async function createTimeline() {
  const values = await FamilAreaConfirm.form({
    title: `Nuova Timeline ${timelineLabel()}`,
    message: 'Scegli un nome per il nuovo archivio.',
    confirmText: 'Crea Timeline',
    fields: [
      { name: 'name', label: 'Nome *', required: true, autocomplete: 'off' },
      { name: 'description', label: 'Descrizione facoltativa', autocomplete: 'off' }
    ]
  });
  if (!values) return;
  timelineCreate.disabled = true;
  timelineMessage.textContent = 'Creazione Timeline...';
  try {
    const { data, error } = await timelineClient.rpc('create_timeline', {
      p_timeline_type: selectedTimelineType,
      p_name: values.name,
      p_description: values.description.trim() || null
    });
    if (error || !data?.id) throw error || new Error('Risposta RPC incompatibile');
    window.location.assign(timelineHref(selectedTimelineType, data.id));
  } catch (error) {
    timelineMessage.textContent = timelineRpcMessage('creare la Timeline', error);
    timelineCreate.disabled = false;
  }
}

function renderTimelineDetail() {
  const timeline = activeTimeline();
  if (!timeline) return;
  setRouteView('detail');
  timelineTitle.textContent = timeline.name;
  timelineIntro.textContent = selectedTimelineType === 'memory' ? 'Ricordi in ordine cronologico.' : 'Archivio documentale cronologico.';
  timelineDetailTitle.textContent = timeline.name;
  timelineDetailDescription.textContent = timeline.description || '';
  timelineReturn.href = timelineHref(selectedTimelineType, null);
  timelineReturn.textContent = 'Torna alla Timeline';
  memoryCreateLink.hidden = selectedTimelineType !== 'memory';
  memoryCreateLink.href = `ricordo.html?${new URLSearchParams({ timeline_id: timeline.id })}`;
  timelineDocumentCreateLink.hidden = selectedTimelineType !== 'document';
  timelineDocumentCreateLink.href = `documento-timeline.html?${new URLSearchParams({ timeline_id: timeline.id })}`;
  timelineDelete.hidden = Boolean(timeline.is_default);
  timelineDelete.disabled = Boolean(timeline.is_default);
  timelineOptions.open = false;
  memoriesTimeline.hidden = selectedTimelineType !== 'memory';
  timelineDocumentsList.hidden = selectedTimelineType !== 'document';
  memoriesEmpty.hidden = true;
}

async function manageActiveTimeline() {
  const timeline = activeTimeline();
  if (!timeline) return;
  const values = await FamilAreaConfirm.form({
    title: 'Modifica Timeline',
    message: 'Aggiorna nome e descrizione della Timeline.',
    confirmText: 'Salva modifiche',
    fields: [
      { name: 'name', label: 'Nome *', value: timeline.name, required: true, autocomplete: 'off' },
      { name: 'description', label: 'Descrizione facoltativa', value: timeline.description || '', autocomplete: 'off' }
    ]
  });
  if (!values) return;
  timelineManage.disabled = true;
  try {
    const { data, error } = await timelineClient.rpc('update_timeline', {
      p_timeline_id: timeline.id,
      p_name: values.name,
      p_description: values.description.trim() || null
    });
    if (error || !data?.id) throw error || new Error('Risposta RPC incompatibile');
    selectedTimelines = selectedTimelines.map((item) => item.id === data.id ? data : item);
    renderTimelineDetail();
    timelineMessage.textContent = 'Timeline aggiornata.';
  } catch (error) {
    timelineMessage.textContent = timelineRpcMessage('aggiornare la Timeline', error);
  } finally {
    timelineManage.disabled = false;
  }
}

async function deleteActiveTimeline() {
  const timeline = activeTimeline();
  if (!timeline || timeline.is_default) return;
  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger', title: 'Eliminare la Timeline?',
    message: `“${timeline.name}” può essere eliminata soltanto se non contiene elementi.`,
    confirmText: 'Elimina Timeline'
  });
  if (!confirmed) return;
  timelineDelete.disabled = true;
  try {
    const { error } = await timelineClient.rpc('delete_timeline', { p_timeline_id: timeline.id });
    if (error) throw error;
    window.location.assign(timelineHref(selectedTimelineType));
  } catch (error) {
    timelineMessage.textContent = timelineRpcMessage('eliminare la Timeline', error);
    timelineDelete.disabled = false;
  }
}

function createMemoryCard(memory, { shared = false, onOpen = null, onLeave = null } = {}) {
  const item = shared ? null : document.createElement('div');
  if (item) item.className = 'fa-v2-memory-timeline-item';
  const card = document.createElement('article');
  card.className = 'fa-v2-deadline-card fa-v2-deadline-card--interactive fa-v2-card-media-layout';
  card.dataset.memoryId = memory.id;
  card.tabIndex = 0;
  card.setAttribute('role', 'button');
  card.setAttribute('aria-label', `Apri galleria dell’album ${memory.title || 'senza titolo'}`);
  const open = () => {
    const opener = onOpen || ((item) => openMemoryGallery(item, card, { canShare: !shared }));
    void opener(memory, card);
  };
  card.addEventListener('click', (event) => {
    if (!event.target.closest('a, button')) open();
  });
  card.addEventListener('keydown', (event) => {
    if (event.target.closest('a, button') || !['Enter', ' '].includes(event.key)) return;
    event.preventDefault();
    open();
  });

  const visual = document.createElement('span');
  visual.className = 'fa-v2-card-visual';
  visual.setAttribute('aria-hidden', 'true');
  visual.textContent = memoryInitial(memory.title);
  const content = document.createElement('div');
  content.className = 'fa-v2-card-content';
  const date = document.createElement('p');
  date.className = 'fa-v2-card-description';
  date.textContent = formatMemoryDate(memory.occurred_on);
  const title = document.createElement('h3');
  title.className = 'fa-v2-card-title';
  title.textContent = memory.title || 'Ricordo senza titolo';
  const description = document.createElement('p');
  description.className = 'fa-v2-card-description';
  description.textContent = memory.description || 'Nessuna descrizione.';
  content.append(date, title, description);
  if (shared) {
    const owner = document.createElement('p');
    owner.className = 'fa-v2-card-description';
    owner.textContent = `Condiviso da: ${memory.owner_display_name || 'un account FamilArea'}`;
    content.append(owner);
  }

  const actions = document.createElement('span');
  actions.className = 'fa-v2-card-actions';
  if (shared) {
    const openButton = document.createElement('button');
    openButton.type = 'button';
    openButton.className = 'fa-v2-button fa-v2-button--secondary';
    openButton.textContent = 'Apri';
    openButton.addEventListener('click', (event) => {
      event.stopPropagation();
      open();
    });
    const leaveButton = document.createElement('button');
    leaveButton.type = 'button';
    leaveButton.className = 'fa-v2-button fa-v2-button--danger';
    leaveButton.textContent = 'Abbandona condivisione';
    leaveButton.addEventListener('click', (event) => {
      event.stopPropagation();
      if (onLeave) void onLeave(memory, leaveButton);
    });
    actions.append(openButton, leaveButton);
  } else {
    const edit = document.createElement('a');
    edit.className = 'fa-v2-button fa-v2-button--secondary';
    edit.href = memoryHref(memory);
    edit.textContent = 'Modifica';
    edit.addEventListener('click', (event) => event.stopPropagation());
    actions.append(edit);
  }
  card.append(visual, content, actions);
  if (item) {
    item.append(card);
    return { item, visual };
  }
  return { item: card, visual };
}

async function renderMemoryCover(memory, visual) {
  if (!memory.cover_attachment_id) return;
  try {
    const { data, error } = await timelineClient.rpc('get_attachments', { p_target_type: 'memory', p_target_id: memory.id });
    if (error) throw error;
    const coverAttachment = (data || []).find((attachment) => attachment.id === memory.cover_attachment_id && memoryPhotoMimeTypes.has(attachment.mime_type));
    if (coverAttachment) await window.FamilAreaAttachmentPreview.renderCardPreview({ client: timelineClient, attachment: coverAttachment, container: visual });
  } catch (error) {
    console.warn('[FamilArea timeline] memory cover unavailable', error);
  }
}

function setTimelineInert(inert) {
  [document.querySelector('main'), document.querySelector('.logout-button'), document.getElementById('logout-message')]
    .filter(Boolean)
    .forEach((element) => {
      element.inert = inert;
      if (inert) element.setAttribute('aria-hidden', 'true');
      else element.removeAttribute('aria-hidden');
    });
  document.body.classList.toggle('confirm-modal-open', inert);
}

function setGalleryMessage(text = '', isError = false) {
  galleryMessage.textContent = text;
  galleryMessage.classList.toggle('is-error', isError);
}

function photoPositionText() {
  return galleryPhotosData.length ? `${galleryPhotoIndex + 1} di ${galleryPhotosData.length}` : '';
}

function renderGalleryPhoto() {
  const photo = galleryPhotosData[galleryPhotoIndex];
  galleryPhotoStage.replaceChildren();
  galleryThumbnails.replaceChildren();
  if (!photo) {
    galleryPhotos.hidden = true;
    return;
  }

  galleryPhotos.hidden = false;
  const photoButton = document.createElement('button');
  photoButton.type = 'button';
  photoButton.className = 'memory-gallery-image-button';
  photoButton.setAttribute('aria-label', 'Apri fotografia a schermo intero');
  if (photo.signedUrl) {
    const image = document.createElement('img');
    image.src = photo.signedUrl;
    image.alt = photo.original_filename || 'Fotografia del ricordo';
    image.addEventListener('error', () => {
      photoButton.replaceChildren('Impossibile caricare questa fotografia.');
      photoButton.disabled = true;
    });
    photoButton.append(image);
  } else {
    photoButton.disabled = true;
    photoButton.textContent = 'Impossibile caricare questa fotografia.';
  }
  photoButton.addEventListener('click', openLightbox);
  galleryPhotoStage.append(photoButton);
  galleryPosition.textContent = photoPositionText();
  galleryPrevious.disabled = galleryPhotosData.length < 2;
  galleryNext.disabled = galleryPhotosData.length < 2;

  galleryPhotosData.forEach((thumbnailPhoto, index) => {
    const thumbnail = document.createElement('button');
    thumbnail.type = 'button';
    thumbnail.className = 'memory-gallery-thumbnail';
    thumbnail.setAttribute('aria-label', `Mostra fotografia ${index + 1}`);
    thumbnail.setAttribute('aria-current', String(index === galleryPhotoIndex));
    if (thumbnailPhoto.signedUrl) {
      const thumbnailImage = document.createElement('img');
      thumbnailImage.src = thumbnailPhoto.signedUrl;
      thumbnailImage.alt = '';
      thumbnailImage.addEventListener('error', () => thumbnail.replaceChildren(String(index + 1)));
      thumbnail.append(thumbnailImage);
    } else {
      thumbnail.textContent = String(index + 1);
      thumbnail.disabled = true;
    }
    thumbnail.addEventListener('click', () => setGalleryPhoto(index));
    galleryThumbnails.append(thumbnail);
  });
}

function setGalleryPhoto(index) {
  if (!galleryPhotosData.length) return;
  galleryPhotoIndex = (index + galleryPhotosData.length) % galleryPhotosData.length;
  renderGalleryPhoto();
  if (!lightbox.hidden) renderLightboxPhoto();
}

function renderLightboxPhoto() {
  const photo = galleryPhotosData[galleryPhotoIndex];
  if (!photo?.signedUrl) return closeLightbox();
  resetLightboxTransform();
  lightboxImage.style.removeProperty('width');
  lightboxImage.style.removeProperty('height');
  lightboxImage.src = photo.signedUrl;
  lightboxImage.alt = photo.original_filename || 'Fotografia del ricordo';
  lightboxPosition.textContent = photoPositionText();
  lightboxPrevious.disabled = galleryPhotosData.length < 2;
  lightboxNext.disabled = galleryPhotosData.length < 2;
}

function useImmersiveLightbox() {
  return window.matchMedia?.('(pointer: coarse)').matches === true;
}

function requestLightboxFullscreen() {
  if (!useImmersiveLightbox() || typeof lightbox.requestFullscreen !== 'function') return;
  Promise.resolve(lightbox.requestFullscreen()).catch(() => {
    // Fullscreen is optional and may be denied by the browser or installed PWA.
  });
}

function exitLightboxFullscreen() {
  if (document.fullscreenElement !== lightbox || typeof document.exitFullscreen !== 'function') return;
  Promise.resolve(document.exitFullscreen()).catch(() => {});
}

function openLightbox() {
  if (!galleryPhotosData[galleryPhotoIndex]?.signedUrl) return;
  lightbox.hidden = false;
  lightbox.classList.toggle('memory-lightbox--immersive', useImmersiveLightbox());
  if (useImmersiveLightbox() && !lightboxHistoryEntry) {
    history.pushState({ ...(history.state || {}), familareaMemoryLightbox: true }, '');
    lightboxHistoryEntry = true;
  }
  renderLightboxPhoto();
  requestLightboxFullscreen();
  if (!useImmersiveLightbox()) lightboxClose.focus();
}

function closeLightbox({ fromHistory = false } = {}) {
  if (lightbox.hidden) return;
  resetLightboxTransform();
  lightbox.hidden = true;
  lightbox.classList.remove('memory-lightbox--immersive');
  lightboxImage.removeAttribute('src');
  exitLightboxFullscreen();
  if (lightboxHistoryEntry && !fromHistory) {
    lightboxHistoryEntry = false;
    history.back();
  } else {
    lightboxHistoryEntry = false;
  }
  galleryPhotoStage.querySelector('button')?.focus();
}

function resetLightboxTransform() {
  lightboxGesture.scale = 1;
  lightboxGesture.x = 0;
  lightboxGesture.y = 0;
  lightboxGesture.baseWidth = 0;
  lightboxGesture.baseHeight = 0;
  lightboxGesture.pointers.clear();
  lightboxGesture.panOrigin = null;
  lightboxGesture.pinchOrigin = null;
  lightboxGesture.moved = false;
  lightboxImage.style.transform = '';
}

function fitLightboxImage() {
  if (lightbox.hidden || !lightboxImage.naturalWidth || !lightboxImage.naturalHeight) return;
  const stage = lightboxImage.parentElement.getBoundingClientRect();
  if (!stage.width || !stage.height) return;
  const fit = Math.min(stage.width / lightboxImage.naturalWidth, stage.height / lightboxImage.naturalHeight);
  lightboxGesture.baseWidth = lightboxImage.naturalWidth * fit;
  lightboxGesture.baseHeight = lightboxImage.naturalHeight * fit;
  lightboxImage.style.width = `${lightboxGesture.baseWidth}px`;
  lightboxImage.style.height = `${lightboxGesture.baseHeight}px`;
  applyLightboxTransform();
}

function clampLightboxPosition() {
  const stage = lightboxImage.parentElement.getBoundingClientRect();
  const maxX = Math.max(0, (lightboxGesture.baseWidth * lightboxGesture.scale - stage.width) / 2);
  const maxY = Math.max(0, (lightboxGesture.baseHeight * lightboxGesture.scale - stage.height) / 2);
  lightboxGesture.x = Math.max(-maxX, Math.min(maxX, lightboxGesture.x));
  lightboxGesture.y = Math.max(-maxY, Math.min(maxY, lightboxGesture.y));
}

function applyLightboxTransform() {
  if (lightboxGesture.scale <= 1) {
    lightboxGesture.scale = 1;
    lightboxGesture.x = 0;
    lightboxGesture.y = 0;
  } else {
    clampLightboxPosition();
  }
  lightboxImage.style.transform = `translate3d(${lightboxGesture.x}px, ${lightboxGesture.y}px, 0) scale(${lightboxGesture.scale})`;
}

function pointerDistance() {
  const [first, second] = [...lightboxGesture.pointers.values()];
  return Math.hypot(second.x - first.x, second.y - first.y);
}

function attachLightboxGestures(stage) {
  stage.addEventListener('pointerdown', (event) => {
    if (event.pointerType === 'mouse' && event.button !== 0) return;
    stage.setPointerCapture?.(event.pointerId);
    lightboxGesture.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
    lightboxGesture.moved = false;
    if (lightboxGesture.pointers.size === 2) {
      lightboxGesture.pinchOrigin = { distance: pointerDistance(), scale: lightboxGesture.scale };
      lightboxGesture.panOrigin = null;
      return;
    }
    lightboxGesture.panOrigin = { pointerId: event.pointerId, x: event.clientX, y: event.clientY, imageX: lightboxGesture.x, imageY: lightboxGesture.y };
  });

  stage.addEventListener('pointermove', (event) => {
    if (!lightboxGesture.pointers.has(event.pointerId)) return;
    const previous = lightboxGesture.pointers.get(event.pointerId);
    lightboxGesture.pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
    if (Math.hypot(event.clientX - previous.x, event.clientY - previous.y) > 4) lightboxGesture.moved = true;

    if (lightboxGesture.pointers.size >= 2 && lightboxGesture.pinchOrigin?.distance) {
      lightboxGesture.scale = Math.max(1, Math.min(4, lightboxGesture.pinchOrigin.scale * (pointerDistance() / lightboxGesture.pinchOrigin.distance)));
      applyLightboxTransform();
      return;
    }
    if (lightboxGesture.scale <= 1 || lightboxGesture.panOrigin?.pointerId !== event.pointerId) return;
    lightboxGesture.x = lightboxGesture.panOrigin.imageX + event.clientX - lightboxGesture.panOrigin.x;
    lightboxGesture.y = lightboxGesture.panOrigin.imageY + event.clientY - lightboxGesture.panOrigin.y;
    applyLightboxTransform();
  });

  const finishPointer = (event) => {
    const origin = lightboxGesture.panOrigin;
    const wasPinching = lightboxGesture.pointers.size >= 2 || Boolean(lightboxGesture.pinchOrigin);
    lightboxGesture.pointers.delete(event.pointerId);
    if (lightboxGesture.pointers.size < 2) lightboxGesture.pinchOrigin = null;

    if (!wasPinching && lightboxGesture.scale === 1 && origin?.pointerId === event.pointerId) {
      const deltaX = event.clientX - origin.x;
      const deltaY = event.clientY - origin.y;
      if (useImmersiveLightbox() && Math.abs(deltaY) >= 72 && Math.abs(deltaY) > Math.abs(deltaX)) {
        closeLightbox();
      } else if (Math.abs(deltaX) >= 48 && Math.abs(deltaX) > Math.abs(deltaY)) {
        setGalleryPhoto(galleryPhotoIndex + (deltaX < 0 ? 1 : -1));
      } else if (!lightboxGesture.moved && event.pointerType !== 'mouse') {
        const now = Date.now();
        if (now - lightboxGesture.lastTapAt < 300) {
          lightboxGesture.scale = lightboxGesture.scale === 1 ? 2 : 1;
          applyLightboxTransform();
          lightboxGesture.lastTapAt = 0;
        } else {
          lightboxGesture.lastTapAt = now;
        }
      }
    }
    if (lightboxGesture.pointers.size === 1) {
      const [pointerId, point] = [...lightboxGesture.pointers.entries()][0];
      lightboxGesture.panOrigin = { pointerId, x: point.x, y: point.y, imageX: lightboxGesture.x, imageY: lightboxGesture.y };
    } else {
      lightboxGesture.panOrigin = null;
    }
  };

  stage.addEventListener('pointerup', finishPointer);
  stage.addEventListener('pointercancel', finishPointer);
}

async function openAttachment(attachment, button) {
  button.disabled = true;
  try {
    const signedUrl = await window.FamilAreaAttachmentPreview.getSignedUrl(timelineClient, attachment, 60);
    window.open(signedUrl, '_blank', 'noopener');
  } catch (error) {
    console.error('[FamilArea timeline] document open failed', error);
    setGalleryMessage('Impossibile aprire il documento. Riprova.', true);
  } finally {
    button.disabled = false;
  }
}

function renderGalleryDocuments(documents) {
  galleryDocuments.replaceChildren();
  galleryDocumentsSection.hidden = documents.length === 0;
  documents.forEach((attachment) => {
    const row = document.createElement('div');
    row.className = 'deadline-attachment';
    const name = document.createElement('strong');
    name.textContent = attachment.original_filename || 'Documento PDF';
    const open = document.createElement('button');
    open.type = 'button';
    open.className = 'secondary-button';
    open.textContent = 'Apri';
    open.addEventListener('click', () => void openAttachment(attachment, open));
    row.append(name, open);
    galleryDocuments.append(row);
  });
}

async function signedPhoto(attachment) {
  try {
    return { ...attachment, signedUrl: await window.FamilAreaAttachmentPreview.getSignedUrl(timelineClient, attachment) };
  } catch (error) {
    console.warn('[FamilArea timeline] memory photograph unavailable', error);
    return { ...attachment, signedUrl: null };
  }
}

async function openMemoryGallery(memory, trigger, { canShare = false } = {}) {
  galleryPreviousFocus = trigger;
  galleryModal.hidden = false;
  setTimelineInert(true);
  galleryDialog.focus();
  galleryDate.textContent = formatMemoryDate(memory.occurred_on);
  galleryTitle.textContent = memory.title || 'Ricordo senza titolo';
  galleryDescription.textContent = memory.description || '';
  galleryDescription.hidden = !memory.description;
  galleryShare.hidden = !canShare;
  if (canShare) {
    const href = new URL(memoryHref(memory), window.location.href);
    href.searchParams.set('share', '1');
    galleryShare.href = `${href.pathname}${href.search}`;
  }
  galleryPhotosData = [];
  galleryPhotoIndex = 0;
  galleryPhotos.hidden = true;
  galleryDocumentsSection.hidden = true;
  galleryPhotoStage.replaceChildren();
  galleryThumbnails.replaceChildren();
  galleryDocuments.replaceChildren();
  setGalleryMessage('Caricamento fotografie e documenti...');

  const { data, error } = await timelineClient.rpc('get_attachments', { p_target_type: 'memory', p_target_id: memory.id });
  if (error) {
    console.error('[FamilArea timeline] gallery attachments failed', error);
    setGalleryMessage('Impossibile caricare gli allegati del ricordo.', true);
    return;
  }
  const attachments = Array.isArray(data) ? data : [];
  const photos = attachments.filter((attachment) => memoryPhotoMimeTypes.has(attachment.mime_type));
  const coverIndex = photos.findIndex((attachment) => attachment.id === memory.cover_attachment_id);
  if (coverIndex > 0) photos.unshift(photos.splice(coverIndex, 1)[0]);
  galleryPhotosData = await Promise.all(photos.map(signedPhoto));
  renderGalleryPhoto();
  renderGalleryDocuments(attachments.filter((attachment) => memoryDocumentMimeTypes.has(attachment.mime_type)));
  setGalleryMessage(galleryPhotosData.some((photo) => !photo.signedUrl) ? 'Alcune fotografie non sono disponibili al momento.' : '');
}

function closeMemoryGallery() {
  closeLightbox();
  if (galleryModal.hidden) return;
  galleryModal.hidden = true;
  setTimelineInert(false);
  galleryPhotosData = [];
  galleryShare.hidden = true;
  galleryPreviousFocus?.focus?.();
  galleryPreviousFocus = null;
}

function attachSwipe(element, callback) {
  let origin = null;
  element.addEventListener('pointerdown', (event) => {
    if (event.pointerType === 'touch' || event.pointerType === 'pen') origin = { x: event.clientX, y: event.clientY };
  });
  element.addEventListener('pointerup', (event) => {
    if (!origin) return;
    const deltaX = event.clientX - origin.x;
    const deltaY = event.clientY - origin.y;
    origin = null;
    if (Math.abs(deltaX) >= 48 && Math.abs(deltaX) > Math.abs(deltaY)) callback(deltaX < 0 ? 1 : -1);
  });
  element.addEventListener('pointercancel', () => { origin = null; });
}

function loadingError(error) {
  console.error('[FamilArea timeline] memories load failed', error);
  const code = error?.code ? ` (${error.code})` : '';
  const reason = error?.message || error?.details || 'Risposta non disponibile.';
  return `Impossibile caricare i ricordi${code}: ${reason}`;
}

function highlightRequestedMemory(cards) {
  const url = new URL(window.location.href);
  const requestedMemoryId = url.searchParams.get('memory_id');
  if (!requestedMemoryId) return;
  const requestedCard = cards.find(({ memory }) => memory.id === requestedMemoryId)?.item.querySelector('[data-memory-id]');
  if (!requestedCard) return;

  requestAnimationFrame(() => {
    requestedCard.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'nearest' });
    requestedCard.classList.add('fa-v2-memory-card--highlighted');
    window.setTimeout(() => requestedCard.classList.remove('fa-v2-memory-card--highlighted'), 3600);
  });
  url.searchParams.delete('memory_id');
  window.history.replaceState(window.history.state, '', `${url.pathname}${url.search}${url.hash}`);
}

async function loadSelectedMemoryTimeline() {
  const timeline = activeTimeline();
  if (!timeline) return;
  memoriesTimeline.replaceChildren();
  memoriesEmpty.hidden = true;
  timelineMessage.textContent = 'Caricamento ricordi...';
  const { data, error } = await timelineClient.rpc('get_my_memories_for_timeline', { p_timeline_id: timeline.id });
  if (error) {
    timelineMessage.textContent = loadingError(error);
    return;
  }
  if (!Array.isArray(data)) {
    timelineMessage.textContent = 'Impossibile caricare i ricordi: risposta RPC incompatibile.';
    return;
  }
  const cards = data.map((memory) => ({ memory, ...createMemoryCard(memory) }));
  memoriesTimeline.replaceChildren(...cards.map(({ item }) => item));
  memoriesEmpty.replaceChildren();
  if (!data.length) {
    const heading = document.createElement('strong');
    heading.textContent = 'Nessun album.';
    const text = document.createElement('span');
    text.textContent = 'Crea il primo album in questa Timeline.';
    memoriesEmpty.append(heading, text);
    memoriesEmpty.hidden = false;
  }
  timelineMessage.textContent = '';
  highlightRequestedMemory(cards);
  await Promise.all(cards.map(({ memory, visual }) => renderMemoryCover(memory, visual)));
}

async function openSharedMemoryGallery(memory, trigger) {
  const { data, error } = await timelineClient.rpc('get_shared_memory', { p_memory_id: memory.id });
  if (error || !data?.id) {
    sharedMemoriesMessage.textContent = error
      ? timelineRpcMessage('aprire l’album condiviso', error)
      : 'Album condiviso non disponibile.';
    return;
  }
  await openMemoryGallery(data, trigger);
}

async function leaveSharedMemory(memory, button) {
  if (!memory?.collaboration_id || button.disabled) return;

  const confirmed = await FamilAreaConfirm.confirm({
    variant: 'danger',
    title: 'Abbandonare la condivisione?',
    message: 'Non potrai più aprire questo album né le sue fotografie. L’album resterà disponibile al proprietario e agli altri destinatari.',
    confirmText: 'Abbandona condivisione'
  });
  if (!confirmed) return;

  button.disabled = true;
  const { error } = await timelineClient.rpc('leave_my_memory_collaboration', {
    p_collaboration_id: memory.collaboration_id
  });
  if (error) {
    button.disabled = false;
    sharedMemoriesMessage.textContent = timelineRpcMessage('abbandonare la condivisione', error);
    return;
  }

  await loadSharedMemories();
  sharedMemoriesMessage.textContent = 'Condivisione abbandonata.';
}

async function loadSharedMemories() {
  if (selectedTimelineType !== 'memory' || selectedTimelineId) return;
  sharedMemoriesCollection.hidden = false;
  sharedMemoriesList.replaceChildren();
  sharedMemoriesEmpty.hidden = true;
  sharedMemoriesMessage.textContent = 'Caricamento album condivisi…';
  const { data, error } = await timelineClient.rpc('get_my_shared_memories');
  if (error) {
    sharedMemoriesMessage.textContent = timelineRpcMessage('caricare gli album condivisi', error);
    return;
  }
  if (!Array.isArray(data)) {
    sharedMemoriesMessage.textContent = 'Impossibile caricare gli album condivisi: risposta RPC incompatibile.';
    return;
  }
  const cards = data.map((memory) => ({
    memory,
    ...createMemoryCard(memory, { shared: true, onOpen: openSharedMemoryGallery, onLeave: leaveSharedMemory })
  }));
  sharedMemoriesList.replaceChildren(...cards.map(({ item }) => item));
  sharedMemoriesEmpty.hidden = data.length > 0;
  sharedMemoriesMessage.textContent = '';
  await Promise.all(cards.map(({ memory, visual }) => renderMemoryCover(memory, visual)));
}

function isTimelineDocumentCardControl(target) { return target instanceof Element && Boolean(target.closest('button, a, input, select, textarea, [data-card-control]')); }
function openTimelineDocumentDetails(href) { window.location.assign(href); }

async function openTimelineDocumentAttachment(attachment, button) {
  button.disabled = true;
  try {
    const signedUrl = await window.FamilAreaAttachmentPreview.getSignedUrl(timelineClient, attachment, 60);
    window.open(signedUrl, '_blank', 'noopener');
  } catch (_) {
    timelineMessage.textContent = 'Non è stato possibile aprire l’allegato del documento. Riprova.';
  } finally {
    button.disabled = false;
  }
}

function createTimelineDocumentCard(timelineDocument) {
  const item = document.createElement('div');
  item.className = 'fa-v2-memory-timeline-item';

  const href = timelineDocumentHref(timelineDocument);
  const card = document.createElement('article');
  card.className = 'fa-v2-deadline-card fa-v2-deadline-card--interactive fa-v2-card-media-layout';
  card.tabIndex = 0;
  card.setAttribute('role', 'link');
  card.setAttribute('aria-label', `Apri documento ${timelineDocument.title || 'senza titolo'}`);
  card.addEventListener('click', (event) => {
    if (!isTimelineDocumentCardControl(event.target)) openTimelineDocumentDetails(href);
  });
  card.addEventListener('keydown', (event) => {
    if (event.target !== card || (event.key !== 'Enter' && event.key !== ' ')) return;
    event.preventDefault();
    openTimelineDocumentDetails(href);
  });

  const visual = document.createElement('span');
  visual.className = 'fa-v2-card-visual';
  visual.setAttribute('aria-hidden', 'true');
  visual.textContent = memoryInitial(timelineDocument.title);

  const content = document.createElement('div');
  content.className = 'fa-v2-card-content';
  const date = document.createElement('p');
  date.className = 'fa-v2-card-description';
  date.textContent = formatMemoryDate(timelineDocument.occurred_on);
  const title = document.createElement('h3');
  title.className = 'fa-v2-card-title';
  title.textContent = timelineDocument.title || 'Documento senza titolo';
  const description = document.createElement('p');
  description.className = 'fa-v2-card-description';
  description.textContent = timelineDocument.description || 'Nessuna descrizione.';
  content.append(date, title, description);

  const actions = document.createElement('div');
  actions.className = 'fa-v2-card-actions';
  const open = document.createElement('button');
  open.type = 'button';
  open.className = 'fa-v2-button fa-v2-button--secondary';
  open.textContent = 'Modifica';
  open.addEventListener('click', (event) => { event.stopPropagation(); openTimelineDocumentDetails(href); });
  actions.append(open);
  card.append(visual, content, actions);
  item.append(card);
  return { item, visual };
}

async function renderTimelineDocumentPreview(timelineDocument, visual) {
  try {
    const { data, error } = await timelineClient.rpc('get_attachments', {
      p_target_type: 'timeline_document',
      p_target_id: timelineDocument.id
    });
    if (error) return;
    const attachment = (data || []).find((row) => window.FamilAreaAttachmentPreview.isSupportedMimeType(row.mime_type));
    if (!attachment || !visual.isConnected) return;

    const open = document.createElement('button');
    open.type = 'button';
    open.className = 'fa-v2-card-visual deadline-card-attachment-preview';
    open.setAttribute('data-card-control', 'attachment-preview');
    open.setAttribute('aria-label', `Apri allegato di ${timelineDocument.title || 'questo documento'}`);
    open.textContent = attachment.mime_type === 'application/pdf' ? 'PDF' : 'Apri allegato';
    open.addEventListener('click', (event) => {
      event.stopPropagation();
      void openTimelineDocumentAttachment(attachment, open);
    });
    visual.replaceWith(open);
    await window.FamilAreaAttachmentPreview.renderCardPreview({ client: timelineClient, attachment, container: open });
  } catch (_) {
    // The document details card remains usable when its optional preview is unavailable.
  }
}
async function loadSelectedDocumentTimeline() {
  const timeline = activeTimeline();
  if (!timeline) return;
  timelineDocumentsList.replaceChildren();
  memoriesEmpty.hidden = true;
  timelineMessage.textContent = 'Caricamento documenti...';

  const { data, error } = await timelineClient.rpc('get_timeline_documents', { p_timeline_id: timeline.id });
  if (error) {
    timelineMessage.textContent = timelineRpcMessage('caricare i documenti', error);
    return;
  }
  if (!Array.isArray(data)) {
    timelineMessage.textContent = 'Impossibile caricare i documenti: risposta RPC incompatibile.';
    return;
  }

  const cards = data.map((timelineDocument) => ({
    timelineDocument,
    ...createTimelineDocumentCard(timelineDocument)
  }));
  timelineDocumentsList.replaceChildren(...cards.map(({ item }) => item));
  memoriesEmpty.replaceChildren();
  if (!data.length) {
    const heading = document.createElement('strong');
    heading.textContent = 'Nessun documento in questa Timeline.';
    const text = document.createElement('span');
    text.textContent = 'Aggiungi il primo documento per iniziare.';
    memoriesEmpty.append(heading, text);
    memoriesEmpty.hidden = false;
  }
  timelineMessage.textContent = '';
  await Promise.all(cards.map(({ timelineDocument, visual }) => renderTimelineDocumentPreview(timelineDocument, visual)));
}

async function loadTimeline() {
  const { data: sessionData, error: sessionError } = await timelineClient.auth.getSession();
  if (sessionError || !sessionData?.session) {
    window.location.replace(`login.html?return_to=${encodeURIComponent(`timeline.html${window.location.search}`)}`);
    return;
  }
  if (!selectedTimelineType) {
    setRouteView('home');
    timelineMessage.textContent = '';
    return;
  }
  try {
    await fetchTimelines();
    if (!selectedTimelineId) {
      renderTimelineCollection();
      timelineMessage.textContent = '';
      await loadSharedMemories();
      return;
    }
    if (!activeTimeline()) {
      setRouteView('collection');
      timelineCollectionList.replaceChildren();
      timelineCollectionEmpty.hidden = false;
      timelineCollectionEmpty.textContent = 'Timeline non trovata o non disponibile.';
      timelineMessage.textContent = '';
      return;
    }
    renderTimelineDetail();
    if (selectedTimelineType === 'memory') await loadSelectedMemoryTimeline();
    else await loadSelectedDocumentTimeline();
  } catch (error) {
    setRouteView('collection');
    timelineMessage.textContent = timelineRpcMessage('caricare le Timeline', error);
  }
}

galleryClose.addEventListener('click', closeMemoryGallery);
galleryModal.addEventListener('click', (event) => { if (event.target === galleryModal) closeMemoryGallery(); });
galleryPrevious.addEventListener('click', () => setGalleryPhoto(galleryPhotoIndex - 1));
galleryNext.addEventListener('click', () => setGalleryPhoto(galleryPhotoIndex + 1));
lightboxClose.addEventListener('click', closeLightbox);
lightboxPrevious.addEventListener('click', () => setGalleryPhoto(galleryPhotoIndex - 1));
lightboxNext.addEventListener('click', () => setGalleryPhoto(galleryPhotoIndex + 1));
timelineCreate.addEventListener('click', () => void createTimeline());
timelineManage.addEventListener('click', () => void manageActiveTimeline());
timelineDelete.addEventListener('click', () => void deleteActiveTimeline());
attachSwipe(galleryPhotoStage, (direction) => setGalleryPhoto(galleryPhotoIndex + direction));
attachLightboxGestures(lightboxImage.parentElement);
lightboxImage.addEventListener('load', fitLightboxImage);
window.addEventListener('resize', () => {
  if (lightbox.hidden) return;
  resetLightboxTransform();
  requestAnimationFrame(fitLightboxImage);
});
window.addEventListener('popstate', () => {
  if (!lightbox.hidden) closeLightbox({ fromHistory: true });
});
document.addEventListener('fullscreenchange', () => {
  if (!document.fullscreenElement && !lightbox.hidden && lightboxHistoryEntry && useImmersiveLightbox()) {
    closeLightbox();
  }
});
document.addEventListener('keydown', (event) => {
  if (!lightbox.hidden) {
    if (event.key === 'Escape') { event.preventDefault(); closeLightbox(); }
    if (event.key === 'ArrowLeft') { event.preventDefault(); setGalleryPhoto(galleryPhotoIndex - 1); }
    if (event.key === 'ArrowRight') { event.preventDefault(); setGalleryPhoto(galleryPhotoIndex + 1); }
    return;
  }
  if (galleryModal.hidden) return;
  if (event.key === 'Escape') { event.preventDefault(); closeMemoryGallery(); }
  if (event.key === 'ArrowLeft') { event.preventDefault(); setGalleryPhoto(galleryPhotoIndex - 1); }
  if (event.key === 'ArrowRight') { event.preventDefault(); setGalleryPhoto(galleryPhotoIndex + 1); }
});

void loadTimeline();

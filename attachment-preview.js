(function () {
  const attachmentTypes = new Map([
    ['application/pdf', 'PDF'],
    ['image/jpeg', 'JPG'],
    ['image/png', 'PNG'],
    ['image/webp', 'WEBP']
  ]);
  const imageMimeTypes = new Set(['image/jpeg', 'image/png', 'image/webp']);
  const maxAttachmentBytes = 10 * 1024 * 1024;
  const pdfJsUrl = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js';
  const pdfJsWorkerUrl = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';
  let pdfJsPromise;

  function isSupportedMimeType(mimeType) {
    return attachmentTypes.has(mimeType);
  }

  function formatAttachmentType(mimeType) {
    return attachmentTypes.get(mimeType) || 'FILE';
  }

  function loadPdfJs() {
    if (window.pdfjsLib) return Promise.resolve(window.pdfjsLib);
    if (pdfJsPromise) return pdfJsPromise;

    pdfJsPromise = new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = pdfJsUrl;
      script.async = true;
      script.onload = () => {
        if (!window.pdfjsLib) {
          reject(new Error('PDF.js non disponibile'));
          return;
        }
        window.pdfjsLib.GlobalWorkerOptions.workerSrc = pdfJsWorkerUrl;
        resolve(window.pdfjsLib);
      };
      script.onerror = () => reject(new Error('Impossibile caricare PDF.js'));
      document.head.append(script);
    });
    return pdfJsPromise;
  }

  async function signedUrlForAttachment(client, attachment, expiresIn = 3600) {
    const { data, error } = await client.storage
      .from('familarea-attachments')
      .createSignedUrl(attachment.storage_path, expiresIn);
    if (error || !data?.signedUrl) throw error || new Error('URL allegato non disponibile');
    return data.signedUrl;
  }

  function setImagePreview(container, signedUrl, fallback) {
    const image = document.createElement('img');
    image.alt = '';
    image.onload = () => container.replaceChildren(image);
    image.onerror = () => {
      container.replaceChildren();
      container.textContent = fallback;
    };
    image.src = signedUrl;
  }

  async function setPdfPreview(container, signedUrl) {
    const pdfjsLib = await loadPdfJs();
    const documentTask = pdfjsLib.getDocument(signedUrl);
    const pdf = await documentTask.promise;
    try {
      const page = await pdf.getPage(1);
      const viewport = page.getViewport({ scale: 1 });
      const targetWidth = 224;
      const scaledViewport = page.getViewport({ scale: targetWidth / viewport.width });
      const canvas = document.createElement('canvas');
      canvas.width = Math.ceil(scaledViewport.width);
      canvas.height = Math.ceil(scaledViewport.height);
      const context = canvas.getContext('2d');
      if (!context) throw new Error('Canvas non disponibile');
      await page.render({ canvasContext: context, viewport: scaledViewport }).promise;
      container.replaceChildren(canvas);
    } finally {
      await pdf.destroy();
    }
  }

  async function renderCardPreview({ client, attachment, container }) {
    if (!attachment?.storage_path || !isSupportedMimeType(attachment.mime_type)) return false;
    const fallback = container.textContent;
    try {
      const signedUrl = await signedUrlForAttachment(client, attachment);
      if (imageMimeTypes.has(attachment.mime_type)) {
        setImagePreview(container, signedUrl, fallback);
        return true;
      }
      if (attachment.mime_type === 'application/pdf') {
        await setPdfPreview(container, signedUrl);
        return true;
      }
    } catch (error) {
      console.warn('attachment card preview unavailable', error);
    }
    container.replaceChildren();
    container.textContent = fallback;
    return false;
  }

  async function renderTargetCardPreview({ client, targetType, targetId, container }) {
    const { data, error } = await client.rpc('get_attachments', {
      p_target_type: targetType,
      p_target_id: targetId
    });
    if (error) return false;
    return renderCardPreview({ client, attachment: (data || [])[0], container });
  }

  window.FamilAreaAttachmentPreview = Object.freeze({
    maxAttachmentBytes,
    isSupportedMimeType,
    formatAttachmentType,
    renderCardPreview,
    renderTargetCardPreview
  });
}());

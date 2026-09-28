(function (global) {
  const SAMPLE_WIDTH = 72;
  const SAMPLE_HEIGHT = 48;
  const LIGHT_LUMINANCE_THRESHOLD = 150;

  function setContrastState(container, state) {
    container.classList.remove('fa-cover--light', 'fa-cover--dark');
    container.classList.add(`fa-cover--${state}`);
  }

  function waitForImage(image) {
    if (image.complete) return image.naturalWidth > 0 ? Promise.resolve() : Promise.reject(new Error('Cover unavailable'));
    return new Promise((resolve, reject) => {
      image.addEventListener('load', resolve, { once: true });
      image.addEventListener('error', () => reject(new Error('Cover unavailable')), { once: true });
    });
  }

  function drawCoverSample(context, image) {
    const sourceRatio = image.naturalWidth / image.naturalHeight;
    const targetRatio = SAMPLE_WIDTH / SAMPLE_HEIGHT;
    let sourceX = 0;
    let sourceY = 0;
    let sourceWidth = image.naturalWidth;
    let sourceHeight = image.naturalHeight;
    if (sourceRatio > targetRatio) {
      sourceWidth = image.naturalHeight * targetRatio;
      sourceX = (image.naturalWidth - sourceWidth) / 2;
    } else {
      sourceHeight = image.naturalWidth / targetRatio;
      sourceY = (image.naturalHeight - sourceHeight) / 2;
    }
    context.drawImage(image, sourceX, sourceY, sourceWidth, sourceHeight, 0, 0, SAMPLE_WIDTH, SAMPLE_HEIGHT);
  }

  function textRegionLuminance(image) {
    const canvas = document.createElement('canvas');
    canvas.width = SAMPLE_WIDTH;
    canvas.height = SAMPLE_HEIGHT;
    const context = canvas.getContext('2d', { willReadFrequently: true });
    if (!context) throw new Error('Canvas unavailable');
    drawCoverSample(context, image);
    const pixels = context.getImageData(0, 0, SAMPLE_WIDTH, SAMPLE_HEIGHT).data;
    const left = 0;
    const right = Math.ceil(SAMPLE_WIDTH * 0.62);
    const top = Math.floor(SAMPLE_HEIGHT * 0.16);
    const bottom = Math.ceil(SAMPLE_HEIGHT * 0.84);
    let total = 0;
    let count = 0;
    for (let y = top; y < bottom; y += 1) {
      for (let x = left; x < right; x += 1) {
        const offset = (y * SAMPLE_WIDTH + x) * 4;
        const alpha = pixels[offset + 3] / 255;
        if (!alpha) continue;
        total += (0.2126 * pixels[offset] + 0.7152 * pixels[offset + 1] + 0.0722 * pixels[offset + 2]) * alpha;
        count += alpha;
      }
    }
    if (!count) throw new Error('Cover sample unavailable');
    return total / count;
  }

  async function applyContrast(container, image) {
    if (!container || !image) return 'light';
    setContrastState(container, 'light');
    try {
      await waitForImage(image);
      const state = textRegionLuminance(image) >= LIGHT_LUMINANCE_THRESHOLD ? 'light' : 'dark';
      setContrastState(container, state);
      return state;
    } catch (_) {
      return 'light';
    }
  }

  global.FamilAreaCoverUtils = { applyContrast };
}(window));

import { ImageMagick, initializeImageMagick, MagickFormat, ResourceLimits } from "npm:@imagemagick/magick-wasm@0.0.44";

export type MemoryCoverContext = {
  ownerAccountId: unknown;
  coverAttachmentId: unknown;
};

export type AttachmentCoverContext = {
  ownerAccountId: string;
  targetType: string;
  targetId: string;
  storagePath: string;
  mimeType: string;
  byteSize: number;
};

export type EmailPhotoThumbnail = {
  base64: string;
  filename: string;
  contentType: "image/jpeg";
  contentId: string;
};

export type CoverThumbnail = EmailPhotoThumbnail & { contentId: "album-preview" };

/** The only Supabase capability needed to read an already-authorized cover. */
type PrivateStorageReader = {
  storage: {
    from(bucket: string): {
      download(path: string): Promise<{ data: Blob | null; error: unknown | null }>;
    };
  };
};

const bucket = "familarea-attachments";
const imageMimeTypes = new Set(["image/jpeg", "image/png", "image/webp"]);
const maxSourceBytes = 10 * 1024 * 1024;
// Ten megapixels admits common camera originals such as 3564x2397 while
// retaining a fixed upper bound before ImageMagick decodes them.
const maxPixels = 10_000_000;
const preferredOutputBytes = 100 * 1024;
const maxOutputBytes = 150 * 1024;
const maxWidth = 600;
const maxHeight = 400;
const photoPreviewPreferredOutputBytes = 36 * 1024;
const photoPreviewMaxOutputBytes = 60 * 1024;
const photoPreviewMaxWidth = 160;
const photoPreviewMaxHeight = 120;
const maxDecodeDimension = 6000n;
// This is ImageMagick's pixel-cache cap, not an unrestricted Function-memory
// allowance. Disk remains disabled, so exceeding it falls back without a photo.
const maxDecodeMemoryBytes = 96n * 1024n * 1024n;
const maxProfileBytes = 1024n * 1024n;
let magickReady: Promise<boolean> | undefined;

function omitCover(code: string): null {
  console.warn(code);
  return null;
}

function initializeMagick(): Promise<boolean> {
  if (!magickReady) {
    magickReady = (async () => {
      try {
        const wasmUrl = new URL(import.meta.resolve("npm:@imagemagick/magick-wasm@0.0.44/magick.wasm"));
        const wasmBytes = await Deno.readFile(wasmUrl);
        await initializeImageMagick(wasmBytes);
        // These are global limits for this isolate. They are constant across all
        // requests and are set before the first decoder invocation.
        ResourceLimits.width = maxDecodeDimension;
        ResourceLimits.height = maxDecodeDimension;
        ResourceLimits.area = BigInt(maxPixels);
        ResourceLimits.listLength = 16n;
        ResourceLimits.memory = maxDecodeMemoryBytes;
        ResourceLimits.maxMemoryRequest = maxDecodeMemoryBytes;
        ResourceLimits.disk = 0n;
        ResourceLimits.maxProfileSize = maxProfileBytes;
        return true;
      } catch {
        console.warn("COVER_WASM_INIT_FAILED");
        return false;
      }
    })();
  }
  return magickReady;
}

function isUuid(value: unknown): value is string {
  return typeof value === "string"
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

export function resolveOwnerAccountId(currentAccount: unknown, currentAccountError: unknown): string | null {
  const accountId = (currentAccount as { account_id?: unknown } | null)?.account_id;
  return currentAccountError || !isUuid(accountId) ? null : accountId;
}

export function resolveMemoryCoverContext(data: unknown, error: unknown): { memory: MemoryCoverContext | null; diagnostic: "COVER_MEMORY_RPC_FAILED" | "COVER_MEMORY_RPC_INVALID" | null } {
  if (error) return { memory: null, diagnostic: "COVER_MEMORY_RPC_FAILED" };
  if (!data || typeof data !== "object" || !("owner_account_id" in data) || !("cover_attachment_id" in data)) {
    return { memory: null, diagnostic: "COVER_MEMORY_RPC_INVALID" };
  }
  const memory = data as { owner_account_id: unknown; cover_attachment_id: unknown };
  return { memory: { ownerAccountId: memory.owner_account_id, coverAttachmentId: memory.cover_attachment_id }, diagnostic: null };
}

export function resolveCoverAttachmentContext(data: unknown, error: unknown, coverAttachmentId: unknown): { attachment: AttachmentCoverContext | null; diagnostic: "COVER_ATTACHMENT_RPC_FAILED" | "COVER_ATTACHMENT_RPC_INVALID" | "COVER_ATTACHMENT_UNAVAILABLE" | null } {
  if (error) return { attachment: null, diagnostic: "COVER_ATTACHMENT_RPC_FAILED" };
  if (!Array.isArray(data) || !isUuid(coverAttachmentId)) return { attachment: null, diagnostic: "COVER_ATTACHMENT_RPC_INVALID" };
  const candidate = data.find((row) => row && typeof row === "object" && (row as { id?: unknown }).id === coverAttachmentId);
  if (!candidate || typeof candidate !== "object") return { attachment: null, diagnostic: "COVER_ATTACHMENT_UNAVAILABLE" };
  const attachment = candidate as { owner_account_id?: unknown; target_type?: unknown; target_id?: unknown; storage_path?: unknown; mime_type?: unknown; byte_size?: unknown };
  if (!isUuid(attachment.owner_account_id) || typeof attachment.target_type !== "string" || !isUuid(attachment.target_id) || typeof attachment.storage_path !== "string" || typeof attachment.mime_type !== "string" || typeof attachment.byte_size !== "number" || !Number.isSafeInteger(attachment.byte_size)) {
    return { attachment: null, diagnostic: "COVER_ATTACHMENT_RPC_INVALID" };
  }
  return { attachment: { ownerAccountId: attachment.owner_account_id, targetType: attachment.target_type, targetId: attachment.target_id, storagePath: attachment.storage_path, mimeType: attachment.mime_type, byteSize: attachment.byte_size }, diagnostic: null };
}

type SourceImage = {
  mimeType: "image/jpeg" | "image/png" | "image/webp";
  width?: number;
  height?: number;
};

function u16be(bytes: Uint8Array, offset: number) {
  return (bytes[offset] << 8) | bytes[offset + 1];
}

function u24le(bytes: Uint8Array, offset: number) {
  return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
}

function u32le(bytes: Uint8Array, offset: number) {
  return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
}

function u32be(bytes: Uint8Array, offset: number) {
  return ((bytes[offset] * 0x1000000) + (bytes[offset + 1] << 16) + (bytes[offset + 2] << 8) + bytes[offset + 3]) >>> 0;
}

function jpegDimensions(bytes: Uint8Array): Pick<SourceImage, "width" | "height"> | null {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  const sofMarkers = new Set([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]);
  let offset = 2;
  while (offset + 3 < bytes.length && offset < 64 * 1024) {
    while (offset < bytes.length && bytes[offset] !== 0xff) offset++;
    while (offset < bytes.length && bytes[offset] === 0xff) offset++;
    if (offset >= bytes.length) break;
    const marker = bytes[offset++];
    if (marker === 0xd8 || marker === 0xd9 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 1 >= bytes.length) break;
    const segmentLength = u16be(bytes, offset);
    if (segmentLength < 2 || offset + segmentLength > bytes.length) break;
    if (sofMarkers.has(marker) && segmentLength >= 8) {
      return { height: u16be(bytes, offset + 3), width: u16be(bytes, offset + 5) };
    }
    offset += segmentLength;
  }
  return {};
}

function webpDimensions(bytes: Uint8Array): Pick<SourceImage, "width" | "height"> {
  let offset = 12;
  while (offset + 8 <= bytes.length && offset < 64 * 1024) {
    const chunk = String.fromCharCode(...bytes.subarray(offset, offset + 4));
    const length = u32le(bytes, offset + 4);
    const data = offset + 8;
    if (data + length > bytes.length) return {};
    if (chunk === "VP8X" && length >= 10) return { width: u24le(bytes, data + 4) + 1, height: u24le(bytes, data + 7) + 1 };
    if (chunk === "VP8L" && length >= 5 && bytes[data] === 0x2f) {
      const packed = u32le(bytes, data + 1);
      return { width: (packed & 0x3fff) + 1, height: ((packed >>> 14) & 0x3fff) + 1 };
    }
    if (chunk === "VP8 " && length >= 10 && bytes[data + 3] === 0x9d && bytes[data + 4] === 0x01 && bytes[data + 5] === 0x2a) {
      return { width: u16be(new Uint8Array([bytes[data + 7], bytes[data + 6]]), 0) & 0x3fff, height: u16be(new Uint8Array([bytes[data + 9], bytes[data + 8]]), 0) & 0x3fff };
    }
    offset = data + length + (length % 2);
  }
  return {};
}

/** Validates the real byte signature; MIME metadata alone is never trusted. */
export function inspectCoverImage(bytes: Uint8Array): SourceImage | null {
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 && bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a) {
    if (bytes.length < 24 || String.fromCharCode(...bytes.subarray(12, 16)) !== "IHDR") return null;
    return { mimeType: "image/png", width: u32be(bytes, 16), height: u32be(bytes, 20) };
  }
  if (bytes.length >= 12 && String.fromCharCode(...bytes.subarray(0, 4)) === "RIFF" && String.fromCharCode(...bytes.subarray(8, 12)) === "WEBP") return { mimeType: "image/webp", ...webpDimensions(bytes) };
  const jpeg = jpegDimensions(bytes);
  return jpeg ? { mimeType: "image/jpeg", ...jpeg } : null;
}

function decodeFailureCode(error: unknown): "COVER_DECODE_LIMIT_EXCEEDED" | "COVER_DECODE_FAILED" {
  const message = error instanceof Error ? error.message : String(error ?? "");
  return /resource limit|cache resources exhausted|memory allocation|width or height exceeds limit|area exceeds/i.test(message)
    ? "COVER_DECODE_LIMIT_EXCEEDED"
    : "COVER_DECODE_FAILED";
}
function toBase64(bytes: Uint8Array) {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}

type ThumbnailOptions = {
  contentId: string;
  filename: string;
  preferredOutputBytes: number;
  maxOutputBytes: number;
  maxWidth: number;
  maxHeight: number;
};

/**
 * Returns only a re-encoded, metadata-free JPEG derivative. Any source-image
 * error is a no-photo fallback and is never reported with personal data.
 */
async function createMemoryAttachmentThumbnail(
  service: PrivateStorageReader,
  ownerAccountId: string,
  memoryId: string,
  attachment: AttachmentCoverContext,
  options: ThumbnailOptions,
): Promise<EmailPhotoThumbnail | null> {
  try {
    if (!/^[A-Za-z0-9._-]{1,127}$/.test(options.contentId)) return omitCover("COVER_CONTENT_ID_INVALID");
    if (attachment.ownerAccountId !== ownerAccountId) return omitCover("COVER_ATTACHMENT_OWNERSHIP_INVALID");
    if (attachment.targetType !== "memory" || attachment.targetId !== memoryId) return omitCover("COVER_ATTACHMENT_TARGET_INVALID");
    if (typeof attachment.storagePath !== "string" || !attachment.storagePath.trim()) return omitCover("COVER_STORAGE_PATH_INVALID");
    if (!imageMimeTypes.has(attachment.mimeType)) return omitCover("COVER_MIME_UNSUPPORTED");
    if (!Number.isSafeInteger(attachment.byteSize) || attachment.byteSize <= 0 || attachment.byteSize > maxSourceBytes) return omitCover("COVER_SOURCE_METADATA_INVALID");

    // Initialize only after the attachment has passed every database validation.
    if (!await initializeMagick()) return null;

    const { data: source, error: sourceError } = await service.storage.from(bucket).download(attachment.storagePath);
    if (sourceError || !source) return omitCover("COVER_DOWNLOAD_FAILED");
    const sourceBytes = new Uint8Array(await source.arrayBuffer());
    if (sourceBytes.byteLength === 0 || sourceBytes.byteLength > maxSourceBytes) return omitCover("COVER_SOURCE_SIZE_INVALID");
    const sourceImage = inspectCoverImage(sourceBytes);
    if (!sourceImage) return omitCover("COVER_SIGNATURE_INVALID");
    if (sourceImage.mimeType !== attachment.mimeType) return omitCover("COVER_MIME_SIGNATURE_MISMATCH");
    if ((sourceImage.width && sourceImage.height) && (sourceImage.width < 1 || sourceImage.height < 1 || sourceImage.width > Number(maxDecodeDimension) || sourceImage.height > Number(maxDecodeDimension) || sourceImage.width * sourceImage.height > maxPixels)) return omitCover("COVER_DIMENSIONS_INVALID");

    let jpeg: Uint8Array;
    let phase: "decode" | "transform" | "encode" = "decode";
    let diagnosticCode: string | null = null;
    try {
      jpeg = ImageMagick.read(sourceBytes, (image): Uint8Array => {
        phase = "transform";
        if (image.width < 1 || image.height < 1 || image.width * image.height > maxPixels) {
          diagnosticCode = "COVER_DIMENSIONS_INVALID";
          throw new Error(diagnosticCode);
        }
        image.autoOrient();
        const scale = Math.min(1, options.maxWidth / image.width, options.maxHeight / image.height);
        image.resize(Math.max(1, Math.round(image.width * scale)), Math.max(1, Math.round(image.height * scale)));
        image.strip();
        phase = "encode";
        let bestWithinMaximum: Uint8Array | null = null;
        let lastCandidate = new Uint8Array();
        for (const quality of [78, 70, 62, 54]) {
          image.quality = quality;
          const candidate = image.write(MagickFormat.Jpeg, (bytes) => new Uint8Array(bytes));
          lastCandidate = candidate;
          if (candidate.byteLength <= options.preferredOutputBytes) return candidate;
          if (!bestWithinMaximum && candidate.byteLength <= options.maxOutputBytes) bestWithinMaximum = candidate;
        }
        return bestWithinMaximum ?? lastCandidate;
      });
    } catch (error) {
      if (diagnosticCode) return omitCover(diagnosticCode);
      return omitCover(phase === "decode" ? decodeFailureCode(error) : phase === "encode" ? "COVER_ENCODE_FAILED" : "COVER_TRANSFORM_FAILED");
    }
    if (jpeg.byteLength === 0) return omitCover("COVER_OUTPUT_EMPTY");
    if (jpeg.byteLength > options.maxOutputBytes) return omitCover("COVER_OUTPUT_TOO_LARGE");

    try {
      return {
        base64: toBase64(jpeg),
        filename: options.filename,
        contentType: "image/jpeg",
        contentId: options.contentId,
      };
    } catch {
      return omitCover("COVER_BASE64_FAILED");
    }
  } catch {
    return omitCover("COVER_UNEXPECTED_FAILED");
  }
}

/**
 * Returns a preview for the full-Album invitation while preserving its existing
 * cover-specific ownership and cover-selection checks.
 */
export async function createMemoryCoverThumbnail(
  service: PrivateStorageReader,
  ownerAccountId: string,
  memoryId: string,
  memory: MemoryCoverContext,
  attachment: AttachmentCoverContext,
): Promise<CoverThumbnail | null> {
  try {
    if (memory.ownerAccountId !== ownerAccountId) return omitCover("COVER_MEMORY_OWNERSHIP_INVALID");
    if (!isUuid(memory.coverAttachmentId)) return omitCover("COVER_ID_UNAVAILABLE");

    const thumbnail = await createMemoryAttachmentThumbnail(service, ownerAccountId, memoryId, attachment, {
      contentId: "album-preview",
      filename: "familarea-album-preview.jpg",
      preferredOutputBytes,
      maxOutputBytes,
      maxWidth,
      maxHeight,
    });
    return thumbnail ? { ...thumbnail, contentId: "album-preview" } : null;
  } catch {
    return omitCover("COVER_UNEXPECTED_FAILED");
  }
}

/**
 * Creates a small CID preview only after the caller has verified that the
 * attachment belongs to the selected photo share.
 */
export async function createMemoryPhotoShareThumbnail(
  service: PrivateStorageReader,
  ownerAccountId: string,
  memoryId: string,
  attachment: AttachmentCoverContext,
  contentId: string,
): Promise<EmailPhotoThumbnail | null> {
  return createMemoryAttachmentThumbnail(service, ownerAccountId, memoryId, attachment, {
    contentId,
    filename: "familarea-photo-preview.jpg",
    preferredOutputBytes: photoPreviewPreferredOutputBytes,
    maxOutputBytes: photoPreviewMaxOutputBytes,
    maxWidth: photoPreviewMaxWidth,
    maxHeight: photoPreviewMaxHeight,
  });
}

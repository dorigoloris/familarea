import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildInvitationEmail, singleLine } from "../_shared/invitation-email.ts";
import {
  createMemoryPhotoShareThumbnail,
  type AttachmentCoverContext,
  type EmailPhotoThumbnail,
} from "../send-memory-share-invitation/cover-thumbnail.ts";

const tokenAad = "familarea:memory-photo-share";
const leaseSeconds = 120;
const retryAfterSeconds = 300;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const maxInlinePhotoPreviews = 9;
const imageMimeTypes = new Set(["image/jpeg", "image/png", "image/webp"]);

type ClaimedEvent = {
  notification_event_id?: unknown;
  share_id?: unknown;
  event_type?: unknown;
  selection_version?: unknown;
  recipient_email?: unknown;
  delivery_token_ciphertext?: unknown;
  delivery_idempotency_key?: unknown;
  lease_token?: unknown;
};

type ValidatedClaim = {
  notification_event_id: string;
  share_id: string;
  event_type: "initial" | "selection_updated";
  selection_version: number;
  recipient_email: string;
  delivery_token_ciphertext?: unknown;
  delivery_idempotency_key: string;
  lease_token: string;
};

const json = (status: number, body?: Record<string, unknown>) => new Response(
  body ? JSON.stringify(body) : null,
  { status, headers: body ? { "Content-Type": "application/json", "Cache-Control": "no-store" } : { "Cache-Control": "no-store" } },
);

function isUuid(value: unknown): value is string {
  return typeof value === "string" && uuidPattern.test(value);
}

function isEmail(value: unknown): value is string {
  return typeof value === "string" && value.length <= 254 && emailPattern.test(value);
}

function base64UrlDecode(value: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return null;
  try {
    const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (value.length % 4)) % 4);
    const binary = atob(padded);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
}

async function constantTimeSecretMatches(authorization: string | null, serviceRoleKey: string): Promise<boolean> {
  if (!authorization?.startsWith("Bearer ")) return false;
  const supplied = authorization.slice("Bearer ".length);
  const encoder = new TextEncoder();
  const [suppliedDigest, expectedDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(supplied)),
    crypto.subtle.digest("SHA-256", encoder.encode(serviceRoleKey)),
  ]);
  const suppliedBytes = new Uint8Array(suppliedDigest);
  const expectedBytes = new Uint8Array(expectedDigest);
  let difference = 0;
  for (let index = 0; index < expectedBytes.length; index += 1) difference |= suppliedBytes[index] ^ expectedBytes[index];
  return difference === 0;
}

async function decryptInvitationToken(ciphertext: string, keyText: string): Promise<string | null> {
  const parts = ciphertext.split(".");
  if (parts.length !== 3 || parts[0] !== "v1") return null;
  const nonce = base64UrlDecode(parts[1]);
  const encrypted = base64UrlDecode(parts[2]);
  const keyBytes = base64UrlDecode(keyText);
  if (!nonce || nonce.byteLength !== 12 || !encrypted || encrypted.byteLength < 17 || !keyBytes || keyBytes.byteLength !== 32) return null;

  try {
    const key = await crypto.subtle.importKey("raw", keyBytes, { name: "AES-GCM" }, false, ["decrypt"]);
    const plaintext = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: nonce, additionalData: new TextEncoder().encode(tokenAad), tagLength: 128 },
      key,
      encrypted,
    );
    const token = new TextDecoder().decode(plaintext);
    return /^[A-Za-z0-9_-]{32,256}$/.test(token) ? token : null;
  } catch {
    return null;
  }
}

function validClaim(value: unknown): value is ValidatedClaim {
  const event = value as ClaimedEvent | null;
  return !!event
    && isUuid(event.notification_event_id)
    && isUuid(event.share_id)
    && (event.event_type === "initial" || event.event_type === "selection_updated")
    && isEmail(event.recipient_email)
    && isUuid(event.delivery_idempotency_key)
    && isUuid(event.lease_token)
    && typeof event.selection_version === "number"
    && Number.isInteger(event.selection_version)
    && event.selection_version > 0;
}

type PhotoPreviewResult = {
  contentTitle: string;
  thumbnails: EmailPhotoThumbnail[];
};

type SharePreviewScope = {
  memoryId: string;
  ownerAccountId: string;
};

function emptyPhotoPreviewResult(): PhotoPreviewResult {
  return { contentTitle: "", thumbnails: [] };
}

function resolveSharePreviewScope(value: unknown): SharePreviewScope | null {
  if (!value || typeof value !== "object") return null;
  const row = value as { memory_id?: unknown; owner_account_id?: unknown; status?: unknown };
  if (row.status !== "pending" || !isUuid(row.memory_id) || !isUuid(row.owner_account_id)) return null;
  return { memoryId: row.memory_id, ownerAccountId: row.owner_account_id };
}

function resolvePhotoAttachment(value: unknown, scope: SharePreviewScope): AttachmentCoverContext | null {
  if (!value || typeof value !== "object") return null;
  const row = value as {
    owner_account_id?: unknown;
    target_type?: unknown;
    target_id?: unknown;
    storage_path?: unknown;
    mime_type?: unknown;
    byte_size?: unknown;
  };
  if (row.owner_account_id !== scope.ownerAccountId || row.target_type !== "memory" || row.target_id !== scope.memoryId) return null;
  if (typeof row.storage_path !== "string" || !row.storage_path.trim()) return null;
  if (typeof row.mime_type !== "string" || !imageMimeTypes.has(row.mime_type)) return null;
  if (typeof row.byte_size !== "number" || !Number.isSafeInteger(row.byte_size) || row.byte_size <= 0) return null;
  return {
    ownerAccountId: scope.ownerAccountId,
    targetType: "memory",
    targetId: scope.memoryId,
    storagePath: row.storage_path,
    mimeType: row.mime_type,
    byteSize: row.byte_size,
  };
}

async function getInitialPhotoSharePreviews(
  service: ReturnType<typeof createClient>,
  shareId: string,
): Promise<PhotoPreviewResult> {
  const unavailable = emptyPhotoPreviewResult();
  try {
    const { data: rawShare, error: shareError } = await service
      .from("memory_photo_shares")
      .select("memory_id, owner_account_id, status")
      .eq("id", shareId)
      .maybeSingle();
    const scope = shareError ? null : resolveSharePreviewScope(rawShare);
    if (!scope) return unavailable;

    const { data: rawMemory, error: memoryError } = await service
      .from("memories")
      .select("title, owner_account_id")
      .eq("id", scope.memoryId)
      .eq("owner_account_id", scope.ownerAccountId)
      .maybeSingle();
    if (memoryError || !rawMemory || typeof rawMemory !== "object") return unavailable;
    const memory = rawMemory as { title?: unknown; owner_account_id?: unknown };
    if (memory.owner_account_id !== scope.ownerAccountId) return unavailable;
    const contentTitle = typeof memory.title === "string" ? singleLine(memory.title) : "";

    const { data: rawAssociations, error: associationError } = await service
      .from("memory_photo_share_attachments")
      .select("attachment_id")
      .eq("share_id", shareId)
      .limit(maxInlinePhotoPreviews);
    if (associationError || !Array.isArray(rawAssociations)) return { contentTitle, thumbnails: [] };

    const attachmentIds = [...new Set(rawAssociations
      .map((row) => row && typeof row === "object" ? (row as { attachment_id?: unknown }).attachment_id : null)
      .filter(isUuid))];
    if (!attachmentIds.length) return { contentTitle, thumbnails: [] };

    const { data: rawAttachments, error: attachmentError } = await service
      .from("attachments")
      .select("id, owner_account_id, target_type, target_id, storage_path, mime_type, byte_size")
      .in("id", attachmentIds);
    if (attachmentError || !Array.isArray(rawAttachments)) return { contentTitle, thumbnails: [] };

    const byId = new Map<string, unknown>();
    for (const row of rawAttachments) {
      if (row && typeof row === "object" && isUuid((row as { id?: unknown }).id)) {
        byId.set((row as { id: string }).id, row);
      }
    }

    const thumbnails: EmailPhotoThumbnail[] = [];
    for (const attachmentId of attachmentIds) {
      const attachment = resolvePhotoAttachment(byId.get(attachmentId), scope);
      if (!attachment) continue;
      const thumbnail = await createMemoryPhotoShareThumbnail(
        service,
        scope.ownerAccountId,
        scope.memoryId,
        attachment,
        `memory-photo-preview-${thumbnails.length + 1}`,
      );
      if (thumbnail) thumbnails.push(thumbnail);
    }
    return { contentTitle, thumbnails };
  } catch {
    // A thumbnail is optional: any read or decode failure leaves delivery intact.
    return unavailable;
  }
}
Deno.serve(async (request) => {
  // No CORS response: this endpoint is exclusively for a server-side scheduler.
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const siteUrl = Deno.env.get("SITE_URL");
  const from = Deno.env.get("MEMORY_SHARE_INVITE_FROM") || Deno.env.get("CONTACT_REGISTRATION_INVITE_FROM");
  const deliveryUrl = Deno.env.get("MEMORY_SHARE_INVITE_DELIVERY_URL") || Deno.env.get("CONTACT_REGISTRATION_INVITE_DELIVERY_URL");
  const deliveryBearer = Deno.env.get("MEMORY_SHARE_INVITE_DELIVERY_BEARER_TOKEN") || Deno.env.get("CONTACT_REGISTRATION_INVITE_DELIVERY_BEARER_TOKEN");
  const encryptionKey = Deno.env.get("MEMORY_PHOTO_SHARE_TOKEN_ENCRYPTION_KEY");
  if (!supabaseUrl || !serviceRoleKey || !siteUrl || !from || !deliveryUrl || !deliveryBearer || !encryptionKey) {
    return json(503, { error: "delivery_service_unavailable" });
  }
  if (!await constantTimeSecretMatches(request.headers.get("Authorization"), serviceRoleKey)) {
    return json(401, { error: "authentication_required" });
  }

  let invitationPage: URL;
  try {
    invitationPage = new URL("/invito-foto.html", siteUrl);
  } catch {
    return json(503, { error: "delivery_service_unavailable" });
  }
  if (invitationPage.origin !== "https://familarea.com") return json(503, { error: "delivery_service_unavailable" });

  const service = createClient(supabaseUrl, serviceRoleKey);
  const { error: expiryError } = await service.rpc("expire_memory_photo_share_deliveries", { p_limit: 100 });
  if (expiryError) return json(503, { error: "delivery_service_unavailable" });

  const { data: rawClaim, error: claimError } = await service.rpc(
    "claim_memory_photo_share_notification_event",
    { p_lease_seconds: leaseSeconds },
  );
  if (claimError) return json(503, { error: "delivery_service_unavailable" });
  if (!rawClaim) return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
  if (!validClaim(rawClaim)) return json(503, { error: "delivery_service_unavailable" });
  const claim = rawClaim;

  const fail = async (errorCode: string) => {
    await service.rpc("fail_memory_photo_share_notification_event", {
      p_notification_event_id: claim.notification_event_id,
      p_lease_token: claim.lease_token,
      p_retry_after_seconds: retryAfterSeconds,
      p_error_code: errorCode,
    });
  };

  let email: { subject: string; text: string; html: string };
  let inlineAttachments: Array<{ content: string; filename: string; content_id: string; content_type: "image/jpeg" }> = [];
  if (claim.event_type === "initial") {
    if (typeof claim.delivery_token_ciphertext !== "string") {
      await fail("invalid_delivery_token");
      return json(502, { error: "delivery_unavailable" });
    }
    const token = await decryptInvitationToken(claim.delivery_token_ciphertext, encryptionKey);
    if (!token) {
      await fail("invalid_delivery_token");
      return json(502, { error: "delivery_unavailable" });
    }
    const invitationUrl = new URL(invitationPage.toString());
    invitationUrl.searchParams.set("token", token);
    const previews = await getInitialPhotoSharePreviews(service, claim.share_id);
    inlineAttachments = previews.thumbnails.map((thumbnail) => ({
      content: thumbnail.base64,
      filename: thumbnail.filename,
      content_id: thumbnail.contentId,
      content_type: thumbnail.contentType,
    }));
    email = buildInvitationEmail({
      kind: "album",
      senderName: "FamilArea",
      href: invitationUrl.toString(),
      subject: "Hai ricevuto fotografie condivise su FamilArea",
      title: "Hai ricevuto fotografie condivise.",
      intro: "Una persona ha condiviso con te alcune fotografie private su FamilArea.",
      contentTitle: previews.contentTitle || undefined,
      albumPhotoCids: previews.thumbnails.map((thumbnail) => thumbnail.contentId),
      buttonLabel: "Apri invito",
      afterClick: "Accedi o registrati con questo stesso indirizzo email per decidere se accettare l'invito.",
      privacyNote: previews.thumbnails.length
        ? "Le miniature mostrano solo le fotografie selezionate per questa condivisione; le altre restano private."
        : "Le fotografie selezionate saranno disponibili in sicurezza dopo l'accettazione dell'invito.",
    });
  } else {
    const galleryUrl = new URL("/foto-condivise.html", invitationPage.origin);
    galleryUrl.searchParams.set("share", claim.share_id);
    email = buildInvitationEmail({
      kind: "album",
      senderName: "FamilArea",
      href: galleryUrl.toString(),
      subject: "Le fotografie condivise con te sono state aggiornate",
      title: "Le fotografie condivise sono state aggiornate.",
      intro: "Sono state aggiunte nuove fotografie a una condivisione che hai già accettato.",
      buttonLabel: "Apri fotografie condivise",
      afterClick: "Accedi a FamilArea con l'indirizzo che ha ricevuto la condivisione.",
    });
  }

  try {
    const delivery = await fetch(deliveryUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${deliveryBearer}`,
        "Idempotency-Key": claim.delivery_idempotency_key,
      },
      body: JSON.stringify({
        from,
        to: claim.recipient_email,
        ...email,
        ...(inlineAttachments.length ? { attachments: inlineAttachments } : {}),
      }),
    });
    if (!delivery.ok) throw new Error("delivery_failed");
  } catch {
    await fail("delivery_failed");
    return json(502, { error: "delivery_unavailable" });
  }

  const { error: completeError } = await service.rpc("complete_memory_photo_share_notification_event", {
    p_notification_event_id: claim.notification_event_id,
    p_lease_token: claim.lease_token,
  });
  if (completeError) return json(503, { error: "delivery_state_unavailable" });

  return json(200, { status: "processed" });
});

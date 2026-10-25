import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildInvitationEmail, singleLine } from "../_shared/invitation-email.ts";
import { createMemoryCoverThumbnail, resolveCoverAttachmentContext, resolveMemoryCoverContext, resolveOwnerAccountId } from "./cover-thumbnail.ts";

type InvitationDetails = { invitation_id: string; recipient_email: string; sender_name: string; memory_title: string };
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...cors } });
const isUuid = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
async function createTokenHash() {
  const bytes = crypto.getRandomValues(new Uint8Array(32)); let raw = ""; bytes.forEach((byte) => { raw += String.fromCharCode(byte); });
  const token = btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return { token, hash: Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("") };
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });
  const authorization = request.headers.get("Authorization"); if (!authorization?.startsWith("Bearer ")) return json(401, { error: "authentication_required" });
  let body: { memory_id?: unknown; contact_id?: unknown }; try { body = await request.json(); } catch { return json(400, { error: "invalid_request" }); }
  if (!isUuid(body?.memory_id) || !isUuid(body?.contact_id)) return json(400, { error: "invalid_request" });

  const url = Deno.env.get("SUPABASE_URL"), anon = Deno.env.get("SUPABASE_ANON_KEY"), serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"), site = Deno.env.get("SITE_URL"), from = Deno.env.get("MEMORY_SHARE_INVITE_FROM") || Deno.env.get("CONTACT_REGISTRATION_INVITE_FROM"), deliveryUrl = Deno.env.get("MEMORY_SHARE_INVITE_DELIVERY_URL") || Deno.env.get("CONTACT_REGISTRATION_INVITE_DELIVERY_URL"), deliveryBearer = Deno.env.get("MEMORY_SHARE_INVITE_DELIVERY_BEARER_TOKEN") || Deno.env.get("CONTACT_REGISTRATION_INVITE_DELIVERY_BEARER_TOKEN");
  if (!url || !anon || !serviceKey || !site || !from || !deliveryUrl || !deliveryBearer) return json(500, { error: "invite_service_misconfigured" });
  let invitationPage: URL; try { invitationPage = new URL("/invito-album.html", site); } catch { return json(500, { error: "invite_service_misconfigured" }); }
  if (invitationPage.origin !== "https://familarea.com") return json(500, { error: "invite_service_misconfigured" });

  // Creation and metadata retrieval use the caller JWT. The service role records delivery only.
  const caller = createClient(url, anon, { global: { headers: { Authorization: authorization } } });
  const service = createClient(url, serviceKey);
  const { data: userData, error: userError } = await caller.auth.getUser(); if (userError || !userData.user) return json(401, { error: "authentication_required" });
  // Media errors deliberately fall back before creating an invitation.
  const { data: currentAccount, error: currentAccountError } = await caller.rpc("get_current_account");
  const ownerAccountId = resolveOwnerAccountId(currentAccount, currentAccountError);
  const { data: memoryData, error: memoryError } = await caller.rpc("get_memory", { p_memory_id: body.memory_id });
  const memoryContext = resolveMemoryCoverContext(memoryData, memoryError);
  const { data: attachmentsData, error: attachmentsError } = await caller.rpc("get_attachments", { p_target_type: "memory", p_target_id: body.memory_id });
  const attachmentContext = resolveCoverAttachmentContext(attachmentsData, attachmentsError, memoryContext.memory?.coverAttachmentId);
  const coverThumbnail = !ownerAccountId
    ? (console.warn("COVER_ACCOUNT_RESOLUTION_FAILED"), null)
    : memoryContext.diagnostic
      ? (console.warn(memoryContext.diagnostic), null)
      : attachmentContext.diagnostic
        ? (console.warn(attachmentContext.diagnostic), null)
        : await createMemoryCoverThumbnail(service, ownerAccountId, body.memory_id, memoryContext.memory!, attachmentContext.attachment!);
  const { token, hash } = await createTokenHash();
  const { data, error } = await caller.rpc("create_memory_share_invitation", { p_memory_id: body.memory_id, p_contact_id: body.contact_id, p_token_hash: hash });
  if (error || !data) return json(403, { error: "invite_unavailable" });

  const invite = data as InvitationDetails;
  const senderName = singleLine(invite.sender_name, "Una persona che conosci");
  const memoryTitle = singleLine(invite.memory_title);
  if (!memoryTitle) {
    const { error: markError } = await service.rpc("mark_memory_share_invitation_delivery", { p_id: invite.invitation_id, p_status: "failed", p_error: "memory_metadata_unavailable" });
    if (markError) console.error("memory share delivery state unavailable");
    return json(500, { error: "invite_metadata_unavailable" });
  }
  const invitationUrl = new URL(invitationPage.toString()); invitationUrl.searchParams.set("token", token);
  const albumLabel = `l'Album "${memoryTitle}"`;
  const payload = {
    from,
    to: invite.recipient_email,
    ...buildInvitationEmail({
      kind: "album",
      senderName,
      href: invitationUrl.toString(),
      subject: `${senderName} ti invita a visualizzare ${albumLabel} su FamilArea`,
      title: `${senderName} ha un ricordo da condividere con te.`,
      intro: "Hai ricevuto un invito personale a scoprire un Album su FamilArea.",
      contentTitle: memoryTitle,
      buttonLabel: "Scopri l’Album",
      afterClick: "Potrai accedere o registrarti con lo stesso indirizzo che ha ricevuto l’invito, poi decidere se accettarlo.",
      privacyNote: coverThumbnail
        ? "La miniatura della copertina e inclusa in questa email. Le altre fotografie restano private finche non accetti l'invito."
        : "Le fotografie restano private finche non accetti l'invito.",
      albumCoverCid: coverThumbnail?.contentId
    }),
    ...(coverThumbnail ? { attachments: [{ content: coverThumbnail.base64, filename: coverThumbnail.filename, content_id: coverThumbnail.contentId, content_type: coverThumbnail.contentType }] } : {})
  };
  try { const delivery = await fetch(deliveryUrl, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${deliveryBearer}` }, body: JSON.stringify(payload) }); if (!delivery.ok) throw new Error("delivery_failed"); }
  catch {
    const { error: markError } = await service.rpc("mark_memory_share_invitation_delivery", { p_id: invite.invitation_id, p_status: "failed", p_error: "delivery_failed" });
    if (markError) { console.error("memory share delivery state unavailable"); return json(502, { error: "invite_delivery_state_unavailable" }); }
    console.error("memory share delivery failed"); return json(502, { error: "email_delivery_failed" });
  }
  const { error: markSentError } = await service.rpc("mark_memory_share_invitation_delivery", { p_id: invite.invitation_id, p_status: "sent", p_error: null });
  if (markSentError) { console.error("memory share delivery state unavailable"); return json(502, { error: "invite_delivery_state_unavailable" }); }
  return json(200, { invitation_id: invite.invitation_id, status: "pending" });
});

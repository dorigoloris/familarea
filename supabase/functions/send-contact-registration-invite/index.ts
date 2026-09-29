import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type DeliveryDetails = {
  recipient_email: string;
  sender_name: string;
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type"
};
const jsonHeaders = { "Content-Type": "application/json", ...corsHeaders };

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

function escapeHtml(value: string) {
  return value.replace(/[&<>'"]/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
  }[character] ?? character));
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return json(401, { error: "authentication_required" });

  let contactId = "";
  try {
    const body = await request.json();
    contactId = typeof body?.contact_id === "string" ? body.contact_id : "";
  } catch {
    return json(400, { error: "invalid_request" });
  }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(contactId)) {
    return json(400, { error: "invalid_contact" });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const siteUrl = Deno.env.get("SITE_URL");
  const from = Deno.env.get("CONTACT_REGISTRATION_INVITE_FROM");
  const deliveryUrl = Deno.env.get("CONTACT_REGISTRATION_INVITE_DELIVERY_URL");
  const deliveryBearerToken = Deno.env.get("CONTACT_REGISTRATION_INVITE_DELIVERY_BEARER_TOKEN");
  if (!supabaseUrl || !supabaseAnonKey || !supabaseServiceRoleKey || !siteUrl || !from) return json(500, { error: "invite_service_misconfigured" });
  if (!deliveryUrl || !deliveryBearerToken) return json(503, { error: "email_delivery_not_configured" });

  const caller = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authorization } }
  });
  const service = createClient(supabaseUrl, supabaseServiceRoleKey);
  const { data: userData, error: userError } = await caller.auth.getUser();
  if (userError || !userData.user) return json(401, { error: "authentication_required" });

  const { data, error } = await caller.rpc("get_my_contact_invitation_delivery", {
    p_contact_id: contactId
  });
  if (error || !data) return json(403, { error: "invite_unavailable" });
  const deliveryDetails = data as DeliveryDetails;

  let registrationUrl: URL;
  try {
    registrationUrl = new URL("/registrati.html", siteUrl);
  } catch {
    return json(500, { error: "invite_service_misconfigured" });
  }

  const senderName = deliveryDetails.sender_name || "Un utente FamilArea";
  const deliveryPayload = {
    from,
    to: deliveryDetails.recipient_email,
    subject: `${senderName} ti invita in FamilArea`,
    text: `${senderName} ti invita a scoprire FamilArea. Iscriviti: ${registrationUrl.toString()}`,
    html: `<p>${escapeHtml(senderName)} ti invita a scoprire FamilArea.</p><p><a href="${escapeHtml(registrationUrl.toString())}">Iscriviti a FamilArea</a></p>`
  };

  try {
    const delivery = await fetch(deliveryUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${deliveryBearerToken}`
      },
      body: JSON.stringify(deliveryPayload)
    });
    if (!delivery.ok) throw new Error(`delivery adapter returned ${delivery.status}`);
  } catch (error) {
    console.error("contact invitation delivery failed", error);
    return json(502, { error: "email_delivery_failed" });
  }

  const { error: markError } = await service.rpc("mark_contact_registration_invite_sent", {
    p_contact_id: contactId
  });
  if (markError) {
    console.error("contact invitation sent but state could not be recorded", markError);
    return json(500, { error: "invite_state_unavailable" });
  }

  return json(200, { status: "sent" });
});

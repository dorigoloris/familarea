import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const allowedOrigins = new Set([
  "https://familarea.com",
  "https://www.familarea.com",
  "http://localhost:8000",
  "http://127.0.0.1:8000"
]);

function cors(request: Request) {
  const origin = request.headers.get("Origin") || "";
  return {
    "Access-Control-Allow-Origin": allowedOrigins.has(origin) ? origin : "https://familarea.com",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Cache-Control": "no-store",
    "Vary": "Origin"
  };
}

function json(request: Request, status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...cors(request) }
  });
}

function isUuid(value: unknown): value is string {
  return typeof value === "string"
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors(request) });
  if (request.method !== "POST") return json(request, 405, { error: "method_not_allowed" });

  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return json(request, 401, { error: "authentication_required" });

  let body: { deadline_id?: unknown };
  try {
    body = await request.json();
  } catch {
    return json(request, 400, { error: "invalid_request" });
  }
  if (!isUuid(body?.deadline_id)) return json(request, 400, { error: "invalid_request" });

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceRoleKey) return json(request, 500, { error: "image_service_misconfigured" });

  // This client preserves the caller JWT: the RPC authorizes the exact deadline ID.
  const caller = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
  const { data: userData, error: userError } = await caller.auth.getUser();
  if (userError || !userData.user) return json(request, 401, { error: "authentication_required" });

  const { data: imagePath, error: accessError } = await caller.rpc(
    "get_my_authorized_deadline_item_image_path",
    { p_deadline_id: body.deadline_id }
  );
  if (accessError) return json(request, 404, { error: "image_unavailable" });
  if (typeof imagePath !== "string" || !imagePath) return json(request, 404, { error: "image_unavailable" });

  // The service key is confined to this server function and signs only the RPC-authorized path.
  const service = createClient(url, serviceRoleKey);
  const { data: signed, error: signingError } = await service.storage
    .from("deadline-item-images")
    .createSignedUrl(imagePath, 60);
  if (signingError || !signed?.signedUrl) return json(request, 404, { error: "image_unavailable" });

  return json(request, 200, { signed_url: signed.signedUrl, expires_in: 60 });
});

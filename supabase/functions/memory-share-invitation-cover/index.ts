import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const allowedOrigins = new Set([
  "https://familarea.com",
  "https://www.familarea.com",
  "http://localhost:8000",
  "http://127.0.0.1:8000",
]);
const imageMimeTypes = new Set(["image/jpeg", "image/png", "image/webp"]);
const maxImageBytes = 15 * 1024 * 1024;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type CoverContext = { attachment_id?: unknown; storage_path?: unknown; mime_type?: unknown };
type CurrentAccount = { account_id?: unknown };

function cors(request: Request) {
  const origin = request.headers.get("Origin") || "";
  return {
    "Access-Control-Allow-Origin": allowedOrigins.has(origin) ? origin : "https://familarea.com",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Cache-Control": "private, no-store",
    "Vary": "Origin",
  };
}

function json(request: Request, status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...cors(request) } });
}

function isUuid(value: unknown): value is string { return typeof value === "string" && uuidPattern.test(value); }
function isStoragePath(value: unknown): value is string { return typeof value === "string" && value.length > 0 && value.length <= 1024 && !/[\u0000-\u001F\u007F]/.test(value); }
function isToken(value: unknown): value is string { return typeof value === "string" && /^[A-Za-z0-9_-]{32,128}$/.test(value); }

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors(request) });
  if (request.method !== "POST") return json(request, 405, { error: "method_not_allowed" });

  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return json(request, 401, { error: "authentication_required" });
  let body: { token?: unknown };
  try { body = await request.json(); } catch { return json(request, 400, { error: "invalid_request" }); }
  if (!isToken(body?.token)) return json(request, 400, { error: "invalid_request" });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) return json(request, 500, { error: "image_service_misconfigured" });

  try {
    const caller = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } } });
    const { data: userData, error: userError } = await caller.auth.getUser();
    if (userError || !userData.user) return json(request, 401, { error: "authentication_required" });
    const { data: currentAccount, error: accountError } = await caller.rpc("get_current_account");
    const recipientAccountId = (currentAccount as CurrentAccount | null)?.account_id;
    if (accountError || !isUuid(recipientAccountId)) return json(request, 403, { error: "image_unavailable" });

    const service = createClient(supabaseUrl, serviceRoleKey);
    const { data: rawContext, error: contextError } = await service.rpc(
      "get_memory_share_invitation_cover_context_for_service",
      { p_recipient_account_id: recipientAccountId, p_token: body.token },
    );
    const context = rawContext as CoverContext | null;
    if (contextError || !context || !isUuid(context.attachment_id) || !isStoragePath(context.storage_path) || typeof context.mime_type !== "string" || !imageMimeTypes.has(context.mime_type)) {
      return json(request, 404, { error: "image_unavailable" });
    }

    const { data: image, error: downloadError } = await service.storage.from("familarea-attachments").download(context.storage_path);
    if (downloadError || !image || image.size <= 0 || image.size > maxImageBytes) return json(request, 404, { error: "image_unavailable" });

    return new Response(image, {
      status: 200,
      // functions.invoke deserializes application/octet-stream as a Blob. The
      // browser reattaches the already-authorized MIME from the context.
      headers: { ...cors(request), "Content-Type": "application/octet-stream", "Content-Length": String(image.size), "X-Content-Type-Options": "nosniff" },
    });
  } catch {
    // Do not expose invitation tokens, storage paths, database errors or bytes.
    return json(request, 500, { error: "image_unavailable" });
  }
});

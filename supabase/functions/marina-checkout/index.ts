// Založenie rezervácie v sekcii Marína rozpis (poplatok 2,50 € sa platí QR kódom).
// Verejná funkcia (verejnosť nie je prihlásená, preto verify_jwt = false). Rezerváciu zakladá len ona, so service_role kľúčom.
//
//  action "create": overí vstupy (deň + hodina 12–21, t. j. termín hodina–hodina+1) a založí rezerváciu v stave pending_payment („Čaká na platbu“, drží deň 24 hodín).
//                   Rezerváciu oficiálne zaeviduje (stav new) až Marína / správca, keď v apke potvrdí prijatie platby.
//
// Žiadna automatická platobná brána ani tlačidlo „Zaplatil som“. Tajné hodnoty netreba.
// SUPABASE_URL a SUPABASE_SERVICE_ROLE_KEY dodáva Supabase automaticky.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const PRICE_CENTS = 250;
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const KNOWN = ["day_not_free", "slot_taken", "bad_day", "bad_hour", "bad_input", "too_many", "busy"];
const str = (v: unknown, max: number) => (typeof v === "string" ? v.slice(0, max) : "");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "bad_input" }, 400); }
  if (body.action !== "create") return json({ error: "bad_input" }, 400);

  const day = str(body.day, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) return json({ error: "bad_day" }, 400);
  const hour = Number(body.hour);
  if (!Number.isInteger(hour) || hour < 12 || hour > 21) return json({ error: "bad_hour" }, 400);
  const { data: id, error } = await db.rpc("marina_create_pending", {
    p_day: day,
    p_hour: hour,
    p_name: str(body.name, 200),
    p_destination: str(body.destination, 300),
    p_note: str(body.note, 2000) || null,
  });
  if (error) {
    const code = KNOWN.find((k) => (error.message || "").includes(k));
    return json({ error: code ?? "server" }, code ? 409 : 500);
  }
  return json({ mode: "qr", booking_id: id, amount_cents: PRICE_CENTS });
});

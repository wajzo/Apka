// Platba za rezerváciu v sekcii Marína rozpis (2,50 €).
// Verejná funkcia (verejnosť nie je prihlásená, preto verify_jwt = false). Rezerváciu zakladá len ona, so service_role kľúčom.
//
//  action "create":       overí a založí rezerváciu v stave pending_payment, vytvorí platbu a vráti
//                         { mode: "stripe", url } (presmerovanie na Stripe Checkout) alebo { mode: "simulation", booking_id }
//  action "abort":        zrušená platba -> uvoľní deň
//  action "simulate_pay": len pri PAYMENT_MODE=simulation; označí rezerváciu ako zaplatenú (skúšobný režim bez peňazí)
//
// Tajné hodnoty (Supabase → Edge Functions → Secrets), nikdy nie v repozitári:
//   PAYMENT_MODE          "stripe" alebo "simulation" (bez nastavenia sa platby odmietnu)
//   STRIPE_SECRET_KEY     sk_live_… / sk_test_… (len režim stripe)
//   APP_URL               adresa apky, napr. https://wajzo.github.io/Apka/ (kam Stripe vráti zákazníka)
// SUPABASE_URL a SUPABASE_SERVICE_ROLE_KEY dodáva Supabase automaticky.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const PRICE_CENTS = 250; // poplatok sa určuje len tu na serveri, nie v prehliadači
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const KNOWN = ["day_not_free", "day_taken", "bad_day", "bad_input", "too_many", "busy"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const str = (v: unknown, max: number) => (typeof v === "string" ? v.slice(0, max) : "");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const mode = Deno.env.get("PAYMENT_MODE");
  if (mode !== "stripe" && mode !== "simulation") return json({ error: "payments_not_configured" }, 503);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "bad_input" }, 400); }
  const action = body.action;

  if (action === "abort") {
    const id = str(body.booking_id, 40);
    if (UUID.test(id)) await db.rpc("marina_cancel_pending", { p_id: id });
    return json({ ok: true });
  }

  if (action === "simulate_pay") {
    if (mode !== "simulation") return json({ error: "forbidden" }, 403);
    const id = str(body.booking_id, 40);
    if (!UUID.test(id)) return json({ error: "bad_input" }, 400);
    const { data, error } = await db.rpc("marina_mark_paid", { p_id: id, p_ref: "simulated", p_amount: PRICE_CENTS });
    if (error) return json({ error: "server" }, 500);
    return json({ ok: true, result: data });
  }

  if (action !== "create") return json({ error: "bad_input" }, 400);

  const day = str(body.day, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) return json({ error: "bad_day" }, 400);
  const { data: id, error } = await db.rpc("marina_create_pending", {
    p_day: day,
    p_name: str(body.name, 200),
    p_destination: str(body.destination, 300),
    p_note: str(body.note, 2000) || null,
  });
  if (error) {
    const code = KNOWN.find((k) => (error.message || "").includes(k));
    return json({ error: code ?? "server" }, code ? 409 : 500);
  }

  if (mode === "simulation") return json({ mode: "simulation", booking_id: id, amount_cents: PRICE_CENTS });

  // Stripe Checkout (hosťovaná platobná stránka Stripe, údaje o karte sa k nám nedostanú)
  const key = Deno.env.get("STRIPE_SECRET_KEY");
  const app = (Deno.env.get("APP_URL") || "").replace(/#.*$/, "");
  if (!key || !/^https:\/\//.test(app)) {
    await db.rpc("marina_cancel_pending", { p_id: id });
    return json({ error: "payments_not_configured" }, 503);
  }
  const sep = app.includes("?") ? "&" : "?";
  const p = new URLSearchParams({
    mode: "payment",
    locale: "sk",
    client_reference_id: id,
    "metadata[booking_id]": id,
    "line_items[0][quantity]": "1",
    "line_items[0][price_data][currency]": "eur",
    "line_items[0][price_data][unit_amount]": String(PRICE_CENTS),
    "line_items[0][price_data][product_data][name]": "Rezervácia termínu: Marína",
    success_url: `${app}${sep}pay=ok&b=${id}#marina`,
    cancel_url: `${app}${sep}pay=cancel&b=${id}#marina`,
    expires_at: String(Math.floor(Date.now() / 1000) + 30 * 60), // zhodné s 30-minútovým držaním dňa
  });
  const r = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/x-www-form-urlencoded", "Idempotency-Key": id },
    body: p,
  });
  const s = await r.json().catch(() => ({}));
  if (!r.ok || !s.url) {
    console.error("stripe checkout error", r.status, s?.error?.message);
    await db.rpc("marina_cancel_pending", { p_id: id });
    return json({ error: "payment_unavailable" }, 502);
  }
  return json({ mode: "stripe", url: s.url, booking_id: id });
});

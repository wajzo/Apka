// Webhook Stripe: po úspešnej platbe označí rezerváciu ako zaplatenú (to spustí upozornenie pre Marínu).
// Nastav v Stripe → Developers → Webhooks: adresa  <SUPABASE_URL>/functions/v1/stripe-webhook
// udalosti: checkout.session.completed, checkout.session.async_payment_succeeded, checkout.session.expired
// Tajná hodnota STRIPE_WEBHOOK_SECRET (whsec_…) patrí do Supabase → Edge Functions → Secrets.
// Podpis sa overuje, takže platbu nemožno sfalšovať. Verejná funkcia (verify_jwt = false).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const PRICE_CENTS = 250;
const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function verify(raw: string, header: string, secret: string): Promise<boolean> {
  const parts = Object.fromEntries(header.split(",").map((kv) => kv.split("=") as [string, string]));
  const t = parts["t"];
  const sigs = header.split(",").filter((x) => x.startsWith("v1=")).map((x) => x.slice(3));
  if (!t || !sigs.length || Math.abs(Date.now() / 1000 - Number(t)) > 300) return false;
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = hex(await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${raw}`)));
  return sigs.some((s) => safeEqual(s, mac));
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });
  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!secret) return new Response("not configured", { status: 503 });
  const raw = await req.text();
  if (!(await verify(raw, req.headers.get("Stripe-Signature") || "", secret))) return new Response("bad signature", { status: 400 });

  const event = JSON.parse(raw);
  const s = event?.data?.object ?? {};
  const id: string | undefined = s.client_reference_id || s.metadata?.booking_id;
  if (!id) return new Response("ok");

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  if (event.type === "checkout.session.completed" || event.type === "checkout.session.async_payment_succeeded") {
    if (s.payment_status !== "paid" || s.currency !== "eur" || s.amount_total !== PRICE_CENTS) {
      console.error("platba nespĺňa podmienky", id, s.payment_status, s.currency, s.amount_total);
      return new Response("ok");
    }
    const { data, error } = await db.rpc("marina_mark_paid", { p_id: id, p_ref: String(s.payment_intent ?? s.id), p_amount: s.amount_total });
    if (error) { console.error("mark_paid", error.message); return new Response("retry", { status: 500 }); } // Stripe zopakuje
    if (data === "conflict") console.error("ZAPLATENÁ rezervácia sa nedá potvrdiť (deň obsadený), treba vrátiť peniaze:", id, s.payment_intent);
  } else if (event.type === "checkout.session.expired") {
    await db.rpc("marina_cancel_pending", { p_id: id });
  }
  return new Response("ok");
});

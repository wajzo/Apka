// Z odkazu zistí názov miesta a obrázok (og:image alebo ikonu stránky).
// Vyžaduje prihláseného používateľa a chráni pred SSRF (súkromné adresy, localhost, presmerovania).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { absoluteHttp, deriveName, iconHref, isMapsLink, mainLabel, mapsName, metaContent, pageTitle } from "./parse.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

class UserError extends Error {}

function jwtRole(req: Request): string | null {
  const tok = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const part = tok.split(".")[1];
  if (!part) return null;
  try {
    const b64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
    return JSON.parse(atob(b64)).role ?? null;
  } catch { return null; }
}

function isPrivateIPv4(ip: string): boolean {
  const p = ip.split(".").map(Number);
  if (p.length !== 4 || p.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return false;
  const [a, b] = p;
  return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224;
}
function isPrivateIPv6(ip: string): boolean {
  const s = ip.toLowerCase();
  return s === "::1" || s === "::" || s.startsWith("fc") || s.startsWith("fd") || s.startsWith("fe80") || s.startsWith("::ffff:");
}

async function assertPublicHost(u: URL): Promise<void> {
  if (!/^https?:$/.test(u.protocol)) throw new UserError("Povolené sú len odkazy http a https.");
  if (u.username || u.password) throw new UserError("Odkaz nesmie obsahovať prihlasovacie údaje.");
  if (u.port && u.port !== "80" && u.port !== "443") throw new UserError("Nepodporovaný port v odkaze.");
  const host = u.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  const isV4 = /^\d+\.\d+\.\d+\.\d+$/.test(host);
  const isV6 = host.includes(":");
  if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal") ||
      (!isV4 && !isV6 && !host.includes("."))) throw new UserError("Neplatná adresa odkazu.");
  if ((isV4 && isPrivateIPv4(host)) || (isV6 && isPrivateIPv6(host))) throw new UserError("Neplatná adresa odkazu.");
  if (isV4 || isV6) return;
  let a: string[] = [], aaaa: string[] = [];
  try {
    [a, aaaa] = await Promise.all([
      Deno.resolveDns(host, "A").catch(() => [] as string[]),
      Deno.resolveDns(host, "AAAA").catch(() => [] as string[]),
    ]);
  } catch { /* DNS nedostupné: fetch zlyhá sám */ }
  if (a.some(isPrivateIPv4) || aaaa.some(isPrivateIPv6)) throw new UserError("Neplatná adresa odkazu.");
}

async function readLimited(res: Response, max = 400_000): Promise<string> {
  const reader = res.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (size < max) {
    const { done, value } = await reader.read();
    if (done || !value) break;
    chunks.push(value);
    size += value.length;
  }
  await reader.cancel().catch(() => {});
  const all = new Uint8Array(size);
  let o = 0;
  for (const c of chunks) { all.set(c, o); o += c.length; }
  const charset = /charset=([\w-]+)/i.exec(res.headers.get("content-type") || "")?.[1] || "utf-8";
  try { return new TextDecoder(charset, { fatal: false }).decode(all); }
  catch { return new TextDecoder("utf-8", { fatal: false }).decode(all); }
}

// Sleduje presmerovania ručne, každý krok znova kontroluje adresu. Vráti poslednú známu URL aj HTML (ak sa dalo načítať).
async function fetchPage(start: URL): Promise<{ finalUrl: URL; html: string | null }> {
  let url = start;
  for (let hop = 0; hop < 5; hop++) {
    await assertPublicHost(url);
    let res: Response;
    try {
      res = await fetch(url, {
        redirect: "manual",
        signal: AbortSignal.timeout(8000),
        headers: {
          "User-Agent": "Mozilla/5.0 (compatible; EvidenciaHodinBot/1.0; link preview)",
          "Accept": "text/html,application/xhtml+xml",
          "Accept-Language": "sk,cs;q=0.9,en;q=0.7",
        },
      });
    } catch { return { finalUrl: url, html: null }; }
    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get("location");
      await res.body?.cancel().catch(() => {});
      if (!loc) return { finalUrl: url, html: null };
      url = new URL(loc, url);
      continue;
    }
    const ctype = (res.headers.get("content-type") || "").toLowerCase();
    if (!res.ok || !/html|xml/.test(ctype)) { await res.body?.cancel().catch(() => {}); return { finalUrl: url, html: null }; }
    return { finalUrl: url, html: await readLimited(res) };
  }
  throw new UserError("Odkaz má príliš veľa presmerovaní.");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "Použi POST." }, 405);
  if (jwtRole(req) !== "authenticated") return json({ ok: false, error: "Musíš byť prihlásený." }, 401);

  let raw = "";
  try { raw = String((await req.json()).url ?? "").trim(); } catch { /* prázdne */ }
  if (!raw || raw.length > 2000) return json({ ok: false, error: "Vlož odkaz na miesto." }, 400);
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(raw)) raw = "https://" + raw;

  let start: URL;
  try { start = new URL(raw); } catch { return json({ ok: false, error: "Odkaz nie je platný." }, 400); }

  try {
    await assertPublicHost(start);
    const { finalUrl, html } = await fetchPage(start);
    const host = finalUrl.hostname;
    const maps = isMapsLink(finalUrl) || isMapsLink(start);
    const fromMaps = mapsName(finalUrl) ?? mapsName(start);

    let name: string | null = fromMaps;
    let image: string | null = null;
    if (html) {
      const head = html.slice(0, 300_000);
      if (!name) {
        name = deriveName({
          siteName: metaContent(head, ["og:site_name", "application-name"]),
          ogTitle: metaContent(head, ["og:title", "twitter:title"]),
          title: pageTitle(head),
          host,
        });
      }
      image = absoluteHttp(metaContent(head, ["og:image:secure_url", "og:image", "twitter:image", "twitter:image:src"]), finalUrl)
        ?? absoluteHttp(iconHref(head), finalUrl);
    }
    if (!name) name = mainLabel(host).charAt(0).toUpperCase() + mainLabel(host).slice(1);
    // bez obrázka z odkazu zoberieme ikonu stránky (nie pri mapách, tam by to bolo logo mapovej služby)
    if (!image && !maps) image = `https://www.google.com/s2/favicons?domain=${encodeURIComponent(host)}&sz=128`;

    return json({ ok: true, name, image, url: finalUrl.href, host, partial: !html });
  } catch (e) {
    if (e instanceof UserError) return json({ ok: false, error: e.message }, 400);
    return json({ ok: false, error: "Údaje z odkazu sa nepodarilo načítať." }, 502);
  }
});

// Čisté pomocné funkcie na získanie názvu a obrázka z HTML (bez sieťových volaní, dajú sa testovať v Node aj Deno).

const cp = (n: number): string => { try { return String.fromCodePoint(n); } catch { return ''; } };

export function decodeEntities(s: string): string {
  return s
    .replace(/&#(\d+);/g, (_, n) => cp(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => cp(parseInt(n, 16)))
    .replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&');
}

function attr(tag: string, name: string): string | null {
  const re = new RegExp(`(?<=[\\s"'/])${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, 'i');
  const m = re.exec(tag);
  return m ? (m[1] ?? m[2] ?? m[3] ?? '') : null;
}

export function metaContent(html: string, keys: string[]): string | null {
  const tags = html.match(/<meta\b[^>]*>/gi) || [];
  for (const key of keys) {
    for (const t of tags) {
      const k = (attr(t, 'property') ?? attr(t, 'name') ?? '').toLowerCase();
      if (k === key) {
        const c = attr(t, 'content');
        if (c && c.trim()) return decodeEntities(c).replace(/\s+/g, ' ').trim();
      }
    }
  }
  return null;
}

export function pageTitle(html: string): string | null {
  const m = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html);
  return m ? decodeEntities(m[1]).replace(/\s+/g, ' ').trim() || null : null;
}

export function iconHref(html: string): string | null {
  const tags = html.match(/<link\b[^>]*>/gi) || [];
  const found = (kind: RegExp) => {
    for (const t of tags) {
      const rel = (attr(t, 'rel') ?? '').toLowerCase();
      const href = attr(t, 'href');
      if (href && kind.test(rel)) return decodeEntities(href).trim();
    }
    return null;
  };
  return found(/apple-touch-icon/) ?? found(/(^|\s)(shortcut\s+)?icon(\s|$)/);
}

const norm = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]/g, '');
const GENERIC = new Set(['domov', 'uvod', 'home', 'homepage', 'vitajte', 'welcome', 'hlavna stranka', 'uvodna stranka']);

export function mainLabel(host: string): string {
  const parts = host.replace(/^www\./, '').split('.');
  return parts.length >= 2 ? parts[parts.length - 2] : parts[0];
}

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

export function deriveName(o: { siteName?: string | null; ogTitle?: string | null; title?: string | null; host: string }): string {
  const bare = o.host.replace(/^www\./, '').toLowerCase();
  const label = mainLabel(o.host);
  const clean = (s: string) => s.replace(/\s+/g, ' ').trim().slice(0, 100);
  if (o.siteName && o.siteName.trim()) return clean(o.siteName);
  const t = (o.ogTitle || o.title || '').trim();
  if (t && t.toLowerCase() !== bare) {
    const segs = t.split(/\s+[|–—·•-]\s+|\s*[|–—]\s*/).map(s => s.trim()).filter(Boolean);
    if (segs.length > 1) {
      const nl = norm(label);
      const match = segs.find(s => { const n = norm(s); return n.length >= 3 && (n.includes(nl) || nl.includes(n)); });
      if (match) return clean(match);
      const nonGeneric = segs.find(s => !GENERIC.has(norm(s).length ? s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase() : s));
      return clean(nonGeneric ?? segs[0]);
    }
    return clean(segs[0] ?? t);
  }
  return cap(label);
}

// Názov z odkazov na mapy (Google Maps /maps/place/NAZOV/…, ?q= pri Brave, Bing, Mapy.cz …)
export function mapsName(u: URL): string | null {
  const host = u.hostname.toLowerCase();
  const path = u.pathname;
  // názov v ceste majú len Google Maps (pri Brave a ďalších je v ceste interné ID, názov je v ?q=)
  const place = /(^|\.)google\.[a-z.]+$/.test(host) ? /\/maps\/place\/([^/@]+)/.exec(path) : null;
  if (place) {
    try { return decodeURIComponent(place[1].replace(/\+/g, ' ')).trim() || null; } catch { /* ignoruj */ }
  }
  if (/maps|mapy/.test(host) || /\/maps|\/mapy/.test(path)) {
    const q = u.searchParams.get('q') || u.searchParams.get('query');
    if (q && q.trim() && !/^-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?$/.test(q.trim())) return cap(q.trim());
  }
  return null;
}

export function isMapsLink(u: URL): boolean {
  const host = u.hostname.toLowerCase();
  return /maps|mapy/.test(host) || /\/maps|\/mapy/.test(u.pathname) || host.endsWith('goo.gl');
}

export function absoluteHttp(raw: string | null | undefined, base: URL): string | null {
  if (!raw) return null;
  try {
    const u = new URL(raw, base);
    return /^https?:$/.test(u.protocol) ? u.href : null;
  } catch { return null; }
}

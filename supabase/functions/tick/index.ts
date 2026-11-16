// DubsDay notifier. The database calls this once a minute. It works out every
// squad's DubTimes and sends push notifications: when one is found, 15 minutes
// before it starts, and when it goes live. All times are New York time.
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const TZ = "America/New_York";
const SLOTS = 48;
const MIN = 60000;
const SITE = "https://dubsday.vercel.app";

type Win = { uid: string; day: string; a: number; b: number; repeat: string; squads: string[] | null };
type Commit = { uid: string; day: string; a: number; b: number; squad: string };
type Squad = { id: string; name: string; members: string[] };
type Game = { name: string; need: string };

function tzParts(ms: number) {
  const f = new Intl.DateTimeFormat("en-US", {
    timeZone: TZ, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
  });
  const o: Record<string, number> = {};
  for (const p of f.formatToParts(new Date(ms))) if (p.type !== "literal") o[p.type] = Number(p.value);
  return o;
}
function zonedToUtc(y: number, m: number, d: number, h: number, mi: number) {
  const guess = Date.UTC(y, m - 1, d, h, mi);
  const p = tzParts(guess);
  const shown = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute);
  return guess - (shown - guess);
}
// A dub day starts at 4:00am New York time.
function dayBase(day: string) {
  const [y, m, d] = day.split("-").map(Number);
  return zonedToUtc(y, m, d, 4, 0);
}
function addDays(day: string, n: number) {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
}
function weekday(day: string) {
  return new Date(day + "T12:00:00Z").getUTCDay();
}
function tl(s: number) {
  const m = (240 + s * 30) % 1440, h = Math.floor(m / 60), mm = m % 60, h12 = h % 12 || 12;
  return h12 + ":" + String(mm).padStart(2, "0") + (h < 12 ? "am" : "pm");
}
function winOn(w: Win, day: string) {
  if (w.day === day) return true;
  if (!w.repeat || w.repeat === "none" || day < w.day) return false;
  return w.repeat === "daily" || weekday(w.day) === weekday(day);
}

Deno.serve(async (req: Request) => {
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
  try {
    const secret = req.headers.get("x-cron-secret") || "";
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: st, error } = await sb.rpc("tick_load", { p_secret: secret });
    if (error) return json({ error: "forbidden" }, 401);

    let pub: string | null = st.vapid_public, priv: string | null = st.vapid_private, generated = false;
    if (!pub || !priv) {
      const keys = webpush.generateVAPIDKeys();
      await sb.rpc("tick_set_vapid", { p_secret: secret, p_public: keys.publicKey, p_private: keys.privateKey });
      const again = await sb.rpc("tick_load", { p_secret: secret });
      pub = again.data.vapid_public; priv = again.data.vapid_private; generated = true;
    }
    webpush.setVapidDetails(SITE, pub!, priv!);

    const squads: Squad[] = st.squads, avail: Win[] = st.avail, commits: Commit[] = st.commits;
    const people: Record<string, { name: string; notif: Record<string, boolean> }> = st.people;
    const rank: Record<string, Record<string, Game[]>> = {};
    for (const r of st.rankings) (rank[r.squad] ||= {})[r.uid] = r.games;
    const byUser: Record<string, Win[]> = {};
    for (const w of avail) (byUser[w.uid] ||= []).push(w);

    const isAvail = (uid: string, sq: string, day: string, s: number) => {
      const ws = byUser[uid] || [];
      if (!ws.some((w) => winOn(w, day) && w.a <= s && s < w.b && (w.squads === null || w.squads.includes(sq)))) return false;
      if (commits.some((c) => c.uid === uid && c.day === day && c.a <= s && s < c.b && c.squad !== sq)) return false;
      return true;
    };
    const pickGame = (q: Squad, members: string[]) => {
      const n = q.members.length, k = members.length;
      const ok = (need: string) => (need === "full" ? k === n : k >= Number(need));
      const games = (m: string) => (rank[q.id] && rank[q.id][m]) || [];
      const blocked = new Set<string>(), seen = new Set<string>();
      members.forEach((m) => games(m).forEach((g) => { seen.add(g.name); if (!ok(g.need)) blocked.add(g.name); }));
      const alive = new Set([...seen].filter((g) => !blocked.has(g)));
      const ballots = members.map((m) => games(m).map((g) => g.name).filter((g) => alive.has(g)));
      const borda: Record<string, number> = {};
      ballots.forEach((b) => b.forEach((g, i) => (borda[g] = (borda[g] || 0) + 5 - i)));
      while (alive.size) {
        const tally: Record<string, number> = {};
        alive.forEach((g) => (tally[g] = 0));
        let active = 0;
        ballots.forEach((b) => { const c = b.find((g) => alive.has(g)); if (c) { tally[c]++; active++; } });
        if (!active) break;
        const order = [...alive].sort((x, y) => tally[y] - tally[x] || borda[y] - borda[x] || x.localeCompare(y));
        if (tally[order[0]] > active / 2 || alive.size === 1) return order[0];
        alive.delete(order[order.length - 1]);
      }
      return null;
    };

    const now = Date.now();
    const today: string = st.today;
    const known: Record<string, { found: boolean; warn: boolean; live: boolean }> = st.blocks;
    const next: Record<string, { found: boolean; warn: boolean; live: boolean; ends_at: string }> = {};
    const outbox: { uids: string[]; kind: string; title: string; body: string; url: string; tag: string }[] = [];

    for (const q of squads) {
      if (q.members.length < 2) continue;
      for (let off = 0; off < 7; off++) {
        const day = addDays(today, off), base = dayBase(day);
        let cur: { key: string; a: number; members: string[] } | null = null;
        for (let s = 0; s <= SLOTS; s++) {
          const mem = s < SLOTS ? q.members.filter((m) => isAvail(m, q.id, day, s)) : [];
          const key = mem.length >= 2 ? mem.join(",") : "";
          if (cur && cur.key !== key) {
            const a = cur.a, b = s, members = cur.members;
            cur = null;
            const start = base + a * 30 * MIN, end = base + b * 30 * MIN;
            if (now < end) {
              const id = [q.id, day, a, b, members.join(",")].join("|");
              const rec = { ...(known[id] || { found: false, warn: false, live: false }), ends_at: new Date(end).toISOString() };
              const full = members.length === q.members.length;
              const tier = full ? "Full-Squad DubTime" : "DubTime";
              const game = pickGame(q, members);
              const pick = game ? ` Pick: ${game}.` : "";
              const when = off === 0 ? "Today" : off === 1 ? "Tomorrow"
                : new Date(day + "T12:00:00Z").toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric", timeZone: "UTC" });
              const url = `${SITE}/?squad=${q.id}`;
              if (!rec.found) {
                outbox.push({ uids: members, kind: "found", title: `${tier} found`, body: `${q.name}: ${when}, ${tl(a)} to ${tl(b)}.${pick}`, url, tag: id + "|found" });
                rec.found = true;
                if (start - now <= 15 * MIN) rec.warn = true;
                if (now >= start) rec.live = true;
              }
              if (!rec.warn && start - now <= 15 * MIN) {
                if (start > now) outbox.push({ uids: members, kind: "warn", title: `${tier} in 15 minutes`, body: `${q.name} starts at ${tl(a)}.${pick}`, url, tag: id + "|warn" });
                rec.warn = true;
              }
              if (!rec.live && now >= start) {
                outbox.push({ uids: members, kind: "live", title: `${tier} is live`, body: `${q.name} until ${tl(b)}.${pick}`, url, tag: id + "|live" });
                rec.live = true;
              }
              next[id] = rec;
            }
          }
          if (!cur && key) cur = { key, a: s, members: mem };
        }
      }
    }

    let sent = 0, failed = 0;
    const dead: string[] = [];
    const errors: string[] = [];
    for (const msg of outbox) {
      for (const sub of st.subs as { uid: string; endpoint: string; p256dh: string; auth: string }[]) {
        if (!msg.uids.includes(sub.uid)) continue;
        const prefs = (people[sub.uid] && people[sub.uid].notif) || {};
        if (prefs[msg.kind] === false) continue;
        try {
          await webpush.sendNotification(
            { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
            JSON.stringify({ title: msg.title, body: msg.body, url: msg.url, tag: msg.tag }),
            { TTL: 3600, urgency: "high" },
          );
          sent++;
        } catch (e) {
          failed++;
          const code = (e as { statusCode?: number }).statusCode;
          if (code === 404 || code === 410) dead.push(sub.endpoint);
          else if (errors.length < 3) errors.push(String((e as Error).message || e).slice(0, 200));
        }
      }
    }
    await sb.rpc("tick_save", { p_secret: secret, p_blocks: next, p_dead: dead });
    return json({ ok: true, generated, blocks: Object.keys(next).length, messages: outbox.length, sent, failed, errors });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});

// Works out every squad's DubTimes as real moments in time and decides which
// notifications to send. Each person's availability is in their own time zone;
// each message is worded in the recipient's time zone. Pure: no I/O.

const MIN = 60000;
const SLOT = 30 * MIN;

export type Win = { uid: string; day: string; a: number; b: number; repeat: string; squads: string[] | null; tz: string };
export type Commit = { uid: string; starts_at: string; ends_at: string; squad: string };
export type Squad = { id: string; name: string; members: string[] };
export type Game = { name: string; need: string };
export type Person = { name: string; notif: Record<string, boolean>; tz: string };
export type Rec = { found: boolean; warn: boolean; live: boolean };
export type State = {
  squads: Squad[]; avail: Win[]; commits: Commit[]; people: Record<string, Person>;
  rankings: { squad: string; uid: string; games: Game[] }[]; blocks: Record<string, Rec>;
};
export type Message = { uid: string; kind: "found" | "warn" | "live"; title: string; body: string; url: string; tag: string };

const fmts: Record<string, Intl.DateTimeFormat> = {};
export function tzParts(ms: number, tz: string) {
  const f = fmts[tz] ||= new Intl.DateTimeFormat("en-US", {
    timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
  });
  const o: Record<string, number> = {};
  for (const p of f.formatToParts(new Date(ms))) if (p.type !== "literal") o[p.type] = Number(p.value);
  if (o.hour === 24) o.hour = 0;
  return o;
}
function zonedToUtc(y: number, m: number, d: number, h: number, mi: number, tz: string) {
  const want = Date.UTC(y, m - 1, d, h, mi);
  let t = want;
  for (let i = 0; i < 2; i++) {
    const p = tzParts(t, tz);
    t += want - Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute);
  }
  return t;
}
const bases: Record<string, number> = {};
// A dub day starts at 4:00am local time on its date.
export function dayBase(day: string, tz: string) {
  const k = day + "|" + tz;
  if (!(k in bases)) {
    const [y, m, d] = day.split("-").map(Number);
    bases[k] = zonedToUtc(y, m, d, 4, 0, tz);
  }
  return bases[k];
}
export function addDays(day: string, n: number) {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
}
const weekday = (day: string) => new Date(day + "T12:00:00Z").getUTCDay();
function winOn(w: Win, day: string) {
  if (w.day === day) return true;
  if (!w.repeat || w.repeat === "none" || day < w.day) return false;
  return w.repeat === "daily" || weekday(w.day) === weekday(day);
}
export function hm(ms: number, tz: string) {
  const p = tzParts(ms, tz), h = p.hour;
  return (h % 12 || 12) + ":" + String(p.minute).padStart(2, "0") + (h < 12 ? "am" : "pm");
}
function dubDayKey(ms: number, tz: string) {
  const p = tzParts(ms, tz);
  return new Date(Date.UTC(p.year, p.month - 1, p.day - (p.hour < 4 ? 1 : 0))).toISOString().slice(0, 10);
}
export function whenLabel(ms: number, tz: string, now: number) {
  const k = dubDayKey(ms, tz), diff = Math.round((Date.parse(k) - Date.parse(dubDayKey(now, tz))) / 864e5);
  if (diff === 0) return "Today";
  if (diff === 1) return "Tomorrow";
  return new Date(k + "T12:00:00Z").toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric", timeZone: "UTC" });
}

export function plan(st: State, now: number, site: string) {
  const NY = "America/New_York";
  const tzOf = (uid: string) => (st.people[uid] && st.people[uid].tz) || NY;
  const rank: Record<string, Record<string, Game[]>> = {};
  for (const r of st.rankings) (rank[r.squad] ||= {})[r.uid] = r.games;

  // every availability window, expanded to real start and end instants
  const today = new Date(now).toISOString().slice(0, 10);
  const iv: Record<string, { s: number; e: number; squads: string[] | null }[]> = {};
  for (const w of st.avail) {
    const list = iv[w.uid] ||= [];
    for (let k = -3; k <= 9; k++) {
      const d = addDays(today, k);
      if (!winOn(w, d)) continue;
      const b = dayBase(d, w.tz || NY);
      list.push({ s: b + w.a * SLOT, e: b + w.b * SLOT, squads: w.squads });
    }
  }
  const commits = st.commits.map((c) => ({ uid: c.uid, s: Date.parse(c.starts_at), e: Date.parse(c.ends_at), squad: c.squad }));

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

  // Old-format records mean this is the first run after the time zone change:
  // those DubTimes were already announced, so record them without sending.
  const keys = Object.keys(st.blocks);
  const seed = keys.length > 0 && !keys.some((k) => k.startsWith("v2|"));

  const horizon = now + 7 * 864e5;
  const next: Record<string, Rec & { ends_at: string }> = {};
  const out: Message[] = [];

  for (const q of st.squads) {
    if (q.members.length < 2) continue;
    const mine = (m: string) => (iv[m] || []).filter((x) => x.squads === null || x.squads.includes(q.id));
    const elsewhere = (m: string) => commits.filter((c) => c.uid === m && c.squad !== q.id);
    const cuts = new Set<number>();
    for (const m of q.members) {
      for (const x of mine(m)) { cuts.add(x.s); cuts.add(x.e); }
      for (const c of elsewhere(m)) { cuts.add(c.s); cuts.add(c.e); }
    }
    const times = [...cuts].sort((a, b) => a - b);
    const found: { s: number; e: number; members: string[] }[] = [];
    for (let i = 0; i + 1 < times.length; i++) {
      const t0 = times[i], t1 = times[i + 1];
      const members = q.members.filter((m) =>
        mine(m).some((x) => x.s <= t0 && t1 <= x.e) && !elsewhere(m).some((c) => c.s < t1 && c.e > t0));
      if (members.length < 2) continue;
      const last = found[found.length - 1];
      if (last && last.e === t0 && last.members.join(",") === members.join(",")) last.e = t1;
      else found.push({ s: t0, e: t1, members });
    }

    for (const blk of found) {
      if (blk.e - blk.s < SLOT || blk.e <= now || blk.s > horizon) continue;
      const id = ["v2", q.id, new Date(blk.s).toISOString(), new Date(blk.e).toISOString(), blk.members.join(",")].join("|");
      const rec = { ...(st.blocks[id] || { found: false, warn: false, live: false }), ends_at: new Date(blk.e).toISOString() };
      const full = blk.members.length === q.members.length;
      const tier = full ? "Full-Squad DubTime" : "DubTime";
      const game = pickGame(q, blk.members);
      const pick = game ? ` Pick: ${game}.` : "";
      const url = `${site}/?squad=${q.id}`;
      const send = (kind: Message["kind"], title: string, body: (tz: string) => string) => {
        if (seed) return;
        for (const uid of blk.members) out.push({ uid, kind, title, body: body(tzOf(uid)), url, tag: id + "|" + kind });
      };
      if (!rec.found) {
        send("found", `${tier} found`, (tz) => `${q.name}: ${whenLabel(blk.s, tz, now)}, ${hm(blk.s, tz)} to ${hm(blk.e, tz)}.${pick}`);
        rec.found = true;
        if (blk.s - now <= 15 * MIN) rec.warn = true;
        if (now >= blk.s) rec.live = true;
      }
      if (!rec.warn && blk.s - now <= 15 * MIN) {
        if (blk.s > now) send("warn", `${tier} in 15 minutes`, (tz) => `${q.name} starts at ${hm(blk.s, tz)}.${pick}`);
        rec.warn = true;
      }
      if (!rec.live && now >= blk.s) {
        send("live", `${tier} is live`, (tz) => `${q.name} until ${hm(blk.e, tz)}.${pick}`);
        rec.live = true;
      }
      next[id] = rec;
    }
  }
  return { next, out, seed };
}

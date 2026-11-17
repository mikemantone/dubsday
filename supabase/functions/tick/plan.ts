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

  const nameOf = (uid: string) => (st.people[uid] && st.people[uid].name) || "Someone";
  const andList = (xs: string[]) => xs.length <= 1 ? (xs[0] || "") : xs.slice(0, -1).join(", ") + " and " + xs[xs.length - 1];
  const lower = (w: string) => (w === "Today" || w === "Tomorrow") ? w.toLowerCase() : w;

  // Records from before evenings were introduced mean this is the first run of
  // the new rules: those DubTimes were already announced, so record without sending.
  const keys = Object.keys(st.blocks);
  const seed = keys.length > 0 && !keys.some((k) => k.startsWith("v3|"));

  const horizon = now + 7 * 864e5;
  const next: Record<string, Rec & { ends_at: string }> = {};
  const out: Message[] = [];
  const foundFor: Record<string, { q: Squad; ev: Evening; r: string }[]> = {};

  type Seg = { s: number; e: number; members: string[]; game: string | null; full: boolean };
  type Sess = { s: number; e: number; game: string | null; full: boolean; segs: Seg[] };
  type Evening = { s: number; e: number; sessions: Sess[] };
  const runs = (m: string, segs: Seg[]) => {
    const out: [number, number][] = [];
    for (const g of segs) if (g.members.includes(m)) {
      const last = out[out.length - 1];
      if (last && last[1] === g.s) last[1] = g.e; else out.push([g.s, g.e]);
    }
    return out;
  };
  const membersOf = (segs: Seg[]) => [...new Set(segs.flatMap((g) => g.members))];

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
    // stretches where the same 2+ people overlap
    const segs: Seg[] = [];
    for (let i = 0; i + 1 < times.length; i++) {
      const t0 = times[i], t1 = times[i + 1];
      const members = q.members.filter((m) =>
        mine(m).some((x) => x.s <= t0 && t1 <= x.e) && !elsewhere(m).some((c) => c.s < t1 && c.e > t0));
      if (members.length < 2) continue;
      const last = segs[segs.length - 1];
      if (last && last.e === t0 && last.members.join(",") === members.join(",")) last.e = t1;
      else segs.push({ s: t0, e: t1, members, game: null, full: false });
    }
    for (const g of segs) { g.game = pickGame(q, g.members); g.full = g.members.length === q.members.length; }
    // back-to-back stretches with the same pick are one DubTime (one card)
    const sessions: Sess[] = [];
    for (const g of segs) {
      const last = sessions[sessions.length - 1];
      if (last && last.e === g.s && last.game === g.game) { last.e = g.e; last.segs.push(g); last.full = last.full && g.full; }
      else sessions.push({ s: g.s, e: g.e, game: g.game, full: g.full, segs: [g] });
    }
    // back-to-back DubTimes are one evening for notifications
    const evenings: Evening[] = [];
    for (const x of sessions) {
      const last = evenings[evenings.length - 1];
      if (last && last.e === x.s) { last.e = x.e; last.sessions.push(x); } else evenings.push({ s: x.s, e: x.e, sessions: [x] });
    }

    for (const ev of evenings) {
      if (ev.e - ev.s < SLOT || ev.e <= now || ev.s > horizon) continue;
      const allSegs = ev.sessions.flatMap((x) => x.segs);
      const base = ["v3", q.id, new Date(ev.s).toISOString()].join("|");
      const ends_at = new Date(ev.e).toISOString();
      for (const r of membersOf(allSegs)) {
        const mine2 = runs(r, allSegs), rs = mine2[0][0], re = mine2[mine2.length - 1][1];
        const key = base + "|" + r;
        const rec = { ...(st.blocks[key] || { found: false, warn: false, live: false }), ends_at };
        const startSess = ev.sessions.find((x) => x.s <= rs && rs < x.e)!;
        const startSeg = startSess.segs.find((g) => g.s <= rs && rs < g.e)!;
        const tz = tzOf(r);
        const send = (kind: Message["kind"], title: string, body: string, tag: string) => {
          if (!seed) out.push({ uid: r, kind, title, body, url: `${site}/?squad=${q.id}`, tag });
        };
        if (!rec.found) {
          if (!seed) (foundFor[r] ||= []).push({ q, ev, r });
          rec.found = true;
          if (rs - now <= 15 * MIN) rec.warn = true;
          if (now >= rs) rec.live = true;
        }
        const tierAtStart = startSeg.full ? "Full-Squad DubTime" : "DubTime";
        const withAt = andList(startSeg.members.filter((m) => m !== r).map(nameOf));
        const gameAt = startSess.game ? startSess.game : "No game picked yet";
        if (!rec.warn && rs - now <= 15 * MIN) {
          if (rs > now) send("warn", `${tierAtStart} in 15 minutes`, `${q.name} at ${hm(rs, tz)}: ${gameAt}${withAt ? " with " + withAt : ""}.`, key + "|warn");
          rec.warn = true;
        }
        if (!rec.live && now >= rs) {
          send("live", `${tierAtStart} is live`, `${q.name} until ${hm(re, tz)}: ${gameAt}.`, key + "|live");
          rec.live = true;
        }
        next[key] = rec;
        // one extra alert when the full squad comes together partway through
        for (const x of ev.sessions) {
          if (!x.full || x.s <= rs || !x.segs[0].members.includes(r)) continue;
          const fk = key + "|full|" + new Date(x.s).toISOString();
          const frec = { ...(st.blocks[fk] || { found: false, warn: false, live: false }), ends_at };
          if (!frec.found && now >= x.s) {
            if (now < x.e) send("live", "Full squad is on", `${q.name}: ${x.game || "no game picked yet"} until ${hm(x.e, tz)}.`, fk);
            frec.found = true;
          }
          next[fk] = frec;
        }
      }
    }
  }

  // "found": one notification per person, however many DubTimes appeared at once
  const describe = (ev: Evening, r: string, tz: string, short: boolean) => {
    const parts = ev.sessions.map((x, i) => {
      const g = x.game || "no game picked yet";
      if (i === 0) return x.full ? `${g} with the full squad` : g;
      return x.full ? `then ${g} with the full squad ${short ? "at " + hm(x.s, tz) : hm(x.s, tz) + " to " + hm(x.e, tz)}` : `then ${g}${short ? "" : " at " + hm(x.s, tz)}`;
    });
    if (short) return parts.join(", ");
    let text = parts.join(", ");
    if (ev.sessions.length === 1) {
      const segs = ev.sessions[0].segs, others = membersOf(segs).filter((m) => m !== r);
      if (others.length) text += " with " + andList(others.map(nameOf));
      const notes: string[] = [];
      for (const m of [r, ...others]) {
        const rr = runs(m, segs), s0 = rr[0][0], e0 = rr[rr.length - 1][1];
        const who = m === r ? "You" : nameOf(m), verb = m === r ? ["join", "leave", "are in"] : ["joins", "leaves", "is in"];
        if (s0 === ev.s && e0 === ev.e) continue;
        if (s0 === ev.s) notes.push(`${who} ${verb[1]} at ${hm(e0, tz)}`);
        else if (e0 === ev.e) notes.push(`${who} ${verb[0]} at ${hm(s0, tz)}`);
        else notes.push(`${who} ${verb[2]} ${hm(s0, tz)} to ${hm(e0, tz)}`);
      }
      if (notes.length) text += ". " + notes.join(". ");
    }
    return text + ".";
  };
  for (const r in foundFor) {
    const list = foundFor[r].sort((a, b) => a.ev.s - b.ev.s), tz = tzOf(r);
    if (list.length === 1) {
      const { q, ev } = list[0];
      const full = ev.sessions.every((x) => x.full);
      out.push({ uid: r, kind: "found", title: full ? "Full-Squad DubTime found" : "DubTime found",
        body: `${q.name}, ${lower(whenLabel(ev.s, tz, now))} ${hm(ev.s, tz)} to ${hm(ev.e, tz)}: ${describe(ev, r, tz, false)}`,
        url: `${site}/?squad=${q.id}`, tag: "found|" + r + "|" + now });
    } else {
      const squads = [...new Set(list.map((x) => x.q.id))];
      const item = (x: { q: Squad; ev: Evening }) => `${lower(whenLabel(x.ev.s, tz, now))} ${hm(x.ev.s, tz)} (${describe(x.ev, r, tz, true)})`;
      const body = squads.length === 1
        ? `${list[0].q.name}: ${andList(list.slice(0, 4).map(item))}${list.length > 4 ? `, and ${list.length - 4} more` : ""}.`
        : list.slice(0, 4).map((x) => `${x.q.name} ${item(x)}`).join("; ") + (list.length > 4 ? `; and ${list.length - 4} more` : "") + ".";
      out.push({ uid: r, kind: "found", title: `${list.length} DubTimes found`, body,
        url: squads.length === 1 ? `${site}/?squad=${squads[0]}` : site, tag: "found|" + r + "|" + now });
    }
  }
  return { next, out, seed };
}

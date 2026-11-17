// DubsDay notifier. The database calls this once a minute. plan.ts works out
// every squad's DubTimes; this file loads the data, sends the push
// notifications and records what was sent.
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";
import { plan } from "./plan.ts";

const SITE = "https://dubsday.vercel.app";

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

    const { next, out, seed } = plan(st, Date.now(), SITE);

    let sent = 0, failed = 0;
    const dead: string[] = [];
    const errors: string[] = [];
    const subs = st.subs as { uid: string; endpoint: string; p256dh: string; auth: string }[];
    for (const msg of out) {
      const prefs = (st.people[msg.uid] && st.people[msg.uid].notif) || {};
      if (prefs[msg.kind] === false) continue;
      for (const sub of subs) {
        if (sub.uid !== msg.uid) continue;
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
    return json({ ok: true, generated, seed, blocks: Object.keys(next).length, messages: out.length, sent, failed, errors });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});

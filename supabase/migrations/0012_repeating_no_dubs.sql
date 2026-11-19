-- Repeating "No dubs": "Every [weekday]" runs until you stop it.
-- Weekly rules live in no_dubs_weekly (one per user per weekday, squads merged).
-- "Just this day" undo on a repeating day, or saving availability that day, adds a skip.
-- private.no_dubs_days() expands one-off days and weekly rules (minus skips) into dated
-- rows, so the app and notifier read the same shape as before (plus a 'weekly' flag).
create table public.no_dubs_weekly (
  user_id uuid not null references public.profiles(id) on delete cascade,
  dow int not null check (dow between 1 and 7),   -- ISO weekday of the dub day
  start_day date not null,
  squads uuid[],                                  -- null means every squad
  tz text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, dow)
);
alter table public.no_dubs_weekly enable row level security;

create table public.no_dubs_skips (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  squads uuid[],                                  -- null means every squad is back that day
  primary key (user_id, day)
);
alter table public.no_dubs_skips enable row level security;

create function private.my_squads(p_user uuid) returns uuid[] language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(array_agg(squad_id), '{}') from squad_members where user_id = p_user
$$;

create function private.no_dubs_days(p_from date, p_to date)
returns table(user_id uuid, day date, tz text, squads uuid[], weekly boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select n.user_id, n.day, n.tz, n.squads, false from no_dubs n where n.day between p_from and p_to
  union all
  select x.user_id, x.day, x.tz, x.squads, true from (
    select w.user_id, d::date as day, w.tz,
           case when k.user_id is null then w.squads
                else (select array_agg(s) from unnest(coalesce(w.squads, private.my_squads(w.user_id))) s where not s = any(k.squads)) end as squads,
           k.user_id is not null and k.squads is null as skipped_all
      from no_dubs_weekly w
      cross join generate_series(greatest(w.start_day, p_from), p_to, interval '1 day') d
      left join no_dubs_skips k on k.user_id = w.user_id and k.day = d::date
     where extract(isodow from d)::int = w.dow
  ) x
  where not x.skipped_all and (x.squads is null or cardinality(x.squads) > 0)
$$;
revoke execute on function private.no_dubs_days(date, date), private.my_squads(uuid) from public, anon, authenticated;

-- removes p_squads (null = all) from a squads array (null = all of the user's squads); returns '{}' when nothing is left
create function private.squads_minus(p_have uuid[], p_drop uuid[], p_user uuid) returns uuid[] language sql stable security definer set search_path = public, pg_temp as $$
  select case when p_drop is null then '{}'::uuid[]
    else coalesce((select array_agg(x) from unnest(coalesce(p_have, private.my_squads(p_user))) x where not x = any(p_drop)), '{}') end
$$;
create function private.squads_plus(p_have uuid[], p_add uuid[]) returns uuid[] language sql immutable as $$
  select case when p_have is null or p_add is null then null
    else (select array_agg(distinct x) from unnest(p_have || p_add) x) end
$$;
revoke execute on function private.squads_minus(uuid[], uuid[], uuid), private.squads_plus(uuid[], uuid[]) from public, anon, authenticated;

drop function public.set_no_dubs(date, uuid[]);
drop function public.clear_no_dubs(date, uuid[]);

create function public.set_no_dubs(p_day date, p_squads uuid[], p_repeat text default 'none') returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); cur no_dubs; wk no_dubs_weekly; my uuid[]; d int := extract(isodow from p_day)::int;
begin
  if p_day is null or p_day < current_date - 1 or p_day > current_date + 14 then raise exception 'bad_time'; end if;
  if p_repeat is null or p_repeat not in ('none', 'weekly') then raise exception 'bad_time'; end if;
  my := private.my_squads(me);
  if p_squads is not null and (cardinality(p_squads) = 0 or not p_squads <@ my) then raise exception 'not_member'; end if;
  if p_repeat = 'weekly' then
    select * into wk from no_dubs_weekly where user_id = me and dow = d;
    if not found then
      insert into no_dubs_weekly(user_id, dow, start_day, squads, tz) values (me, d, p_day, p_squads, (select tz from profiles where id = me));
    else
      update no_dubs_weekly set squads = private.squads_plus(wk.squads, p_squads), start_day = least(wk.start_day, p_day)
       where user_id = me and dow = d;
    end if;
    -- earlier "just this day" exceptions on this weekday no longer apply to these squads
    update no_dubs_skips set squads = private.squads_minus(squads, p_squads, me)
     where user_id = me and day >= p_day and extract(isodow from day)::int = d;
    delete from no_dubs_skips where user_id = me and squads = '{}';
    return;
  end if;
  select * into cur from no_dubs where user_id = me and day = p_day;
  if not found then
    insert into no_dubs(user_id, day, squads, tz) values (me, p_day, p_squads, (select tz from profiles where id = me));
  elsif cur.squads is not null then
    update no_dubs set squads = private.squads_plus(cur.squads, p_squads) where user_id = me and day = p_day;
  end if;
end $$;

create function public.clear_no_dubs(p_day date, p_squads uuid[], p_every boolean default false) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); cur no_dubs; wk no_dubs_weekly; k no_dubs_skips; left_over uuid[]; d int := extract(isodow from p_day)::int;
begin
  if p_day is null then raise exception 'bad_time'; end if;
  -- the one-off day
  select * into cur from no_dubs where user_id = me and day = p_day;
  if found then
    left_over := private.squads_minus(cur.squads, p_squads, me);
    if cardinality(left_over) = 0 then delete from no_dubs where user_id = me and day = p_day;
    else update no_dubs set squads = left_over where user_id = me and day = p_day; end if;
  end if;
  -- the weekly rule for this weekday
  select * into wk from no_dubs_weekly where user_id = me and dow = d;
  if not found then return; end if;
  if p_every then
    left_over := private.squads_minus(wk.squads, p_squads, me);
    if cardinality(left_over) = 0 then delete from no_dubs_weekly where user_id = me and dow = d;
    else update no_dubs_weekly set squads = left_over where user_id = me and dow = d; end if;
  elsif wk.start_day <= p_day then
    select * into k from no_dubs_skips where user_id = me and day = p_day;
    if not found then insert into no_dubs_skips(user_id, day, squads) values (me, p_day, p_squads);
    else update no_dubs_skips set squads = private.squads_plus(k.squads, p_squads) where user_id = me and day = p_day; end if;
  end if;
end $$;

revoke execute on function public.set_no_dubs(date, uuid[], text), public.clear_no_dubs(date, uuid[], boolean) from public, anon;
grant execute on function public.set_no_dubs(date, uuid[], text), public.clear_no_dubs(date, uuid[], boolean) to authenticated;

create or replace function public.get_state() returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  me uuid := auth.uid();
  p profiles;
  my_squads uuid[];
  mates uuid[];
  pals uuid[];
begin
  if me is null then raise exception 'not_signed_in'; end if;
  select * into p from profiles where id = me;
  if not found then return jsonb_build_object('me', null); end if;
  select coalesce(array_agg(squad_id), '{}') into my_squads from squad_members where user_id = me;
  select coalesce(array_agg(distinct user_id), '{}') into mates from squad_members where squad_id = any(my_squads) and user_id <> me;
  select coalesce(array_agg(case when requester = me then addressee else requester end), '{}') into pals
    from friendships where status = 'accepted' and me in (requester, addressee);
  return jsonb_build_object(
    'me', jsonb_build_object('id', p.id, 'first_name', p.first_name, 'gamertag', p.gamertag, 'friend_token', p.friend_token, 'notif', p.notif, 'tz', p.tz),
    'people', (select coalesce(jsonb_object_agg(pr.id, jsonb_build_object('name', pr.first_name, 'u', pr.gamertag)), '{}')
               from profiles pr where pr.id = any(mates) or pr.id = any(pals)),
    'friends', to_jsonb(pals),
    'req_in', (select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'u', pr.gamertag)), '[]')
               from friendships f join profiles pr on pr.id = f.requester where f.addressee = me and f.status = 'pending'),
    'req_out', (select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'u', pr.gamertag)), '[]')
               from friendships f join profiles pr on pr.id = f.addressee where f.requester = me and f.status = 'pending'),
    'squads', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'code', s.code, 'invite_token', s.invite_token, 'owner', s.created_by, 'icon', s.icon,
                 'members', (select jsonb_agg(m.user_id order by m.joined_at) from squad_members m where m.squad_id = s.id)) order by s.created_at), '[]')
               from squads s where s.id = any(my_squads)),
    'invites', (select coalesce(jsonb_agg(jsonb_build_object('squad', s.id, 'name', s.name, 'icon', s.icon, 'from', coalesce(pr.first_name, 'A friend'),
                 'members', (select count(*) from squad_members m where m.squad_id = s.id))), '[]')
               from squad_invitations i join squads s on s.id = i.squad_id left join profiles pr on pr.id = i.invited_by where i.user_id = me),
    'rankings', (select coalesce(jsonb_agg(jsonb_build_object('squad', r.squad_id, 'uid', r.user_id, 'games', r.games)), '[]')
               from rankings r where r.squad_id = any(my_squads)),
    'avail', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'uid', a.user_id, 'day', a.day, 'a', a.a, 'b', a.b, 'repeat', a.repeat, 'tz', a.tz,
                 'squads', case when a.squads is null then null
                           else (select coalesce(jsonb_agg(x), '[]') from unnest(a.squads) x where x = any(my_squads)) end) order by a.day, a.a), '[]')
               from availability a
               where (a.user_id = me or (a.user_id = any(mates) and (a.squads is null or a.squads && my_squads)))
                 and (a.repeat <> 'none' or a.day >= current_date - 3)),
    'nodubs', (select coalesce(jsonb_agg(jsonb_build_object('uid', n.user_id, 'day', n.day, 'tz', n.tz, 'weekly', n.weekly,
                 'squads', case when n.squads is null then null
                           else (select coalesce(jsonb_agg(x), '[]') from unnest(n.squads) x where x = any(my_squads)) end)), '[]')
               from private.no_dubs_days(current_date - 2, current_date + 14) n
               where (n.user_id = me or (n.user_id = any(mates) and (n.squads is null or n.squads && my_squads)))),
    'commits', (select coalesce(jsonb_agg(jsonb_build_object('uid', c.user_id, 'starts_at', c.starts_at, 'ends_at', c.ends_at,
                 'squad', case when c.squad_id = any(my_squads) then c.squad_id else null end)), '[]')
               from commitments c where (c.user_id = me or c.user_id = any(mates)) and c.ends_at > now() - interval '1 day')
  );
end $$;

create or replace function public.tick_load(p_secret text) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.check_secret(p_secret);
  return jsonb_build_object(
    'vapid_public', (select value from private.app_config where key = 'vapid_public'),
    'vapid_private', (select value from private.app_config where key = 'vapid_private'),
    'squads', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name,
                 'members', (select coalesce(jsonb_agg(m.user_id order by m.joined_at), '[]') from squad_members m where m.squad_id = s.id))), '[]') from squads s),
    'people', (select coalesce(jsonb_object_agg(id, jsonb_build_object('name', first_name, 'notif', notif, 'tz', tz)), '{}') from profiles),
    'rankings', (select coalesce(jsonb_agg(jsonb_build_object('squad', squad_id, 'uid', user_id, 'games', games)), '[]') from rankings),
    'avail', (select coalesce(jsonb_agg(jsonb_build_object('uid', user_id, 'day', day, 'a', a, 'b', b, 'repeat', repeat, 'squads', squads, 'tz', tz)), '[]')
              from availability where repeat <> 'none' or day >= current_date - 3),
    'commits', (select coalesce(jsonb_agg(jsonb_build_object('uid', user_id, 'starts_at', starts_at, 'ends_at', ends_at, 'squad', squad_id)), '[]')
              from commitments where ends_at > now() - interval '1 day'),
    'nodubs', (select coalesce(jsonb_agg(jsonb_build_object('uid', user_id, 'day', day, 'tz', tz, 'squads', squads)), '[]')
              from private.no_dubs_days(current_date - 2, current_date + 14)),
    'subs', (select coalesce(jsonb_agg(jsonb_build_object('uid', user_id, 'endpoint', endpoint, 'p256dh', p256dh, 'auth', auth)), '[]') from push_subs),
    'blocks', (select coalesce(jsonb_object_agg(d.key, jsonb_build_object('found', d.found, 'warn', d.warn, 'live', d.live)), '{}') from private.dub_blocks d)
  );
end $$;


-- leaving a squad also forgets repeating No dubs for it
create or replace function private.forget_squad_times() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update availability set squads = array_remove(squads, old.squad_id)
   where user_id = old.user_id and squads is not null and old.squad_id = any(squads);
  delete from availability where user_id = old.user_id and squads = '{}';
  delete from commitments where user_id = old.user_id and squad_id = old.squad_id;
  update no_dubs set squads = array_remove(squads, old.squad_id)
   where user_id = old.user_id and squads is not null and old.squad_id = any(squads);
  delete from no_dubs where user_id = old.user_id and squads = '{}';
  update no_dubs_weekly set squads = array_remove(squads, old.squad_id)
   where user_id = old.user_id and squads is not null and old.squad_id = any(squads);
  delete from no_dubs_weekly where user_id = old.user_id and squads = '{}';
  update no_dubs_skips set squads = array_remove(squads, old.squad_id)
   where user_id = old.user_id and squads is not null and old.squad_id = any(squads);
  delete from no_dubs_skips where user_id = old.user_id and squads = '{}';
  return old;
end $$;

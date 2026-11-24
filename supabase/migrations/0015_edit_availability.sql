-- Edit and remove existing availability.
-- A repeating time can skip single dates ("Remove just today", or "Edit just today", which
-- skips the date and adds a one-off time). update_availability changes a time in place.
create table public.availability_skips (
  window_id uuid not null references public.availability(id) on delete cascade,
  day date not null,
  primary key (window_id, day)
);
alter table public.availability_skips enable row level security;

create function public.skip_availability(p_id uuid, p_day date) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me();
begin
  if not exists (select 1 from availability where id = p_id and user_id = me and repeat <> 'none') then raise exception 'not_found'; end if;
  if p_day is null or p_day < current_date - 2 or p_day > current_date + 62 then raise exception 'bad_day'; end if;
  insert into availability_skips(window_id, day) values (p_id, p_day) on conflict do nothing;
end $$;

-- p_day is the date being viewed when Edit was tapped; for a repeating time the new pattern
-- keeps running from the earliest matching date that hasn't passed.
create function public.update_availability(p_id uuid, p_day date, p_a int, p_b int, p_repeat text, p_squads uuid[]) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); old availability; sq uuid[]; nd date; rp text := coalesce(p_repeat, 'none');
begin
  select * into old from availability where id = p_id and user_id = me;
  if not found then raise exception 'not_found'; end if;
  if p_a < 0 or p_b > 48 or p_a >= p_b then raise exception 'bad_time'; end if;
  if p_day < current_date - 2 or p_day > current_date + 62 then raise exception 'bad_day'; end if;
  if rp not in ('none', 'daily', 'weekly') then raise exception 'bad_repeat'; end if;
  if p_squads is not null then
    select array_agg(x) into sq from unnest(p_squads) x where exists (select 1 from squad_members where squad_id = x and user_id = me);
    if sq is null then raise exception 'not_member'; end if;
  end if;
  nd := case
    when rp = 'none' then p_day
    when rp = 'daily' then case when old.repeat = 'none' then p_day else least(old.day, p_day) end
    else p_day - 7 * (greatest(0, p_day - (current_date - 1)) / 7) end;
  update availability set day = nd, a = p_a, b = p_b, repeat = rp, squads = sq, tz = (select tz from profiles where id = me)
   where id = p_id;
end $$;

revoke execute on function public.skip_availability(uuid, date), public.update_availability(uuid, date, int, int, text, uuid[]) from public, anon;
grant execute on function public.skip_availability(uuid, date), public.update_availability(uuid, date, int, int, text, uuid[]) to authenticated;

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
                 'skip', (select coalesce(jsonb_agg(k.day), '[]') from availability_skips k where k.window_id = a.id),
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
    'avail', (select coalesce(jsonb_agg(jsonb_build_object('uid', w.user_id, 'day', w.day, 'a', w.a, 'b', w.b, 'repeat', w.repeat, 'squads', w.squads, 'tz', w.tz,
                 'skip', (select coalesce(jsonb_agg(k.day), '[]') from availability_skips k where k.window_id = w.id))), '[]')
              from availability w where w.repeat <> 'none' or w.day >= current_date - 3),
    'commits', (select coalesce(jsonb_agg(jsonb_build_object('uid', user_id, 'starts_at', starts_at, 'ends_at', ends_at, 'squad', squad_id)), '[]')
              from commitments where ends_at > now() - interval '1 day'),
    'nodubs', (select coalesce(jsonb_agg(jsonb_build_object('uid', user_id, 'day', day, 'tz', tz, 'squads', squads)), '[]')
              from private.no_dubs_days(current_date - 2, current_date + 14)),
    'subs', (select coalesce(jsonb_agg(jsonb_build_object('uid', user_id, 'endpoint', endpoint, 'p256dh', p256dh, 'auth', auth)), '[]') from push_subs),
    'blocks', (select coalesce(jsonb_object_agg(d.key, jsonb_build_object('found', d.found, 'warn', d.warn, 'live', d.live)), '{}') from private.dub_blocks d)
  );
end $$;



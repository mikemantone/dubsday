-- "No dubs": say you can't play on a given dub day, for all your squads or some.
-- Squadmates see it (striped column, "Out" tag). Saved times are left alone and simply
-- don't count that day, so undoing brings them straight back.
create table public.no_dubs (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  squads uuid[],            -- null means every squad, including ones joined later
  tz text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, day)
);
alter table public.no_dubs enable row level security;

create function public.set_no_dubs(p_day date, p_squads uuid[]) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); cur no_dubs; my uuid[];
begin
  if p_day is null or p_day < current_date - 1 or p_day > current_date + 14 then raise exception 'bad_time'; end if;
  select coalesce(array_agg(squad_id), '{}') into my from squad_members where user_id = me;
  if p_squads is not null and (cardinality(p_squads) = 0 or not p_squads <@ my) then raise exception 'not_member'; end if;
  select * into cur from no_dubs where user_id = me and day = p_day;
  if not found then
    insert into no_dubs(user_id, day, squads, tz) values (me, p_day, p_squads, (select tz from profiles where id = me));
  elsif cur.squads is not null then
    update no_dubs set squads = case when p_squads is null then null
      else (select array_agg(distinct x) from unnest(cur.squads || p_squads) x) end
     where user_id = me and day = p_day;
  end if;
end $$;

create function public.clear_no_dubs(p_day date, p_squads uuid[]) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); cur no_dubs; left_over uuid[];
begin
  select * into cur from no_dubs where user_id = me and day = p_day;
  if not found then return; end if;
  if p_squads is null then delete from no_dubs where user_id = me and day = p_day; return; end if;
  select coalesce(array_agg(x), '{}') into left_over
    from unnest(coalesce(cur.squads, (select array_agg(squad_id) from squad_members where user_id = me))) x
   where not x = any(p_squads);
  if cardinality(left_over) = 0 then delete from no_dubs where user_id = me and day = p_day;
  else update no_dubs set squads = left_over where user_id = me and day = p_day; end if;
end $$;

revoke execute on function public.set_no_dubs(date, uuid[]), public.clear_no_dubs(date, uuid[]) from public, anon;
grant execute on function public.set_no_dubs(date, uuid[]), public.clear_no_dubs(date, uuid[]) to authenticated;

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
    'nodubs', (select coalesce(jsonb_agg(jsonb_build_object('uid', n.user_id, 'day', n.day, 'tz', n.tz,
                 'squads', case when n.squads is null then null
                           else (select coalesce(jsonb_agg(x), '[]') from unnest(n.squads) x where x = any(my_squads)) end)), '[]')
               from no_dubs n
               where (n.user_id = me or (n.user_id = any(mates) and (n.squads is null or n.squads && my_squads)))
                 and n.day >= current_date - 2),
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
              from no_dubs where day >= current_date - 2),
    'subs', (select coalesce(jsonb_agg(jsonb_build_object('uid', user_id, 'endpoint', endpoint, 'p256dh', p256dh, 'auth', auth)), '[]') from push_subs),
    'blocks', (select coalesce(jsonb_object_agg(d.key, jsonb_build_object('found', d.found, 'warn', d.warn, 'live', d.live)), '{}') from private.dub_blocks d)
  );
end $$;

-- leaving a squad also forgets No dubs for it
create or replace function private.forget_squad_times() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update availability set squads = array_remove(squads, old.squad_id)
   where user_id = old.user_id and squads is not null and old.squad_id = any(squads);
  delete from availability where user_id = old.user_id and squads = '{}';
  delete from commitments where user_id = old.user_id and squad_id = old.squad_id;
  update no_dubs set squads = array_remove(squads, old.squad_id)
   where user_id = old.user_id and squads is not null and old.squad_id = any(squads);
  delete from no_dubs where user_id = old.user_id and squads = '{}';
  return old;
end $$;

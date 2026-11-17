-- Time zones. Each person has a time zone; each availability row keeps the zone
-- it was entered in (its day/a/b are slots from 4:00am local on that date), and
-- squad picks (commitments) become absolute start and end instants.
-- Everything existing was entered as New York time, so that is the default.

alter table public.profiles add column tz text not null default 'America/New_York';
alter table public.availability add column tz text not null default 'America/New_York';

alter table public.commitments add column starts_at timestamptz, add column ends_at timestamptz;
update public.commitments set
  starts_at = ((day::timestamp + interval '4 hours') at time zone 'America/New_York') + a * interval '30 minutes',
  ends_at   = ((day::timestamp + interval '4 hours') at time zone 'America/New_York') + b * interval '30 minutes';
alter table public.commitments
  alter column starts_at set not null,
  alter column ends_at set not null,
  drop column day, drop column a, drop column b,
  add constraint commitments_range check (starts_at < ends_at);
create index on public.commitments(user_id, ends_at);

create function private.check_tz(t text) returns void language plpgsql stable set search_path = pg_catalog, pg_temp as $$
begin
  if t is null or char_length(t) > 64 or not exists (select 1 from pg_timezone_names where name = t) then raise exception 'bad_tz'; end if;
end $$;

-- the old dub_today was New York only and is no longer used
alter function private.dub_today() set search_path = pg_catalog, pg_temp;
alter function private.new_code() set search_path = public, pg_temp;

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
    'squads', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'code', s.code, 'invite_token', s.invite_token,
                 'members', (select jsonb_agg(m.user_id order by m.joined_at) from squad_members m where m.squad_id = s.id)) order by s.created_at), '[]')
               from squads s where s.id = any(my_squads)),
    'invites', (select coalesce(jsonb_agg(jsonb_build_object('squad', s.id, 'name', s.name, 'from', coalesce(pr.first_name, 'A friend'),
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
    'commits', (select coalesce(jsonb_agg(jsonb_build_object('uid', c.user_id, 'starts_at', c.starts_at, 'ends_at', c.ends_at,
                 'squad', case when c.squad_id = any(my_squads) then c.squad_id else null end)), '[]')
               from commitments c where (c.user_id = me or c.user_id = any(mates)) and c.ends_at > now() - interval '1 day')
  );
end $$;

drop function public.create_profile(text, text);
create function public.create_profile(p_first_name text, p_gamertag text, p_tz text default null) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := auth.uid(); tag text := lower(trim(coalesce(p_gamertag, ''))); nm text := trim(coalesce(p_first_name, '')); z text := coalesce(p_tz, 'America/New_York');
begin
  if me is null then raise exception 'not_signed_in'; end if;
  if nm = '' or char_length(nm) > 20 then raise exception 'bad_name'; end if;
  if tag !~ '^[a-z0-9_]{3,20}$' then raise exception 'bad_gamertag'; end if;
  perform private.check_tz(z);
  if exists (select 1 from profiles where gamertag = tag and id <> me) then raise exception 'gamertag_taken'; end if;
  insert into profiles(id, first_name, gamertag, tz) values (me, nm, tag, z)
    on conflict (id) do update set first_name = excluded.first_name, gamertag = excluded.gamertag, tz = excluded.tz;
end $$;

drop function public.update_profile(text, text, jsonb);
create function public.update_profile(p_first_name text, p_gamertag text, p_notif jsonb, p_tz text default null) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); tag text; nm text;
begin
  if p_gamertag is not null then
    tag := lower(trim(p_gamertag));
    if tag !~ '^[a-z0-9_]{3,20}$' then raise exception 'bad_gamertag'; end if;
    if exists (select 1 from profiles where gamertag = tag and id <> me) then raise exception 'gamertag_taken'; end if;
    update profiles set gamertag = tag where id = me;
  end if;
  if p_first_name is not null then
    nm := trim(p_first_name);
    if nm = '' or char_length(nm) > 20 then raise exception 'bad_name'; end if;
    update profiles set first_name = nm where id = me;
  end if;
  if p_notif is not null then
    update profiles set notif = jsonb_build_object(
      'found', coalesce((p_notif->>'found')::boolean, true),
      'warn', coalesce((p_notif->>'warn')::boolean, true),
      'live', coalesce((p_notif->>'live')::boolean, true)) where id = me;
  end if;
  if p_tz is not null then
    perform private.check_tz(p_tz);
    update profiles set tz = p_tz where id = me;
    -- times already set keep their clock time in the new zone (8pm stays 8pm)
    update availability set tz = p_tz where user_id = me;
  end if;
end $$;

create or replace function public.add_availability(p_day date, p_a int, p_b int, p_repeat text, p_squads uuid[]) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); sq uuid[]; aid uuid; z text;
begin
  if p_a < 0 or p_b > 48 or p_a >= p_b then raise exception 'bad_time'; end if;
  if p_day < current_date - 2 or p_day > current_date + 62 then raise exception 'bad_day'; end if;
  if coalesce(p_repeat, 'none') not in ('none', 'daily', 'weekly') then raise exception 'bad_repeat'; end if;
  if p_squads is not null then
    select array_agg(x) into sq from unnest(p_squads) x where exists (select 1 from squad_members where squad_id = x and user_id = me);
    if sq is null then raise exception 'not_member'; end if;
  end if;
  if (select count(*) from availability where user_id = me) >= 300 then raise exception 'too_many'; end if;
  select tz into z from profiles where id = me;
  insert into availability(user_id, day, a, b, repeat, squads, tz) values (me, p_day, p_a, p_b, coalesce(p_repeat, 'none'), sq, z) returning id into aid;
  return aid;
end $$;

drop function public.commit_squad(date, int, int, uuid);
create function public.commit_squad(p_start timestamptz, p_end timestamptz, sid uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me();
begin
  if p_start is null or p_end is null or p_start >= p_end or p_end - p_start > interval '26 hours' then raise exception 'bad_time'; end if;
  if not exists (select 1 from squad_members where squad_id = sid and user_id = me) then raise exception 'not_member'; end if;
  delete from commitments where user_id = me and starts_at < p_end and ends_at > p_start;
  insert into commitments(user_id, starts_at, ends_at, squad_id) values (me, p_start, p_end, sid);
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
    'subs', (select coalesce(jsonb_agg(jsonb_build_object('uid', user_id, 'endpoint', endpoint, 'p256dh', p256dh, 'auth', auth)), '[]') from push_subs),
    'blocks', (select coalesce(jsonb_object_agg(d.key, jsonb_build_object('found', d.found, 'warn', d.warn, 'live', d.live)), '{}') from private.dub_blocks d)
  );
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function
  public.get_state(), public.search_gamertags(text), public.push_public_key(),
  public.create_profile(text, text, text), public.update_profile(text, text, jsonb, text),
  public.send_friend_request(uuid), public.accept_friend_request(uuid), public.remove_friend(uuid), public.accept_friend_link(uuid),
  public.create_squad(text), public.join_squad_by_code(text), public.join_squad_by_invite(uuid),
  public.invite_friend_to_squad(uuid, uuid), public.respond_squad_invitation(uuid, boolean), public.leave_squad(uuid),
  public.set_rankings(uuid, jsonb, boolean),
  public.add_availability(date, int, int, text, uuid[]), public.delete_availability(uuid), public.commit_squad(timestamptz, timestamptz, uuid),
  public.save_push_sub(text, text, text), public.delete_push_sub(text)
  to authenticated;
grant execute on function public.invite_info(uuid) to anon, authenticated;
grant execute on function public.tick_load(text), public.tick_set_vapid(text, text, text), public.tick_save(text, jsonb, text[]) to service_role;

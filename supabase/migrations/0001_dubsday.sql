-- DubsDay schema. All tables have row level security on with no policies:
-- the app never reads tables directly, it only calls the functions below,
-- each of which checks who is calling.

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
create schema if not exists private;

create table public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  first_name text not null check (char_length(first_name) between 1 and 20),
  gamertag text not null unique check (gamertag ~ '^[a-z0-9_]{3,20}$'),
  friend_token uuid not null unique default gen_random_uuid(),
  notif jsonb not null default '{"found":true,"warn":true,"live":true}',
  created_at timestamptz not null default now()
);
create table public.friendships(
  requester uuid not null references public.profiles(id) on delete cascade,
  addressee uuid not null references public.profiles(id) on delete cascade,
  status text not null check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  primary key (requester, addressee),
  check (requester <> addressee)
);
create index on public.friendships(addressee);
create table public.squads(
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 24),
  code text not null unique,
  invite_token uuid not null unique default gen_random_uuid(),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create table public.squad_members(
  squad_id uuid not null references public.squads(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (squad_id, user_id)
);
create index on public.squad_members(user_id);
create table public.squad_invitations(
  squad_id uuid not null references public.squads(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  invited_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (squad_id, user_id)
);
create index on public.squad_invitations(user_id);
create table public.rankings(
  squad_id uuid not null references public.squads(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  games jsonb not null default '[]',
  primary key (squad_id, user_id)
);
create table public.availability(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  a int not null,
  b int not null,
  repeat text not null default 'none' check (repeat in ('none','daily','weekly')),
  squads uuid[],               -- null means every squad the person is in
  created_at timestamptz not null default now(),
  check (a >= 0 and b <= 48 and a < b)
);
create index on public.availability(user_id, day);
create table public.commitments(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  a int not null,
  b int not null,
  squad_id uuid not null references public.squads(id) on delete cascade,
  created_at timestamptz not null default now(),
  check (a >= 0 and b <= 48 and a < b)
);
create index on public.commitments(user_id, day);
create table public.push_subs(
  endpoint text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
create index on public.push_subs(user_id);

create table private.app_config(key text primary key, value text not null);
create table private.dub_blocks(
  key text primary key,
  found boolean not null default false,
  warn boolean not null default false,
  live boolean not null default false,
  ends_at timestamptz not null
);
insert into private.app_config(key, value) values ('cron_secret', encode(extensions.gen_random_bytes(24), 'hex'));

alter table public.profiles enable row level security;
alter table public.friendships enable row level security;
alter table public.squads enable row level security;
alter table public.squad_members enable row level security;
alter table public.squad_invitations enable row level security;
alter table public.rankings enable row level security;
alter table public.availability enable row level security;
alter table public.commitments enable row level security;
alter table public.push_subs enable row level security;
alter table private.app_config enable row level security;
alter table private.dub_blocks enable row level security;

-- ---------- helpers ----------
create function private.dub_today() returns date language sql stable as $$
  select ((now() at time zone 'America/New_York') - interval '4 hours')::date
$$;
create function private.me() returns uuid language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'not_signed_in'; end if;
  if not exists (select 1 from profiles where id = v) then raise exception 'no_profile'; end if;
  return v;
end $$;
create function private.are_friends(x uuid, y uuid) returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from friendships where status = 'accepted'
    and ((requester = x and addressee = y) or (requester = y and addressee = x)))
$$;
create function private.new_code() returns text language plpgsql as $$
declare c text; chars text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; i int;
begin
  loop
    c := '';
    for i in 1..6 loop c := c || substr(chars, 1 + floor(random() * length(chars))::int, 1); end loop;
    exit when not exists (select 1 from public.squads where code = c);
  end loop;
  return c;
end $$;

-- ---------- reading ----------
create function public.get_state() returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  me uuid := auth.uid();
  p profiles;
  today date := private.dub_today();
  my_squads uuid[];
  mates uuid[];
  pals uuid[];
begin
  if me is null then raise exception 'not_signed_in'; end if;
  select * into p from profiles where id = me;
  if not found then return jsonb_build_object('me', null, 'today', today); end if;
  select coalesce(array_agg(squad_id), '{}') into my_squads from squad_members where user_id = me;
  select coalesce(array_agg(distinct user_id), '{}') into mates from squad_members where squad_id = any(my_squads) and user_id <> me;
  select coalesce(array_agg(case when requester = me then addressee else requester end), '{}') into pals
    from friendships where status = 'accepted' and me in (requester, addressee);
  return jsonb_build_object(
    'me', jsonb_build_object('id', p.id, 'first_name', p.first_name, 'gamertag', p.gamertag, 'friend_token', p.friend_token, 'notif', p.notif),
    'today', today,
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
    'avail', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'uid', a.user_id, 'day', a.day, 'a', a.a, 'b', a.b, 'repeat', a.repeat,
                 'squads', case when a.squads is null then null
                           else (select coalesce(jsonb_agg(x), '[]') from unnest(a.squads) x where x = any(my_squads)) end) order by a.day, a.a), '[]')
               from availability a
               where (a.user_id = me or (a.user_id = any(mates) and (a.squads is null or a.squads && my_squads)))
                 and (a.repeat <> 'none' or a.day >= today - 1)),
    'commits', (select coalesce(jsonb_agg(jsonb_build_object('uid', c.user_id, 'day', c.day, 'a', c.a, 'b', c.b,
                 'squad', case when c.squad_id = any(my_squads) then c.squad_id else null end)), '[]')
               from commitments c where (c.user_id = me or c.user_id = any(mates)) and c.day >= today - 1)
  );
end $$;

create function public.search_gamertags(q text) returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); clean text := lower(regexp_replace(coalesce(q, ''), '[^a-zA-Z0-9_]', '', 'g'));
begin
  if char_length(clean) < 2 then return '[]'::jsonb; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'u', t.gamertag) order by t.gamertag), '[]')
          from (select id, gamertag from profiles where id <> me and position(clean in gamertag) > 0 order by gamertag limit 10) t);
end $$;

create function public.invite_info(token uuid) returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('squad', s.id, 'name', s.name, 'members', (select count(*) from squad_members m where m.squad_id = s.id))
  from squads s where s.invite_token = token
$$;

create function public.push_public_key() returns text language sql stable security definer set search_path = public, pg_temp as $$
  select value from private.app_config where key = 'vapid_public'
$$;

-- ---------- profile ----------
create function public.create_profile(p_first_name text, p_gamertag text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := auth.uid(); tag text := lower(trim(coalesce(p_gamertag, ''))); nm text := trim(coalesce(p_first_name, ''));
begin
  if me is null then raise exception 'not_signed_in'; end if;
  if nm = '' or char_length(nm) > 20 then raise exception 'bad_name'; end if;
  if tag !~ '^[a-z0-9_]{3,20}$' then raise exception 'bad_gamertag'; end if;
  if exists (select 1 from profiles where gamertag = tag and id <> me) then raise exception 'gamertag_taken'; end if;
  insert into profiles(id, first_name, gamertag) values (me, nm, tag)
    on conflict (id) do update set first_name = excluded.first_name, gamertag = excluded.gamertag;
end $$;

create function public.update_profile(p_first_name text, p_gamertag text, p_notif jsonb) returns void language plpgsql security definer set search_path = public, pg_temp as $$
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
end $$;

-- ---------- friends ----------
create function public.send_friend_request(target uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me();
begin
  if target = me or not exists (select 1 from profiles where id = target) then raise exception 'no_user'; end if;
  if private.are_friends(me, target) then return; end if;
  if exists (select 1 from friendships where requester = target and addressee = me) then
    update friendships set status = 'accepted' where requester = target and addressee = me;
  else
    insert into friendships(requester, addressee, status) values (me, target, 'pending') on conflict do nothing;
  end if;
end $$;
create function public.accept_friend_request(from_id uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me();
begin
  update friendships set status = 'accepted' where requester = from_id and addressee = me;
end $$;
create function public.remove_friend(other uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me();
begin
  delete from friendships where (requester = me and addressee = other) or (requester = other and addressee = me);
end $$;
create function public.accept_friend_link(token uuid) returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); them profiles;
begin
  select * into them from profiles where friend_token = token;
  if not found or them.id = me then return null; end if;
  delete from friendships where (requester = me and addressee = them.id) or (requester = them.id and addressee = me);
  insert into friendships(requester, addressee, status) values (them.id, me, 'accepted');
  return them.first_name;
end $$;

-- ---------- squads ----------
create function public.create_squad(p_name text) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); nm text := trim(coalesce(p_name, '')); sid uuid;
begin
  if nm = '' or char_length(nm) > 24 then raise exception 'bad_name'; end if;
  if (select count(*) from squad_members where user_id = me) >= 20 then raise exception 'too_many_squads'; end if;
  insert into squads(name, code, created_by) values (nm, private.new_code(), me) returning id into sid;
  insert into squad_members(squad_id, user_id) values (sid, me);
  return sid;
end $$;
create function private.join(sid uuid, who uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (select count(*) from squad_members where squad_id = sid) >= 12 and not exists (select 1 from squad_members where squad_id = sid and user_id = who) then
    raise exception 'squad_full';
  end if;
  insert into squad_members(squad_id, user_id) values (sid, who) on conflict do nothing;
  delete from squad_invitations where squad_id = sid and user_id = who;
end $$;
create function public.join_squad_by_code(p_code text) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); sid uuid;
begin
  select id into sid from squads where code = upper(trim(coalesce(p_code, '')));
  if sid is null then raise exception 'no_squad'; end if;
  perform private.join(sid, me);
  return sid;
end $$;
create function public.join_squad_by_invite(token uuid) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); sid uuid;
begin
  select id into sid from squads where invite_token = token;
  if sid is null then raise exception 'no_squad'; end if;
  perform private.join(sid, me);
  return sid;
end $$;
create function public.invite_friend_to_squad(sid uuid, friend uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me();
begin
  if not exists (select 1 from squad_members where squad_id = sid and user_id = me) then raise exception 'not_member'; end if;
  if not private.are_friends(me, friend) then raise exception 'not_friends'; end if;
  if exists (select 1 from squad_members where squad_id = sid and user_id = friend) then return; end if;
  insert into squad_invitations(squad_id, user_id, invited_by) values (sid, friend, me) on conflict do nothing;
end $$;
create function public.respond_squad_invitation(sid uuid, accept boolean) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me();
begin
  if not exists (select 1 from squad_invitations where squad_id = sid and user_id = me) then raise exception 'no_invitation'; end if;
  if accept then perform private.join(sid, me);
  else delete from squad_invitations where squad_id = sid and user_id = me; end if;
end $$;
create function public.leave_squad(sid uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me();
begin
  delete from squad_members where squad_id = sid and user_id = me;
  delete from rankings where squad_id = sid and user_id = me;
  delete from commitments where squad_id = sid and user_id = me;
  if not exists (select 1 from squad_members where squad_id = sid) then delete from squads where id = sid; end if;
end $$;

-- ---------- rankings ----------
create function public.set_rankings(sid uuid, p_games jsonb, apply_all boolean) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); g jsonb; clean jsonb := '[]';
begin
  if not exists (select 1 from squad_members where squad_id = sid and user_id = me) then raise exception 'not_member'; end if;
  if jsonb_typeof(p_games) <> 'array' or jsonb_array_length(p_games) > 5 then raise exception 'bad_games'; end if;
  for g in select * from jsonb_array_elements(p_games) loop
    if coalesce(trim(g->>'name'), '') = '' or char_length(g->>'name') > 60 or (g->>'need') not in ('2', '3', 'full') then raise exception 'bad_games'; end if;
    clean := clean || jsonb_build_object('name', trim(g->>'name'), 'need', g->>'need');
  end loop;
  insert into rankings(squad_id, user_id, games)
    select m.squad_id, me, clean from squad_members m where m.user_id = me and (m.squad_id = sid or apply_all)
    on conflict (squad_id, user_id) do update set games = excluded.games;
end $$;

-- ---------- availability ----------
create function public.add_availability(p_day date, p_a int, p_b int, p_repeat text, p_squads uuid[]) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); today date := private.dub_today(); sq uuid[]; aid uuid;
begin
  if p_a < 0 or p_b > 48 or p_a >= p_b then raise exception 'bad_time'; end if;
  if p_day < today - 1 or p_day > today + 60 then raise exception 'bad_day'; end if;
  if coalesce(p_repeat, 'none') not in ('none', 'daily', 'weekly') then raise exception 'bad_repeat'; end if;
  if p_squads is not null then
    select array_agg(x) into sq from unnest(p_squads) x where exists (select 1 from squad_members where squad_id = x and user_id = me);
    if sq is null then raise exception 'not_member'; end if;
  end if;
  if (select count(*) from availability where user_id = me) >= 300 then raise exception 'too_many'; end if;
  insert into availability(user_id, day, a, b, repeat, squads) values (me, p_day, p_a, p_b, coalesce(p_repeat, 'none'), sq) returning id into aid;
  return aid;
end $$;
create function public.delete_availability(aid uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me();
begin
  delete from availability where id = aid and user_id = me;
end $$;
create function public.commit_squad(p_day date, p_a int, p_b int, sid uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me();
begin
  if p_a < 0 or p_b > 48 or p_a >= p_b then raise exception 'bad_time'; end if;
  if not exists (select 1 from squad_members where squad_id = sid and user_id = me) then raise exception 'not_member'; end if;
  delete from commitments where user_id = me and day = p_day and a < p_b and b > p_a;
  insert into commitments(user_id, day, a, b, squad_id) values (me, p_day, p_a, p_b, sid);
end $$;

-- ---------- push ----------
create function public.save_push_sub(p_endpoint text, p_p256dh text, p_auth text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me();
begin
  if p_endpoint !~ '^https://' or char_length(p_endpoint) > 2000 then raise exception 'bad_endpoint'; end if;
  insert into push_subs(endpoint, user_id, p256dh, auth) values (p_endpoint, me, p_p256dh, p_auth)
    on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
end $$;
create function public.delete_push_sub(p_endpoint text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me();
begin
  delete from push_subs where endpoint = p_endpoint and user_id = me;
end $$;

-- ---------- the every-minute notifier (called only by the tick function) ----------
create function private.check_secret(p_secret text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_secret is null or p_secret <> (select value from private.app_config where key = 'cron_secret') then raise exception 'forbidden'; end if;
end $$;
create function public.tick_load(p_secret text) returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare today date := private.dub_today();
begin
  perform private.check_secret(p_secret);
  return jsonb_build_object(
    'today', today,
    'vapid_public', (select value from private.app_config where key = 'vapid_public'),
    'vapid_private', (select value from private.app_config where key = 'vapid_private'),
    'squads', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name,
                 'members', (select coalesce(jsonb_agg(m.user_id order by m.joined_at), '[]') from squad_members m where m.squad_id = s.id))), '[]') from squads s),
    'people', (select coalesce(jsonb_object_agg(id, jsonb_build_object('name', first_name, 'notif', notif)), '{}') from profiles),
    'rankings', (select coalesce(jsonb_agg(jsonb_build_object('squad', squad_id, 'uid', user_id, 'games', games)), '[]') from rankings),
    'avail', (select coalesce(jsonb_agg(jsonb_build_object('uid', user_id, 'day', day, 'a', a, 'b', b, 'repeat', repeat, 'squads', squads)), '[]')
              from availability where repeat <> 'none' or day >= today - 1),
    'commits', (select coalesce(jsonb_agg(jsonb_build_object('uid', user_id, 'day', day, 'a', a, 'b', b, 'squad', squad_id)), '[]')
              from commitments where day >= today - 1),
    'subs', (select coalesce(jsonb_agg(jsonb_build_object('uid', user_id, 'endpoint', endpoint, 'p256dh', p256dh, 'auth', auth)), '[]') from push_subs),
    'blocks', (select coalesce(jsonb_object_agg(d.key, jsonb_build_object('found', d.found, 'warn', d.warn, 'live', d.live)), '{}') from private.dub_blocks d)
  );
end $$;
create function public.tick_set_vapid(p_secret text, p_public text, p_private text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.check_secret(p_secret);
  insert into private.app_config(key, value) values ('vapid_public', p_public), ('vapid_private', p_private) on conflict (key) do nothing;
end $$;
create function public.tick_save(p_secret text, p_blocks jsonb, p_dead text[]) returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.check_secret(p_secret);
  delete from private.dub_blocks d where d.key not in (select jsonb_object_keys(p_blocks));
  insert into private.dub_blocks as d (key, found, warn, live, ends_at)
    select e.key, (e.value->>'found')::boolean, (e.value->>'warn')::boolean, (e.value->>'live')::boolean, (e.value->>'ends_at')::timestamptz
    from jsonb_each(p_blocks) e
    on conflict (key) do update set found = excluded.found, warn = excluded.warn, live = excluded.live, ends_at = excluded.ends_at;
  if p_dead is not null then delete from push_subs where endpoint = any(p_dead); end if;
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function
  public.get_state(), public.search_gamertags(text), public.push_public_key(),
  public.create_profile(text, text), public.update_profile(text, text, jsonb),
  public.send_friend_request(uuid), public.accept_friend_request(uuid), public.remove_friend(uuid), public.accept_friend_link(uuid),
  public.create_squad(text), public.join_squad_by_code(text), public.join_squad_by_invite(uuid),
  public.invite_friend_to_squad(uuid, uuid), public.respond_squad_invitation(uuid, boolean), public.leave_squad(uuid),
  public.set_rankings(uuid, jsonb, boolean),
  public.add_availability(date, int, int, text, uuid[]), public.delete_availability(uuid), public.commit_squad(date, int, int, uuid),
  public.save_push_sub(text, text, text), public.delete_push_sub(text)
  to authenticated;
grant execute on function public.invite_info(uuid) to anon, authenticated;
grant execute on function public.tick_load(text), public.tick_set_vapid(text, text, text), public.tick_save(text, jsonb, text[]) to service_role;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

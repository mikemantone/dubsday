-- Squad owners can rename a squad and give it an icon (an emoji from the app's list).
-- Everyone in the squad sees the change; there is no notification.
alter table public.squads add column icon text check (icon is null or char_length(icon) <= 16);

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
    'commits', (select coalesce(jsonb_agg(jsonb_build_object('uid', c.user_id, 'starts_at', c.starts_at, 'ends_at', c.ends_at,
                 'squad', case when c.squad_id = any(my_squads) then c.squad_id else null end)), '[]')
               from commitments c where (c.user_id = me or c.user_id = any(mates)) and c.ends_at > now() - interval '1 day')
  );
end $$;

create function public.update_squad(sid uuid, p_name text, p_icon text) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); nm text := trim(coalesce(p_name, '')); ic text := nullif(trim(coalesce(p_icon, '')), '');
begin
  if not exists (select 1 from squads where id = sid and created_by = me) then raise exception 'not_owner'; end if;
  if nm = '' or char_length(nm) > 24 then raise exception 'bad_name'; end if;
  if ic is not null and char_length(ic) > 16 then raise exception 'bad_icon'; end if;
  update squads set name = nm, icon = ic where id = sid;
end $$;
revoke execute on function public.update_squad(uuid, text, text) from public, anon;
grant execute on function public.update_squad(uuid, text, text) to authenticated;

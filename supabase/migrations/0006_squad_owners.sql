-- Squad owners. The person who created a squad owns it and can remove members.
-- When an owner leaves or deletes their profile, the squad passes to the member
-- who has been in it longest.

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
    'squads', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'code', s.code, 'invite_token', s.invite_token, 'owner', s.created_by,
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

create function private.pass_on_ownership(sid uuid, leaving uuid) returns void language sql security definer set search_path = public, pg_temp as $$
  update squads set created_by = (select m.user_id from squad_members m where m.squad_id = sid and m.user_id <> leaving order by m.joined_at limit 1)
  where id = sid and created_by = leaving
$$;

create or replace function public.leave_squad(sid uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me();
begin
  perform private.pass_on_ownership(sid, me);
  delete from squad_members where squad_id = sid and user_id = me;
  delete from rankings where squad_id = sid and user_id = me;
  delete from commitments where squad_id = sid and user_id = me;
  if not exists (select 1 from squad_members where squad_id = sid) then delete from squads where id = sid; end if;
end $$;

create or replace function public.delete_account() returns void language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare me uuid := auth.uid(); mine uuid[]; sid uuid;
begin
  if me is null then raise exception 'not_signed_in'; end if;
  select coalesce(array_agg(squad_id), '{}') into mine from public.squad_members where user_id = me;
  foreach sid in array mine loop perform private.pass_on_ownership(sid, me); end loop;
  delete from auth.users where id = me;
  delete from public.squads s where s.id = any(mine) and not exists (select 1 from public.squad_members m where m.squad_id = s.id);
end $$;

create function public.remove_member(sid uuid, member uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me();
begin
  if not exists (select 1 from squads where id = sid and created_by = me) then raise exception 'not_owner'; end if;
  if member = me then raise exception 'not_owner'; end if;
  delete from squad_members where squad_id = sid and user_id = member;
  delete from rankings where squad_id = sid and user_id = member;
  delete from commitments where squad_id = sid and user_id = member;
  delete from squad_invitations where squad_id = sid and user_id = member;
end $$;

revoke execute on function private.pass_on_ownership(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.remove_member(uuid, uuid) from public, anon;
grant execute on function public.remove_member(uuid, uuid) to authenticated;

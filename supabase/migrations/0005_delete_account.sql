-- Delete your own account and everything tied to it. Removing the auth user
-- cascades to the profile and from there to friendships, squad memberships,
-- invitations, rankings, availability, squad picks and push subscriptions.
-- Squads left with no members are removed too. The gamertag is free again
-- immediately.
create function public.delete_account() returns void language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare me uuid := auth.uid(); mine uuid[];
begin
  if me is null then raise exception 'not_signed_in'; end if;
  select coalesce(array_agg(squad_id), '{}') into mine from public.squad_members where user_id = me;
  delete from auth.users where id = me;
  delete from public.squads s where s.id = any(mine) and not exists (select 1 from public.squad_members m where m.squad_id = s.id);
end $$;
revoke execute on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

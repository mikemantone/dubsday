-- When someone leaves a squad (by leaving, being removed, the squad being deleted,
-- or deleting their profile), forget the times they had shared with that squad:
-- the squad is taken off each saved time, a time shared only with that squad is
-- deleted, and any squad choice they made for that squad is removed.
-- Times shared with "all squads" are untouched.
create function private.forget_squad_times() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update availability set squads = array_remove(squads, old.squad_id)
   where user_id = old.user_id and squads is not null and old.squad_id = any(squads);
  delete from availability where user_id = old.user_id and squads = '{}';
  delete from commitments where user_id = old.user_id and squad_id = old.squad_id;
  return old;
end $$;
revoke execute on function private.forget_squad_times() from public, anon, authenticated;
create trigger squad_members_forget_times after delete on public.squad_members
  for each row execute function private.forget_squad_times();

-- Clean up times left behind by squads people had already left.
update availability a set squads = (
  select coalesce(array_agg(sid), '{}') from unnest(a.squads) sid
   where exists (select 1 from squad_members m where m.squad_id = sid and m.user_id = a.user_id))
 where a.squads is not null
   and exists (select 1 from unnest(a.squads) sid
                where not exists (select 1 from squad_members m where m.squad_id = sid and m.user_id = a.user_id));
delete from availability where squads = '{}';
delete from commitments c where not exists (select 1 from squad_members m where m.squad_id = c.squad_id and m.user_id = c.user_id);

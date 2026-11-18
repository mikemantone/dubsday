-- Squads hold up to 6 people (was 12), and game head-count rules can be 2+ to 5+
-- or full squad only (was 2+, 3+ or full), so games with bigger parties can ask for more.
create or replace function private.join(sid uuid, who uuid) returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (select count(*) from squad_members where squad_id = sid) >= 6 and not exists (select 1 from squad_members where squad_id = sid and user_id = who) then
    raise exception 'squad_full';
  end if;
  insert into squad_members(squad_id, user_id) values (sid, who) on conflict do nothing;
  delete from squad_invitations where squad_id = sid and user_id = who;
end $$;

create or replace function public.set_rankings(sid uuid, p_games jsonb, apply_all boolean) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me(); g jsonb; clean jsonb := '[]';
begin
  if not exists (select 1 from squad_members where squad_id = sid and user_id = me) then raise exception 'not_member'; end if;
  if jsonb_typeof(p_games) <> 'array' or jsonb_array_length(p_games) > 5 then raise exception 'bad_games'; end if;
  for g in select * from jsonb_array_elements(p_games) loop
    if coalesce(trim(g->>'name'), '') = '' or char_length(g->>'name') > 60 or (g->>'need') not in ('2', '3', '4', '5', 'full') then raise exception 'bad_games'; end if;
    clean := clean || jsonb_build_object('name', trim(g->>'name'), 'need', g->>'need');
  end loop;
  insert into rankings(squad_id, user_id, games)
    select m.squad_id, me, clean from squad_members m where m.user_id = me and (m.squad_id = sid or apply_all)
    on conflict (squad_id, user_id) do update set games = excluded.games;
end $$;

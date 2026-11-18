-- Lets you change your mind after picking a squad in a DubTime Conflict:
-- removes your own choices that overlap the given time, so the clash shows again.
create function public.uncommit(p_start timestamptz, p_end timestamptz) returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := private.me();
begin
  if p_start is null or p_end is null or p_start >= p_end then raise exception 'bad_time'; end if;
  delete from commitments where user_id = me and starts_at < p_end and ends_at > p_start;
end $$;
revoke all on function public.uncommit(timestamptz, timestamptz) from public, anon;
grant execute on function public.uncommit(timestamptz, timestamptz) to authenticated;

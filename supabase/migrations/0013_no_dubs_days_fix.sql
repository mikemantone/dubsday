-- A "just this day" skip that brings back every squad in a weekly rule must hide the day,
-- not turn it into "all squads" (array_agg over no rows is null).
create or replace function private.no_dubs_days(p_from date, p_to date)
returns table(user_id uuid, day date, tz text, squads uuid[], weekly boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select n.user_id, n.day, n.tz, n.squads, false from no_dubs n where n.day between p_from and p_to
  union all
  select x.user_id, x.day, x.tz, x.squads, true from (
    select w.user_id, d::date as day, w.tz,
           case when k.user_id is null then w.squads
                when k.squads is null then '{}'::uuid[]
                else coalesce((select array_agg(s) from unnest(coalesce(w.squads, private.my_squads(w.user_id))) s where not s = any(k.squads)), '{}') end as squads
      from no_dubs_weekly w
      cross join generate_series(greatest(w.start_day, p_from), p_to, interval '1 day') d
      left join no_dubs_skips k on k.user_id = w.user_id and k.day = d::date
     where extract(isodow from d)::int = w.dow
  ) x
  where x.squads is null or cardinality(x.squads) > 0
$$;

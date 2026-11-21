-- Keep the new "Roll call" notification setting (on unless turned off).
CREATE OR REPLACE FUNCTION public.update_profile(p_first_name text, p_gamertag text, p_notif jsonb, p_tz text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
      'live', coalesce((p_notif->>'live')::boolean, true),
      'rollcall', coalesce((p_notif->>'rollcall')::boolean, true)) where id = me;
  end if;
  if p_tz is not null then
    perform private.check_tz(p_tz);
    update profiles set tz = p_tz where id = me;
    update availability set tz = p_tz where user_id = me;
  end if;
end $function$;

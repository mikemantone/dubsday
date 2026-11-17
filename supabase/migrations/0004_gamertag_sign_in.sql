-- Sign in with gamertag and password; no email addresses are collected.
-- Supabase Auth still needs an email-shaped login, so every account gets a
-- meaningless one (<random id>@users.dubsday.vercel.app). No mail is ever sent.
-- The app looks up that login from the gamertag when someone signs in.

create function public.account_login(p_gamertag text) returns text language sql stable security definer set search_path = public, auth, pg_temp as $$
  select u.email from public.profiles p join auth.users u on u.id = p.id
  where p.gamertag = lower(trim(coalesce(p_gamertag, '')))
$$;
revoke execute on function public.account_login(text) from public;
grant execute on function public.account_login(text) to anon, authenticated;

-- Replace every real email address with the account's meaningless login.
-- Passwords, profiles, squads, friends and schedules are untouched.
update auth.users set
  email = id::text || '@users.dubsday.vercel.app',
  email_change = '', email_change_token_new = '', email_change_token_current = '',
  raw_user_meta_data = raw_user_meta_data - 'email'
where email not like '%@users.dubsday.vercel.app';
update auth.identities set identity_data = identity_data - 'email' || jsonb_build_object('email', user_id::text || '@users.dubsday.vercel.app')
where provider = 'email';
delete from auth.audit_log_entries;
delete from auth.one_time_tokens;
delete from auth.flow_state;

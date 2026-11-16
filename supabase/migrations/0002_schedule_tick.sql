-- Calls the notifier once a minute. Replace the project URL if the project changes.
select cron.schedule('dubsday-tick', '* * * * *', $job$
  select net.http_post(
    url := 'https://pzwtkdyocvsrqfjvktkl.supabase.co/functions/v1/tick',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', (select value from private.app_config where key = 'cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 20000)
$job$);

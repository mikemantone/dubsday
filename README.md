# DubsDay

Web app for lining up a squad's gaming schedules and finding "dub time".

## How it fits together

- `index.html` is the whole front end: markup, styles and script in one file. No build step; Vercel serves the files as they are.
- `vendor/supabase.js` is the Supabase browser library, kept in the repo so the app does not depend on a CDN.
- `sw.js` shows push notifications. `manifest.webmanifest` and `icons/` let people add DubsDay to their Home Screen.
- `supabase/migrations/` is the database: tables plus the functions the app calls. The app never reads tables directly;
  every table has row level security on with no policies, and each function checks who is calling.
- `supabase/functions/tick/` is the notifier. The database calls it once a minute; it works out each squad's DubTimes
  and sends push notifications (found, 15 minutes before, live).

## Things to know

- All times are New York time. A dub day runs 4:00am to 4:00am in 30-minute slots.
- The Supabase project URL and publishable key in `index.html` are public values by design. No secret keys live in this repo:
  the push keys and the notifier's secret are generated and kept inside the database.
- Email sign-up needs "Confirm email" turned off in Supabase (Authentication, Sign In / Providers, Email) unless a custom
  SMTP server is configured, because Supabase's built-in mailer only sends to the project's own team.
- Google sign-in needs a Google OAuth client added under Authentication, Sign In / Providers, Google.

## Deploying

Every push to `main` redeploys the site on Vercel. Other branches get their own preview address.
Database changes are applied to Supabase separately (they are not run by Vercel).

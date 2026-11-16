# DubsDay

Web app for lining up a squad's gaming schedules and finding "dub time".

## What is in this repo

- `index.html` is the whole app: markup, styles and script in one file.
- `manifest.webmanifest` and `icons/` let people add DubsDay to their phone's Home Screen.

There is no build step. Vercel serves these files as they are.

## Current state

This is the clickable prototype. It runs on sample data stored in each visitor's own browser:
sign-in is simulated, squads and schedules are not shared between people, and no notifications are sent.
The next phase adds real accounts, a shared database and push notifications.

## Deploying

1. Import this repository in Vercel (Add New, Project). Framework preset: Other. Leave build settings empty.
2. Every push to `main` redeploys the site automatically.

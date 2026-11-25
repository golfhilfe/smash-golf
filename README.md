# Smash Golf (installable web app)

Static PWA (index.html + manifest + service worker) hosted on GitHub Pages, with a Supabase database.

- `config.js`: Supabase Project URL + anon key (public by design).
- `setup/supabase-setup.sql`: run once in Supabase SQL Editor. All data access goes through `sg_*` functions; tables are not readable directly.
- `setup/002-pin-recovery.sql`, then `setup/003-anti-cheat.sql`: run once each, in order. 003 makes the server enforce every match step (only the defender accepts, only the other player confirms a result, walkovers only after 7 days, positions/points/match type computed server-side), locks sign-in for an hour after 5 wrong PINs, shows contacts only to your current opponent and the organiser, and freezes handicaps when a match is accepted.
- Players sign in with name + 4-8 digit PIN (hashed with bcrypt). The first player to join is the organiser (can reset PINs and cancel challenges).

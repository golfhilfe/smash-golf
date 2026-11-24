# Smash Golf (installable web app)

Static PWA (index.html + manifest + service worker) hosted on GitHub Pages, with a Supabase database.

- `config.js`: Supabase Project URL + anon key (public by design).
- `setup/supabase-setup.sql`: run once in Supabase SQL Editor. All data access goes through `sg_*` functions; tables are not readable directly.
- Players sign in with name + 4-8 digit PIN (hashed with bcrypt). The first player to join is the organiser (can reset PINs and cancel challenges).

# Smash Golf (installable web app)

Static PWA (index.html + manifest + service worker) hosted on GitHub Pages, with a Supabase database.

- `config.js`: Supabase Project URL + anon key (public by design).
- `setup/supabase-setup.sql`: run once in Supabase SQL Editor. All data access goes through `sg_*` functions; tables are not readable directly.
- Players sign in with name + 4-8 digit PIN (hashed with bcrypt). The first player to join is the organiser (can reset PINs and cancel challenges).

## Forgotten PIN
- A player taps **Forgot your PIN?** on the sign-in screen. The organiser then sees "<name> forgot their PIN" at the top of the app, taps **Set a new PIN**, and tells the player the new PIN.
- If the organiser forgets their own PIN, reset it in Supabase > SQL Editor (replace the name and PIN):
  `update public.sg_players set pin_hash = extensions.crypt('1234', extensions.gen_salt('bf')), reset_asked = null where lower(name) = lower('Organiser Name');`

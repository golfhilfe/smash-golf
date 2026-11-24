-- Smash Golf: PIN recovery by email (run once, after supabase-setup.sql).
-- The player proves they own the email with a Supabase Auth email code/link; the resulting login token is checked here.
create or replace function public.sg_recover_pin(p_name text, p_new text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare em text := lower(coalesce(auth.jwt()->>'email','')); r public.sg_players;
begin
  if em = '' then raise exception 'auth' using errcode = '28000'; end if;
  if p_new !~ '^[0-9]{4,8}$' then raise exception 'pin' using errcode = '22023'; end if;
  select * into r from public.sg_players
    where lower(name) = lower(btrim(p_name)) and lower(btrim(coalesce(data->>'email',''))) = em;
  if r.id is null then raise exception 'nomatch' using errcode = '22023'; end if;
  update public.sg_players set pin_hash = crypt(p_new, gen_salt('bf')) where id = r.id;
  return jsonb_build_object('id', r.id);
end $$;
grant execute on function public.sg_recover_pin(text,text) to anon, authenticated;

-- Emails are private: only the player themself gets their own email back.
create or replace function public.sg_state(p_id text default null, p_pin text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ok boolean := false; me public.sg_players; pl jsonb; ch jsonb; o jsonb;
begin
  if p_id is not null then
    select * into me from public.sg_players where id = p_id;
    ok := me.id is not null and me.pin_hash = crypt(coalesce(p_pin,''), me.pin_hash);
  end if;
  select coalesce(jsonb_object_agg(id,
           ((case when ok then data else data - 'contact' end) - (case when ok and id = p_id then '' else 'email' end))
           || jsonb_build_object('name',name,'admin',is_admin,'hasEmail',coalesce(data->>'email','') <> '')), '{}'::jsonb)
    into pl from public.sg_players;
  select coalesce(jsonb_object_agg(id, data || jsonb_build_object('id',id)), '{}'::jsonb) into ch from public.sg_challenges;
  select ord into o from public.sg_ladder where id = 1;
  return jsonb_build_object('players',pl,'challenges',ch,'order',coalesce(o,'[]'::jsonb),'auth',ok,
    'names',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name) order by lower(name)),'[]'::jsonb) from public.sg_players));
end $$;
notify pgrst, 'reload schema';

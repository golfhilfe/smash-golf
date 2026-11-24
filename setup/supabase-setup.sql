-- Smash Golf: one-time database setup. Paste all of this into Supabase > SQL Editor and click Run.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.sg_players(
  id text primary key default replace(gen_random_uuid()::text,'-',''),
  name text not null,
  pin_hash text not null,
  data jsonb not null default '{}'::jsonb,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index if not exists sg_players_name_uq on public.sg_players(lower(name));
create table if not exists public.sg_challenges(
  id text primary key,
  data jsonb not null,
  updated_at timestamptz not null default now()
);
create table if not exists public.sg_ladder(
  id int primary key,
  ord jsonb not null default '[]'::jsonb
);
insert into public.sg_ladder(id,ord) values(1,'[]'::jsonb) on conflict do nothing;

-- No direct table access from the app: everything goes through the functions below.
alter table public.sg_players enable row level security;
alter table public.sg_challenges enable row level security;
alter table public.sg_ladder enable row level security;
revoke all on public.sg_players, public.sg_challenges, public.sg_ladder from anon, authenticated;

-- check name+PIN, returns the player row or raises
create or replace function public.sg_check(p_id text, p_pin text) returns public.sg_players
language plpgsql security definer set search_path = public, extensions as $$
declare r public.sg_players;
begin
  select * into r from public.sg_players where id = p_id;
  if r.id is null or r.pin_hash <> crypt(coalesce(p_pin,''), r.pin_hash) then
    raise exception 'auth' using errcode = '28000';
  end if;
  return r;
end $$;
revoke execute on function public.sg_check(text,text) from public, anon, authenticated;

create or replace function public.sg_state(p_id text default null, p_pin text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ok boolean := false; me public.sg_players; pl jsonb; ch jsonb; o jsonb;
begin
  if p_id is not null then
    select * into me from public.sg_players where id = p_id;
    ok := me.id is not null and me.pin_hash = crypt(coalesce(p_pin,''), me.pin_hash);
  end if;
  select coalesce(jsonb_object_agg(id,
           (case when ok then data else data - 'contact' end) || jsonb_build_object('name',name,'admin',is_admin)), '{}'::jsonb)
    into pl from public.sg_players;
  select coalesce(jsonb_object_agg(id, data || jsonb_build_object('id',id)), '{}'::jsonb) into ch from public.sg_challenges;
  select ord into o from public.sg_ladder where id = 1;
  return jsonb_build_object('players',pl,'challenges',ch,'order',coalesce(o,'[]'::jsonb),'auth',ok,
    'names',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name) order by lower(name)),'[]'::jsonb) from public.sg_players));
end $$;

create or replace function public.sg_register(p_name text, p_pin text, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare nid text; first boolean; n text := btrim(p_name);
begin
  if length(n) < 2 or length(n) > 60 then raise exception 'name' using errcode = '22023'; end if;
  if p_pin !~ '^[0-9]{4,8}$' then raise exception 'pin' using errcode = '22023'; end if;
  if exists(select 1 from public.sg_players where lower(name) = lower(n)) then raise exception 'taken' using errcode = '23505'; end if;
  perform 1 from public.sg_ladder where id = 1 for update;
  first := not exists(select 1 from public.sg_players);
  insert into public.sg_players(name,pin_hash,data,is_admin)
    values(n, crypt(p_pin, gen_salt('bf')), coalesce(p_data,'{}'::jsonb) - 'name' - 'admin', first)
    returning id into nid;
  update public.sg_ladder set ord = ord || to_jsonb(nid) where id = 1;
  return jsonb_build_object('id',nid);
end $$;

create or replace function public.sg_login(p_name text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r public.sg_players;
begin
  select * into r from public.sg_players where lower(name) = lower(btrim(p_name));
  if r.id is null or r.pin_hash <> crypt(coalesce(p_pin,''), r.pin_hash) then
    perform pg_sleep(1);
    raise exception 'auth' using errcode = '28000';
  end if;
  return jsonb_build_object('id',r.id);
end $$;

create or replace function public.sg_save_profile(p_id text, p_pin text, p_data jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me public.sg_players := public.sg_check(p_id,p_pin); n text := btrim(coalesce(p_data->>'name', me.name));
begin
  if length(n) < 2 or length(n) > 60 then raise exception 'name' using errcode = '22023'; end if;
  if exists(select 1 from public.sg_players where lower(name) = lower(n) and id <> me.id) then raise exception 'taken' using errcode = '23505'; end if;
  update public.sg_players set name = n, data = coalesce(p_data,'{}'::jsonb) - 'name' - 'admin' where id = me.id;
end $$;

create or replace function public.sg_leave(p_id text, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me public.sg_players := public.sg_check(p_id,p_pin);
begin
  update public.sg_challenges set data = data || jsonb_build_object('status','cancelled','note','The player left the ladder.','closedAt',(extract(epoch from now())*1000)::bigint)
    where data->>'status' in ('pending','accepted','reported') and (data->>'challenger' = me.id or data->>'defender' = me.id);
  update public.sg_ladder set ord = coalesce((select jsonb_agg(x) from jsonb_array_elements(ord) x where x <> to_jsonb(me.id)),'[]'::jsonb) where id = 1;
  delete from public.sg_players where id = me.id;
end $$;

-- create or update a challenge; when it becomes "done" with the challenger winning a ladder challenge, the ladder is updated atomically
create or replace function public.sg_save_challenge(p_id text, p_pin text, p_cid text, p_data jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me public.sg_players := public.sg_check(p_id,p_pin); old jsonb; o jsonb; arr text[]; ci int; di int; ch text; de text;
begin
  if p_cid !~ '^[a-z0-9]{4,40}$' then raise exception 'id' using errcode = '22023'; end if;
  perform 1 from public.sg_ladder where id = 1 for update;
  select data into old from public.sg_challenges where id = p_cid;
  if old is null then
    if p_data->>'challenger' <> me.id or p_data->>'status' <> 'pending' then raise exception 'forbidden' using errcode = '42501'; end if;
    if not exists(select 1 from public.sg_players where id = p_data->>'defender') then raise exception 'forbidden' using errcode = '42501'; end if;
  else
    if old->>'status' in ('done','cancelled') then raise exception 'closed' using errcode = '42501'; end if;
    if (p_data->>'challenger') is distinct from (old->>'challenger') or (p_data->>'defender') is distinct from (old->>'defender') then
      raise exception 'forbidden' using errcode = '42501'; end if;
    if not (me.id in (old->>'challenger', old->>'defender') or (me.is_admin and p_data->>'status' = 'cancelled')) then
      raise exception 'forbidden' using errcode = '42501'; end if;
  end if;
  insert into public.sg_challenges(id,data,updated_at) values(p_cid, p_data - 'id', now())
    on conflict (id) do update set data = excluded.data, updated_at = now();
  ch := p_data->>'challenger'; de := p_data->>'defender';
  -- one match at a time: accepting withdraws every other pending invitation involving either player
  if p_data->>'status' = 'accepted' and coalesce(old->>'status','') = 'pending' then
    update public.sg_challenges set data = data || jsonb_build_object('status','cancelled','note','The player has already accepted another match.','closedAt',(extract(epoch from now())*1000)::bigint), updated_at = now()
      where id <> p_cid and data->>'status' = 'pending'
        and (data->>'challenger' in (ch,de) or data->>'defender' in (ch,de));
  end if;
  if p_data->>'status' = 'done' and p_data->>'winner' = ch and coalesce(p_data->>'kind','ladder') = 'ladder' then
    select ord into o from public.sg_ladder where id = 1;
    select array_agg(x order by n) into arr from jsonb_array_elements_text(o) with ordinality t(x,n);
    ci := array_position(arr, ch); di := array_position(arr, de);
    if ci is not null and di is not null and ci > di then
      arr := array_remove(arr, ch);
      arr := arr[1:di-1] || ch || arr[di:];
      update public.sg_ladder set ord = to_jsonb(arr) where id = 1;
    end if;
  end if;
end $$;

-- organiser only: reset a player's PIN
create or replace function public.sg_reset_pin(p_id text, p_pin text, p_target text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me public.sg_players := public.sg_check(p_id,p_pin);
begin
  if not me.is_admin then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_new !~ '^[0-9]{4,8}$' then raise exception 'pin' using errcode = '22023'; end if;
  update public.sg_players set pin_hash = crypt(p_new, gen_salt('bf')) where id = p_target;
end $$;

grant execute on function public.sg_state(text,text), public.sg_register(text,text,jsonb), public.sg_login(text,text),
  public.sg_save_profile(text,text,jsonb), public.sg_leave(text,text), public.sg_save_challenge(text,text,text,jsonb),
  public.sg_reset_pin(text,text,text,text) to anon, authenticated;
notify pgrst, 'reload schema';

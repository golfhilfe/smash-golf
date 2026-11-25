-- Smash Golf: anti-cheat hardening (run once, after supabase-setup.sql and 002-pin-recovery.sql).
-- 1. The server now decides every match step itself: who may accept, decline, report, confirm or claim a walkover,
--    the ladder/points match type (up to 3 places above = ladder, up to 2 below = points, nothing further), the positions, the deadlines and the points. Values sent by the app are ignored.
-- 2. PIN guessing is limited: 5 wrong PINs in an hour lock that player's sign-in for 1 hour.
-- 3. Phone/contact details are shown only to the player themself, their current opponent and the organiser.
-- 4. Handicaps are frozen when a match is accepted, so changing your handicap afterwards gives no extra strokes.

alter table public.sg_players add column if not exists pin_fails int not null default 0;
alter table public.sg_players add column if not exists pin_fail_since timestamptz;
alter table public.sg_players add column if not exists pin_locked_until timestamptz;

-- 'ok' | 'bad' | 'locked'. Records failed attempts (only works when the caller does not raise afterwards).
create or replace function public.sg_pin_status(p_id text, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare r public.sg_players;
begin
  select * into r from public.sg_players where id = p_id for update;
  if r.id is null then return 'bad'; end if;
  if r.pin_locked_until is not null and r.pin_locked_until > now() then return 'locked'; end if;
  if r.pin_hash = crypt(coalesce(p_pin,''), r.pin_hash) then
    if r.pin_fails > 0 or r.pin_locked_until is not null then
      update public.sg_players set pin_fails = 0, pin_fail_since = null, pin_locked_until = null where id = r.id;
    end if;
    return 'ok';
  end if;
  if r.pin_fail_since is null or r.pin_fail_since < now() - interval '1 hour' then
    update public.sg_players set pin_fails = 1, pin_fail_since = now() where id = r.id;
  elsif r.pin_fails + 1 >= 5 then
    update public.sg_players set pin_fails = 0, pin_fail_since = null, pin_locked_until = now() + interval '1 hour' where id = r.id;
  else
    update public.sg_players set pin_fails = r.pin_fails + 1 where id = r.id;
  end if;
  return 'bad';
end $$;
revoke execute on function public.sg_pin_status(text,text) from public, anon, authenticated;

-- Returns the player, raises 'locked', or returns an empty row for a wrong PIN.
-- Callers must "return" (not raise) on an empty row, otherwise the failed attempt would be rolled back and not counted.
create or replace function public.sg_check(p_id text, p_pin text) returns public.sg_players
language plpgsql security definer set search_path = public, extensions as $$
declare r public.sg_players; s text := public.sg_pin_status(p_id, p_pin);
begin
  if s = 'locked' then raise exception 'locked' using errcode = '28000'; end if;
  if s = 'ok' then select * into r from public.sg_players where id = p_id; end if;
  return r;
end $$;
revoke execute on function public.sg_check(text,text) from public, anon, authenticated;

-- Wrong PIN returns {"error":"auth"} instead of raising, so the attempt is counted.
create or replace function public.sg_login(p_name text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare rid text; s text;
begin
  select id into rid from public.sg_players where lower(name) = lower(btrim(p_name));
  if rid is null then perform pg_sleep(0.5); return jsonb_build_object('error','auth'); end if;
  s := public.sg_pin_status(rid, p_pin);
  if s = 'locked' then return jsonb_build_object('error','locked'); end if;
  if s <> 'ok' then perform pg_sleep(0.5); return jsonb_build_object('error','auth'); end if;
  return jsonb_build_object('id',rid);
end $$;

create or replace function public.sg_state(p_id text default null, p_pin text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s text := 'none'; ok boolean := false; adm boolean := false; opp text[] := '{}'; pl jsonb; ch jsonb; o jsonb;
begin
  if p_id is not null then
    s := public.sg_pin_status(p_id, p_pin);
    ok := s = 'ok';
  end if;
  if ok then
    select is_admin into adm from public.sg_players where id = p_id;
    select coalesce(array_agg(case when data->>'challenger' = p_id then data->>'defender' else data->>'challenger' end), '{}') into opp
      from public.sg_challenges where data->>'status' in ('pending','accepted','reported') and p_id in (data->>'challenger', data->>'defender');
  end if;
  select coalesce(jsonb_object_agg(id,
           ((case when ok and (adm or id = p_id or id = any(opp)) then data else data - 'contact' end)
             - (case when ok and id = p_id then '' else 'email' end))
           || jsonb_build_object('name',name,'admin',is_admin,'hasEmail',coalesce(data->>'email','') <> '')), '{}'::jsonb)
    into pl from public.sg_players;
  select coalesce(jsonb_object_agg(id, data || jsonb_build_object('id',id)), '{}'::jsonb) into ch from public.sg_challenges;
  select ord into o from public.sg_ladder where id = 1;
  return jsonb_build_object('players',pl,'challenges',ch,'order',coalesce(o,'[]'::jsonb),
    'auth', case when s = 'locked' then null else to_jsonb(ok) end, 'locked', s = 'locked',
    'names',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name) order by lower(name)),'[]'::jsonb) from public.sg_players));
end $$;

create or replace function public.sg_register(p_name text, p_pin text, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare nid text; first boolean; n text := btrim(p_name);
begin
  if length(n) < 2 or length(n) > 60 then raise exception 'name' using errcode = '22023'; end if;
  if p_pin !~ '^[0-9]{4,8}$' then raise exception 'pin' using errcode = '22023'; end if;
  if length(coalesce(p_data,'{}'::jsonb)::text) > 2000 then raise exception 'too long' using errcode = '22023'; end if;
  if exists(select 1 from public.sg_players where lower(name) = lower(n)) then raise exception 'taken' using errcode = '23505'; end if;
  perform 1 from public.sg_ladder where id = 1 for update;
  first := not exists(select 1 from public.sg_players);
  insert into public.sg_players(name,pin_hash,data,is_admin)
    values(n, crypt(p_pin, gen_salt('bf')), coalesce(p_data,'{}'::jsonb) - 'name' - 'admin', first)
    returning id into nid;
  update public.sg_ladder set ord = ord || to_jsonb(nid) where id = 1;
  return jsonb_build_object('id',nid);
end $$;

create or replace function public.sg_save_profile(p_id text, p_pin text, p_data jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me public.sg_players := public.sg_check(p_id,p_pin); n text;
begin
  if me.id is null then return; end if;
  n := btrim(coalesce(p_data->>'name', me.name));
  if length(n) < 2 or length(n) > 60 then raise exception 'name' using errcode = '22023'; end if;
  if length(coalesce(p_data,'{}'::jsonb)::text) > 2000 then raise exception 'too long' using errcode = '22023'; end if;
  if exists(select 1 from public.sg_players where lower(name) = lower(n) and id <> me.id) then raise exception 'taken' using errcode = '23505'; end if;
  update public.sg_players set name = n, data = coalesce(p_data,'{}'::jsonb) - 'name' - 'admin' where id = me.id;
end $$;

create or replace function public.sg_leave(p_id text, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me public.sg_players := public.sg_check(p_id,p_pin);
begin
  if me.id is null then return; end if;
  perform 1 from public.sg_ladder where id = 1 for update;
  update public.sg_challenges set data = data || jsonb_build_object('status','cancelled','note','The player left the ladder.','closedAt',(extract(epoch from now())*1000)::bigint), updated_at = now()
    where data->>'status' in ('pending','accepted','reported') and (data->>'challenger' = me.id or data->>'defender' = me.id);
  update public.sg_ladder set ord = coalesce((select jsonb_agg(x) from jsonb_array_elements(ord) x where x <> to_jsonb(me.id)),'[]'::jsonb) where id = 1;
  delete from public.sg_players where id = me.id;
end $$;

-- Every match step is checked here. The app only says which step it wants (p_data.status) plus, when reporting, winner/score/holes.
create or replace function public.sg_save_challenge(p_id text, p_pin text, p_cid text, p_data jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me public.sg_players := public.sg_check(p_id,p_pin);
  old jsonb; nd jsonb; o jsonb; arr text[]; ci int; di int; ch text; de text; st text; ns text := p_data->>'status';
  kind text; w text; l text; wp int; lp int; nowms bigint := (extract(epoch from now())*1000)::bigint;
  accept_ms constant bigint := 7*86400000;
begin
  if me.id is null then return; end if;
  if p_cid !~ '^[a-z0-9]{4,40}$' then raise exception 'id' using errcode = '22023'; end if;
  perform 1 from public.sg_ladder where id = 1 for update;
  select ord into o from public.sg_ladder where id = 1;
  select array_agg(x order by n) into arr from jsonb_array_elements_text(o) with ordinality t(x,n);
  select data into old from public.sg_challenges where id = p_cid for update;

  if old is null then
    -- new challenge
    ch := me.id; de := p_data->>'defender';
    if ns is distinct from 'pending' or (p_data->>'challenger') is distinct from me.id or de is null or de = me.id then
      raise exception 'forbidden' using errcode = '42501'; end if;
    ci := array_position(arr, ch); di := array_position(arr, de);
    if ci is null or di is null then raise exception 'forbidden' using errcode = '42501'; end if;
    if exists(select 1 from public.sg_challenges where data->>'status' in ('pending','accepted','reported')
                and (data->>'challenger' in (ch,de) or data->>'defender' in (ch,de))) then
      raise exception 'busy' using errcode = '42501'; end if;
    -- opponents: up to 3 places above (ladder challenge) or up to 2 places below (points match); nobody further away
    if ci - di between 1 and 3 then kind := 'ladder';
    elsif di - ci between 1 and 2 then kind := 'points';
    else raise exception 'range' using errcode = '42501'; end if;
    nd := jsonb_build_object('challenger',ch,'defender',de,'chPos',ci,'dePos',di,'kind',kind,'status','pending','createdAt',nowms);
  else
    ch := old->>'challenger'; de := old->>'defender'; st := old->>'status'; kind := coalesce(old->>'kind','ladder');
    if st not in ('pending','accepted','reported') then raise exception 'closed' using errcode = '42501'; end if;
    if (p_data->>'challenger') is distinct from ch or (p_data->>'defender') is distinct from de then
      raise exception 'forbidden' using errcode = '42501'; end if;
    nd := old;
    if me.id not in (ch, de) then
      if me.is_admin and ns = 'cancelled' then
        nd := nd || jsonb_build_object('status','cancelled','note','The organiser cancelled the challenge.','closedAt',nowms);
      else raise exception 'forbidden' using errcode = '42501'; end if;
    elsif st = 'pending' and ns = 'accepted' and me.id = de then
      nd := nd || jsonb_build_object('status','accepted','acceptedAt',nowms,
        'chHcp',(select data->'hcp' from public.sg_players where id = ch),
        'deHcp',(select data->'hcp' from public.sg_players where id = de));
      update public.sg_challenges set data = data || jsonb_build_object('status','cancelled','note','The player has already accepted another match.','closedAt',nowms), updated_at = now()
        where id <> p_cid and data->>'status' = 'pending'
          and (data->>'challenger' in (ch,de) or data->>'defender' in (ch,de));
    elsif st = 'pending' and ns = 'cancelled' and me.id = ch then
      nd := nd || jsonb_build_object('status','cancelled','note','The challenger withdrew the challenge.','closedAt',nowms);
    elsif st = 'pending' and ns = 'cancelled' and me.id = de and kind = 'points' then
      nd := nd || jsonb_build_object('status','cancelled','note','Points match declined.','closedAt',nowms);
    elsif st = 'pending' and ns = 'done' and me.id = de and kind = 'ladder' then
      w := ch; nd := nd || jsonb_build_object('score','conceded','how','forfeit');            -- declining a ladder challenge = conceding
    elsif st = 'pending' and ns = 'done' and me.id = ch and kind = 'ladder' and nowms >= coalesce((old->>'createdAt')::bigint, nowms) + accept_ms then
      w := ch; nd := nd || jsonb_build_object('score','walkover','how','noshow');             -- no answer within 7 days
    elsif st = 'accepted' and ns = 'reported' then
      w := p_data->>'winner';
      if w is null or w not in (ch, de) then raise exception 'forbidden' using errcode = '42501'; end if;
      nd := (nd - 'note') || jsonb_build_object('status','reported','winner',w,'score',left(coalesce(p_data->>'score',''),20),
        'holes', case when p_data->>'holes' in ('9','18','27') then (p_data->>'holes')::int else 18 end,
        'reportedBy',me.id,'reportedAt',nowms);
      w := null;
    elsif st = 'reported' and ns = 'done' and me.id is distinct from (old->>'reportedBy') then
      w := old->>'winner'; nd := nd || jsonb_build_object('how','played');                    -- the OTHER player confirms
    elsif st = 'reported' and ns = 'accepted' and me.id is distinct from (old->>'reportedBy') then
      nd := (nd - 'winner' - 'score' - 'holes' - 'reportedBy' - 'reportedAt') || jsonb_build_object('status','accepted','note','Result disputed.');
    else
      raise exception 'forbidden' using errcode = '42501';
    end if;
  end if;

  if w is not null then
    -- match finished: positions and points are worked out here, from the ladder as it stands now
    l := case when w = ch then de else ch end;
    ci := coalesce(array_position(arr, ch), (old->>'chPos')::int); di := coalesce(array_position(arr, de), (old->>'dePos')::int);
    wp := case when w = ch then ci else di end; lp := case when w = ch then di else ci end;
    nd := nd || jsonb_build_object('status','done','winner',w,'closedAt',nowms,'chPos',ci,'dePos',di,'kind',kind,
      'points', case when wp is not null and lp is not null and wp > lp then 3 + wp - lp else 3 end);
    if kind = 'ladder' and w = ch then
      ci := array_position(arr, ch); di := array_position(arr, de);
      if ci is not null and di is not null and ci > di then
        arr := array_remove(arr, ch);
        arr := arr[1:di-1] || ch || arr[di:];
        update public.sg_ladder set ord = to_jsonb(arr) where id = 1;
      end if;
    end if;
  end if;

  insert into public.sg_challenges(id,data,updated_at) values(p_cid, nd, now())
    on conflict (id) do update set data = excluded.data, updated_at = now();
end $$;

create or replace function public.sg_reset_pin(p_id text, p_pin text, p_target text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me public.sg_players := public.sg_check(p_id,p_pin);
begin
  if me.id is null then return; end if;
  if not me.is_admin then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_new !~ '^[0-9]{4,8}$' then raise exception 'pin' using errcode = '22023'; end if;
  update public.sg_players set pin_hash = crypt(p_new, gen_salt('bf')), pin_fails = 0, pin_fail_since = null, pin_locked_until = null where id = p_target;
end $$;

create or replace function public.sg_recover_pin(p_name text, p_new text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare em text := lower(coalesce(auth.jwt()->>'email','')); r public.sg_players;
begin
  if em = '' then raise exception 'auth' using errcode = '28000'; end if;
  if p_new !~ '^[0-9]{4,8}$' then raise exception 'pin' using errcode = '22023'; end if;
  select * into r from public.sg_players
    where lower(name) = lower(btrim(p_name)) and lower(btrim(coalesce(data->>'email',''))) = em;
  if r.id is null then raise exception 'nomatch' using errcode = '22023'; end if;
  update public.sg_players set pin_hash = crypt(p_new, gen_salt('bf')), pin_fails = 0, pin_fail_since = null, pin_locked_until = null where id = r.id;
  return jsonb_build_object('id', r.id);
end $$;

grant execute on function public.sg_state(text,text), public.sg_register(text,text,jsonb), public.sg_login(text,text),
  public.sg_save_profile(text,text,jsonb), public.sg_leave(text,text), public.sg_save_challenge(text,text,text,jsonb),
  public.sg_reset_pin(text,text,text,text), public.sg_recover_pin(text,text) to anon, authenticated;
notify pgrst, 'reload schema';

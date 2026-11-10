-- Mon CV – Schülerdossier: Datenbank für Supabase
-- Einmal im Supabase SQL-Editor ausführen (oder per MCP apply_migration).
--
-- Sicherheitsmodell:
--   * Die Tabelle ist per RLS komplett gesperrt (keine Policies). Der öffentliche
--     Schlüssel im Browser kann sie weder lesen noch auflisten.
--   * Schüler kommen nur über student_load / student_save an IHRE Zeile, und nur mit
--     ihrem persönlichen Code (8 Zeichen, ca. 850 Milliarden Möglichkeiten).
--   * Die Lehrerin verwaltet Codes über teacher_* Funktionen, geschützt durch ein
--     Lehrer-Passwort (nur als bcrypt-Hash gespeichert).
--   * Jede Zeile hat ein Ablaufdatum (Standard 35 Tage) und wird danach gelöscht.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.dossiers (
  code        text primary key,
  name        text not null,
  klasse      text not null default '',
  data        jsonb not null default '{}'::jsonb,
  rev         integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz,
  expires_at  timestamptz not null default now() + interval '35 days'
);
alter table public.dossiers enable row level security;

create table if not exists public.app_config (
  id            boolean primary key default true check (id),
  teacher_hash  text not null
);
alter table public.app_config enable row level security;

revoke all on public.dossiers, public.app_config from anon, authenticated;

-- ---------- Hilfsfunktionen ----------
create or replace function public._norm_code(p text)
returns text language sql immutable set search_path = public as $$
  select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

create or replace function public._check_teacher(p_secret text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_secret is null or not exists (
    select 1 from app_config where teacher_hash = crypt(p_secret, teacher_hash)
  ) then
    perform pg_sleep(1);  -- bremst Raten
    raise exception 'Falsches Lehrer-Passwort' using errcode = '28P01';
  end if;
end $$;

create or replace function public._new_code()
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';  -- ohne 0/O, 1/I/L
  b bytea; c text;
begin
  loop
    b := gen_random_bytes(8); c := '';
    for i in 0..7 loop
      c := c || substr(alphabet, (get_byte(b, i) % 31) + 1, 1);
    end loop;
    exit when not exists (select 1 from dossiers where code = c);
  end loop;
  return c;
end $$;

-- ---------- Schüler ----------
create or replace function public.student_load(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare r dossiers;
begin
  select * into r from dossiers where code = _norm_code(p_code) and expires_at > now();
  if not found then
    perform pg_sleep(0.5);
    return null;
  end if;
  return json_build_object('code', r.code, 'name', r.name, 'klasse', r.klasse,
                           'data', r.data, 'rev', r.rev, 'expires_at', r.expires_at);
end $$;

-- Speichert nur, wenn p_rev der aktuelle Stand ist (sonst war das Dossier
-- inzwischen auf einem anderen Gerät offen). Gibt die neue rev zurück,
-- -1 bei Konflikt, null wenn der Code nicht (mehr) existiert.
create or replace function public.student_save(p_code text, p_data jsonb, p_rev integer)
returns integer language plpgsql security definer set search_path = public as $$
declare new_rev integer;
begin
  if pg_column_size(p_data) > 600000 then
    raise exception 'Dossier zu groß' using errcode = '54000';
  end if;
  -- Das Foto wird nie gespeichert (bleibt nur im Browser des Schülers).
  update dossiers set data = p_data #- '{cv,photo}', rev = rev + 1, updated_at = now()
   where code = _norm_code(p_code) and expires_at > now() and rev = p_rev
  returning rev into new_rev;
  if found then return new_rev; end if;
  if exists (select 1 from dossiers where code = _norm_code(p_code) and expires_at > now()) then
    return -1;
  end if;
  return null;
end $$;

-- ---------- Lehrerin ----------
create or replace function public.teacher_create(p_secret text, p_names text[], p_klasse text default '', p_days integer default 35)
returns table(code text, name text) language plpgsql security definer set search_path = public as $$
declare n text;
begin
  perform _check_teacher(p_secret);
  foreach n in array p_names loop
    n := btrim(n);
    continue when n = '';
    code := _new_code(); name := n;
    insert into dossiers(code, name, klasse, expires_at)
      values (code, name, coalesce(btrim(p_klasse), ''), now() + make_interval(days => greatest(1, least(p_days, 120))));
    return next;
  end loop;
end $$;

create or replace function public.teacher_list(p_secret text)
returns table(code text, name text, klasse text, created_at timestamptz, updated_at timestamptz,
              expires_at timestamptz, cv_name text, cv_score integer, bytes integer)
language plpgsql security definer set search_path = public as $$
begin
  perform _check_teacher(p_secret);
  return query
    select d.code, d.name, d.klasse, d.created_at, d.updated_at, d.expires_at,
           btrim(coalesce(d.data#>>'{cv,prenom}', '') || ' ' || coalesce(d.data#>>'{cv,nom}', '')),
           (select count(*)::int from jsonb_each(coalesce(d.data->'f', '{}'::jsonb)) e where btrim(e.value #>> '{}') <> ''),
           pg_column_size(d.data)
      from dossiers d order by d.klasse, d.name;
end $$;

create or replace function public.teacher_get(p_secret text, p_code text)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform _check_teacher(p_secret);
  return (select json_build_object('code', code, 'name', name, 'klasse', klasse, 'data', data, 'rev', rev)
            from dossiers where code = _norm_code(p_code));
end $$;

create or replace function public.teacher_extend(p_secret text, p_days integer)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  perform _check_teacher(p_secret);
  update dossiers set expires_at = expires_at + make_interval(days => greatest(1, least(p_days, 60)));
  get diagnostics n = row_count; return n;
end $$;

create or replace function public.teacher_delete(p_secret text, p_code text)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  perform _check_teacher(p_secret);
  if p_code is null or p_code = '*' then delete from dossiers;
  else delete from dossiers where code = _norm_code(p_code); end if;
  get diagnostics n = row_count; return n;
end $$;

-- ---------- Wartung (täglich von GitHub Actions aufgerufen) ----------
-- Hält das kostenlose Supabase-Projekt wach (pausiert sonst nach 7 Tagen ohne
-- Zugriff) und löscht abgelaufene Dossiers.
create or replace function public.maintenance()
returns json language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  delete from dossiers where expires_at <= now();
  get diagnostics n = row_count;
  return json_build_object('deleted', n, 'active', (select count(*) from dossiers));
end $$;

-- Nur diese Funktionen sind von außen aufrufbar.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.student_load(text), public.student_save(text, jsonb, integer),
  public.teacher_create(text, text[], text, integer), public.teacher_list(text),
  public.teacher_get(text, text), public.teacher_extend(text, integer),
  public.teacher_delete(text, text), public.maintenance()
  to anon, authenticated;

-- Lehrer-Passwort setzen (Platzhalter ersetzen, dann nur diese Zeile ausführen):
-- insert into app_config(teacher_hash) values (extensions.crypt('PASSWORT', extensions.gen_salt('bf')))
--   on conflict (id) do update set teacher_hash = excluded.teacher_hash;

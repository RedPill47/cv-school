-- Mon CV – Schülerdossier: Datenbank für Supabase (Neuinstallation).
-- Bestehende Datenbank aktualisieren: Dateien in supabase/migrations/ der Reihe nach,
-- danach den Teil "Funktionen" dieser Datei.
--
-- Sicherheitsmodell:
--   * Alle Tabellen sind per RLS gesperrt (keine Policies). Der öffentliche Schlüssel
--     im Browser kann sie weder lesen noch auflisten.
--   * Schüler kommen nur über student_* Funktionen an IHRE Zeile, mit ihrem
--     persönlichen Code (8 Zeichen, ca. 850 Milliarden Möglichkeiten).
--   * Jede Lehrerin hat ein eigenes Konto (Passwort, nur als bcrypt-Hash gespeichert)
--     und sieht nur ihre eigenen Klassen und Schüler.
--   * Jedes Dossier hat ein Ablaufdatum (Standard 35 Tage) und wird danach gelöscht.
--   * Das CV-Foto wird nie gespeichert (bleibt im Browser des Schülers).

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tabellen ----------
create table if not exists public.teachers (
  id          serial primary key,
  name        text not null,
  pw_hash     text not null,
  created_at  timestamptz not null default now()
);

create table if not exists public.dossiers (
  code        text primary key,
  teacher_id  integer not null references public.teachers(id) on delete cascade,
  name        text not null,
  klasse      text not null default '',
  data        jsonb not null default '{}'::jsonb,
  rev         integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz,
  expires_at  timestamptz not null default now() + interval '35 days'
);
create index if not exists dossiers_teacher_idx on public.dossiers(teacher_id, klasse);

-- Kapitel freigeben, pro Lehrerin und Klasse. Keine Zeile = alle Kapitel offen.
create table if not exists public.chapter_locks (
  teacher_id     integer not null references public.teachers(id) on delete cascade,
  klasse         text not null,
  open_chapters  text[] not null,
  updated_at     timestamptz not null default now(),
  primary key (teacher_id, klasse)
);

alter table public.teachers enable row level security;
alter table public.dossiers enable row level security;
alter table public.chapter_locks enable row level security;
revoke all on public.teachers, public.dossiers, public.chapter_locks from anon, authenticated;

-- ---------- Funktionen ----------
create or replace function public._norm_code(p text)
returns text language sql immutable set search_path = public as $$
  select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

-- Gibt die Konto-ID zum Passwort zurück, sonst Fehler.
create or replace function public._teacher_id(p_secret text)
returns integer language plpgsql security definer set search_path = public, extensions as $$
declare tid integer;
begin
  if p_secret is not null and p_secret <> '' then
    select id into tid from teachers where pw_hash = crypt(p_secret, pw_hash) limit 1;
  end if;
  if tid is null then
    perform pg_sleep(1);  -- bremst Raten
    raise exception 'Falsches Lehrer-Passwort' using errcode = '28P01';
  end if;
  return tid;
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

create or replace function public._open_for(p_teacher integer, p_klasse text)
returns text[] language sql stable security definer set search_path = public as $$
  select open_chapters from chapter_locks where teacher_id = p_teacher and klasse = coalesce(p_klasse, '')
$$;

create or replace function public._drop_empty_classes()
returns void language sql security definer set search_path = public as $$
  delete from chapter_locks c
   where not exists (select 1 from dossiers d where d.teacher_id = c.teacher_id and d.klasse = c.klasse)
$$;

-- ----- Schüler -----
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
                           'data', r.data, 'rev', r.rev, 'expires_at', r.expires_at,
                           'open', _open_for(r.teacher_id, r.klasse));
end $$;

-- Leichte Abfrage, die die Schülerseite jede Minute macht.
create or replace function public.student_open(p_code text)
returns json language plpgsql stable security definer set search_path = public as $$
declare r dossiers;
begin
  select * into r from dossiers where code = _norm_code(p_code) and expires_at > now();
  if not found then return null; end if;
  return json_build_object('open', _open_for(r.teacher_id, r.klasse));
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

-- ----- Lehrerin (alles nur für das eigene Konto) -----
create or replace function public.teacher_me(p_secret text)
returns json language plpgsql security definer set search_path = public as $$
declare tid integer := _teacher_id(p_secret);
begin
  return (select json_build_object('id', id, 'name', name) from teachers where id = tid);
end $$;

create or replace function public.teacher_create(p_secret text, p_names text[], p_klasse text default '', p_days integer default 35)
returns table(code text, name text) language plpgsql security definer set search_path = public as $$
declare tid integer := _teacher_id(p_secret); n text;
begin
  foreach n in array p_names loop
    n := btrim(n);
    continue when n = '';
    code := _new_code(); name := n;
    insert into dossiers(code, teacher_id, name, klasse, expires_at)
      values (code, tid, name, coalesce(btrim(p_klasse), ''), now() + make_interval(days => greatest(1, least(p_days, 120))));
    return next;
  end loop;
end $$;

create or replace function public.teacher_list(p_secret text)
returns table(code text, name text, klasse text, created_at timestamptz, updated_at timestamptz,
              expires_at timestamptz, cv_name text, cv_score integer, bytes integer)
language plpgsql security definer set search_path = public as $$
declare tid integer := _teacher_id(p_secret);
begin
  return query
    select d.code, d.name, d.klasse, d.created_at, d.updated_at, d.expires_at,
           btrim(coalesce(d.data#>>'{cv,prenom}', '') || ' ' || coalesce(d.data#>>'{cv,nom}', '')),
           (select count(*)::int from jsonb_each(coalesce(d.data->'f', '{}'::jsonb)) e where btrim(e.value #>> '{}') <> ''),
           pg_column_size(d.data)
      from dossiers d where d.teacher_id = tid order by d.klasse, d.name;
end $$;

create or replace function public.teacher_get(p_secret text, p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare tid integer := _teacher_id(p_secret);
begin
  return (select json_build_object('code', d.code, 'name', d.name, 'klasse', d.klasse, 'data', d.data, 'rev', d.rev)
            from dossiers d where d.code = _norm_code(p_code) and d.teacher_id = tid);
end $$;

create or replace function public.teacher_extend(p_secret text, p_days integer)
returns integer language plpgsql security definer set search_path = public as $$
declare tid integer := _teacher_id(p_secret); n integer;
begin
  update dossiers set expires_at = expires_at + make_interval(days => greatest(1, least(p_days, 60)))
   where teacher_id = tid;
  get diagnostics n = row_count; return n;
end $$;

-- p_code = '*' löscht alle Dossiers DIESES Kontos.
create or replace function public.teacher_delete(p_secret text, p_code text)
returns integer language plpgsql security definer set search_path = public as $$
declare tid integer := _teacher_id(p_secret); n integer;
begin
  if p_code is null or p_code = '*' then delete from dossiers where teacher_id = tid;
  else delete from dossiers where code = _norm_code(p_code) and teacher_id = tid; end if;
  get diagnostics n = row_count;
  perform _drop_empty_classes();  -- Klassen ohne Schüler verschwinden
  return n;
end $$;

create or replace function public.teacher_locks_get(p_secret text)
returns table(klasse text, open_chapters text[]) language plpgsql security definer set search_path = public as $$
declare tid integer := _teacher_id(p_secret);
begin
  return query
    select k.klasse, l.open_chapters
      from (select d.klasse from dossiers d where d.teacher_id = tid
            union select c.klasse from chapter_locks c where c.teacher_id = tid) k
      left join chapter_locks l on l.teacher_id = tid and l.klasse = k.klasse
     order by k.klasse;
end $$;

-- p_open = null hebt alle Sperren für die Klasse auf.
create or replace function public.teacher_locks_set(p_secret text, p_klasse text, p_open text[])
returns void language plpgsql security definer set search_path = public as $$
declare tid integer := _teacher_id(p_secret);
begin
  if p_open is null then
    delete from chapter_locks where teacher_id = tid and klasse = coalesce(btrim(p_klasse), '');
    return;
  end if;
  if exists (select 1 from unnest(p_open) x where x !~ '^k[1-9]$') then
    raise exception 'Unbekanntes Kapitel' using errcode = '22023';
  end if;
  insert into chapter_locks(teacher_id, klasse, open_chapters, updated_at)
    values (tid, coalesce(btrim(p_klasse), ''), p_open, now())
  on conflict (teacher_id, klasse) do update set open_chapters = excluded.open_chapters, updated_at = now();
end $$;

-- ----- Wartung (täglich von GitHub Actions aufgerufen) -----
-- Hält das kostenlose Supabase-Projekt wach (pausiert sonst nach 7 Tagen ohne
-- Zugriff) und löscht abgelaufene Dossiers.
create or replace function public.maintenance()
returns json language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  delete from dossiers where expires_at <= now();
  get diagnostics n = row_count;
  perform _drop_empty_classes();
  return json_build_object('deleted', n, 'active', (select count(*) from dossiers));
end $$;

-- Nur diese Funktionen sind von außen aufrufbar.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.student_load(text), public.student_open(text),
  public.student_save(text, jsonb, integer), public.teacher_me(text),
  public.teacher_create(text, text[], text, integer), public.teacher_list(text),
  public.teacher_get(text, text), public.teacher_extend(text, integer),
  public.teacher_delete(text, text), public.teacher_locks_get(text),
  public.teacher_locks_set(text, text, text[]), public.maintenance()
  to anon, authenticated;

-- ---------- Lehrer-Konten verwalten (im Supabase SQL-Editor) ----------
-- Neues Konto:
--   insert into teachers(name, pw_hash) values ('Name', extensions.crypt('PASSWORT', extensions.gen_salt('bf')));
-- Passwort ändern:
--   update teachers set pw_hash = extensions.crypt('NEUES-PASSWORT', extensions.gen_salt('bf')) where name = 'Name';
-- Konto löschen (löscht auch alle seine Schüler-Dossiers):
--   delete from teachers where name = 'Name';

-- Mehrere Lehrer-Konten: jede Lehrerin sieht nur ihre eigenen Klassen und Schüler.
-- Das bisherige Lehrer-Passwort wird Konto 1; alle bestehenden Dossiers und
-- Kapitel-Einstellungen gehören zu Konto 1.

create table public.teachers (
  id          serial primary key,
  name        text not null,
  pw_hash     text not null,
  created_at  timestamptz not null default now()
);
alter table public.teachers enable row level security;
revoke all on public.teachers from anon, authenticated;

insert into public.teachers(id, name, pw_hash) select 1, 'Lehrerin 1', teacher_hash from public.app_config;
select setval(pg_get_serial_sequence('public.teachers', 'id'), (select max(id) from public.teachers));

alter table public.dossiers add column teacher_id integer references public.teachers(id) on delete cascade;
update public.dossiers set teacher_id = 1;
alter table public.dossiers alter column teacher_id set not null;
create index dossiers_teacher_idx on public.dossiers(teacher_id, klasse);

alter table public.chapter_locks add column teacher_id integer references public.teachers(id) on delete cascade;
update public.chapter_locks set teacher_id = 1;
alter table public.chapter_locks alter column teacher_id set not null;
alter table public.chapter_locks drop constraint chapter_locks_pkey;
alter table public.chapter_locks add primary key (teacher_id, klasse);

drop function public._check_teacher(text);
drop function public._open_for(text);
drop table public.app_config;

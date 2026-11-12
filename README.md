# Mon CV – Schülerdossier

Interaktives CV-Arbeitsheft (4 Wochen) für den Informatikraum. Jeder Schüler meldet sich mit einem
persönlichen 8-stelligen Code an; seine Arbeit wird online gespeichert (Supabase) und ist an jedem
Computer wieder da. Nach Ablauf (Standard 35 Tage) werden die Dossiers automatisch gelöscht.

- **Schüler:** `https://redpill47.github.io/cv-school/`
- **Lehrerin:** `https://redpill47.github.io/cv-school/lehrer.html`: Codes erstellen, Code-Zettel drucken, Fortschritt sehen, verlängern, löschen.

## Aufbau
- `index.html`: das Dossier. Speichert automatisch (1 s nach jeder Änderung), zeigt den Speicherstatus oben rechts,
  meldet sich nach 30 min ohne Aktivität ab und hinterlässt nach dem Abmelden nichts im Browser.
  Wird dasselbe Dossier an zwei Computern gleichzeitig bearbeitet, fragt es, welcher Stand bleiben soll.
- `lehrer.html`: Lehrerbereich (Passwort). Unter „Kapitel freigeben“ werden Kapitel pro Klasse geöffnet oder gesperrt
  (Schnellknöpfe „Woche 1“, „bis Woche 2“ …). Die Schülerseite fragt jede Minute nach, Änderungen wirken ohne neu anmelden.
- Das CV-Foto bleibt nur im Browser-Tab des Schülers (sessionStorage) und wird nie online gespeichert.
- `config.json`: Supabase-URL und öffentlicher (publishable) Schlüssel. Kein Geheimnis: die Tabellen sind per RLS gesperrt,
  Zugriff gibt es nur über die Funktionen in `supabase/schema.sql`, mit Schüler-Code bzw. Lehrer-Passwort.
- `.github/workflows/deploy.yml`: veröffentlicht bei jedem Push auf `main` auf GitHub Pages.
- `.github/workflows/maintenance.yml`: täglich: löscht abgelaufene Dossiers und hält das kostenlose Supabase-Projekt wach
  (es pausiert sonst nach 7 Tagen ohne Zugriff, z. B. in den Ferien).

## Lehrer-Konten
Jede Lehrerin hat ein eigenes Passwort und sieht nur ihre eigenen Klassen, Schüler und Kapitel-Sperren.
Konten verwalten im Supabase SQL-Editor (Projekt `cv-school`):
```sql
-- neues Konto
insert into teachers(name, pw_hash) values ('Name', extensions.crypt('PASSWORT', extensions.gen_salt('bf')));
-- Passwort ändern
update teachers set pw_hash = extensions.crypt('NEUES-PASSWORT', extensions.gen_salt('bf')) where name = 'Name';
-- Konto löschen (löscht auch alle seine Schüler-Dossiers)
delete from teachers where name = 'Name';
```

# Camp Ojibwa Leaderboard — Technical Spec (MVP)

Status: draft for review · Target: ready for the 2027 summer sessions

## 1. Goal

Replace the 2026 single-file chat artifact with a leaderboard that:

- parents can follow from a public link, live, on any phone;
- a handful of counselors/staff can score from a phone or computer at the same time without overwriting each other;
- is set up fresh for each session (teams, colors, events, points) from an admin screen, with no code changes;
- never silently loses data, and keeps a record of who logged or changed what.

Out of scope for the MVP (planned next): multi-year history and comparisons. The data is organized
by session from day one, so the 2026 archive (`archive/2026/`) can be imported later.

## 2. People and permissions

| Who | Signs in? | Can do |
|-----|-----------|--------|
| Parents & campers | No | View public sessions: standings, event log, team analysis, trends |
| Scorer (counselor) | Yes | Log results while a session is **live**; correct or delete only their own entries |
| Admin | Yes | Everything: session setup, teams, events, points, staff accounts, any correction, audit log |

Accounts are created by an admin (no public sign-up). Staff sign in with email + password.
Magic-link sign-in is avoided because Supabase's built-in email service only sends a few emails per hour.

All rules are enforced in the database (`supabase/schema.sql`, Row Level Security), not in the page,
and are covered by `supabase/tests/test_rls.py`.

## 3. Architecture

```
 Parents / staff browser
        │  static HTML + JS (no build step)
        ▼
 GitHub Pages  ── serves site/ from bhirvela/ojibwa
        │  supabase-js (public "publishable/anon" key only)
        ▼
 Supabase (free plan)
   • Postgres: data + security rules
   • Auth: staff email/password logins
   • Realtime: live updates to staff screens
```

- **Frontend:** plain HTML/CSS/JS modules in `site/`, `supabase-js` loaded from a CDN at a pinned
  version. No build tooling, so a future volunteer can edit it.
- **The public key in the page is meant to be public.** It only grants what the database rules allow
  a parent. The secret/service key and database password are never put in the repo or the page.
- **Live updates:** staff screens subscribe to realtime changes. The public board refreshes every
  ~20 seconds while the tab is open (cheap, and not limited by the free plan's realtime connection cap).

## 4. Data model

| Table | Purpose |
|-------|---------|
| `sessions` | One per camp session ("The Week 2027"): dates, status, public on/off, time zone, Team Analysis on/off |
| `teams` | Per session: name, short name, primary/secondary color, order. Any number of teams |
| `event_types` | Per session: name, and whether it's a **regular** event (SV/JV/Prep/Team) or **special** (Song, Swimming...) |
| `point_rules` | Default points per level, with optional per-event overrides (Team 15, Team + Tug of War 20) |
| `rounds` | The "Event #" staff call out, with its day |
| `results` | One contest: round, level, event, kind (`matchup` / `placement` / `adjustment`), winner/loser, tie flag, note, who logged it, soft-delete |
| `awards` | Points actually given: one row per team per result (points, extras, place) |
| `staff` | Approved logins and role (admin/scorer), can be deactivated |
| `audit_log` | Every change to results, awards, teams, staff: who, when, before/after |

Levels are fixed: **SV, JV, Prep, Team, Special**.

How the 2026 workarounds are now handled directly:

| 2026 workaround | New way |
|-----------------|---------|
| 2.5 + 2.5 for a tie in Swimming | Two awards with the same place |
| A fake 0-point Field Hockey entry for a bonus point | An `adjustment` result with a required note |
| Talent points typed as "extras" | Placements enter points per place; extras stay for genuine bonuses |
| Specials placing only some teams | Placements list only the teams that placed |
| Editing = deleting and re-entering | "Correct" replaces the old entry; the old one is kept in the audit trail |

Writes from the app go through two database functions, `save_result` and `delete_result`, which
check the rules (staff only, session is live, matchup points only to the two teams that played,
special events only at the Special level, scorers can only change their own entries) and save the
result and its points in one step, so a half-saved entry can't happen.

## 5. Screens

### Public (no sign-in) — mirrors the 2026 tabs
- **Standings** — ranked teams with plank-style name badges and sweep icons; ticker of recent results.
- **Event Log** — rounds with matchup cards and placement tables; jump-to-round.
- **Team Analysis** — W-L record by level; tap to see the events. Shown to parents by default;
  admins can hide it per session (`show_team_analysis`).
- **Trends** — cumulative points chart by level.
- **TV mode** (`?tv=1`) — full-screen standings + ticker for a screen in the dining hall, auto-refresh.

### Staff (signed in)
- **Log results**, built for a phone:
  - *Matchup round:* pick round # and opponents once, then tap the SV, JV and Prep winners;
    points fill from the session's rules.
  - *Team event:* pick event, winner, loser (20 auto-filled for Tug of War / Field Hockey).
  - *Special placements:* pick event, then assign places/points to the teams that placed; ties allowed.
  - *Adjustment:* team, points, and a required reason.
  - Round # suggests the current round; day defaults to **today in camp's time zone**, Central / America/Chicago by default and set per session (fixes the 2026 evening bug).
- **My entries** — the scorer's recent entries with Correct / Delete.

### Admin
- **Session setup** (step by step): name & dates → teams (add/remove any number, names, colors with a
  live badge preview) → events (regular/special) and point rules (pre-filled from the 2026 rules) →
  review → **Go live**.
- **Copy from a previous session** to start the next one with the same teams/events.
- **Session status:** setup → live → final (locked) → archived; public on/off.
- **Staff:** add/deactivate, admin vs scorer.
- **Results:** edit/delete anyone's entries; view the audit log.
- **Export** the session as CSV and JSON at any time.

## 6. Reliability rules

- If the page can't load data it says so and offers **Retry**. It never shows an empty board as if it were real.
- If a save fails, the entry stays on screen with a clear error and Retry. Nothing is lost silently.
- Two scorers entering at once never overwrite each other, because each result is its own row.
- Deletes are soft (hidden, kept) and every change is in the audit log.
- Supabase's free plan pauses a project after about a week with no activity. The pre-camp checklist
  includes opening the dashboard and restoring it if needed.

## 7. Milestones

| # | Deliverable | Check before moving on |
|---|-------------|------------------------|
| M1 | Supabase project + schema + first admin; repo public; Pages on | Security tests pass locally; you can sign in to the Supabase dashboard |
| M2 | Admin session setup + staff management | You set up a test session with teams and events on your phone |
| M3 | Staff scoring screens | Two people log a test round at the same time; both entries land |
| M4 | Public views + TV mode | A parent-style phone with no login sees live standings |
| M5 | Export, polish, dry run | Replay a day of 2026 results; totals match the archive |
| Later | History (import 2026, past sessions, all-time records) | After MVP |

## 8. Open questions

1. Is the camp logo OK to show on the public page?

Decided: camp time zone is Central (America/Chicago). Parents see Team Analysis, with a per-session switch to hide it.

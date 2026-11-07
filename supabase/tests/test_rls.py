#!/usr/bin/env python3
"""Security and scoring tests for supabase/schema.sql against a local Postgres.

Usage:  python3 supabase/tests/test_rls.py            (needs psql + a server you can create DBs on)
        PGHOST=... PGPORT=... python3 supabase/tests/test_rls.py

Creates a throwaway database, loads the Supabase stub + schema, then runs each
case as parent (anon), scorer, admin, etc. and checks what is allowed.
"""
import os, subprocess, sys, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
DB = "ojibwa_test_" + uuid.uuid4().hex[:8]

ADMIN, S1, S2, INACTIVE, RANDO = (str(uuid.UUID(int=i)) for i in range(1, 6))
LIVE, SETUP = "aaaaaaaa-0000-0000-0000-000000000001", "aaaaaaaa-0000-0000-0000-000000000002"
T1, T2, T3, TX = ("bbbbbbbb-0000-0000-0000-00000000000" + c for c in "123x".replace("x", "9"))
BBALL, SWIM, TUG, XEV = ("cccccccc-0000-0000-0000-00000000000" + c for c in "1239")


def psql(sql, db=DB, role=None, sub=None):
    pre = ""
    if role:
        pre += f"set role {role};"
    if sub:
        pre += f"set request.jwt.claim.sub = '{sub}';"
    r = subprocess.run(["psql", "-X", "-q", "-tA", "-v", "ON_ERROR_STOP=1", "-d", db, "-c", pre + sql],
                       capture_output=True, text=True)
    return r.returncode == 0, (r.stdout.strip() or r.stderr.strip())


def load(path):
    r = subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", DB, "-f", path],
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"Failed loading {path}:\n{r.stderr}")


FIXTURES = f"""
insert into auth.users values ('{ADMIN}','admin@x'),('{S1}','s1@x'),('{S2}','s2@x'),
  ('{INACTIVE}','old@x'),('{RANDO}','rando@x');
insert into public.staff values ('{ADMIN}','Admin','admin',true),('{S1}','Scorer One','scorer',true),
  ('{S2}','Scorer Two','scorer',true),('{INACTIVE}','Old','scorer',false);
insert into public.sessions (id,name,status,is_public) values
  ('{LIVE}','The Week 2027','live',true),('{SETUP}','Hidden draft','setup',false);
insert into public.teams (id,session_id,name) values ('{T1}','{LIVE}','Army'),('{T2}','{LIVE}','Iowa'),
  ('{T3}','{LIVE}','USC'),('{TX}','{SETUP}','Draft Team');
insert into public.event_types (id,session_id,name,is_special) values ('{BBALL}','{LIVE}','Basketball',false),
  ('{SWIM}','{LIVE}','Swimming',true),('{TUG}','{LIVE}','Tug of War',false),('{XEV}','{SETUP}','Basketball',false);
insert into public.point_rules (session_id,level,event_type_id,points) values
  ('{LIVE}','SV',null,15),('{LIVE}','Team',null,15),('{LIVE}','Team','{TUG}',20);
"""


def save(session=LIVE, rnd=1, level="SV", ev=BBALL, kind="matchup", awards=None, w=T1, l=T2,
         note=None, replaces=None):
    awards = awards if awards is not None else [{"team_id": w, "points": 15}]
    import json
    a = json.dumps(awards).replace("'", "''")
    w_ = f"'{w}'" if w else "null"
    l_ = f"'{l}'" if l else "null"
    n_ = f"'{note}'" if note else "null"
    r_ = f"'{replaces}'" if replaces else "null"
    return (f"select public.save_result('{session}',{rnd},'2027-07-26','{level}','{ev}','{kind}',"
            f"'{a}'::jsonb,{w_},{l_},false,{n_},{r_});")


def total(team, role="anon", sub=None):
    ok, out = psql(f"select total from public.standings where team_id='{team}';", role=role, sub=sub)
    return out if ok else "ERR:" + out


results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"\n     -> {detail}"))


def main():
    subprocess.run(["createdb", DB], check=True)
    try:
        load(os.path.join(HERE, "supabase_stub.sql"))
        load(os.path.join(HERE, "..", "schema.sql"))
        ok, out = psql(FIXTURES)
        assert ok, out

        # --- parents (anon)
        ok, out = psql("select count(*) from public.standings;", role="anon")
        check("parent sees standings of public session only", ok and out == "3", out)
        ok, out = psql(f"select count(*) from public.sessions where id='{SETUP}';", role="anon")
        check("parent cannot see non-public session", ok and out == "0", out)
        ok, out = psql("select count(*) from public.staff;", role="anon")
        check("parent cannot read staff list", not ok, out)
        ok, out = psql("select count(*) from public.audit_log;", role="anon")
        check("parent cannot read audit log", not ok, out)
        ok, out = psql(save(), role="anon")
        check("parent cannot log a result", not ok, out)
        ok, out = psql(f"update public.teams set name='Hacked' where id='{T1}';", role="anon")
        check("parent cannot rename a team", not ok, out)

        # --- signed-in but not staff
        ok, out = psql(save(), role="authenticated", sub=RANDO)
        check("non-staff login cannot log a result", not ok, out)
        ok, out = psql(f"select count(*) from public.sessions where id='{SETUP}';", role="authenticated", sub=RANDO)
        check("non-staff login cannot see non-public session", ok and out == "0", out)

        # --- scorers
        ok, r1 = psql(save(), role="authenticated", sub=S1)
        check("scorer logs a matchup", ok, r1)
        check("standings update for parents", total(T1) == "15", total(T1))
        ok, out = psql(save(session=SETUP, ev=XEV, w=TX, l=None, awards=[{"team_id": TX}]),
                       role="authenticated", sub=S1)
        check("scorer cannot log into a session that isn't live", not ok, out)
        ok, out = psql(save(awards=[{"team_id": T3, "points": 15}]), role="authenticated", sub=S1)
        check("matchup points can't go to a team that didn't play", not ok, out)
        ok, out = psql(save(level="SV", ev=SWIM), role="authenticated", sub=S1)
        check("special event can't be logged at SV", not ok, out)
        ok, out = psql(save(ev=BBALL, w=T1, l=T1), role="authenticated", sub=S1)
        check("winner and loser must differ", not ok, out)
        ok, out = psql(f"insert into public.awards (result_id,session_id,team_id,points) "
                       f"values ('{r1}','{LIVE}','{T3}',100);", role="authenticated", sub=S1)
        check("scorer cannot write awards directly", not ok, out)
        ok, out = psql(f"update public.results set winner_team_id='{T2}' where id='{r1}';",
                       role="authenticated", sub=S1)
        check("scorer cannot edit results directly", not ok, out)
        ok, out = psql(f"insert into public.teams (session_id,name) values ('{LIVE}','Sneaky');",
                       role="authenticated", sub=S1)
        check("scorer cannot add teams", not ok, out)
        ok, out = psql(save(kind="adjustment", w=None, l=None, awards=[{"team_id": T1, "extras": 1}]),
                       role="authenticated", sub=S1)
        check("adjustment requires a note", not ok, out)
        ok, out = psql(save(kind="adjustment", w=None, l=None, note="Bonus point, ref call",
                            awards=[{"team_id": T1, "extras": 1}]), role="authenticated", sub=S1)
        check("adjustment with note works", ok and total(T1) == "16", out + " total=" + total(T1))
        ok, out = psql(save(), role="authenticated", sub=INACTIVE)
        check("deactivated staff cannot log", not ok, out)

        # ties / split points (Special placement)
        ok, out = psql(save(rnd=2, level="Special", ev=SWIM, kind="placement", w=None, l=None,
                            awards=[{"team_id": T2, "points": 2.5, "place": 5},
                                    {"team_id": T3, "points": 2.5, "place": 5}]),
                       role="authenticated", sub=S2)
        check("tied placement splits points", ok and total(T2) == "2.5" and total(T3) == "2.5", out)

        # corrections and deletes
        ok, out = psql(save(replaces=r1, awards=[{"team_id": T1, "points": 15, "extras": 2}]),
                       role="authenticated", sub=S2)
        check("scorer cannot correct someone else's result", not ok, out)
        ok, r1b = psql(save(replaces=r1, awards=[{"team_id": T1, "points": 15, "extras": 2}]),
                       role="authenticated", sub=S1)
        check("scorer corrects own result (old one replaced, counted once)", ok and total(T1) == "18",
              r1b + " total=" + total(T1))
        ok, out = psql(f"select count(*) from public.results where id='{r1}';", role="anon")
        check("replaced result hidden from parents", ok and out == "0", out)
        ok, out = psql(f"select public.delete_result('{r1b}');", role="authenticated", sub=S2)
        check("scorer cannot delete someone else's result", not ok, out)
        ok, out = psql(f"select public.delete_result('{r1b}');", role="authenticated", sub=S1)
        check("scorer deletes own result", ok and total(T1) == "1", out + " total=" + total(T1))
        ok, out = psql(f"select count(*) from public.results where id='{r1b}';", role="authenticated", sub=S2)
        check("staff still see deleted results", ok and out == "1", out)

        # admins
        ok, out = psql(f"insert into public.teams (session_id,name) values ('{LIVE}','Kansas');",
                       role="authenticated", sub=ADMIN)
        check("admin adds a team", ok, out)
        ok, out = psql(f"select public.delete_result(id) from public.results "
                       f"where created_by='{S2}' and deleted_at is null;", role="authenticated", sub=ADMIN)
        check("admin deletes another scorer's result", ok and total(T2) == "0", out)
        ok, out = psql(f"update public.sessions set status='final' where id='{LIVE}';",
                       role="authenticated", sub=S1)
        check("scorer cannot change session status", ok and "UPDATE" not in out, out)
        ok, out = psql(f"select status from public.sessions where id='{LIVE}';")
        check("...status unchanged", out == "live", out)
        ok, out = psql("select count(*) > 0 from public.audit_log;", role="authenticated", sub=ADMIN)
        check("admin reads audit log", ok and out == "t", out)
        ok, out = psql("select count(*) from public.audit_log;", role="authenticated", sub=S1)
        check("scorer cannot read audit log", ok and out == "0", out)
        ok, out = psql(f"select actor from public.audit_log where table_name='results' "
                       f"and action='INSERT' order by id limit 1;")
        check("audit log records who logged it", out == S1, out)

        # scoring defaults
        ok, out = psql(f"select public.default_points('{LIVE}','Team','{TUG}'), "
                       f"public.default_points('{LIVE}','Team','{BBALL}');")
        check("point rules: Tug of War 20, other Team events 15", out == "20|15", out)

        # session goes final -> scorers locked out
        psql(f"update public.sessions set status='final' where id='{LIVE}';")
        ok, out = psql(save(rnd=9), role="authenticated", sub=S1)
        check("no new results once session is final", not ok, out)
    finally:
        subprocess.run(["dropdb", DB])

    print(f"\n{sum(results)}/{len(results)} passed")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()

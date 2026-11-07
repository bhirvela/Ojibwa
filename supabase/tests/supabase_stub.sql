-- Minimal stand-in for the pieces of Supabase that schema.sql relies on, so the
-- schema and its security rules can be tested on a plain local Postgres.
-- NEVER run this on the real Supabase project.

create role anon nologin;
create role authenticated nologin;

create schema auth;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;

create publication supabase_realtime;

-- Supabase's default: API roles get full table/function privileges; RLS is the gate.
grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables    to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;

# Setup guide (one time, about 20 minutes)

You do steps 1–4. Send Claude only the two values marked **send this** in step 2.
**Never** share the database password, the secret/service_role key, or anyone's login password.

Supabase's screens change from time to time. If a label below doesn't match exactly, look for the
closest equivalent.

## 1. Create the Supabase project

1. Go to supabase.com and **Sign up** (signing in with GitHub is easiest).
2. Create an **organization** when asked (name it "Camp Ojibwa", plan **Free**).
3. **New project:**
   - Name: `camp-ojibwa-leaderboard`
   - Database password: click **Generate**, then save it in your password manager. You won't need it day to day.
   - Region: **East US** (or the region closest to camp).
4. Wait a couple of minutes for it to finish setting up.

## 2. Copy the two public connection values

Click **Connect** at the top of the project (or go to **Project Settings → API Keys / Data API**) and copy:

- **Project URL**, which looks like `https://abcdefgh.supabase.co`. **Send this.**
- **Publishable key**, which starts with `sb_publishable_`. Older projects call it the **anon public** key. **Send this.**

These two are designed to be public, because they go in the web page. Do **not** send the *secret* or *service_role* key.

## 3. Turn off public sign-ups

**Authentication → Sign In / Providers** (or **Authentication → Settings**):
- Turn **off** "Allow new users to sign up".
- Leave **Email** enabled as a provider.

This means only accounts you create can sign in.

## 4. Load the database and make yourself admin

1. **SQL Editor → New query**. Paste the full contents of `supabase/schema.sql` from this repo and click **Run**.
   It should finish with "Success. No rows returned".
2. **Authentication → Users → Add user → Create new user**: enter your email and a password, and tick **Auto Confirm User**.
3. Back in **SQL Editor → New query**, run this with your email and name filled in:

   ```sql
   insert into public.staff (user_id, display_name, role)
   select id, 'YOUR NAME', 'admin' from auth.users where email = 'you@example.com';
   ```

   It should report 1 row inserted. Counselor accounts get added later from the app's Admin screen.

## 5. GitHub (already decided: public repo + GitHub Pages)

1. github.com/bhirvela/Ojibwa → **Settings → General → Danger Zone → Change visibility → Public**.
   The repo holds code, team names and 2026 scores. No passwords or secret keys are ever committed.
2. **Settings → Pages → Build and deployment → Source: GitHub Actions.**
   Claude will add the deploy workflow when the site exists (milestone M2). The public link will be
   `https://bhirvela.github.io/Ojibwa/`.

## Before each summer (checklist)

- Open the Supabase dashboard. If the project shows **Paused**, click **Restore** (free projects pause after about a week of no use).
- Admin → copy the last session → update teams and events → add/reactivate counselor accounts → **Go live** on day one.
- Send parents the link.

## For developers: run the security tests

Requires Postgres 15+ and `psql` locally:

```bash
python3 supabase/tests/test_rls.py   # creates and drops a temporary database
```

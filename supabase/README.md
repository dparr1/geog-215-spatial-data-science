# geog215.org sign-in: email + password

Students sign in to https://geog215.org with **their own email and a password
they choose**. You add each student (name and email), which gives them a
one-time **setup code**; they use it once to choose their password. No email
is ever sent, so the UNC mail server doesn't matter.

- **First visit:** the student clicks *First time here?*, enters their email,
  their setup code and a new password. The `redeem-code` Edge Function checks
  that the email and code belong to the same student and creates their
  Supabase account (already confirmed, so no email goes out).
- **After that:** they sign in with email + password.
- **Forgotten password:** you allow a reset; they use *First time here?* again
  with the same email and setup code.
- **Progress:** every page a student opens is recorded in `page_progress`.
  The admin page shows it.

| File | What it is |
| --- | --- |
| `supabase/setup.sql` | Tables, security rules, progress tracking and the admin functions. Run in the SQL Editor. |
| `supabase/functions/redeem-code/index.ts` | First-time password setup and resets. Deployed as an Edge Function. |
| `assets/auth-gate.html` | The sign-in screen on every geog215.org page. |
| `admin/index.html` | Your admin page at https://geog215.org/admin/ (geog215.org only, never daveparr.com). |

## One-time setup

Do steps 1 to 3 **before** pushing changes to the sign-in screen: geog215.org
rebuilds on every push and the new screen needs them.

### 1. Run the database setup

Supabase dashboard > **SQL Editor** > New query > paste all of
`supabase/setup.sql` > **Run**. It's safe to re-run; it keeps your students,
instructors and progress.

### 2. Deploy the Edge Function

Re-deploy it whenever `supabase/functions/redeem-code/index.ts` changes.

**From the dashboard (no install):**

1. **Edge Functions** > `redeem-code` > **Code** (or, the first time,
   **Deploy a new function** > **Via Editor** and name it exactly
   `redeem-code`).
2. Replace all of the code with `supabase/functions/redeem-code/index.ts`, then
   **Deploy**.
3. On the function's **Details** (settings) tab, make sure *Enforce JWT
   verification* / *Verify JWT with legacy secret* is **off**. Students aren't
   signed in yet when they call it. Save.

**From a terminal with the Supabase CLI:**

```bash
supabase login
supabase functions deploy redeem-code --no-verify-jwt --project-ref liihdtyoqneslfbfgqml
```

No secrets to add: Supabase gives every Edge Function `SUPABASE_URL` and
`SUPABASE_SERVICE_ROLE_KEY` automatically.

### 3. Check Authentication settings

**Authentication > Sign In / Providers**

- **Email** provider: **enabled**. Everyone signs in with email + password, so
  with it off nobody (students or you) can sign in ("Email logins are
  disabled").
- **Allow new users to sign up**: **off**. The function still creates
  accounts (it uses the admin API), and the database also refuses any account
  that isn't a roster student setting up with their code, or an instructor.
- **Confirm email**: either setting is fine; accounts are created confirmed.

Resend/SMTP settings and email templates aren't used.

### 4. Set up your admin account

1. Add yourself as an instructor (lowercase email):
   ```sql
   insert into public.instructors (email) values ('you@unc.edu');
   ```
2. **Authentication > Users > Add user > Create new user**: the same email, a
   strong password, and tick **Auto Confirm User**. No email is sent.
3. Sign in at https://geog215.org/admin/.

To add another instructor, repeat with their email. To change your password,
open your user under **Authentication > Users**.

### 5. Test it yourself

On the admin page, add a test student with an email you can type (it never
receives mail), for example `Test Student, test@example.com`. Then, in a
private/incognito window, open https://geog215.org, click *First time here?*,
and use that email, its setup code and a password. Open a page or two; they
appear on the admin page under **Activity**. Delete the test student
afterwards.

## Admin page (https://geog215.org/admin/)

| Tab | |
| --- | --- |
| **Students** | Every student with their email, setup code, status, pages opened and last activity. Search by name, email or code; filter by group/term or status. **Lock out** / **Let back in**, **Allow password reset**, **Delete** (removes their account and progress). Click a name to see their activity. |
| **Add students** | Paste one student per line as `Name, email` (comma or tab, so two columns pasted from a spreadsheet or Canvas export work too), plus an optional group/term. Each gets a setup code; copy or download `name,email,setup_code` as CSV. Emails already on the roster are skipped. |
| **Activity** | The latest page opens, for everyone or one student. |
| **Pages** | How many students have opened each page. |

Send each student their setup code privately, for example as a Canvas
message. Codes are not case sensitive and can be typed with or without a dash.

While signed in to the admin page you can also read the book (instructors
count as approved), and your own page visits aren't recorded as progress.
Every button calls an `admin_*` function in Supabase that refuses to run
unless you're signed in as an instructor, so the page being public doesn't let
anyone else see or change anything.

To fix a typo in a student's email before they've set up their password,
delete them and add them again (they get a new code).

## Everyday tasks in SQL

The admin page does all of these; they're here in case you prefer the
**SQL Editor** (or **Table Editor > roster**).

```sql
-- Add students (each gets a random 8-character setup code, like K7MQ2XHP)
insert into public.roster (student_name, email, note) values
  ('Ada Lovelace', 'ada@unc.edu',   'Spring 2027'),
  ('Grace Hopper', 'grace@unc.edu', 'Spring 2027')
returning student_name, email, code;

-- Everyone, and whether they've set up a password
select student_name, email, note, code, user_id is not null as set_up, active
from public.roster order by student_name;

-- Forgotten password: they use "First time here?" again with email + code
update public.roster set allow_reset = true where email = 'ada@unc.edu';

-- Lock out (next page load) / let back in
update public.roster set active = false where email = 'ada@unc.edu';
update public.roster set active = true  where email = 'ada@unc.edu';

-- Every page each student has opened
select * from public.instructor_progress order by student_name, page;
```

Emails must be lowercase. **New term:** add the new students with a new
group/term, and lock out last term's.

## Security notes

- The roster, instructor list and everyone's progress can only be read by
  instructors (admin page) or from the dashboard. Students see only their own
  progress rows and can't edit them.
- A setup code only works together with the matching email, and only before
  the student has set a password (or after you allow a reset).
- The gate hides pages in the browser but doesn't encrypt them: the page text
  is still in the downloaded HTML, and the same book is public at
  daveparr.com/geog215/.
- Students who set up before email sign-in have accounts named
  `<code>@students.geog215.org`; they show as **No email** on the admin page.
  Delete and re-add them with their real email.

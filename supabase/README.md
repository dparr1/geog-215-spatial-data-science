# geog215.org sign-in: access codes

Students sign in to https://geog215.org with an **access code** you give them
and a password they choose. No email is ever sent, so the UNC mail server
doesn't matter.

- **First visit:** the student clicks *First time here?*, enters their code,
  and picks a password. The `redeem-code` Edge Function checks the code and
  creates their Supabase account.
- **After that:** they sign in with code + password.
- **Progress:** every page a student opens is recorded in `page_progress`
  under their Supabase user id. The `instructor_progress` view shows it with
  their name.

| File | What it is |
| --- | --- |
| `supabase/setup.sql` | Tables, security rules, and progress tracking. Run in the SQL Editor. |
| `supabase/functions/redeem-code/index.ts` | First-time sign-up and password resets. Deployed as an Edge Function. |
| `assets/auth-gate.html` | The sign-in screen on every geog215.org page. |
| `admin/index.html` | Your admin page at https://geog215.org/admin/ (geog215.org only, never daveparr.com). |

## One-time setup

Do steps 1 to 3 **before** merging the pull request. The merge redeploys
geog215.org with the new sign-in screen, and it needs these to exist.

### 1. Run the database setup

Supabase dashboard > **SQL Editor** > New query > paste all of
`supabase/setup.sql` > **Run**. It's safe to re-run later.

This also removes the old "approved emails only" sign-up rule. The old
`approved_emails` table is left in place; delete it whenever you like.

### 2. Deploy the Edge Function

Either way works.

**From the dashboard (no install):**

1. **Edge Functions** > **Deploy a new function** > **Via Editor**.
2. Name it exactly `redeem-code`.
3. Replace the sample code with all of
   `supabase/functions/redeem-code/index.ts`, then **Deploy function**.
4. Open the function's **Details** (settings) tab and turn **off**
   *Verify JWT with legacy secret* / *Enforce JWT verification*. Students
   aren't signed in yet when they call it, so it must accept calls without a
   login. Save.

**From a terminal with the Supabase CLI:**

```bash
supabase login
supabase functions deploy redeem-code --no-verify-jwt --project-ref liihdtyoqneslfbfgqml
```

No secrets to add: Supabase gives every Edge Function `SUPABASE_URL` and
`SUPABASE_SERVICE_ROLE_KEY` automatically.

### 3. Check Authentication settings

**Authentication > Sign In / Providers**

- **Email** provider: leave it **enabled** (the password sign-in uses it).
- **Allow new users to sign up**: turn it **off**. The function still creates
  accounts (it uses the admin API), and the database also refuses any account
  not made from a code, so this is a second lock on the door.
- **Confirm email**: either setting is fine; the function marks accounts
  confirmed itself.

**Authentication > Emails > SMTP Settings:** the Resend SMTP settings are no
longer used. You can leave or remove them.

### 4. Test it yourself

Add a test student (next section), open https://geog215.org after the merge
deploys, click *First time here?*, and use the test code. Then run
`select * from public.instructor_progress;` and you should see the page you
opened. Lock the test code afterwards
(`update public.roster set active = false where student_name = 'Test';`).

## Admin page (https://geog215.org/admin/)

A page for you to add, lock, reset and delete students and to see their
activity, without writing SQL. Only the geog215.org build includes it.

### One-time setup

1. **Re-run the database setup.** Paste all of `supabase/setup.sql` into the
   SQL Editor again and run it. It adds the `instructors` table and the
   `admin_*` functions the page uses; nothing else changes.
2. **Add yourself as an instructor** (lowercase email):
   ```sql
   insert into public.instructors (email) values ('you@unc.edu');
   ```
3. **Create your account:** **Authentication > Users > Add user > Create new
   user**, enter the same email and a strong password, and tick **Auto Confirm
   User**. No email is sent. (Sign-ups are off, and the database only accepts
   new accounts for roster codes or emails on the instructor list.)
4. Open https://geog215.org/admin/ and sign in with that email and password.

To add another instructor, repeat steps 2 and 3 with their email. To change
your password, use **Authentication > Users**, open your user, and send a
password recovery or set a new password there.

### What it does

| Tab | |
| --- | --- |
| **Students** | Every student with their code, status, pages opened and last activity. Search and filter by group/term or status. **Lock out** / **Let back in**, **Allow password reset**, **Delete** (removes their account and progress). Click a name to see their activity. |
| **Add students** | Paste names, one per line, plus an optional group/term. Each gets a code; copy or download them as CSV to send through Canvas. |
| **Activity** | The latest page opens, for everyone or one student. |
| **Pages** | How many students have opened each page. |

While signed in to the admin page you can also read the book (instructors
count as approved), and your own page visits aren't recorded as progress.

Every button calls an `admin_*` function in Supabase that refuses to run
unless you're signed in as an instructor, so the page being public doesn't let
anyone else see or change anything.

## Everyday tasks

The admin page does all of these. You can also run them in **SQL Editor**,
or browse and edit the `roster` table in **Table Editor**.

**Add students** (each gets a random 8-character code, like `K7MQ2XHP`):

```sql
insert into public.roster (student_name, note) values
  ('Ada Lovelace', 'Spring 2027'),
  ('Grace Hopper', 'Spring 2027')
returning student_name, code;
```

Copy the result and send each student their code privately, for example as a
Canvas message or a private Canvas grade comment. Codes are not case
sensitive, and students can type them with or without a dash.

To add a whole class, export the Canvas roster to CSV, then import the names
in **Table Editor > roster > Insert > Import data from CSV** (one column,
`student_name`, plus `note` if you like). Codes fill in automatically.

**See all codes and who has set up an account:**

```sql
select student_name, note, code, claimed_at is not null as set_up, active
from public.roster
order by student_name;
```

**Forgotten password.** Let the student choose a new one with the same code:

```sql
update public.roster set allow_reset = true where code = 'K7MQ2XHP';
```

Tell them to use *First time here?* again. Their progress is kept.

**Lock a student out** (takes effect on their next page load), or let them
back in:

```sql
update public.roster set active = false where code = 'K7MQ2XHP';
update public.roster set active = true  where code = 'K7MQ2XHP';
```

**Progress:**

```sql
-- Every page each student has opened
select * from public.instructor_progress order by student_name, page;

-- How many pages each student has opened, and when they were last active
select r.student_name,
       count(p.page)     as pages_opened,
       max(p.last_visit) as last_active
from public.roster r
left join public.page_progress p on p.user_id = r.user_id
group by r.student_name
order by r.student_name;
```

**Start a new term:** add the new students with a new `note`, and set
`active = false` for last term's codes. Deleting a student's account under
**Authentication > Users** also deletes their progress.

## Security notes

- The roster and everyone's progress can only be read from the dashboard.
  Students can see only their own progress rows and can't edit them.
- Like before, the gate hides pages in the browser but doesn't encrypt them.
  The page text is still in the downloaded HTML.
- Each student account's email is `<code>@students.geog215.org`. Nothing is
  ever sent to it.

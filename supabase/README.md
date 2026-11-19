# geog215.org sign-in: emailed code or link

Students sign in to https://geog215.org with **their email address**. There
are no passwords. They type their email, and Supabase emails them (through
Resend, from `mail.geog215.org`) a 6-digit code and a link:

- **Code:** they type it into the sign-in screen.
- **Link:** it opens the page they were on with a **Continue** button. The
  button is deliberate. UNC's mail (Microsoft 365 Safe Links) opens every
  link in an email to scan it, so a link that signed you in straight away
  would be used up before the student ever clicked it.

Only emails you've added to the roster (or the instructor list) can sign in.
The database refuses to create an account for any other email. The sign-in
screen shows the same "if this email is on the class list…" message either
way, so it can't be used to find out who is in the class.

Students stay signed in on that browser until they sign out. **Progress:**
the admin page shows three kinds of progress, all recorded by
`assets/auth-gate.html` for active students only (never instructors):

| What | Table | Recorded when |
| --- | --- | --- |
| Pages opened | `page_progress` | A student opens a page. |
| Self-check quiz answers | `quiz_responses` | A student picks or types an answer to a webexercises question (`mcq()`, `torf()`, `fitb()`, `longmcq()`). Typed answers are saved when they leave the box or stop typing for 2 seconds. It keeps the latest answer, the number of attempts, and whether they got it right at least once. |
| Code runs | `code_runs` | A student runs a webR cell with **Run Code** or Shift/Ctrl+Enter. Cells that run by themselves when the page loads don't count. It keeps the number of runs, how many ended in an R error, and the code as they last ran it. |

Questions and code cells are identified by their text (the question, or the
code a cell starts with), so adding or moving other questions doesn't mix up
their results. Editing a question's wording or a cell's starting code makes it
a new question or cell on the admin page.

| File | What it is |
| --- | --- |
| `supabase/setup.sql` | Tables, the sign-up rules, progress tracking and the admin functions. Run in the SQL Editor. |
| `assets/auth-gate.html` | The sign-in screen on every geog215.org page. |
| `admin/index.html` | Your admin page at https://geog215.org/admin/ (geog215.org only, never daveparr.com). |

## One-time setup

Do steps 1 to 5 **before** pushing changes to the sign-in screen, because
geog215.org rebuilds on every push and the new screen needs them.

### 1. Resend: send from geog215.org

1. resend.com > **Domains > Add Domain** > `mail.geog215.org`.
2. Add the DNS records Resend lists in Cloudflare (or use Resend's
   Cloudflare auto-configure). These are a DKIM `TXT` record, an SPF `TXT`
   record and an `MX` record. Set each one to **DNS only** (grey cloud).
   Also add a DMARC record (`TXT` at `_dmarc`, value `v=DMARC1; p=none;`),
   which helps delivery to unc.edu.
3. Wait until the domain shows **Verified**.
4. **API Keys > Create API key**, choose *Sending access*, and limit it to
   `mail.geog215.org`. Copy it.

### 2. Supabase: send auth email through Resend

**Authentication > Emails > SMTP Settings** > enable custom SMTP:

| Field | Value |
| --- | --- |
| Sender email | `login@mail.geog215.org` |
| Sender name | `GEOG 215` |
| Host | `smtp.resend.com` |
| Port | `465` |
| Username | `resend` |
| Password | the Resend API key |

Then go to **Authentication > Rate Limits** and raise *emails sent per hour*
(for example to 200). The default is tiny, and a class signing in on the
first day would hit it.

### 3. Supabase: URLs and providers

**Authentication > URL Configuration**

- **Site URL:** `https://geog215.org`
- **Redirect URLs:** add `https://geog215.org/**` (and
  `http://localhost:*/**` if you preview locally).

**Authentication > Sign In / Providers**

- **Email** provider: **enabled**.
- **Allow new users to sign up**: **on**. Each student's account is created
  the first time they ask for a code. `setup.sql` makes the database refuse
  anyone who isn't an active roster student or an instructor.
- **Confirm email**: either setting is fine.
- **Email OTP expiration**: 3600 seconds (1 hour) is a sensible value.

### 4. Supabase: email templates

**Authentication > Emails > Templates.** A student's *first* sign-in uses the
**Confirm signup** template, and every sign-in after that uses **Magic Link**.
Paste this into **both** (subject: `Your GEOG 215 sign-in code`):

```html
<h2>Sign in to the GEOG 215 textbook</h2>
<p>Your sign-in code is:</p>
<p style="font-size:28px;font-weight:bold;letter-spacing:6px">{{ .Token }}</p>
<p>Type it into the sign-in screen, or
  <a href="{{ .RedirectTo }}#token_hash={{ .TokenHash }}&type=email">open the textbook and click Continue</a>.</p>
<p>The code and link work once and expire in an hour. If you didn't ask to
  sign in, you can ignore this email.</p>
```

The link uses `#token_hash=…`, not Supabase's default `{{ .ConfirmationURL }}`.
That way nothing signs in until the student clicks **Continue**, and the token
never reaches Google Analytics or server logs.

### 5. Run the database setup

**SQL Editor** > New query > paste all of `supabase/setup.sql` > **Run**.
It's safe to re-run, and it keeps your students, instructors and progress.
It also:

- replaces the old "setup code only" sign-up rule with "roster or instructor
  email";
- links any existing accounts to their roster rows by email;
- removes the password-reset admin function.

Then **Edge Functions** > `redeem-code` > delete it. Nothing uses it any more.

### 6. Set up your admin account

1. Add yourself as an instructor (lowercase email):
   ```sql
   insert into public.instructors (email) values ('you@unc.edu');
   ```
2. Go to https://geog215.org/admin/, enter that email, and sign in with the
   emailed code. Your account is created the first time.

To add another instructor, insert their email the same way.

### 7. Test it yourself

1. On the admin page, add a test student with **an address you can read**,
   for example a personal Gmail address. In a private/incognito window, open
   https://geog215.org, enter it, and sign in once with the code and once
   with the link. Open a page or two; they should appear under **Activity**.
2. Do the same with a **unc.edu** address. Check that the email arrives (not
   in junk or quarantine) and that the link still works after UNC's scanner
   has seen it.
3. Delete the test students afterwards.

## Admin page (https://geog215.org/admin/)

| Tab | |
| --- | --- |
| **Students** | Every student with their email, status (*Has signed in* / *Not signed in yet* / *Locked out*), pages opened, quiz questions right (of those answered), code runs and last activity. Search by name or email, and filter by group/term or status. **Lock out** / **Let back in**, **Delete** (removes their account and progress). Click a name to see their activity, quiz answers and code runs. |
| **Add students** | Paste one student per line as `Name, email` (comma or tab, so two columns pasted from a spreadsheet or Canvas export work too), plus an optional group/term. Emails already on the roster are skipped. Added students can sign in straight away. |
| **Activity** | The latest page opens, for everyone or one student. |
| **Pages** | How many students have opened each page. |
| **Quizzes** | Each self-check question, by page: how many students answered it, how many got it right, and total attempts. Pick a student to see their last answer to each question. |
| **Code** | Each webR code cell, by page: how many students ran it, total runs, and how many ended in an error. Pick a student to see the code they last ran in each cell. |

Tell students to go to geog215.org and sign in with **the email you added**.
For most, that's their unc.edu address.

While signed in to the admin page you can also read the book (instructors
count as approved), and your own page visits aren't recorded as progress.
Every button calls an `admin_*` function in Supabase that refuses to run
unless you're signed in as an instructor, so the page being public doesn't
let anyone else see or change anything.

**Wrong email on the roster:** if the student hasn't signed in yet, delete
them and add them again with the right email. If they have signed in, do the
same; it also deletes their progress.

## Everyday tasks in SQL

The admin page does all of these. They're here in case you prefer the
**SQL Editor** (or **Table Editor > roster**).

```sql
-- Add students (they can sign in with that email straight away)
insert into public.roster (student_name, email, note) values
  ('Ada Lovelace', 'ada@unc.edu',   'Spring 2027'),
  ('Grace Hopper', 'grace@unc.edu', 'Spring 2027');

-- Everyone, and whether they've signed in yet
select student_name, email, note, user_id is not null as signed_in, active
from public.roster order by student_name;

-- Lock out (next page load) / let back in
update public.roster set active = false where email = 'ada@unc.edu';
update public.roster set active = true  where email = 'ada@unc.edu';

-- Every page each student has opened
select * from public.instructor_progress order by student_name, page;
```

Emails must be lowercase. **New term:** add the new students with a new
group/term, and lock out last term's.

## Troubleshooting

- **"No email arrived":** check junk/quarantine, and check that the address
  matches the roster exactly. In Resend, **Emails** shows each message and
  whether it was delivered, bounced or blocked. In Supabase, **Logs > Auth**
  shows the request.
- **"That sign-in link has expired":** the link was already used, or it's
  over an hour old. Ask for a new code. Typing the code always works, even
  when the link doesn't.
- **"Too many emails requested":** that's the Supabase rate limit (step 2),
  or Supabase's 60-second wait between codes for the same email.

## Security notes

- The roster, instructor list and everyone's progress can only be read by
  instructors (admin page) or from the dashboard. Students see only their own
  progress rows and can't edit them.
- Quiz answers are checked in the browser (the answers are in the page, as
  webexercises works), so a student who knows how could report a wrong answer
  as right. Treat the Quizzes tab as a record of practice, not a grade.
- Anyone can ask for a code for any email, but only the owner of that inbox
  receives it, and only roster or instructor emails get an account.
- The gate hides pages in the browser but doesn't encrypt them: the page text
  is still in the downloaded HTML, and the same book is public at
  daveparr.com/geog215/.
- Students who set up with the very first version of the sign-in have
  accounts named `<code>@students.geog215.org`; they show as **No email** on
  the admin page. Delete and re-add them with their real email.

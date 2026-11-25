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

**Several classes, one database.** Every roster row is an enrollment: a
student in one **course** (e.g. `geog215`) and **term** (e.g. `Fall 2026`).
Each class's site sends its course code (`SDS_COURSE` in
`assets/auth-gate.html`), so a student only gets into the classes they're on
the roster for, and all their progress is filed under that course and term.
The term comes from the student's roster row, never from the browser. The
same email can be in several classes or terms with one account. See
[Adding another class](#adding-another-class).
The database refuses to create an account for any other email. The sign-in
screen shows the same "if this email is on the class list…" message either
way, so it can't be used to find out who is in the class.

Students stay signed in on that browser until they sign out. **Progress:**
the admin page shows four kinds of progress, all recorded for active students
only (never instructors) through `assets/auth-gate.html`:

| What | Table | Recorded when |
| --- | --- | --- |
| Pages opened | `page_progress` | A student opens a page. |
| Chapter quizzes | `chapter_quiz_sessions`, `chapter_quiz_answers` | A student answers a question on a chapter quiz page (see `quizzes/README.md`). Each run through a quiz is a session, with its correct answers, incorrect answers, how many questions were right on the first try, and its score (+100 per right answer plus a 10-point bonus for each right answer in a row before it, -100 per wrong answer; worked out in `record_chapter_quiz_answer`). The second table keeps each student's totals for each question. |
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
| `assets/questions.html` | "Ask a question" on highlighted text, and the students' **My questions** list (see [Questions](#questions-on-highlighted-text)). |
| `assets/polls.html` | Poll and survey banner, the poll itself, and the students' **Polls** list (see [Polls and surveys](#polls-and-surveys)). |
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

- adds course and term to the roster and all progress tables, filing
  everything that was there before as `geog215`, `Fall 2026`;
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

The **Course** and **Term** pickers at the top choose what every tab shows.
The term starts on the course's newest term; pick **All terms** to see
everyone. The page remembers your choice on that browser. You only see the
courses you teach: an instructor whose `courses` is empty (null) sees every
course, and one with `courses = '{geog370}'` sees only GEOG 370.

| Tab | |
| --- | --- |
| **Questions** | Questions students asked about text they highlighted, newest first, with the number still open on the tab. Each shows the student, the page and section (the link opens that spot with the text marked), the highlighted text and the question. **Save answer** shows your answer to the student under *My questions*; **Close without answering** is for ones you dealt with in class or by email; **Reopen**, **Email student** and **Delete** do what they say. The badge says whether the email to you went out. |
| **Students** | Every student with their email, term, group, status (*Has signed in* / *Not signed in yet* / *Locked out*), pages opened, chapter quiz score and success, self-check questions right (of those answered), code runs and last activity. Search by name or email, and filter by group or status. **Lock out** / **Let back in** (this course only), **Delete** (removes them and their progress from this course and term, and their account too unless they're in another course or term). Click a name to see their activity, quiz answers and code runs. |
| **Polls** | Polls and surveys: write, open and close them, see results, and download responses as CSV or Excel. See [Polls and surveys](#polls-and-surveys). |
| **Add students** | Paste one student per line as `Name, email` (comma or tab, so two columns pasted from a spreadsheet or Canvas export work too), plus the term (required) and an optional group such as a section. They're added to the course picked in the header. Emails already on that course and term are skipped. Added students can sign in straight away, including students who already have an account from another term or class. |
| **Activity** | The latest page opens, for everyone or one student. |
| **Pages** | How many students have opened each page. |
| **Quiz scores** | A leaderboard of chapter quiz points: each student's rank, total score, score for each chapter, quizzes finished and best streak, highest total first. Filter by group. Click a name to see that student on the Chapter quizzes tab. |
| **Chapter quizzes** | Results from the quiz page after each chapter, for everyone or one student, and for all chapters or one. **Correct** and **incorrect** count every answer, including re-asks of missed questions, and **success** is correct answers as a share of all answers. *By chapter* gives class totals. *By student* gives each student's quizzes finished, correct and incorrect answers, success, best first-try score, total points for the chapter and best single-quiz score. *Questions* lists every question, hardest first. |
| **Self-checks** | Each self-check question in the chapters, by page: how many students answered it, how many got it right, and total attempts. Pick a student to see their last answer to each question. |
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

The admin page does most of these. They're here in case you prefer the
**SQL Editor** (or **Table Editor > roster**).

```sql
-- Add students to a course and term (they can sign in with that email straight away)
insert into public.roster (course, term, student_name, email) values
  ('geog215', 'Spring 2027', 'Ada Lovelace', 'ada@unc.edu'),
  ('geog215', 'Spring 2027', 'Grace Hopper', 'grace@unc.edu');

-- Everyone, and whether they've signed in yet
select course, term, student_name, email, user_id is not null as signed_in, active
from public.roster order by course, term, student_name;

-- Lock out of one course (next page load) / let back in
update public.roster set active = false
where course = 'geog215' and term = 'Spring 2027' and email = 'ada@unc.edu';

-- Every page each student has opened
select * from public.instructor_progress order by course, term, student_name, page;
```

Emails must be lowercase. **New term:** add the new students on the admin page
with the new term (for example `Spring 2027`), then lock out last term's:

```sql
update public.roster set active = false where course = 'geog215' and term = 'Fall 2026';
```

**Clearing out an old term** once you've exported what you need (Export to
CSV on the Students tab). This deletes that term's progress and roster rows;
accounts stay, so students in other terms or classes aren't affected:

```sql
delete from public.page_progress         where course = 'geog215' and term = 'Fall 2026';
delete from public.quiz_responses        where course = 'geog215' and term = 'Fall 2026';
delete from public.code_runs             where course = 'geog215' and term = 'Fall 2026';
delete from public.chapter_quiz_answers  where course = 'geog215' and term = 'Fall 2026';
delete from public.chapter_quiz_sessions where course = 'geog215' and term = 'Fall 2026';
delete from public.questions             where course = 'geog215' and term = 'Fall 2026';
delete from public.poll_responses        where course = 'geog215' and term = 'Fall 2026';
delete from public.roster                where course = 'geog215' and term = 'Fall 2026';
```

## Questions on highlighted text

A signed-in student highlights text in a chapter, and an **Ask a question**
button appears under it. They type a question and send it. The site saves it
in `public.questions` (with the highlighted text, page and section) and emails
it to you, one email per question:

- **From** `GEOG 215 Questions <questions@mail.geog215.org>`, **to** the
  course's `questions_email` (GEOG 215: `daveparr@unc.edu`), with the subject
  *New question on* and the page's title.
- It says "A student asked a question" and has the page and section, the
  highlighted text, the question, a link that opens the page with that text
  marked, and a link to the admin page. It deliberately leaves out the
  student's name and email address (UNC's mail filtering held emails that had
  them); the admin page's Questions tab shows who asked.

Answer on the admin page's **Questions** tab. Students see their questions and
your answers under **My questions** in the bottom-right corner of every page
(with a count of new answers). Students only ever see their own questions.

### Setting up the email (once)

1. **Resend > API Keys > Create API key**: name it `geog215 questions`, choose
   *Sending access*, and limit it to `mail.geog215.org`. Copy it.
2. **Supabase > SQL Editor**, with your key in place of `re_...`:
   ```sql
   select vault.create_secret('re_...', 'resend_api_key');
   ```
   This stores it encrypted in Supabase Vault. To replace it later:
   `select vault.update_secret((select id from vault.secrets where name = 'resend_api_key'), 're_new...');`
3. Run `supabase/setup.sql` (it turns on the `pg_net` extension that sends
   the email, and creates the table and functions).
4. Test it: on any chapter page, signed in through /admin/, highlight some
   text and ask a question. It's filed as *Instructor (test)*; check that the
   email arrives and that the Questions tab shows **Emailed**, then delete it.

Without the key, questions are still saved and shown on the admin page; the
Questions tab says *Email not sent: no resend_api_key in Vault*.

To send a course's questions somewhere else (or stop the emails):

```sql
update public.courses set questions_email = 'you@unc.edu' where course = 'geog215';
update public.courses set questions_email = null where course = 'geog215';  -- no emails
```

### Limits

Resend's free plan sends **100 emails a day**, shared with sign-in codes. So:

- Question emails stop after **60 in 24 hours** (all courses together), which
  leaves at least 40 for sign-in codes. Questions past that are still saved
  and appear on the Questions tab (*Email not sent: daily email limit*).
- One student can ask at most **20 questions in 24 hours**.

Both numbers are in `sds_question_email_daily_limit()` and
`sds_question_student_daily_limit()` in `setup.sql`. If the email limit
starts to bite, the emails could become one daily digest instead, or Resend
Pro ($20/month) has no daily cap.

## Polls and surveys

Short polls and longer surveys that students answer on the site. You write
them on the admin page's **Polls** tab; they're stored in `public.polls` and
`public.poll_questions`, and each student's answers in one row of
`public.poll_responses` (section 8 of `setup.sql`).

- **Draft** (where every new poll starts): students never see it.
- **Open**: every signed-in student it's for sees a banner at the top of
  every page until they take it (**Later** hides it until they open a new
  tab). A **Polls** button in the bottom-right corner lists every open poll,
  so they can go back and change their answers.
- **Closed**: hidden again, and answers can't be changed. Every answer is
  kept; **Reopen** brings it back.

A poll is for one term (pick it under **For**) or for every term. Question
types: **Pick one** (radio buttons), **Pick any** (checkboxes), **Scale**
(for example 1 to 5, with labels for the ends), **Short text** and
**Paragraph**. Pick one and Pick any can add an **Other** choice with a text
box. Mark a question **Required** and students can't submit without it.

Poll answers aren't anonymous: they're saved with the student's account,
and the admin page shows names. Students can read only their own.

On the Polls tab:

| Button | |
| --- | --- |
| **New poll** / **Edit** / **Copy** | Write or change a poll. Changing wording after students have answered is fine; removing a question leaves its answers out of the downloads. **Copy** is handy for reusing last term's survey. |
| **Open** / **Close** / **Back to draft** | Show the poll to students, or hide it. |
| **Results** | A summary of each question (counts and shares, the average for scales, every text answer with who wrote it) and a table of responses. Delete a single response there (for example your own test). |
| **CSV** / **Excel** | Download the responses for the term picked in the header: one row per student, one column per question (Pick any answers joined with `;`). The Excel file has a second *Summary* sheet with the counts. Your own test answers are left out unless you tick *Include instructor tests* on the Results view. |
| **Delete** | The poll and every response to it, in every term. Download first. |

**Try a poll yourself:** sign in at /admin/, open the poll, then open any
chapter. You see the banner too (marked *Instructor preview*); your answers
are saved as an instructor test, which the counts and downloads leave out.

`setup.sql` adds an example **Start-of-semester survey** (based on the
Fall 2026 Google Form) as a draft for every term, once. Edit it, open it when
you're ready, or delete it. Re-running `setup.sql` never re-adds or changes it.

A direct link opens a poll on any page: `https://geog215.org/preface.html?sds-poll=<poll id>`
(the id is in `public.polls`), for example from a Canvas announcement.

## Adding another class

Another class can use this same Supabase project, Resend domain and admin
page. Each class gets its own site (its own copy of the book's Quarto
project, or a different book).

1. **Add the course** (SQL Editor). The code is lowercase letters, numbers
   and dashes:
   ```sql
   insert into public.courses (course, title, site_url)
   values ('geog370', 'GEOG 370: Introduction to GIS', 'https://geog370.org');
   ```
2. **The class's site:** copy `assets/auth-gate.html` and change
   `SDS_COURSE` to the new code (`"geog370"`), plus the title and wording on
   the sign-in card. Include it the same way `_quarto-geog215.yml` does.
3. **Supabase > Authentication > URL Configuration:** add the new site to
   **Redirect URLs** (e.g. `https://geog370.org/**`), or the emailed link
   won't bring students back to it. The code in the email works either way.
4. **Questions email:** set where its questions go:
   `update public.courses set questions_email = 'you@unc.edu' where course = 'geog370';`
   Copy `assets/questions.html` along with the gate.
5. **Email template:** the sign-in email says "GEOG 215". Supabase has one
   template for the whole project, so make its wording general (for example
   "Sign in to your course textbook") once a second class uses it.
6. **Instructors:** you see every course already. To add an instructor for
   only the new class:
   ```sql
   insert into public.instructors (email, courses) values ('ta@unc.edu', '{geog370}');
   ```
   They use the same admin page (https://geog215.org/admin/) and see only
   their courses.
7. **Add students** on the admin page: pick the course in the header, then
   **Add students** with the term.

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
- Self-check and chapter quiz answers are checked in the browser (the answers
  are in the page and in `quizzes/*.json`), so a student who knows how could
  report a wrong answer as right. Treat the Self-checks and Chapter quizzes
  tabs as a record of practice, not a grade.
- Anyone can ask for a code for any email, but only the owner of that inbox
  receives it, and only roster or instructor emails get an account.
- The gate hides pages in the browser but doesn't encrypt them: the page text
  is still in the downloaded HTML, and the same book is public at
  daveparr.com/intro-spatial-data-science/.
- Students who set up with the very first version of the sign-in have
  accounts named `<code>@students.geog215.org`; they show as **No email** on
  the admin page. Delete and re-add them with their real email.

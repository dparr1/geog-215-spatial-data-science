-- Course textbooks (GEOG 215 and any other class that uses this database):
-- students sign in with an emailed one-time code or link (no passwords).
--
-- Run once in the Supabase dashboard: SQL Editor > New query > paste > Run.
-- Safe to re-run. Step-by-step setup is in supabase/README.md.
--
-- How it works
--   1. courses lists each class that uses this database, by a short code
--      (e.g. geog215). Each class's site sends its code with everything it
--      records (SDS_COURSE in assets/auth-gate.html).
--   2. roster holds one row per enrollment: a student's name and email in
--      one course and term (plus a random `code` that the admin page uses as
--      the row's id; students never see it). The same email can be on the
--      roster for several courses or terms. Row-level security is on with no
--      policies, so the browser (anon or signed-in) can never read it. Add
--      students on the admin page (geog215.org/admin/), in Table Editor, or
--      with SQL.
--   3. A student enters their email on the sign-in screen and Supabase emails
--      them a code and link (sent through Resend). The first time, that
--      creates their Supabase account, and a trigger links it to every roster
--      row with that email. Rows added later for an email that already has an
--      account are linked when they're added.
--   4. A trigger on auth.users refuses any new account whose email isn't an
--      active, not-yet-linked roster row or an instructor, so nobody else
--      can get in by asking for a code.
--   5. is_current_user_approved(course) lets a signed-in student ask "am I
--      still an active student in this course?" (only about themselves). The
--      book calls it on every page load, so setting active = false locks
--      someone out of that course.
--   6. Progress (pages, self-checks, code runs, chapter quizzes) is keyed by
--      Supabase user id, course and term. The browser sends only the course;
--      the term comes from the student's newest active roster row for that
--      course. Students can only see their own rows; the admin page shows
--      them with names, one course at a time.
--   7. Instructors see the courses listed in instructors.courses, or every
--      course when that is empty (null).
--   8. Polls and surveys (section 8) are written and opened on the admin
--      page; students answer them on the site and see only their own answers.
--   9. Push notifications (section 9): students who turn them on are saved
--      as push subscriptions (one row per device and course); the admin
--      page's Announcements tab sends to them through the `push` Edge
--      Function (supabase/functions/push/).
--  10. Exercise answer keys (section 10) are in a private Storage bucket.
--  11. Weekly quiz leaderboard (section 11): after a quiz, students see the
--      top 10 of the week (ending Friday) in their course and term, with
--      classmates' names hidden unless they opt in; the admin page's Weekly
--      quiz tab shows every student's weekly score.
--
-- Upgrading from the one-class version: running this file adds course and
-- term to the roster and every progress table, and fills them in for the
-- existing rows as course 'geog215', term 'Fall 2026' (see 2a). Run it before
-- deploying the matching site, because the new site sends the course code.

create extension if not exists pgcrypto with schema extensions;

-- 0. Retire the old approved-email sign-in -----------------------------------
-- The old trigger rejected every account whose email wasn't on
-- approved_emails, which would block the access-code accounts. The
-- approved_emails table itself is left alone; drop it when you no longer need
-- it:  drop table if exists public.approved_emails;
drop trigger if exists enforce_approved_signup on auth.users;
drop function if exists public.enforce_approved_signup();

-- 1. Access codes -------------------------------------------------------------
-- 8 characters from a 32-symbol alphabet with no look-alikes (no 0/O, 1/I),
-- drawn from a cryptographic random source: about a trillion possibilities.
create or replace function public.new_access_code()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  -- 32 symbols, so each random byte maps evenly (256 / 32 = 8).
  alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  b bytea;
  result text := '';
begin
  b := extensions.gen_random_bytes(8);
  for i in 0..7 loop
    result := result || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  return result;
end;
$$;

revoke all on function public.new_access_code() from public, anon, authenticated;

-- 1b. Courses -----------------------------------------------------------------
-- One row per class. The code is what that class's site sends (SDS_COURSE in
-- its copy of assets/auth-gate.html). Add a class with SQL, for example:
--   insert into public.courses (course, title, site_url)
--   values ('geog370', 'GEOG 370: Intro to GIS', 'https://geog370.org');
create table if not exists public.courses (
  course   text primary key check (course ~ '^[a-z0-9][a-z0-9-]{1,31}$'),
  title    text not null,
  site_url text,                               -- e.g. https://geog215.org
  added_at timestamptz not null default now()
);

insert into public.courses (course, title, site_url)
values ('geog215', 'GEOG 215: Introduction to Spatial Data Science', 'https://geog215.org')
on conflict (course) do nothing;

alter table public.courses enable row level security;
revoke all on table public.courses from anon, authenticated;

-- 2. The class roster ---------------------------------------------------------
-- One row per student per course and term.
create table if not exists public.roster (
  code         text primary key default public.new_access_code()
               check (code ~ '^[A-Z0-9]{6,16}$'),
  course       text not null references public.courses (course) on update cascade,
  term         text not null,                -- e.g. Fall 2026
  student_name text not null,
  email        text                          -- the student's sign-in email
               check (email = lower(btrim(email))),
  note         text,                         -- e.g. section, onyen
  active       boolean not null default true, -- false = locked out of this course
  allow_reset  boolean not null default false,-- unused since passwords were retired
  user_id      uuid references auth.users (id) on delete set null,
  claimed_at   timestamptz,                  -- when they first signed in
  added_at     timestamptz not null default now()
);

-- Rosters created before email sign-in: add the email column.
alter table public.roster add column if not exists email text;
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.roster'::regclass and conname = 'roster_email_check') then
    alter table public.roster add constraint roster_email_check check (email = lower(btrim(email)));
  end if;
end;
$$;

-- 2a. Upgrade from the one-class version ---------------------------------------
-- Rows from before courses and terms existed all belong to GEOG 215, Fall 2026.
-- Each block runs only once, when its table doesn't have a course column yet.
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'roster'
                   and column_name = 'course') then
    alter table public.roster
      add column course text references public.courses (course) on update cascade,
      add column term   text;
    update public.roster set course = 'geog215', term = 'Fall 2026';
    alter table public.roster
      alter column course set not null,
      alter column term   set not null;
  end if;

  -- An email (or account) is unique within a course and term, not overall.
  alter table public.roster drop constraint if exists roster_email_key;
  alter table public.roster drop constraint if exists roster_user_id_key;
  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.roster'::regclass and conname = 'roster_enrollment_email_key') then
    alter table public.roster
      add constraint roster_enrollment_email_key unique (course, term, email);
  end if;
  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.roster'::regclass and conname = 'roster_enrollment_user_key') then
    alter table public.roster
      add constraint roster_enrollment_user_key unique (course, term, user_id);
  end if;
  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.roster'::regclass and conname = 'roster_term_check') then
    alter table public.roster
      add constraint roster_term_check check (term = btrim(term) and term <> '' and length(term) <= 40);
  end if;
end;
$$;

create index if not exists roster_user_idx on public.roster (user_id);
create index if not exists roster_email_idx on public.roster (email);

alter table public.roster enable row level security;
revoke all on table public.roster from anon, authenticated;

-- 2b. Instructors (the admin page at geog215.org/admin/) ----------------------
-- Add your email here, then sign in at geog215.org/admin/ with the emailed
-- code. See supabase/README.md. courses limits an instructor to some courses,
-- e.g. '{geog370}'; leave it null for every course.
create table if not exists public.instructors (
  email    text primary key check (email = lower(btrim(email))),
  courses  text[],                            -- null = every course
  added_at timestamptz not null default now()
);

alter table public.instructors add column if not exists courses text[];

alter table public.instructors enable row level security;
revoke all on table public.instructors from anon, authenticated;

-- "Am I an instructor?" for the signed-in user: of this course, or of any
-- course when p_course is null. Every admin function below checks this, so
-- the admin page can't do anything for anyone else.
drop function if exists public.is_instructor();
create or replace function public.is_instructor(p_course text default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from public.instructors i
    where i.email = lower(btrim(auth.jwt() ->> 'email'))
      and (p_course is null or i.courses is null
           or lower(btrim(p_course)) = any (i.courses))
  );
$$;

revoke all on function public.is_instructor(text) from public, anon;
grant execute on function public.is_instructor(text) to authenticated;

-- 3. Only roster students and instructors can get an account -----------------
-- Asking for a sign-in code with an unknown email tries to create an account;
-- this refuses it (the sign-in screen shows the same message either way).
create or replace function public.enforce_roster_signup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.instructors i
    where i.email = lower(btrim(new.email))
  ) then
    return new;
  end if;

  if not exists (
    select 1 from public.roster r
    where r.email = lower(btrim(new.email))
      and r.active
      and r.user_id is null
  ) then
    raise exception 'This email is not on a class list.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_roster_signup on auth.users;
create trigger enforce_roster_signup
  before insert on auth.users
  for each row execute function public.enforce_roster_signup();

-- Link each new account to its roster rows (every course and term).
create or replace function public.link_roster_account()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.roster r
  set user_id = new.id, claimed_at = coalesce(r.claimed_at, now())
  where r.email = lower(btrim(new.email)) and r.user_id is null;
  return new;
end;
$$;

drop trigger if exists link_roster_account on auth.users;
create trigger link_roster_account
  after insert on auth.users
  for each row execute function public.link_roster_account();

-- A roster row added (or given a new email) for someone who already has an
-- account, for example a student from last term or another class: link it
-- straight away, since they won't be creating an account again.
create or replace function public.link_roster_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.user_id is null and new.email is not null then
    select u.id into new.user_id
    from auth.users u
    where lower(btrim(u.email)) = new.email
    limit 1;
    if new.user_id is not null then
      new.claimed_at := coalesce(new.claimed_at, now());
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.link_roster_row() from public, anon, authenticated;

drop trigger if exists link_roster_row on public.roster;
create trigger link_roster_row
  before insert or update of email on public.roster
  for each row execute function public.link_roster_row();

-- Roster rows whose account already exists but isn't linked (for example an
-- account you made by hand in the dashboard).
update public.roster r
set user_id = u.id, claimed_at = coalesce(r.claimed_at, now())
from auth.users u
where r.user_id is null
  and r.email = lower(btrim(u.email));

-- 4. "Am I an active student?" for the signed-in user only --------------------
-- The caller's newest active enrollment in a course (or in any course when
-- p_course is null). The record_* functions use its term.
create or replace function public.current_enrollment(p_course text default null)
returns table (course text, term text)
language sql
stable
security definer
set search_path = ''
as $$
  select r.course, r.term
  from public.roster r
  where r.user_id = auth.uid() and r.active
    and (p_course is null or r.course = lower(btrim(p_course)))
  order by r.added_at desc, r.code
  limit 1;
$$;

revoke all on function public.current_enrollment(text) from public, anon, authenticated;

-- Instructors of the course count too, so you can read the book while signed
-- in to /admin/.
drop function if exists public.is_current_user_approved();
create or replace function public.is_current_user_approved(p_course text default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.current_enrollment(p_course))
      or public.is_instructor(p_course);
$$;

revoke all on function public.is_current_user_approved(text) from public, anon;
grant execute on function public.is_current_user_approved(text) to authenticated;

-- 5. Progress -----------------------------------------------------------------
-- Every progress table has course and term, filled in by the record_*
-- functions from the student's enrollment (current_enrollment above).
create table if not exists public.page_progress (
  user_id     uuid not null default auth.uid()
              references auth.users (id) on delete cascade,
  course      text not null references public.courses (course) on update cascade,
  term        text not null,
  page        text not null,                 -- e.g. /chapters/census-data-apis
  first_visit timestamptz not null default now(),
  last_visit  timestamptz not null default now(),
  visits      integer not null default 1,
  primary key (user_id, course, term, page)
);

-- 5a. Upgrade from the one-class version: add course and term to a progress
-- table, fill them in as GEOG 215, Fall 2026, and put them in its key. Runs
-- once per table (only while the table has no course column).
create or replace function public.sds_add_course_term(p_table text, p_key text)
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = p_table
               and column_name = 'course') then
    return;
  end if;
  execute format('alter table public.%I
                    add column course text references public.courses (course) on update cascade,
                    add column term text', p_table);
  execute format('update public.%I set course = %L, term = %L', p_table, 'geog215', 'Fall 2026');
  execute format('alter table public.%I alter column course set not null,
                                         alter column term set not null', p_table);
  if p_key is not null then
    execute format('alter table public.%I drop constraint %I, add primary key (%s)',
                   p_table, p_table || '_pkey', p_key);
  end if;
end;
$$;

revoke all on function public.sds_add_course_term(text, text) from public, anon, authenticated;

select public.sds_add_course_term('page_progress', 'user_id, course, term, page');

alter table public.page_progress enable row level security;
revoke all on table public.page_progress from anon, authenticated;
grant select on table public.page_progress to authenticated;

drop policy if exists "Students read their own progress" on public.page_progress;
create policy "Students read their own progress"
  on public.page_progress for select
  to authenticated
  using (user_id = (select auth.uid()));

-- Students write progress only through this function, so they can't edit
-- their own counts or anyone else's. p_course is the site's course code; old
-- pages that don't send one count toward the student's newest enrollment.
drop function if exists public.record_page_visit(text);
create or replace function public.record_page_visit(p_page text, p_course text default null)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  -- One name per page: "/intro.html" and "/intro" are the same page, and so
  -- are "/index.html" and "/".
  v_page text := regexp_replace(
    regexp_replace(left(coalesce(p_page, '/'), 300), '\.html$', ''),
    '(^|/)index$', '\1');
  v_course text;
  v_term   text;
begin
  -- Only active students of this course; instructors' visits aren't recorded.
  if auth.uid() is null or public.is_instructor() then
    return;
  end if;
  select e.course, e.term into v_course, v_term from public.current_enrollment(p_course) e;
  if v_course is null then
    return;
  end if;
  if v_page = '' then v_page := '/'; end if;
  insert into public.page_progress as p (user_id, course, term, page)
  values (auth.uid(), v_course, v_term, v_page)
  on conflict (user_id, course, term, page) do update
    set last_visit = now(), visits = p.visits + 1;
end;
$$;

revoke all on function public.record_page_visit(text, text) from public, anon;
grant execute on function public.record_page_visit(text, text) to authenticated;

-- For you (SQL Editor / Table Editor only; students can't read it).
drop view if exists public.instructor_progress;
create view public.instructor_progress
with (security_invoker = true) as
select r.course,
       r.term,
       r.student_name,
       r.note,
       r.code,
       p.page,
       p.first_visit,
       p.last_visit,
       p.visits
from public.roster r
join public.page_progress p
  on p.user_id = r.user_id and p.course = r.course and p.term = r.term;

revoke all on table public.instructor_progress from anon, authenticated;

-- 5b. Self-check quiz answers and code runs -------------------------------------
-- The book's webexercises questions and webR code cells report here through
-- record_quiz_answer() and record_code_run() (called by assets/auth-gate.html).
-- Like page_progress: one row per student, course, term and question (or code
-- cell) with running totals; students only see their own rows.
-- Whether an answer was correct is decided in the browser (the answers are in
-- the page), so treat it as a self-check record, not a grade.

create table if not exists public.quiz_responses (
  user_id          uuid not null default auth.uid()
                   references auth.users (id) on delete cascade,
  course           text not null references public.courses (course) on update cascade,
  term             text not null,
  page             text not null,
  question         text not null,          -- id made in the browser from the question text
  label            text,                   -- the question text, for the admin page
  attempts         integer not null default 1,
  correct          boolean not null,       -- was the latest answer right?
  ever_correct     boolean not null,       -- right at least once
  last_answer      text,
  first_at         timestamptz not null default now(),
  first_correct_at timestamptz,
  last_at          timestamptz not null default now(),
  primary key (user_id, course, term, page, question)
);

create table if not exists public.code_runs (
  user_id    uuid not null default auth.uid()
             references auth.users (id) on delete cascade,
  course     text not null references public.courses (course) on update cascade,
  term       text not null,
  page       text not null,
  cell       text not null,                -- id made in the browser from the cell's starting code
  label      text,                         -- section heading and first line of code
  runs       integer not null default 1,
  error_runs integer not null default 0,   -- runs that ended in an R error
  last_code  text,                         -- the code as last run (first 4000 characters)
  last_error boolean not null default false,
  first_run  timestamptz not null default now(),
  last_run   timestamptz not null default now(),
  primary key (user_id, course, term, page, cell)
);

select public.sds_add_course_term('quiz_responses', 'user_id, course, term, page, question');
select public.sds_add_course_term('code_runs', 'user_id, course, term, page, cell');

alter table public.quiz_responses enable row level security;
alter table public.code_runs enable row level security;
revoke all on table public.quiz_responses from anon, authenticated;
revoke all on table public.code_runs from anon, authenticated;
grant select on table public.quiz_responses to authenticated;
grant select on table public.code_runs to authenticated;

drop policy if exists "Students read their own quiz answers" on public.quiz_responses;
create policy "Students read their own quiz answers"
  on public.quiz_responses for select
  to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "Students read their own code runs" on public.code_runs;
create policy "Students read their own code runs"
  on public.code_runs for select
  to authenticated
  using (user_id = (select auth.uid()));

-- Same rule as record_page_visit: active students of the course only, never
-- instructors.
drop function if exists public.record_quiz_answer(text, text, text, text, boolean);
create or replace function public.record_quiz_answer(
  p_page text, p_question text, p_label text, p_answer text, p_correct boolean,
  p_course text default null)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_page     text := public.normalize_page(left(p_page, 300));
  v_question text := left(btrim(coalesce(p_question, '')), 100);
  v_correct  boolean := coalesce(p_correct, false);
  v_course   text;
  v_term     text;
begin
  if auth.uid() is null or public.is_instructor() or v_question = '' then
    return;
  end if;
  select e.course, e.term into v_course, v_term from public.current_enrollment(p_course) e;
  if v_course is null then
    return;
  end if;
  insert into public.quiz_responses as q
    (user_id, course, term, page, question, label, correct, ever_correct, last_answer, first_correct_at)
  values (auth.uid(), v_course, v_term, v_page, v_question, left(p_label, 500), v_correct, v_correct,
          left(p_answer, 500), case when v_correct then now() end)
  on conflict (user_id, course, term, page, question) do update
    set attempts         = q.attempts + 1,
        label            = coalesce(excluded.label, q.label),
        correct          = excluded.correct,
        ever_correct     = q.ever_correct or excluded.correct,
        last_answer      = excluded.last_answer,
        first_correct_at = coalesce(q.first_correct_at, excluded.first_correct_at),
        last_at          = now();
end;
$$;

drop function if exists public.record_code_run(text, text, text, text, boolean);
create or replace function public.record_code_run(
  p_page text, p_cell text, p_label text, p_code text, p_error boolean,
  p_course text default null)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_page   text := public.normalize_page(left(p_page, 300));
  v_cell   text := left(btrim(coalesce(p_cell, '')), 100);
  v_error  boolean := coalesce(p_error, false);
  v_course text;
  v_term   text;
begin
  if auth.uid() is null or public.is_instructor() or v_cell = '' then
    return;
  end if;
  select e.course, e.term into v_course, v_term from public.current_enrollment(p_course) e;
  if v_course is null then
    return;
  end if;
  insert into public.code_runs as c
    (user_id, course, term, page, cell, label, error_runs, last_code, last_error)
  values (auth.uid(), v_course, v_term, v_page, v_cell, left(p_label, 300), v_error::int,
          left(p_code, 4000), v_error)
  on conflict (user_id, course, term, page, cell) do update
    set runs       = c.runs + 1,
        error_runs = c.error_runs + excluded.error_runs,
        label      = coalesce(excluded.label, c.label),
        last_code  = excluded.last_code,
        last_error = excluded.last_error,
        last_run   = now();
end;
$$;

revoke all on function public.record_quiz_answer(text, text, text, text, boolean, text) from public, anon;
grant execute on function public.record_quiz_answer(text, text, text, text, boolean, text) to authenticated;
revoke all on function public.record_code_run(text, text, text, text, boolean, text) from public, anon;
grant execute on function public.record_code_run(text, text, text, text, boolean, text) to authenticated;

-- 5c. Chapter quizzes -------------------------------------------------------------
-- The quiz page after each chapter (assets/quiz/quiz.js) asks about 10 random
-- questions from that chapter's bank, then re-asks the ones a student got wrong
-- until all are right. Every answer counts: "correct" and "incorrect" include
-- the re-asks, so success = correct / (correct + incorrect). Each run through a
-- quiz is a session; students can take as many as they like.
--
-- Score (worked out here, not in the browser): every answer, re-asks included,
-- is +100 if right and -100 if wrong. A right answer also earns a streak bonus
-- of 10 for each right answer in a row just before it in the same quiz, so a
-- run of right answers scores 100, 110, 120, 130, ... A wrong answer resets the
-- streak to 0, and each new quiz starts at 0. A student's total score is the sum
-- over all their quizzes. assets/quiz/quiz.js shows the same numbers to the
-- student as they go (QUIZ_POINTS there must match these).

create table if not exists public.chapter_quiz_sessions (
  id                uuid primary key,             -- made in the browser
  user_id           uuid not null default auth.uid()
                    references auth.users (id) on delete cascade,
  course            text not null references public.courses (course) on update cascade,
  term              text not null,
  chapter           text not null,                -- the bank's id, e.g. r-rstudio-rmarkdown
  chapter_title     text,
  questions         integer not null default 0,   -- questions in this session
  correct           integer not null default 0,
  incorrect         integer not null default 0,
  first_try_correct integer not null default 0,   -- right the first time they were asked
  score             integer not null default 0,   -- points, see above
  streak            integer not null default 0,   -- right answers in a row right now
  best_streak       integer not null default 0,
  started_at        timestamptz not null default now(),
  last_at           timestamptz not null default now(),
  completed_at      timestamptz                   -- null until every question is right
);

-- Scores were added in November 2026. Sessions from before then get 100 per
-- right answer and -100 per wrong one (the order of their answers wasn't kept,
-- so no streak bonus). This runs only the first time, when the column is added.
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'chapter_quiz_sessions'
                   and column_name = 'score') then
    alter table public.chapter_quiz_sessions
      add column score       integer not null default 0,
      add column streak      integer not null default 0,
      add column best_streak integer not null default 0;
    update public.chapter_quiz_sessions set score = 100 * (correct - incorrect);
  end if;
end;
$$;

-- Sessions keep their own id as the key; course and term are just columns.
select public.sds_add_course_term('chapter_quiz_sessions', null);

drop index if exists public.chapter_quiz_sessions_user_idx;
create index if not exists chapter_quiz_sessions_enrollment_idx
  on public.chapter_quiz_sessions (user_id, course, term, chapter);

-- Running totals for each student and question, across all their sessions.
create table if not exists public.chapter_quiz_answers (
  user_id           uuid not null default auth.uid()
                    references auth.users (id) on delete cascade,
  course            text not null references public.courses (course) on update cascade,
  term              text not null,
  chapter           text not null,
  question          text not null,                -- the question's id in the bank
  label             text,                         -- the question text, for the admin page
  correct           integer not null default 0,
  incorrect         integer not null default 0,
  first_try_correct integer not null default 0,
  first_try_total   integer not null default 0,   -- times it was asked fresh
  last_at           timestamptz not null default now(),
  primary key (user_id, course, term, chapter, question)
);

select public.sds_add_course_term('chapter_quiz_answers', 'user_id, course, term, chapter, question');

alter table public.chapter_quiz_sessions enable row level security;
alter table public.chapter_quiz_answers enable row level security;
revoke all on table public.chapter_quiz_sessions from anon, authenticated;
revoke all on table public.chapter_quiz_answers from anon, authenticated;
grant select on table public.chapter_quiz_sessions to authenticated;
grant select on table public.chapter_quiz_answers to authenticated;

drop policy if exists "Students read their own quiz sessions" on public.chapter_quiz_sessions;
create policy "Students read their own quiz sessions"
  on public.chapter_quiz_sessions for select
  to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "Students read their own chapter quiz answers" on public.chapter_quiz_answers;
create policy "Students read their own chapter quiz answers"
  on public.chapter_quiz_answers for select
  to authenticated
  using (user_id = (select auth.uid()));

-- One answer. The first answer of a session creates the session row, in the
-- student's current enrollment for the course.
drop function if exists public.record_chapter_quiz_answer(uuid, text, text, integer, text, text, boolean, boolean);
create or replace function public.record_chapter_quiz_answer(
  p_session uuid, p_chapter text, p_chapter_title text, p_size integer,
  p_question text, p_label text, p_correct boolean, p_first_try boolean,
  p_course text default null)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_chapter  text := left(btrim(coalesce(p_chapter, '')), 100);
  v_question text := left(btrim(coalesce(p_question, '')), 100);
  v_correct  boolean := coalesce(p_correct, false);
  v_first    boolean := coalesce(p_first_try, false);
  v_course   text;
  v_term     text;
begin
  if auth.uid() is null or public.is_instructor()
     or p_session is null or v_chapter = '' or v_question = '' then
    return;
  end if;
  select e.course, e.term into v_course, v_term from public.current_enrollment(p_course) e;
  if v_course is null then
    return;
  end if;

  insert into public.chapter_quiz_sessions (id, user_id, course, term, chapter, chapter_title, questions)
  values (p_session, auth.uid(), v_course, v_term, v_chapter, left(p_chapter_title, 200),
          least(greatest(coalesce(p_size, 0), 0), 100))
  on conflict (id) do nothing;

  -- Only the student's own, unfinished session (a session id can't be reused
  -- to add answers to someone else's). Its course and term are used for the
  -- question totals, so a session never straddles two enrollments.
  -- Score: +100 plus 10 per right answer in a row before this one, or -100.
  -- (The right-hand sides all see the row as it was before this update.)
  update public.chapter_quiz_sessions s
  set correct           = s.correct + v_correct::int,
      incorrect         = s.incorrect + (not v_correct)::int,
      first_try_correct = s.first_try_correct + (v_correct and v_first)::int,
      score             = s.score + case when v_correct then 100 + 10 * s.streak else -100 end,
      streak            = case when v_correct then s.streak + 1 else 0 end,
      best_streak       = case when v_correct then greatest(s.best_streak, s.streak + 1)
                               else s.best_streak end,
      last_at           = now()
  where s.id = p_session and s.user_id = auth.uid() and s.completed_at is null
  returning s.course, s.term into v_course, v_term;
  if not found then
    return;
  end if;

  insert into public.chapter_quiz_answers as a
    (user_id, course, term, chapter, question, label, correct, incorrect, first_try_correct, first_try_total)
  values (auth.uid(), v_course, v_term, v_chapter, v_question, left(p_label, 500),
          v_correct::int, (not v_correct)::int, (v_correct and v_first)::int, v_first::int)
  on conflict (user_id, course, term, chapter, question) do update
    set correct           = a.correct + excluded.correct,
        incorrect         = a.incorrect + excluded.incorrect,
        first_try_correct = a.first_try_correct + excluded.first_try_correct,
        first_try_total   = a.first_try_total + excluded.first_try_total,
        label             = coalesce(excluded.label, a.label),
        last_at           = now();
end;
$$;

-- Every question answered correctly: the session is finished. (p_course is
-- accepted because the sign-in gate sends it with every call; the session
-- already knows its course.)
drop function if exists public.record_chapter_quiz_finish(uuid);
create or replace function public.record_chapter_quiz_finish(p_session uuid, p_course text default null)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or p_session is null then
    return;
  end if;
  update public.chapter_quiz_sessions s
  set completed_at = now(), last_at = now()
  where s.id = p_session and s.user_id = auth.uid() and s.completed_at is null;
end;
$$;

revoke all on function public.record_chapter_quiz_answer(uuid, text, text, integer, text, text, boolean, boolean, text) from public, anon;
grant execute on function public.record_chapter_quiz_answer(uuid, text, text, integer, text, text, boolean, boolean, text) to authenticated;
revoke all on function public.record_chapter_quiz_finish(uuid, text) from public, anon;
grant execute on function public.record_chapter_quiz_finish(uuid, text) to authenticated;

-- 6. Admin page functions (instructors only) ------------------------------------
-- Used by geog215.org/admin/. Each one stops with "Instructors only." unless
-- the caller is signed in as an instructor, so the admin page can't be used by
-- anyone else even though the page itself is public.
--
-- They all take p_course (a course code) and most take p_term. The admin page
-- always sends one course; p_course null means every course you teach, and
-- p_term null means every term. Progress always comes with its own course and
-- term, so a student's work in two classes (or two terms) stays apart.

drop function if exists public.require_instructor();

-- The courses the caller may see: p_course alone, or every course they teach
-- when p_course is null. Stops unless they're an instructor of it.
create or replace function public.require_instructor(p_course text default null)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_course  text := nullif(lower(btrim(coalesce(p_course, ''))), '');
  v_courses text[];
begin
  if not public.is_instructor(v_course) then
    raise exception 'Instructors only.' using errcode = '42501';
  end if;
  select coalesce(array_agg(c.course order by c.course), '{}') into v_courses
  from public.courses c
  where (v_course is null or c.course = v_course) and public.is_instructor(c.course);
  if v_course is not null and v_courses = '{}' then
    raise exception 'No course has the code %.', p_course;
  end if;
  return v_courses;
end;
$$;

revoke all on function public.require_instructor(text) from public, anon, authenticated;

-- Same page naming as record_page_visit (older rows may still end in .html).
create or replace function public.normalize_page(p_page text)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(nullif(
    regexp_replace(regexp_replace(coalesce(p_page, '/'), '\.html$', ''),
                   '(^|/)index$', '\1'), ''), '/');
$$;

-- The courses you teach, with their terms (newest first) and student counts.
-- The admin page's course and term pickers come from this.
create or replace function public.admin_courses()
returns table (course text, title text, site_url text, terms text[], students bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(null);
begin
  return query
    select c.course, c.title, c.site_url,
           coalesce((select array_agg(t.term order by t.newest desc)
                     from (select r.term, max(r.added_at) as newest
                           from public.roster r where r.course = c.course
                           group by r.term) t), '{}'),
           (select count(*) from public.roster r where r.course = c.course)
    from public.courses c
    where c.course = any (v_courses)
    order by c.course;
end;
$$;

-- Every enrollment with its status and activity totals for that course and
-- term. (Dropped first because its columns change from time to time:
-- passwords were retired, then quiz and code totals were added, then chapter
-- quiz scores, then course and term.)
drop function if exists public.admin_roster();
drop function if exists public.admin_roster(text, text);
create or replace function public.admin_roster(p_course text default null, p_term text default null)
returns table (
  code text, course text, term text, student_name text, email text, note text, active boolean,
  signed_in boolean, claimed_at timestamptz, added_at timestamptz,
  pages_opened bigint, total_visits bigint, last_active timestamptz,
  quiz_answered bigint, quiz_correct bigint, code_runs bigint, code_errors bigint,
  cq_correct bigint, cq_incorrect bigint, cq_completed bigint, cq_score bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(p_course);
begin
  return query
    select r.code, r.course, r.term, r.student_name, r.email, r.note, r.active,
           r.user_id is not null, r.claimed_at, r.added_at,
           count(distinct public.normalize_page(p.page)) filter (where p.page is not null),
           coalesce(sum(p.visits), 0)::bigint,
           greatest(max(p.last_visit),
                    (select max(q.last_at) from public.quiz_responses q
                     where q.user_id = r.user_id and q.course = r.course and q.term = r.term),
                    (select max(c.last_run) from public.code_runs c
                     where c.user_id = r.user_id and c.course = r.course and c.term = r.term),
                    (select max(s.last_at) from public.chapter_quiz_sessions s
                     where s.user_id = r.user_id and s.course = r.course and s.term = r.term)),
           (select count(*) from public.quiz_responses q
            where q.user_id = r.user_id and q.course = r.course and q.term = r.term),
           (select count(*) from public.quiz_responses q
            where q.user_id = r.user_id and q.course = r.course and q.term = r.term and q.ever_correct),
           (select coalesce(sum(c.runs), 0) from public.code_runs c
            where c.user_id = r.user_id and c.course = r.course and c.term = r.term)::bigint,
           (select coalesce(sum(c.error_runs), 0) from public.code_runs c
            where c.user_id = r.user_id and c.course = r.course and c.term = r.term)::bigint,
           (select coalesce(sum(s.correct), 0) from public.chapter_quiz_sessions s
            where s.user_id = r.user_id and s.course = r.course and s.term = r.term)::bigint,
           (select coalesce(sum(s.incorrect), 0) from public.chapter_quiz_sessions s
            where s.user_id = r.user_id and s.course = r.course and s.term = r.term)::bigint,
           (select count(*) from public.chapter_quiz_sessions s
            where s.user_id = r.user_id and s.course = r.course and s.term = r.term
              and s.completed_at is not null),
           (select coalesce(sum(s.score), 0) from public.chapter_quiz_sessions s
            where s.user_id = r.user_id and s.course = r.course and s.term = r.term)::bigint
    from public.roster r
    left join public.page_progress p
      on p.user_id = r.user_id and p.course = r.course and p.term = r.term
    where r.course = any (v_courses) and (p_term is null or r.term = p_term)
    group by r.code
    order by r.student_name, r.code;
end;
$$;

-- Add students to one course and term. p_students is a JSON array like
--   [{"name": "Ada Lovelace", "email": "ada@unc.edu"}, ...]
-- Returns each new student. Emails already on the roster for that course and
-- term are skipped (not returned). Without p_course, you must teach exactly
-- one course; without p_term, the course's newest term is used.
drop function if exists public.admin_add_students(text[], text);
drop function if exists public.admin_add_students(jsonb, text);
create or replace function public.admin_add_students(
  p_students jsonb, p_note text default null, p_course text default null, p_term text default null)
returns table (student_name text, email text, code text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  bad       text;
  v_courses text[] := public.require_instructor(p_course);
  v_course  text;
  v_term    text := nullif(btrim(coalesce(p_term, '')), '');
begin
  if array_length(v_courses, 1) is distinct from 1 then
    raise exception 'Pick a course to add students to.';
  end if;
  v_course := v_courses[1];
  if v_term is null then
    select r.term into v_term from public.roster r
    where r.course = v_course order by r.added_at desc limit 1;
  end if;
  if v_term is null then
    raise exception 'Enter a term, for example Spring 2027.';
  end if;
  if length(v_term) > 40 then
    raise exception 'Keep the term under 40 characters.';
  end if;
  if jsonb_typeof(p_students) is distinct from 'array' then
    raise exception 'Send a list of students.';
  end if;
  if jsonb_array_length(p_students) > 500 then
    raise exception 'Add at most 500 students at a time.';
  end if;

  select x.e into bad
  from (
    select lower(btrim(coalesce(el ->> 'email', ''))) as e
    from jsonb_array_elements(p_students) as el
  ) x
  where x.e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
  limit 1;
  if found then
    raise exception 'Not a valid email address: "%".', bad;
  end if;

  return query
    insert into public.roster as r (course, term, student_name, email, note)
    select v_course, v_term,
           coalesce(nullif(btrim(t.el ->> 'name'), ''), split_part(lower(btrim(t.el ->> 'email')), '@', 1)),
           lower(btrim(t.el ->> 'email')),
           nullif(btrim(coalesce(p_note, '')), '')
    from jsonb_array_elements(p_students) with ordinality as t(el, ord)
    order by t.ord
    on conflict (course, term, email) do nothing
    returning r.student_name, r.email, r.code;
end;
$$;

-- An enrollment the caller may change: its course, term and account.
create or replace function public.admin_enrollment(p_code text)
returns table (course text, term text, user_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(null);
begin
  return query
    select r.course, r.term, r.user_id from public.roster r
    where r.code = upper(btrim(p_code)) and r.course = any (v_courses);
  if not found then raise exception 'No student has the code %.', p_code; end if;
end;
$$;

revoke all on function public.admin_enrollment(text) from public, anon, authenticated;

-- Lock a student out of that course (false) or let them back in (true).
create or replace function public.admin_set_active(p_code text, p_active boolean)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform public.admin_enrollment(p_code);
  update public.roster r set active = p_active where r.code = upper(btrim(p_code));
end;
$$;

-- Password resets were retired with passwords.
drop function if exists public.admin_allow_reset(text, boolean);

-- Remove a student from one course and term: the roster row and their
-- progress there. Their account goes too, unless they're on the roster for
-- another course or term (or are an instructor).
create or replace function public.admin_delete_student(p_code text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_course text;
  v_term   text;
  v_user   uuid;
begin
  select e.course, e.term, e.user_id into v_course, v_term, v_user
  from public.admin_enrollment(p_code) e;
  delete from public.roster r where r.code = upper(btrim(p_code));
  if v_user is null then
    return;
  end if;
  delete from public.page_progress x
  where x.user_id = v_user and x.course = v_course and x.term = v_term;
  delete from public.quiz_responses x
  where x.user_id = v_user and x.course = v_course and x.term = v_term;
  delete from public.code_runs x
  where x.user_id = v_user and x.course = v_course and x.term = v_term;
  delete from public.chapter_quiz_answers x
  where x.user_id = v_user and x.course = v_course and x.term = v_term;
  delete from public.chapter_quiz_sessions x
  where x.user_id = v_user and x.course = v_course and x.term = v_term;
  -- (questions exists once section 7 below has run.)
  if to_regclass('public.questions') is not null then
    delete from public.questions x
    where x.user_id = v_user and x.course = v_course and x.term = v_term;
  end if;
  -- (poll_responses exists once section 8 below has run.)
  if to_regclass('public.poll_responses') is not null then
    delete from public.poll_responses x
    where x.user_id = v_user and x.course = v_course and x.term = v_term;
  end if;
  if not exists (select 1 from public.roster r where r.user_id = v_user)
     and not exists (select 1 from public.instructors i, auth.users u
                     where u.id = v_user and i.email = lower(btrim(u.email))) then
    delete from auth.users u where u.id = v_user;
  end if;
end;
$$;

-- Most recent page visits.
drop function if exists public.admin_activity(integer);
drop function if exists public.admin_activity(integer, text, text);
create or replace function public.admin_activity(
  p_limit integer default 200, p_course text default null, p_term text default null)
returns table (
  student_name text, code text, page text,
  first_visit timestamptz, last_visit timestamptz, visits integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(p_course);
begin
  return query
    select r.student_name, r.code, public.normalize_page(p.page),
           p.first_visit, p.last_visit, p.visits
    from public.page_progress p
    join public.roster r on r.user_id = p.user_id and r.course = p.course and r.term = p.term
    where r.course = any (v_courses) and (p_term is null or r.term = p_term)
    order by p.last_visit desc
    limit least(greatest(coalesce(p_limit, 200), 1), 2000);
end;
$$;

-- Each page: how many students have opened it, and how often.
drop function if exists public.admin_pages();
drop function if exists public.admin_pages(text, text);
create or replace function public.admin_pages(p_course text default null, p_term text default null)
returns table (course text, page text, students bigint, visits bigint, last_visit timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(p_course);
begin
  return query
    select p.course, public.normalize_page(p.page) as pg,
           count(distinct p.user_id),
           sum(p.visits)::bigint,
           max(p.last_visit)
    from public.page_progress p
    join public.roster r on r.user_id = p.user_id and r.course = p.course and r.term = p.term
    where r.course = any (v_courses) and (p_term is null or r.term = p_term)
    group by p.course, pg
    order by p.course, pg;
end;
$$;

-- Each quiz question: how many students answered it and got it right.
drop function if exists public.admin_quiz();
drop function if exists public.admin_quiz(text, text);
create or replace function public.admin_quiz(p_course text default null, p_term text default null)
returns table (
  course text, page text, question text, label text, students bigint,
  students_correct bigint, attempts bigint, last_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(p_course);
begin
  return query
    select q.course, q.page, q.question, max(q.label),
           count(*), count(*) filter (where q.ever_correct),
           sum(q.attempts)::bigint, max(q.last_at)
    from public.quiz_responses q
    join public.roster r on r.user_id = q.user_id and r.course = q.course and r.term = q.term
    where r.course = any (v_courses) and (p_term is null or r.term = p_term)
    group by q.course, q.page, q.question
    order by q.course, q.page, min(q.first_at);
end;
$$;

-- One enrollment's quiz answers (p_code), or everyone's, newest first.
drop function if exists public.admin_quiz_responses(text, integer);
drop function if exists public.admin_quiz_responses(text, integer, text, text);
create or replace function public.admin_quiz_responses(
  p_code text default null, p_limit integer default 1000,
  p_course text default null, p_term text default null)
returns table (
  student_name text, code text, page text, question text, label text,
  attempts integer, correct boolean, ever_correct boolean, last_answer text,
  first_at timestamptz, last_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(p_course);
begin
  return query
    select r.student_name, r.code, q.page, q.question, q.label,
           q.attempts, q.correct, q.ever_correct, q.last_answer, q.first_at, q.last_at
    from public.quiz_responses q
    join public.roster r on r.user_id = q.user_id and r.course = q.course and r.term = q.term
    where r.course = any (v_courses) and (p_term is null or r.term = p_term)
      and (p_code is null or r.code = upper(btrim(p_code)))
    order by q.last_at desc
    limit least(greatest(coalesce(p_limit, 1000), 1), 5000);
end;
$$;

-- Each code cell: how many students ran it, how often, and how often it errored.
drop function if exists public.admin_code();
drop function if exists public.admin_code(text, text);
create or replace function public.admin_code(p_course text default null, p_term text default null)
returns table (
  course text, page text, cell text, label text, students bigint,
  runs bigint, error_runs bigint, last_run timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(p_course);
begin
  return query
    select c.course, c.page, c.cell, max(c.label), count(*),
           sum(c.runs)::bigint, sum(c.error_runs)::bigint, max(c.last_run)
    from public.code_runs c
    join public.roster r on r.user_id = c.user_id and r.course = c.course and r.term = c.term
    where r.course = any (v_courses) and (p_term is null or r.term = p_term)
    group by c.course, c.page, c.cell
    order by c.course, c.page, min(c.first_run);
end;
$$;

-- One enrollment's code runs (p_code), or everyone's, newest first.
drop function if exists public.admin_code_runs(text, integer);
drop function if exists public.admin_code_runs(text, integer, text, text);
create or replace function public.admin_code_runs(
  p_code text default null, p_limit integer default 1000,
  p_course text default null, p_term text default null)
returns table (
  student_name text, code text, page text, cell text, label text,
  runs integer, error_runs integer, last_code text, last_error boolean,
  first_run timestamptz, last_run timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(p_course);
begin
  return query
    select r.student_name, r.code, c.page, c.cell, c.label,
           c.runs, c.error_runs, c.last_code, c.last_error, c.first_run, c.last_run
    from public.code_runs c
    join public.roster r on r.user_id = c.user_id and r.course = c.course and r.term = c.term
    where r.course = any (v_courses) and (p_term is null or r.term = p_term)
      and (p_code is null or r.code = upper(btrim(p_code)))
    order by c.last_run desc
    limit least(greatest(coalesce(p_limit, 1000), 1), 5000);
end;
$$;

-- Chapter quizzes: one row per enrollment and chapter. score is the sum over
-- all of that student's quizzes for the chapter; best_score is their best one
-- quiz. (Dropped first because its columns have changed.)
drop function if exists public.admin_chapter_quizzes();
drop function if exists public.admin_chapter_quizzes(text, text);
create or replace function public.admin_chapter_quizzes(p_course text default null, p_term text default null)
returns table (
  student_name text, code text, chapter text, chapter_title text,
  started bigint, completed bigint, correct bigint, incorrect bigint,
  best_first_try numeric, last_at timestamptz,
  score bigint, best_score integer, best_streak integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(p_course);
begin
  return query
    select r.student_name, r.code, s.chapter, max(s.chapter_title),
           count(*), count(*) filter (where s.completed_at is not null),
           sum(s.correct)::bigint, sum(s.incorrect)::bigint,
           -- best share of a finished session's questions right on the first try
           max(round(100.0 * s.first_try_correct / nullif(s.questions, 0), 1))
             filter (where s.completed_at is not null),
           max(s.last_at),
           sum(s.score)::bigint, max(s.score), max(s.best_streak)
    from public.chapter_quiz_sessions s
    join public.roster r on r.user_id = s.user_id and r.course = s.course and r.term = s.term
    where r.course = any (v_courses) and (p_term is null or r.term = p_term)
    group by r.code, r.student_name, s.chapter
    order by r.student_name, s.chapter;
end;
$$;

-- Chapter quizzes: each question's totals across the class.
drop function if exists public.admin_chapter_quiz_questions();
drop function if exists public.admin_chapter_quiz_questions(text, text);
create or replace function public.admin_chapter_quiz_questions(p_course text default null, p_term text default null)
returns table (
  course text, chapter text, question text, label text, students bigint,
  correct bigint, incorrect bigint, first_try_correct bigint, first_try_total bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(p_course);
begin
  return query
    select a.course, a.chapter, a.question, max(a.label), count(*),
           sum(a.correct)::bigint, sum(a.incorrect)::bigint,
           sum(a.first_try_correct)::bigint, sum(a.first_try_total)::bigint
    from public.chapter_quiz_answers a
    join public.roster r on r.user_id = a.user_id and r.course = a.course and r.term = a.term
    where r.course = any (v_courses) and (p_term is null or r.term = p_term)
    group by a.course, a.chapter, a.question
    order by a.course, a.chapter, a.question;
end;
$$;

-- 7. Questions on highlighted text -------------------------------------------
-- A signed-in student highlights text in a chapter, clicks "Ask a question",
-- and types a question (assets/questions.html). record_question() saves it
-- here and emails it to the course's questions_email (one email per question,
-- sent through Resend by pg_net; see "Questions" in supabase/README.md). You
-- answer on the admin page's Questions tab, and the student sees your answer
-- under "My questions" on the site.
--
-- Email needs two things, both done once:
--   * your Resend API key in Supabase Vault, named resend_api_key:
--       select vault.create_secret('re_...', 'resend_api_key');
--   * courses.questions_email set (GEOG 215 starts as daveparr@unc.edu).
-- Without them, questions are still saved; they just aren't emailed.
--
-- Resend's free plan sends 100 emails a day, shared with sign-in codes. So
-- question emails stop for the rest of a 24-hour window after
-- sds_question_email_daily_limit() of them (questions are still saved and
-- shown on the admin page), and one student can ask at most
-- sds_question_student_daily_limit() questions in 24 hours.
create extension if not exists pg_net;

alter table public.courses add column if not exists questions_email text;
update public.courses set questions_email = 'daveparr@unc.edu'
where course = 'geog215' and questions_email is null;

create table if not exists public.questions (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users (id) on delete cascade,
  course           text not null references public.courses (course) on update cascade,
  term             text not null,
  from_instructor  boolean not null default false,  -- a test question from an instructor
  page             text not null,                    -- e.g. /chapters/r-basics
  page_title       text,
  section          text,                             -- the heading the text is under
  anchor           text,                             -- that heading's id, e.g. sec-vectors
  highlighted      text not null,                    -- the text the student highlighted
  question         text not null,
  asked_at         timestamptz not null default now(),
  status           text not null default 'open'
                   check (status in ('open', 'answered', 'closed')),
  answer           text,
  answered_at      timestamptz,
  answered_by      text,
  email_status     text,          -- queued / not sent: daily limit / not sent: no key / ...
  email_request_id bigint         -- pg_net request, to look up whether Resend took it
);

create index if not exists questions_enrollment_idx on public.questions (course, term, asked_at desc);
create index if not exists questions_user_idx on public.questions (user_id, asked_at desc);

alter table public.questions enable row level security;
revoke all on table public.questions from anon, authenticated;
grant select on table public.questions to authenticated;

-- Students see their own questions and your answers; nobody else's.
drop policy if exists "Students read their own questions" on public.questions;
create policy "Students read their own questions"
  on public.questions for select
  to authenticated
  using (user_id = (select auth.uid()));

create or replace function public.sds_question_email_daily_limit()
returns integer language sql immutable set search_path = '' as $$ select 60 $$;

create or replace function public.sds_question_student_daily_limit()
returns integer language sql immutable set search_path = '' as $$ select 20 $$;

-- Helpers for the email: HTML-escape student text, and percent-encode the
-- highlighted text for the link back to it.
create or replace function public.sds_html(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select replace(replace(replace(replace(replace(coalesce(p, ''),
    '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
$$;

create or replace function public.sds_urlencode(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(string_agg(
    case when t.ch ~ '^[A-Za-z0-9._~-]$' then t.ch
         else (select string_agg('%' || upper(lpad(to_hex(get_byte(b.v, i)), 2, '0')), '' order by i)
               from (select convert_to(t.ch, 'UTF8') as v) b,
                    generate_series(0, length(convert_to(t.ch, 'UTF8')) - 1) as i)
    end, '' order by t.n), '')
  from regexp_split_to_table(coalesce(p, ''), '') with ordinality as t(ch, n);
$$;

-- The link in the email and on the admin page: the page, plus ?sds-ask= (the
-- start of the highlighted text) and &sds-sec= (the heading's id). The site
-- scrolls to that text and marks it (assets/questions.html).
create or replace function public.sds_question_link(p_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(nullif(rtrim(c.site_url, '/'), ''), 'https://geog215.org')
         || q.page
         || '?sds-ask=' || public.sds_urlencode(left(regexp_replace(q.highlighted, '\s+', ' ', 'g'), 120))
         || case when nullif(q.anchor, '') is null then ''
                 else '&sds-sec=' || public.sds_urlencode(q.anchor) end
  from public.questions q
  join public.courses c on c.course = q.course
  where q.id = p_id;
$$;

revoke all on function public.sds_question_link(uuid) from public, anon, authenticated;

-- Email one question to the course's questions_email through Resend. Never
-- raises: a question is saved even if the email can't be sent. Returns the
-- email status it recorded. The email never names the student or includes
-- their email address (UNC's mail filtering held emails that did); who asked
-- is on the admin page's Questions tab.
create or replace function public.sds_email_question(p_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  q        public.questions;
  v_to     text;
  v_title  text;
  v_key    text;
  v_who    text;
  v_link   text;
  v_status text;
  v_req    bigint;
  v_html   text;
  v_text   text;
begin
  select * into q from public.questions where id = p_id;
  if not found then
    return null;
  end if;
  select c.questions_email, c.title into v_to, v_title
  from public.courses c where c.course = q.course;

  if nullif(btrim(coalesce(v_to, '')), '') is null then
    v_status := 'not sent: no questions_email for the course';
  elsif (select count(*) from public.questions x
         where x.email_status = 'queued' and x.asked_at > now() - interval '24 hours')
        >= public.sds_question_email_daily_limit() then
    v_status := 'not sent: daily email limit';
  else
    begin
      select s.decrypted_secret into v_key
      from vault.decrypted_secrets s where s.name = 'resend_api_key' limit 1;
    exception when others then
      v_key := null;
    end;
    if v_key is null then
      v_status := 'not sent: no resend_api_key in Vault';
    end if;
  end if;

  if v_status is null then
    v_who := case when q.from_instructor then 'An instructor (test question)' else 'A student' end;
    v_link := public.sds_question_link(q.id);

    v_html :=
      '<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.45;color:#1f2933">'
      || '<p>' || v_who || ' asked a question on <a href="' || public.sds_html(v_link) || '">'
      || public.sds_html(coalesce(nullif(q.page_title, ''), q.page)) || '</a>'
      || coalesce(', in <em>' || public.sds_html(nullif(q.section, '')) || '</em>', '') || '.</p>'
      || '<p style="margin:0 0 4px;color:#52606d;font-size:13px">Highlighted text:</p>'
      || '<blockquote style="margin:0 0 16px;padding:8px 12px;border-left:4px solid #f2c94c;background:#fffbea">'
      || replace(public.sds_html(q.highlighted), E'\n', '<br>') || '</blockquote>'
      || '<p style="margin:0 0 4px;color:#52606d;font-size:13px">Question:</p>'
      || '<p style="margin:0 0 16px;white-space:pre-wrap">' || public.sds_html(q.question) || '</p>'
      || '<p><a href="' || public.sds_html(v_link) || '">Open this spot in the textbook</a>'
      || ' &middot; <a href="https://geog215.org/admin/">Answer on the admin page</a></p>'
      || '<p style="color:#52606d;font-size:13px">The admin page shows who asked. '
      || 'An answer there shows to the student on the site under "My questions".</p>'
      || '</div>';
    v_text :=
      v_who || ' asked a question on '
      || coalesce(nullif(q.page_title, ''), q.page)
      || coalesce(', in "' || nullif(q.section, '') || '"', '') || E'.\n\n'
      || E'Highlighted text:\n> ' || replace(q.highlighted, E'\n', E'\n> ') || E'\n\n'
      || E'Question:\n' || q.question || E'\n\n'
      || 'Open this spot: ' || v_link || E'\n'
      || E'Answer on the admin page: https://geog215.org/admin/\n';

    begin
      select net.http_post(
        url     := 'https://api.resend.com/emails',
        headers := jsonb_build_object('Authorization', 'Bearer ' || v_key,
                                      'Content-Type', 'application/json'),
        body    := jsonb_strip_nulls(jsonb_build_object(
          'from',     coalesce(nullif(btrim(split_part(v_title, ':', 1)), ''), upper(q.course))
                      || ' Questions <questions@mail.geog215.org>',
          'to',       jsonb_build_array(btrim(v_to)),
          'subject',  'New question on ' || left(coalesce(nullif(q.page_title, ''), q.page), 80),
          'html',     v_html,
          'text',     v_text))
      ) into v_req;
      v_status := 'queued';
    exception when others then
      v_status := 'not sent: ' || left(sqlerrm, 200);
    end;
  end if;

  update public.questions
  set email_status = v_status, email_request_id = v_req
  where id = p_id;
  return v_status;
end;
$$;

revoke all on function public.sds_email_question(uuid) from public, anon, authenticated;

-- Ask a question. Active students of the course, plus instructors (whose
-- questions are marked as tests, so you can try it yourself). Returns the
-- new question's id.
create or replace function public.record_question(
  p_page text, p_highlighted text, p_question text,
  p_page_title text default null, p_section text default null, p_anchor text default null,
  p_course text default null)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_course text;
  v_term   text;
  v_test   boolean := false;
  v_high   text := btrim(left(coalesce(p_highlighted, ''), 2000));
  v_q      text := btrim(left(coalesce(p_question, ''), 4000));
  v_anchor text := nullif(left(btrim(coalesce(p_anchor, '')), 120), '');
  v_id     uuid;
begin
  if auth.uid() is null then
    raise exception 'Sign in to ask a question.' using errcode = '42501';
  end if;
  select e.course, e.term into v_course, v_term from public.current_enrollment(p_course) e;
  if v_course is null then
    v_course := nullif(lower(btrim(coalesce(p_course, ''))), '');
    if v_course is null or not public.is_instructor(v_course)
       or not exists (select 1 from public.courses c where c.course = v_course) then
      raise exception 'Only students in this course can ask questions here.' using errcode = '42501';
    end if;
    v_test := true;
    select r.term into v_term from public.roster r
    where r.course = v_course order by r.added_at desc limit 1;
    v_term := coalesce(v_term, 'Test');
  end if;
  if length(v_high) < 1 then
    raise exception 'Highlight some text to ask about.';
  end if;
  if length(v_q) < 2 then
    raise exception 'Type your question.';
  end if;
  if v_anchor is not null and v_anchor !~ '^[A-Za-z0-9_:.-]+$' then
    v_anchor := null;
  end if;
  if (select count(*) from public.questions x
      where x.user_id = auth.uid() and x.asked_at > now() - interval '24 hours')
     >= public.sds_question_student_daily_limit() then
    raise exception 'You''ve asked % questions today, the most for one day. Email your instructor, or ask again tomorrow.',
      public.sds_question_student_daily_limit();
  end if;

  insert into public.questions (user_id, course, term, from_instructor, page, page_title,
                                section, anchor, highlighted, question)
  values (auth.uid(), v_course, v_term, v_test, public.normalize_page(left(p_page, 300)),
          nullif(btrim(left(coalesce(p_page_title, ''), 200)), ''),
          nullif(btrim(left(coalesce(p_section, ''), 200)), ''),
          v_anchor, v_high, v_q)
  returning id into v_id;

  perform public.sds_email_question(v_id);
  return v_id;
end;
$$;

revoke all on function public.record_question(text, text, text, text, text, text, text) from public, anon;
grant execute on function public.record_question(text, text, text, text, text, text, text) to authenticated;

-- Questions for the admin page's Questions tab, newest first. p_status is
-- open / answered / closed, or null for all. email_status becomes 'sent' or
-- 'failed (HTTP ...)' once Resend has replied (pg_net keeps replies for about
-- 6 hours; after that a queued email just shows as queued).
create or replace function public.admin_questions(
  p_course text default null, p_term text default null, p_status text default null,
  p_limit integer default 500)
returns table (
  id uuid, course text, term text, student_name text, email text, code text,
  from_instructor boolean, page text, page_title text, section text, anchor text,
  highlighted text, question text, asked_at timestamptz, status text,
  answer text, answered_at timestamptz, answered_by text, email_status text, link text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(p_course);
begin
  return query
    select q.id, q.course, q.term,
           coalesce(r.student_name, case when q.from_instructor then 'Instructor (test)' end, u.email),
           coalesce(r.email, lower(u.email)), r.code, q.from_instructor,
           q.page, q.page_title, q.section, q.anchor, q.highlighted, q.question, q.asked_at,
           q.status, q.answer, q.answered_at, q.answered_by,
           case
             when q.email_status = 'queued' and resp.status_code between 200 and 299 then 'sent'
             when q.email_status = 'queued' and resp.status_code is not null
               then 'failed (HTTP ' || resp.status_code || ': ' || left(coalesce(resp.content, ''), 120) || ')'
             when q.email_status = 'queued' and resp.error_msg is not null
               then 'failed (' || left(resp.error_msg, 120) || ')'
             else q.email_status
           end,
           public.sds_question_link(q.id)
    from public.questions q
    left join auth.users u on u.id = q.user_id
    left join lateral (
      select r.student_name, r.email, r.code from public.roster r
      where r.user_id = q.user_id and r.course = q.course and r.term = q.term
      order by r.added_at desc limit 1) r on true
    left join net._http_response resp on resp.id = q.email_request_id
    where q.course = any (v_courses) and (p_term is null or q.term = p_term)
      and (p_status is null or q.status = p_status)
    order by q.asked_at desc
    limit least(greatest(coalesce(p_limit, 500), 1), 5000);
end;
$$;

-- Answer a question (p_answer), or just change its status: 'answered' with an
-- answer, 'closed' (dealt with, e.g. in class or by email, without an answer
-- here), or 'open' to reopen it. The student sees the answer on the site.
create or replace function public.admin_answer_question(
  p_id uuid, p_answer text default null, p_status text default null)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_course text;
  v_answer text := nullif(btrim(left(coalesce(p_answer, ''), 8000)), '');
  v_status text := coalesce(nullif(btrim(coalesce(p_status, '')), ''),
                            case when v_answer is not null then 'answered' end);
begin
  select q.course into v_course from public.questions q where q.id = p_id;
  if v_course is null then
    raise exception 'That question no longer exists.';
  end if;
  perform public.require_instructor(v_course);
  if v_status is null or v_status not in ('open', 'answered', 'closed') then
    raise exception 'Status must be open, answered or closed.';
  end if;
  if v_status = 'answered' and v_answer is null
     and not exists (select 1 from public.questions q where q.id = p_id and q.answer is not null) then
    raise exception 'Type an answer first.';
  end if;
  update public.questions q
  set status      = v_status,
      answer      = coalesce(v_answer, q.answer),
      answered_at = case when v_answer is not null and v_answer is distinct from q.answer
                         then now() else q.answered_at end,
      answered_by = case when v_answer is not null and v_answer is distinct from q.answer
                         then (select lower(u.email) from auth.users u where u.id = auth.uid())
                         else q.answered_by end
  where q.id = p_id;
end;
$$;

-- Delete a question (for example a test one).
create or replace function public.admin_delete_question(p_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_course text;
begin
  select q.course into v_course from public.questions q where q.id = p_id;
  if v_course is null then
    return;
  end if;
  perform public.require_instructor(v_course);
  delete from public.questions q where q.id = p_id;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'admin_courses()',
    'admin_roster(text, text)', 'admin_add_students(jsonb, text, text, text)',
    'admin_set_active(text, boolean)',
    'admin_delete_student(text)', 'admin_activity(integer, text, text)',
    'admin_pages(text, text)',
    'admin_quiz(text, text)', 'admin_quiz_responses(text, integer, text, text)',
    'admin_code(text, text)', 'admin_code_runs(text, integer, text, text)',
    'admin_chapter_quizzes(text, text)', 'admin_chapter_quiz_questions(text, text)',
    'admin_questions(text, text, text, integer)', 'admin_answer_question(uuid, text, text)',
    'admin_delete_question(uuid)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end;
$$;

-- 8. Polls and surveys ----------------------------------------------------------
-- Short polls and longer surveys that students take on the site
-- (assets/polls.html). Each poll belongs to one course, and to one term or to
-- every term (term null). You write and edit polls on the admin page's Polls
-- tab, open and close them there, and download the answers as CSV or Excel.
--
-- While a poll is open, a signed-in student who hasn't taken it sees a banner
-- at the top of every page. Students can change their answers until you close
-- the poll. Answers are saved with the student's account (polls aren't
-- anonymous), and students can read only their own.
--
-- Question kinds:
--   single  pick one option (radio buttons); allow_other adds "Other: ____"
--   multi   pick any number of options (checkboxes); allow_other too
--   scale   a number from scale_min to scale_max (e.g. 1 to 5), with optional
--           labels for the two ends
--   short   one line of text
--   long    a paragraph of text
-- Answers are stored as JSON keyed by question id: a string (single, short,
-- long; "Other: ..." for a typed-in other), an array of strings (multi) or a
-- number (scale).
--
-- New polls start as drafts, which students never see. Status open shows it;
-- closed hides it again and stops changes, but keeps every answer.

create table if not exists public.polls (
  id          uuid primary key default gen_random_uuid(),
  course      text not null references public.courses (course) on update cascade,
  term        text,                                  -- null: every term of the course
  title       text not null,
  intro       text,                                  -- shown above the questions
  status      text not null default 'draft'
              check (status in ('draft', 'open', 'closed')),
  seed_key    text,                                  -- the built-in example poll(s)
  created_at  timestamptz not null default now(),
  created_by  text,
  updated_at  timestamptz not null default now(),
  opened_at   timestamptz,
  closed_at   timestamptz
);

create unique index if not exists polls_seed_idx on public.polls (course, seed_key)
  where seed_key is not null;
create index if not exists polls_course_idx on public.polls (course, status);

create table if not exists public.poll_questions (
  id           uuid primary key default gen_random_uuid(),
  poll_id      uuid not null references public.polls (id) on delete cascade,
  position     integer not null default 0,
  kind         text not null check (kind in ('single', 'multi', 'scale', 'short', 'long')),
  prompt       text not null,
  help         text,                                 -- smaller text under the question
  options      text[] not null default '{}',         -- single / multi
  allow_other  boolean not null default false,       -- single / multi
  required     boolean not null default false,
  scale_min    integer not null default 1,
  scale_max    integer not null default 5,
  min_label    text,                                 -- e.g. "Not at all"
  max_label    text                                  -- e.g. "Very"
);

create index if not exists poll_questions_poll_idx on public.poll_questions (poll_id, position);

-- One response per student per poll (changing answers updates it).
create table if not exists public.poll_responses (
  id               uuid primary key default gen_random_uuid(),
  poll_id          uuid not null references public.polls (id) on delete cascade,
  user_id          uuid not null references auth.users (id) on delete cascade,
  course           text not null references public.courses (course) on update cascade,
  term             text not null,
  from_instructor  boolean not null default false,   -- an instructor trying it out
  answers          jsonb not null default '{}'::jsonb,
  submitted_at     timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (poll_id, user_id)
);

create index if not exists poll_responses_enrollment_idx on public.poll_responses (course, term);
create index if not exists poll_responses_user_idx on public.poll_responses (user_id);

alter table public.polls enable row level security;
alter table public.poll_questions enable row level security;
alter table public.poll_responses enable row level security;
-- Students reach polls only through the functions below. They may read their
-- own responses; nobody can read anyone else's from the browser.
revoke all on table public.polls from anon, authenticated;
revoke all on table public.poll_questions from anon, authenticated;
revoke all on table public.poll_responses from anon, authenticated;
grant select on table public.poll_responses to authenticated;

drop policy if exists "Students read their own poll responses" on public.poll_responses;
create policy "Students read their own poll responses"
  on public.poll_responses for select
  to authenticated
  using (user_id = (select auth.uid()));

-- Who is taking a poll: the caller's enrollment that the poll is for (course
-- and term), or an instructor of the course trying it out (test = true; the
-- term is the poll's own, else the course's newest). Raises otherwise.
create or replace function public.sds_poll_taker(p_poll uuid)
returns table (course text, term text, test boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_poll   public.polls;
  v_course text;
  v_term   text;
begin
  if auth.uid() is null then
    raise exception 'Sign in to take this poll.' using errcode = '42501';
  end if;
  select * into v_poll from public.polls p where p.id = p_poll;
  if v_poll.id is null then
    raise exception 'That poll no longer exists.';
  end if;
  select e.course, e.term into v_course, v_term from public.current_enrollment(v_poll.course) e;
  if v_course is not null and (v_poll.term is null or v_poll.term = v_term) then
    return query select v_course, v_term, false;
    return;
  end if;
  if public.is_instructor(v_poll.course) then
    if v_poll.term is null then
      select r.term into v_term from public.roster r
      where r.course = v_poll.course order by r.added_at desc limit 1;
    end if;
    return query select v_poll.course, coalesce(v_poll.term, v_term, 'Test'), true;
    return;
  end if;
  raise exception 'This poll is for another class or term.' using errcode = '42501';
end;
$$;

revoke all on function public.sds_poll_taker(uuid) from public, anon, authenticated;

-- A poll's questions as JSON, in order (for the site and the admin page).
create or replace function public.sds_poll_questions_json(p_poll uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'position', q.position, 'kind', q.kind, 'prompt', q.prompt,
           'help', q.help, 'options', to_jsonb(q.options), 'allow_other', q.allow_other,
           'required', q.required, 'scale_min', q.scale_min, 'scale_max', q.scale_max,
           'min_label', q.min_label, 'max_label', q.max_label)
         order by q.position, q.prompt), '[]'::jsonb)
  from public.poll_questions q
  where q.poll_id = p_poll;
$$;

revoke all on function public.sds_poll_questions_json(uuid) from public, anon, authenticated;

-- Check a student's answers against the poll's questions and return them
-- cleaned up (trimmed, unknown questions and blank answers dropped). Raises
-- with a message the student can act on.
create or replace function public.sds_poll_clean_answers(p_poll uuid, p_answers jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  q      public.poll_questions;
  v_in   jsonb := coalesce(p_answers, '{}'::jsonb);
  v_out  jsonb := '{}'::jsonb;
  v_val  jsonb;
  v_txt  text;
  v_list text[];
  v_item text;
  v_num  numeric;
  v_n    integer := 0;
begin
  if jsonb_typeof(v_in) <> 'object' then
    raise exception 'Answers must be a JSON object.';
  end if;
  for q in select * from public.poll_questions x where x.poll_id = p_poll order by x.position loop
    v_n := v_n + 1;
    v_val := v_in -> q.id::text;
    if v_val is null or v_val = 'null'::jsonb then
      v_val := null;
    end if;

    if q.kind in ('short', 'long', 'single') then
      if v_val is not null and jsonb_typeof(v_val) not in ('string', 'number') then
        raise exception 'Question %: answer with text.', v_n;
      end if;
      v_txt := nullif(btrim(left(coalesce(v_val #>> '{}', ''), case when q.kind = 'long' then 4000 else 500 end)), '');
      if v_txt is not null and q.kind = 'single' and not (v_txt = any (q.options)) then
        if q.allow_other and v_txt like 'Other:%' and length(btrim(substr(v_txt, 7))) > 0 then
          v_txt := 'Other: ' || btrim(substr(v_txt, 7));
        else
          raise exception 'Question %: pick one of the choices.', v_n;
        end if;
      end if;
      if v_txt is not null then
        v_out := v_out || jsonb_build_object(q.id::text, v_txt);
      end if;
    elsif q.kind = 'multi' then
      v_list := '{}';
      if v_val is not null then
        if jsonb_typeof(v_val) <> 'array' then
          raise exception 'Question %: pick from the list.', v_n;
        end if;
        for v_item in select btrim(left(e, 500)) from jsonb_array_elements_text(v_val) e loop
          continue when v_item = '' or v_item = any (v_list);
          if v_item = any (q.options) then
            v_list := v_list || v_item;
          elsif q.allow_other and v_item like 'Other:%' and length(btrim(substr(v_item, 7))) > 0 then
            v_list := v_list || ('Other: ' || btrim(substr(v_item, 7)));
          else
            raise exception 'Question %: "%" isn''t one of the choices.', v_n, left(v_item, 60);
          end if;
        end loop;
      end if;
      if cardinality(v_list) > 0 then
        v_out := v_out || jsonb_build_object(q.id::text, to_jsonb(v_list));
        v_txt := 'x';
      else
        v_txt := null;
      end if;
    elsif q.kind = 'scale' then
      v_txt := null;
      if v_val is not null then
        begin
          v_num := (v_val #>> '{}')::numeric;
        exception when others then
          raise exception 'Question %: pick a number.', v_n;
        end;
        if v_num <> trunc(v_num) or v_num < q.scale_min or v_num > q.scale_max then
          raise exception 'Question %: pick a number from % to %.', v_n, q.scale_min, q.scale_max;
        end if;
        v_out := v_out || jsonb_build_object(q.id::text, v_num::integer);
        v_txt := 'x';
      end if;
    end if;

    if q.required and v_txt is null then
      raise exception 'Question % needs an answer.', v_n;
    end if;
  end loop;
  return v_out;
end;
$$;

revoke all on function public.sds_poll_clean_answers(uuid, jsonb) from public, anon, authenticated;

-- Open polls for the signed-in student in this course and term (instructors:
-- every open poll of the course), newest first, and whether they've taken
-- each one. The site's banner and Polls button come from this.
create or replace function public.my_polls(p_course text default null)
returns table (id uuid, title text, intro text, questions integer,
               answered boolean, submitted_at timestamptz, updated_at timestamptz, test boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_course text := nullif(lower(btrim(coalesce(p_course, ''))), '');
  v_term   text;
  v_test   boolean := false;
begin
  if auth.uid() is null then
    return;
  end if;
  select e.course, e.term into v_course, v_term from public.current_enrollment(v_course) e;
  if v_course is null then
    v_course := nullif(lower(btrim(coalesce(p_course, ''))), '');
    if v_course is null or not public.is_instructor(v_course) then
      return;
    end if;
    v_test := true;
  end if;
  return query
    select p.id, p.title, p.intro,
           (select count(*)::integer from public.poll_questions q where q.poll_id = p.id),
           r.id is not null, r.submitted_at, r.updated_at, v_test
    from public.polls p
    left join public.poll_responses r on r.poll_id = p.id and r.user_id = auth.uid()
    where p.course = v_course and p.status = 'open'
      and (v_test or p.term is null or p.term = v_term)
    order by coalesce(p.opened_at, p.created_at) desc;
end;
$$;

revoke all on function public.my_polls(text) from public, anon;
grant execute on function public.my_polls(text) to authenticated;

-- One open poll with its questions and the caller's answers so far (null if
-- they haven't taken it).
create or replace function public.get_poll(p_poll uuid, p_course text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_poll public.polls;
  v_resp public.poll_responses;
  v_test boolean;
begin
  select t.test into v_test from public.sds_poll_taker(p_poll) t;
  select * into v_poll from public.polls p where p.id = p_poll;
  if v_poll.status <> 'open' and not public.is_instructor(v_poll.course) then
    raise exception 'This poll is closed.';
  end if;
  select * into v_resp from public.poll_responses r
  where r.poll_id = p_poll and r.user_id = auth.uid();
  return jsonb_build_object(
    'id', v_poll.id, 'title', v_poll.title, 'intro', v_poll.intro, 'status', v_poll.status,
    'test', v_test,
    'questions', public.sds_poll_questions_json(v_poll.id),
    'answers', case when v_resp.id is null then null else v_resp.answers end,
    'submitted_at', v_resp.submitted_at, 'updated_at', v_resp.updated_at);
end;
$$;

revoke all on function public.get_poll(uuid, text) from public, anon;
grant execute on function public.get_poll(uuid, text) to authenticated;

-- Save (or change) the caller's answers to an open poll. p_answers is a JSON
-- object keyed by question id. Returns when it was saved.
create or replace function public.submit_poll(p_poll uuid, p_answers jsonb, p_course text default null)
returns timestamptz
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_course text;
  v_term   text;
  v_test   boolean;
  v_clean  jsonb;
begin
  select t.course, t.term, t.test into v_course, v_term, v_test from public.sds_poll_taker(p_poll) t;
  if not exists (select 1 from public.polls p where p.id = p_poll and p.status = 'open') then
    raise exception 'This poll is closed, so answers can''t be changed.';
  end if;
  if length(coalesce(p_answers, '{}'::jsonb)::text) > 100000 then
    raise exception 'Those answers are too long.';
  end if;
  v_clean := public.sds_poll_clean_answers(p_poll, p_answers);
  insert into public.poll_responses as r (poll_id, user_id, course, term, from_instructor, answers)
  values (p_poll, auth.uid(), v_course, v_term, v_test, v_clean)
  on conflict (poll_id, user_id) do update
    set answers = excluded.answers, updated_at = now();
  return now();
end;
$$;

revoke all on function public.submit_poll(uuid, jsonb, text) from public, anon;
grant execute on function public.submit_poll(uuid, jsonb, text) to authenticated;

-- Admin: polls for the Polls tab. A term-specific poll shows only under its
-- term (or All terms); an every-term poll shows under every term. responses
-- counts students (not instructors' tests) in the picked term; eligible is
-- the number of active students it's for.
create or replace function public.admin_polls(p_course text default null, p_term text default null)
returns table (
  id uuid, course text, term text, title text, intro text, status text, questions integer,
  responses bigint, test_responses bigint, eligible bigint, last_response timestamptz,
  created_at timestamptz, updated_at timestamptz, opened_at timestamptz, closed_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(p_course);
begin
  return query
    select p.id, p.course, p.term, p.title, p.intro, p.status,
           (select count(*)::integer from public.poll_questions q where q.poll_id = p.id),
           (select count(*) from public.poll_responses r
            where r.poll_id = p.id and not r.from_instructor and (p_term is null or r.term = p_term)),
           (select count(*) from public.poll_responses r where r.poll_id = p.id and r.from_instructor),
           (select count(*) from public.roster s
            where s.course = p.course and s.active
              and (p.term is null or s.term = p.term) and (p_term is null or s.term = p_term)),
           (select max(r.updated_at) from public.poll_responses r where r.poll_id = p.id),
           p.created_at, p.updated_at, p.opened_at, p.closed_at
    from public.polls p
    where p.course = any (v_courses)
      and (p_term is null or p.term is null or p.term = p_term)
    order by (p.status = 'open') desc, coalesce(p.opened_at, p.created_at) desc;
end;
$$;

-- Admin: one poll with its questions (the editor and the exports use this).
create or replace function public.admin_poll(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_poll public.polls;
begin
  select * into v_poll from public.polls p where p.id = p_id;
  if v_poll.id is null then
    raise exception 'That poll no longer exists.';
  end if;
  perform public.require_instructor(v_poll.course);
  return to_jsonb(v_poll) || jsonb_build_object('questions', public.sds_poll_questions_json(v_poll.id));
end;
$$;

-- Admin: create or update a poll from JSON:
--   {"id": null for a new poll, "course": "geog215", "term": "Spring 2027" or null,
--    "title": "...", "intro": "...",
--    "questions": [{"id": (keep for existing questions), "kind": "single",
--                   "prompt": "...", "help": "...", "options": ["A", "B"],
--                   "allow_other": false, "required": true,
--                   "scale_min": 1, "scale_max": 5, "min_label": "", "max_label": ""}, ...]}
-- Questions are saved in the order given. A question left out is deleted
-- (answers already given to it stay in the responses but aren't exported).
-- Status isn't changed here; see admin_set_poll_status. Returns the poll id.
create or replace function public.admin_save_poll(p_poll jsonb)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id     uuid := nullif(p_poll ->> 'id', '')::uuid;
  v_course text := nullif(lower(btrim(coalesce(p_poll ->> 'course', ''))), '');
  v_term   text := nullif(btrim(coalesce(p_poll ->> 'term', '')), '');
  v_title  text := nullif(btrim(left(coalesce(p_poll ->> 'title', ''), 200)), '');
  v_intro  text := nullif(btrim(left(coalesce(p_poll ->> 'intro', ''), 4000)), '');
  v_qs     jsonb := coalesce(p_poll -> 'questions', '[]'::jsonb);
  v_q      jsonb;
  v_qid    uuid;
  v_keep   uuid[] := '{}';
  v_kind   text;
  v_prompt text;
  v_opts   text[];
  v_min    integer;
  v_max    integer;
  v_pos    integer := 0;
  v_me     text := (select lower(u.email) from auth.users u where u.id = auth.uid());
begin
  if v_id is not null then
    select p.course into v_course from public.polls p where p.id = v_id;
    if v_course is null then
      raise exception 'That poll no longer exists.';
    end if;
  end if;
  if v_course is null then
    raise exception 'Pick a course for the poll.';
  end if;
  perform public.require_instructor(v_course);
  if v_title is null then
    raise exception 'Give the poll a title.';
  end if;
  if jsonb_typeof(v_qs) <> 'array' or jsonb_array_length(v_qs) = 0 then
    raise exception 'Add at least one question.';
  end if;
  if jsonb_array_length(v_qs) > 100 then
    raise exception 'A poll can have at most 100 questions.';
  end if;

  if v_id is null then
    insert into public.polls (course, term, title, intro, created_by)
    values (v_course, v_term, v_title, v_intro, v_me)
    returning id into v_id;
  else
    update public.polls p
    set term = v_term, title = v_title, intro = v_intro, updated_at = now()
    where p.id = v_id;
  end if;

  for v_q in select * from jsonb_array_elements(v_qs) loop
    v_pos := v_pos + 1;
    v_kind := lower(btrim(coalesce(v_q ->> 'kind', '')));
    v_prompt := nullif(btrim(left(coalesce(v_q ->> 'prompt', ''), 1000)), '');
    if v_kind not in ('single', 'multi', 'scale', 'short', 'long') then
      raise exception 'Question %: the type must be single, multi, scale, short or long.', v_pos;
    end if;
    if v_prompt is null then
      raise exception 'Question % has no text.', v_pos;
    end if;
    select coalesce(array_agg(o order by n), '{}') into v_opts
    from (select distinct on (btrim(o)) btrim(left(o, 300)) as o, n
          from jsonb_array_elements_text(
                 case when jsonb_typeof(v_q -> 'options') = 'array' then v_q -> 'options' else '[]'::jsonb end
               ) with ordinality as t(o, n)
          where btrim(o) <> '' order by btrim(o), n) d;
    if v_kind in ('single', 'multi') and cardinality(v_opts) = 0 then
      raise exception 'Question % needs at least one choice.', v_pos;
    end if;
    if v_kind <> 'scale' then
      v_min := 1; v_max := 5;
    else
      v_min := coalesce(nullif(v_q ->> 'scale_min', '')::integer, 1);
      v_max := coalesce(nullif(v_q ->> 'scale_max', '')::integer, 5);
      if v_min < 0 or v_max > 10 or v_max <= v_min then
        raise exception 'Question %: the scale must run from 0 or 1 up to at most 10.', v_pos;
      end if;
    end if;
    v_qid := nullif(v_q ->> 'id', '')::uuid;
    if v_qid is not null and not exists (
         select 1 from public.poll_questions x where x.id = v_qid and x.poll_id = v_id) then
      v_qid := null;
    end if;
    if v_qid is null then
      insert into public.poll_questions (poll_id, position, kind, prompt) values (v_id, v_pos, v_kind, v_prompt)
      returning id into v_qid;
    end if;
    update public.poll_questions x
    set position = v_pos, kind = v_kind, prompt = v_prompt,
        help = nullif(btrim(left(coalesce(v_q ->> 'help', ''), 1000)), ''),
        options = case when v_kind in ('single', 'multi') then v_opts else '{}' end,
        allow_other = v_kind in ('single', 'multi') and coalesce((v_q ->> 'allow_other')::boolean, false),
        required = coalesce((v_q ->> 'required')::boolean, false),
        scale_min = v_min, scale_max = v_max,
        min_label = case when v_kind = 'scale' then nullif(btrim(left(coalesce(v_q ->> 'min_label', ''), 100)), '') end,
        max_label = case when v_kind = 'scale' then nullif(btrim(left(coalesce(v_q ->> 'max_label', ''), 100)), '') end
    where x.id = v_qid;
    v_keep := v_keep || v_qid;
  end loop;

  delete from public.poll_questions x where x.poll_id = v_id and not (x.id = any (v_keep));
  return v_id;
end;
$$;

-- Admin: open a poll (students see it), close it (hidden, answers kept, no
-- more changes), or put it back to draft.
create or replace function public.admin_set_poll_status(p_id uuid, p_status text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_course text;
begin
  select p.course into v_course from public.polls p where p.id = p_id;
  if v_course is null then
    raise exception 'That poll no longer exists.';
  end if;
  perform public.require_instructor(v_course);
  if p_status is null or p_status not in ('draft', 'open', 'closed') then
    raise exception 'Status must be draft, open or closed.';
  end if;
  update public.polls p
  set status = p_status, updated_at = now(),
      opened_at = case when p_status = 'open' and p.status <> 'open' then now() else p.opened_at end,
      closed_at = case when p_status = 'closed' and p.status <> 'closed' then now()
                       when p_status <> 'closed' then null else p.closed_at end
  where p.id = p_id;
end;
$$;

-- Admin: every response to a poll (one term, or all with p_term null), with
-- the student's name and email from the roster.
create or replace function public.admin_poll_responses(p_id uuid, p_term text default null)
returns table (
  id uuid, student_name text, email text, code text, term text, note text,
  from_instructor boolean, submitted_at timestamptz, updated_at timestamptz, answers jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_course text;
begin
  select p.course into v_course from public.polls p where p.id = p_id;
  if v_course is null then
    raise exception 'That poll no longer exists.';
  end if;
  perform public.require_instructor(v_course);
  return query
    select x.id,
           coalesce(r.student_name, case when x.from_instructor then 'Instructor (test)' end, u.email),
           coalesce(r.email, lower(u.email)), r.code, x.term, r.note,
           x.from_instructor, x.submitted_at, x.updated_at, x.answers
    from public.poll_responses x
    left join auth.users u on u.id = x.user_id
    left join lateral (
      select r.student_name, r.email, r.code, r.note from public.roster r
      where r.user_id = x.user_id and r.course = x.course and r.term = x.term
      order by r.added_at desc limit 1) r on true
    where x.poll_id = p_id and (p_term is null or x.term = p_term)
    order by x.submitted_at;
end;
$$;

-- Admin: delete one response (for example your own test), or a whole poll
-- with all of its responses.
create or replace function public.admin_delete_poll_response(p_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_course text;
begin
  select x.course into v_course from public.poll_responses x where x.id = p_id;
  if v_course is null then
    return;
  end if;
  perform public.require_instructor(v_course);
  delete from public.poll_responses x where x.id = p_id;
end;
$$;

create or replace function public.admin_delete_poll(p_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_course text;
begin
  select p.course into v_course from public.polls p where p.id = p_id;
  if v_course is null then
    return;
  end if;
  perform public.require_instructor(v_course);
  delete from public.polls p where p.id = p_id;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'admin_polls(text, text)', 'admin_poll(uuid)', 'admin_save_poll(jsonb)',
    'admin_set_poll_status(uuid, text)', 'admin_poll_responses(uuid, text)',
    'admin_delete_poll_response(uuid)', 'admin_delete_poll(uuid)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end;
$$;

-- 8a. Example: start-of-semester survey (GEOG 215) ------------------------------
-- (sds_seeded remembers that it was added, so deleting it on the admin page
-- doesn't bring it back the next time this file runs.)
create table if not exists public.sds_seeded (
  key      text primary key,
  added_at timestamptz not null default now()
);
alter table public.sds_seeded enable row level security;
revoke all on table public.sds_seeded from anon, authenticated;

-- Based on the Google Form "Fall 2026 Student Start-of-Semester Survey
-- (SSoSS)". Added once, as a draft for every term; edit it on the admin
-- page's Polls tab and open it when you're ready. Re-running this file never
-- changes or re-adds it (delete it on the admin page if you don't want it).
do $$
declare
  v_poll uuid;
  v_pos  integer := 0;
  q      jsonb;
begin
  if exists (select 1 from public.sds_seeded s where s.key = 'poll:geog215:start-of-semester')
     or exists (select 1 from public.polls p where p.course = 'geog215' and p.seed_key = 'start-of-semester')
     or not exists (select 1 from public.courses c where c.course = 'geog215') then
    return;
  end if;
  insert into public.sds_seeded (key) values ('poll:geog215:start-of-semester');
  insert into public.polls (course, term, title, intro, seed_key, created_by)
  values ('geog215', null, 'Start-of-semester survey',
          'Help me get to know you! This takes about 10 minutes. Your answers go only to me '
          || '(Dr. Parr), with your name, and aren''t graded. Questions marked * need an answer; '
          || 'you can change your answers until the survey closes.',
          'start-of-semester', 'setup.sql')
  returning id into v_poll;

  for q in select * from jsonb_array_elements($json$[
    {"kind": "short", "prompt": "What name do you like to be called?",
     "help": "Your first name, a nickname, or anything else you go by."},
    {"kind": "short", "prompt": "How do you pronounce your name?",
     "help": "I won't share the answer with the class, but it is helpful for me to refer to when learning names."},
    {"kind": "single", "prompt": "What pronouns do you prefer?",
     "options": ["she/her", "he/him", "they/them", "Prefer not to say"], "allow_other": true},
    {"kind": "single", "prompt": "What year are you at in school?", "required": true,
     "options": ["First-Year / Freshman / Freshwoman / Freshperson", "Sophomore", "Junior", "Senior",
                 "Graduate student"], "allow_other": true},
    {"kind": "short", "prompt": "What are you planning to major/majoring in?", "required": true},
    {"kind": "scale", "prompt": "How would you rate your comfort level with computers?", "required": true,
     "scale_min": 1, "scale_max": 5, "min_label": "Not comfortable", "max_label": "Very comfortable"},
    {"kind": "multi", "prompt": "Which of the following programming languages have you used before?",
     "help": "Pick all that apply, or none.",
     "options": ["Python", "R", "JavaScript", "C/C++", "Java", "SQL", "SAS", "MATLAB"], "allow_other": true},
    {"kind": "single", "prompt": "How many college-level math classes have you taken?", "required": true,
     "options": ["None (0)", "1", "2", "3", "4", "5 or more"]},
    {"kind": "multi", "prompt": "What kind(s) of computer do you use or have access to?", "required": true,
     "options": ["Windows Laptop", "Windows PC", "Apple Mac Laptop (like a Macbook)", "Apple iMac",
                 "Chromebook", "iPad Tablet", "Linux"], "allow_other": true},
    {"kind": "single", "prompt": "Have you read the syllabus and course resources yet?", "required": true,
     "options": ["Yes", "No", "Maybe"]},
    {"kind": "single", "prompt": "Will you read the syllabus and course resources?", "required": true,
     "options": ["Yes", "No", "Maybe"]},
    {"kind": "single", "required": true,
     "prompt": "Outside of the classroom, how much time do you normally spend on classwork each week for each class on average?",
     "options": ["Less than 2 hours", "2-4 hours", "4-6 hours", "6-8 hours", "8-10 hours", "More than 10 hours"]},
    {"kind": "scale", "prompt": "On a scale of 1 to 5, how well do you handle obstacles and difficulty when they come up?",
     "required": true, "scale_min": 1, "scale_max": 5, "min_label": "Not well", "max_label": "Very well"},
    {"kind": "long", "prompt": "What's a piece of culture (movie, book, piece of music, video, game, etc) that you love that I should watch, read, listen to, or play?"},
    {"kind": "long", "prompt": "What was your favorite experience from this summer?",
     "help": "(Mine was hiking the redwoods in California.)"},
    {"kind": "single", "prompt": "Are you from North Carolina? (Just curious!)",
     "options": ["Yes", "No", "Sort of"]},
    {"kind": "long", "prompt": "What's something about you that you want me to know?",
     "help": "I won't share this with the class."},
    {"kind": "long", "prompt": "What's something about me (Dr. Parr) that you'd like to know?"},
    {"kind": "long", "prompt": "I learn best from teachers that ..."},
    {"kind": "long", "prompt": "I struggle to learn from teachers that ..."},
    {"kind": "long", "prompt": "Do you have any questions or concerns? What would you like to know?",
     "help": "I'll sum these up and answer them in class."}
  ]$json$::jsonb) loop
    v_pos := v_pos + 1;
    insert into public.poll_questions (poll_id, position, kind, prompt, help, options, allow_other,
                                       required, scale_min, scale_max, min_label, max_label)
    values (v_poll, v_pos, q ->> 'kind', q ->> 'prompt', q ->> 'help',
            coalesce(array(select jsonb_array_elements_text(q -> 'options')), '{}'),
            coalesce((q ->> 'allow_other')::boolean, false), coalesce((q ->> 'required')::boolean, false),
            coalesce((q ->> 'scale_min')::integer, 1), coalesce((q ->> 'scale_max')::integer, 5),
            q ->> 'min_label', q ->> 'max_label');
  end loop;
end;
$$;

-- 9. Push notifications (announcements) ------------------------------------------
-- A student who installs a course site on their home screen can tap
-- "Notifications" (bottom right, assets/notifications.html) and allow them.
-- Their browser then makes a push subscription: an address on Apple's,
-- Google's or Mozilla's push service plus two encryption keys. It is saved
-- here as one row, with the student's user id and the course code. It holds
-- no message content, only where to deliver.
--
-- The instructor writes an announcement on the admin page's Announcements
-- tab. The Supabase Edge Function `push` (supabase/functions/push/) checks
-- that the caller is an instructor of the course, reads the course's
-- subscriptions through admin_push_targets, sends the message to each one,
-- and removes the ones the push service says are gone (the student turned
-- notifications off or deleted the app) through admin_push_finish.
--
-- Students never read this table: RLS is on with no policies, and the
-- functions below only add or remove the caller's own rows.
create table if not exists public.push_subscriptions (
  endpoint   text primary key
             check (endpoint ~ '^https://' and length(endpoint) <= 1024),
  user_id    uuid not null references auth.users (id) on delete cascade,
  course     text not null references public.courses (course) on update cascade on delete cascade,
  p256dh     text not null check (length(p256dh) between 40 and 200),
  auth       text not null check (length(auth) between 8 and 100),
  user_agent text check (length(user_agent) <= 300),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_ok_at timestamptz                       -- last successful delivery
);

create index if not exists push_subscriptions_course_idx on public.push_subscriptions (course);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);

alter table public.push_subscriptions enable row level security;
revoke all on table public.push_subscriptions from anon, authenticated;

-- What was sent, for the admin page's list (no student data).
create table if not exists public.push_announcements (
  id         uuid primary key default gen_random_uuid(),
  course     text not null references public.courses (course) on update cascade on delete cascade,
  term       text,                             -- null = every active student
  title      text not null check (length(title) between 1 and 120),
  body       text not null default '' check (length(body) <= 400),
  url        text check (url is null or (url ~ '^/' and length(url) <= 500)),
  test       boolean not null default false,   -- sent only to the sender's own devices
  sent_by    text,
  sent_at    timestamptz not null default now(),
  devices    integer not null default 0,
  delivered  integer not null default 0,
  removed    integer not null default 0,
  failed     integer not null default 0
);

create index if not exists push_announcements_course_idx on public.push_announcements (course, sent_at desc);

alter table public.push_announcements enable row level security;
revoke all on table public.push_announcements from anon, authenticated;

-- Student (or instructor): save this browser's subscription for a course.
-- Only someone who may read that course can. Re-saving the same endpoint
-- (it's sent again on every page load) just refreshes it. Keeps at most 10
-- devices per person per course.
create or replace function public.save_push_subscription(
  p_course text, p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null
)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_course text := lower(btrim(coalesce(p_course, '')));
begin
  if auth.uid() is null or not public.is_current_user_approved(v_course) then
    raise exception 'Not signed in to this course.' using errcode = '42501';
  end if;
  insert into public.push_subscriptions (endpoint, user_id, course, p256dh, auth, user_agent)
  values (btrim(p_endpoint), auth.uid(), v_course, btrim(p_p256dh), btrim(p_auth), left(p_user_agent, 300))
  on conflict (endpoint) do update
    set user_id = excluded.user_id, course = excluded.course, p256dh = excluded.p256dh,
        auth = excluded.auth, user_agent = excluded.user_agent, updated_at = now();

  delete from public.push_subscriptions s
  where s.user_id = auth.uid() and s.course = v_course
    and s.endpoint not in (select s2.endpoint from public.push_subscriptions s2
                           where s2.user_id = auth.uid() and s2.course = v_course
                           order by s2.updated_at desc limit 10);
  return true;
end;
$$;

-- Student: forget this browser's subscription (they turned notifications off).
create or replace function public.delete_push_subscription(p_endpoint text)
returns boolean
language sql
volatile
security definer
set search_path = ''
as $$
  with d as (
    delete from public.push_subscriptions s
    where s.endpoint = btrim(p_endpoint) and s.user_id = auth.uid()
    returning 1
  )
  select exists (select 1 from d);
$$;

-- Admin: how many students and devices have notifications on.
create or replace function public.admin_push_summary(p_course text default null, p_term text default null)
returns table (course text, students bigint, devices bigint, instructor_devices bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(p_course);
begin
  return query
    select c.course,
           (select count(distinct s.user_id) from public.push_subscriptions s
            where s.course = c.course and exists (
              select 1 from public.roster r
              where r.user_id = s.user_id and r.course = c.course and r.active
                and (p_term is null or r.term = p_term))),
           (select count(*) from public.push_subscriptions s
            where s.course = c.course and exists (
              select 1 from public.roster r
              where r.user_id = s.user_id and r.course = c.course and r.active
                and (p_term is null or r.term = p_term))),
           (select count(*) from public.push_subscriptions s
            where s.course = c.course and s.user_id = auth.uid())
    from public.courses c
    where c.course = any (v_courses)
    order by c.course;
end;
$$;

-- Admin: the announcements sent for a course (newest first).
create or replace function public.admin_push_announcements(p_course text default null, p_limit integer default 50)
returns setof public.push_announcements
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_courses text[] := public.require_instructor(p_course);
begin
  return query
    select a.* from public.push_announcements a
    where a.course = any (v_courses)
    order by a.sent_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 500));
end;
$$;

-- Admin (called by the `push` Edge Function with the instructor's sign-in):
-- log an announcement and return it with the devices to send it to. One
-- course at a time. Students must be active on that course's roster (in
-- p_term, when given); with p_test, only the caller's own devices.
create or replace function public.admin_push_targets(
  p_course text, p_term text, p_title text, p_body text, p_url text, p_test boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_course  text := nullif(lower(btrim(coalesce(p_course, ''))), '');
  v_term    text := nullif(btrim(coalesce(p_term, '')), '');
  v_title   text := btrim(coalesce(p_title, ''));
  v_body    text := btrim(coalesce(p_body, ''));
  v_url     text := nullif(btrim(coalesce(p_url, '')), '');
  v_id      uuid;
  v_targets jsonb;
begin
  if v_course is null then
    raise exception 'Pick a course.';
  end if;
  perform public.require_instructor(v_course);
  if v_title = '' then raise exception 'The announcement needs a title.'; end if;
  if length(v_title) > 120 then raise exception 'Keep the title to 120 characters.'; end if;
  if length(v_body) > 400 then raise exception 'Keep the message to 400 characters.'; end if;
  if v_url is not null and v_url !~ '^/' then
    raise exception 'The link must be a page on the site, starting with / (for example /syllabus.html).';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)), '[]')
  into v_targets
  from public.push_subscriptions s
  where s.course = v_course
    and (case when coalesce(p_test, false) then s.user_id = auth.uid()
         else s.user_id = auth.uid()
           or exists (select 1 from public.roster r
                      where r.user_id = s.user_id and r.course = v_course and r.active
                        and (v_term is null or r.term = v_term))
         end);

  insert into public.push_announcements (course, term, title, body, url, test, sent_by, devices)
  values (v_course, v_term, v_title, v_body, v_url, coalesce(p_test, false),
          lower(btrim(auth.jwt() ->> 'email')), jsonb_array_length(v_targets))
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'targets', v_targets);
end;
$$;

-- Admin (the `push` Edge Function): record how sending went, and remove the
-- subscriptions the push service said no longer exist.
create or replace function public.admin_push_finish(
  p_id uuid, p_ok text[], p_gone text[], p_failed integer default 0
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_course  text;
  v_removed integer;
begin
  select a.course into v_course from public.push_announcements a where a.id = p_id;
  if v_course is null then raise exception 'No such announcement.'; end if;
  perform public.require_instructor(v_course);

  update public.push_subscriptions s set last_ok_at = now()
  where s.course = v_course and s.endpoint = any (coalesce(p_ok, '{}'));

  delete from public.push_subscriptions s
  where s.course = v_course and s.endpoint = any (coalesce(p_gone, '{}'));
  get diagnostics v_removed = row_count;

  update public.push_announcements a
  set delivered = coalesce(array_length(p_ok, 1), 0), removed = v_removed,
      failed = greatest(coalesce(p_failed, 0), 0)
  where a.id = p_id;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'save_push_subscription(text, text, text, text, text)', 'delete_push_subscription(text)',
    'admin_push_summary(text, text)', 'admin_push_announcements(text, integer)',
    'admin_push_targets(text, text, text, text, text, boolean)', 'admin_push_finish(uuid, text[], text[], integer)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end;
$$;

-- 10. Exercise answer keys ----------------------------------------------------------
-- The answer keys to the chapter exercises live in a private Storage bucket,
-- never in the textbook or its (public) repository. Each key is stored under
-- its course, for example geog215/regression-exercise-key.Rmd. Only an
-- instructor of that course can list, download, upload, replace or delete
-- one; students and signed-out visitors can't even see the file names. The
-- admin page's Exercise keys tab uses these.
insert into storage.buckets (id, name, public, file_size_limit)
values ('exercise-keys', 'exercise-keys', false, 10485760)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

drop policy if exists "Instructors read exercise keys" on storage.objects;
create policy "Instructors read exercise keys" on storage.objects
  for select to authenticated
  using (bucket_id = 'exercise-keys'
         and (storage.foldername(name))[1] is not null
         and public.is_instructor((storage.foldername(name))[1]));

drop policy if exists "Instructors add exercise keys" on storage.objects;
create policy "Instructors add exercise keys" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'exercise-keys'
              and (storage.foldername(name))[1] is not null
              and public.is_instructor((storage.foldername(name))[1]));

drop policy if exists "Instructors replace exercise keys" on storage.objects;
create policy "Instructors replace exercise keys" on storage.objects
  for update to authenticated
  using (bucket_id = 'exercise-keys'
         and (storage.foldername(name))[1] is not null
         and public.is_instructor((storage.foldername(name))[1]))
  with check (bucket_id = 'exercise-keys'
              and (storage.foldername(name))[1] is not null
              and public.is_instructor((storage.foldername(name))[1]));

drop policy if exists "Instructors delete exercise keys" on storage.objects;
create policy "Instructors delete exercise keys" on storage.objects
  for delete to authenticated
  using (bucket_id = 'exercise-keys'
         and (storage.foldername(name))[1] is not null
         and public.is_instructor((storage.foldername(name))[1]));

-- 11. Weekly quiz leaderboard ------------------------------------------------------
-- After a student finishes a chapter or unit quiz, the quiz page shows the top
-- 10 quiz scores in their course and term for the current week. Weeks end on
-- Friday: each one runs from Saturday 00:00 to Friday 23:59, Eastern time
-- (America/New_York). A student's weekly score is the total score of every
-- quiz session they started that week (finished or not), using the same
-- points as the Quiz scores tab (section 5c).
--
-- Privacy: other students never see names unless the student turns on "Show
-- my name" under the leaderboard (roster.show_on_leaderboard, per course and
-- term, off by default). Then classmates see their first name and last
-- initial ("Ada L."); everyone else is shown as "Classmate". Each student sees
-- their own row as "You". The admin page's Weekly quiz tab shows every
-- student's full name and weekly score to instructors.

alter table public.roster add column if not exists show_on_leaderboard boolean not null default false;

create index if not exists chapter_quiz_sessions_week_idx
  on public.chapter_quiz_sessions (course, term, started_at);

-- The Saturday that starts the quiz week holding p_at (Eastern time).
create or replace function public.quiz_week_start(p_at timestamptz default now())
returns date
language sql
stable
set search_path = ''
as $$
  select (p_at at time zone 'America/New_York')::date
         - ((extract(dow from (p_at at time zone 'America/New_York'))::int + 1) % 7);
$$;

grant execute on function public.quiz_week_start(timestamptz) to authenticated;

-- Every student's quiz totals for one course, term and week (internal: the
-- two functions below check who is asking first). p_week can be any day of
-- the week; it is moved back to that week's Saturday.
create or replace function public.quiz_week_totals(p_course text, p_term text, p_week date)
returns table (
  code text, user_id uuid, student_name text, active boolean, show_on_leaderboard boolean,
  score bigint, quizzes bigint, completed bigint, correct bigint, incorrect bigint,
  best_streak integer, first_at timestamptz, last_at timestamptz, chapters text
)
language sql
stable
security definer
set search_path = ''
as $$
  with w as (
    select d as week_start,
           (d::timestamp at time zone 'America/New_York') as t0,
           ((d + 7)::timestamp at time zone 'America/New_York') as t1
    from (select public.quiz_week_start((p_week::timestamp + interval '12 hours') at time zone 'America/New_York') as d) x
  )
  select r.code, r.user_id, r.student_name, r.active, r.show_on_leaderboard,
         coalesce(sum(s.score), 0)::bigint,
         count(s.id),
         count(s.id) filter (where s.completed_at is not null),
         coalesce(sum(s.correct), 0)::bigint,
         coalesce(sum(s.incorrect), 0)::bigint,
         coalesce(max(s.best_streak), 0),
         min(s.started_at),
         max(s.last_at),
         string_agg(distinct coalesce(s.chapter_title, s.chapter), '; ')
  from public.roster r
  cross join w
  left join public.chapter_quiz_sessions s
    on s.user_id = r.user_id and s.course = r.course and s.term = r.term
   and s.started_at >= w.t0 and s.started_at < w.t1
  where r.course = p_course and r.term = p_term
  group by r.code;
$$;

revoke all on function public.quiz_week_totals(text, text, date) from public, anon, authenticated;

-- The leaderboard a student sees: the top 10 of their course and term this
-- week (or the week holding p_week), plus their own row when they're not in
-- it. Ties share a rank; the 10 shown break ties by who got there first.
-- Instructors get the course's newest term, with no "You" row, so they can
-- see what students see.
drop function if exists public.quiz_week_leaderboard(text, date);
create or replace function public.quiz_week_leaderboard(p_course text default null, p_week date default null)
returns table (
  place integer, display_name text, score bigint, quizzes bigint,
  is_me boolean, name_shown boolean, week_start date, week_end date, players bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_course text;
  v_term   text;
  v_week   date := public.quiz_week_start(coalesce(
                     (p_week::timestamp + interval '12 hours') at time zone 'America/New_York', now()));
begin
  if auth.uid() is null then
    return;
  end if;
  select e.course, e.term into v_course, v_term from public.current_enrollment(p_course) e;
  if v_course is null then
    v_course := nullif(lower(btrim(coalesce(p_course, ''))), '');
    if v_course is null or not public.is_instructor(v_course) then
      return;
    end if;
    select r.term into v_term from public.roster r
    where r.course = v_course order by r.added_at desc limit 1;
    if v_term is null then
      return;
    end if;
  end if;

  return query
    with t as (
      select x.*, x.user_id = auth.uid() as me
      from public.quiz_week_totals(v_course, v_term, v_week) x
      where x.active and x.quizzes > 0
    ),
    ranked as (
      select t.*,
             rank() over (order by t.score desc)::int as place,
             row_number() over (order by t.score desc, t.last_at, t.code) as n,
             count(*) over () as players
      from t
    )
    select k.place,
           case when k.me then 'You'
                when k.show_on_leaderboard then
                  split_part(btrim(k.student_name), ' ', 1) ||
                  case when btrim(k.student_name) like '% %'
                       then ' ' || upper(left(regexp_replace(btrim(k.student_name), '^.*\s', ''), 1)) || '.'
                       else '' end
                else 'Classmate' end,
           k.score, k.quizzes, k.me, k.show_on_leaderboard,
           v_week, v_week + 6, k.players
    from ranked k
    where k.n <= 10 or k.me
    order by k.n;
end;
$$;

revoke all on function public.quiz_week_leaderboard(text, date) from public, anon;
grant execute on function public.quiz_week_leaderboard(text, date) to authenticated;

-- "Show my name on the leaderboard" (true) or hide it (false), for the
-- student's current enrollment in the course. Returns the new setting, or
-- null when the caller isn't an active student of the course.
create or replace function public.set_leaderboard_name(p_show boolean, p_course text default null)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_course text;
  v_term   text;
begin
  if auth.uid() is null then
    return null;
  end if;
  select e.course, e.term into v_course, v_term from public.current_enrollment(p_course) e;
  if v_course is null then
    return null;
  end if;
  update public.roster r set show_on_leaderboard = coalesce(p_show, false)
  where r.user_id = auth.uid() and r.course = v_course and r.term = v_term;
  return coalesce(p_show, false);
end;
$$;

revoke all on function public.set_leaderboard_name(boolean, text) from public, anon;
grant execute on function public.set_leaderboard_name(boolean, text) to authenticated;

-- Admin page, Weekly quiz tab: every student in the course and term with
-- their totals for the week holding p_week (this week when null).
create or replace function public.admin_quiz_week(p_course text, p_term text, p_week date default null)
returns table (
  code text, student_name text, email text, note text, active boolean, show_on_leaderboard boolean,
  score bigint, quizzes bigint, completed bigint, correct bigint, incorrect bigint,
  best_streak integer, first_at timestamptz, last_at timestamptz, chapters text,
  week_start date, week_end date
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(p_course);
  v_week    date := public.quiz_week_start(coalesce(
                      (p_week::timestamp + interval '12 hours') at time zone 'America/New_York', now()));
begin
  if array_length(v_courses, 1) is distinct from 1 or nullif(btrim(coalesce(p_term, '')), '') is null then
    raise exception 'Pick a course and a term to see weekly quiz scores.';
  end if;
  return query
    select t.code, t.student_name, r.email, r.note, t.active, t.show_on_leaderboard,
           t.score, t.quizzes, t.completed, t.correct, t.incorrect,
           t.best_streak, t.first_at, t.last_at, t.chapters,
           v_week, v_week + 6
    from public.quiz_week_totals(v_courses[1], p_term, v_week) t
    join public.roster r on r.code = t.code
    order by t.quizzes > 0 desc, t.score desc, t.student_name;
end;
$$;

-- The weeks with any quiz activity in a course and term (newest first), and
-- always the current week, for the Weekly quiz tab's week picker.
create or replace function public.admin_quiz_weeks(p_course text, p_term text)
returns table (week_start date, week_end date, students bigint, quizzes bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_courses text[] := public.require_instructor(p_course);
begin
  return query
    select w.d, w.d + 6, count(distinct s.user_id), count(s.id)
    from (
      select distinct public.quiz_week_start(s.started_at) as d
      from public.chapter_quiz_sessions s
      where s.course = any (v_courses) and s.term = p_term
      union
      select public.quiz_week_start(now())
    ) w
    left join public.chapter_quiz_sessions s
      on s.course = any (v_courses) and s.term = p_term
     and public.quiz_week_start(s.started_at) = w.d
    group by w.d
    order by w.d desc;
end;
$$;

revoke all on function public.admin_quiz_week(text, text, date) from public, anon;
grant execute on function public.admin_quiz_week(text, text, date) to authenticated;
revoke all on function public.admin_quiz_weeks(text, text) from public, anon;
grant execute on function public.admin_quiz_weeks(text, text) to authenticated;

-- Everyday tasks (the admin page at geog215.org/admin/ does most of these) --
--
-- Add students to a course and term (they can sign in with that email
-- straight away):
--
--   insert into public.roster (course, term, student_name, email) values
--     ('geog215', 'Spring 2027', 'Ada Lovelace', 'ada@unc.edu'),
--     ('geog215', 'Spring 2027', 'Grace Hopper', 'grace@unc.edu');
--
-- Add a class (then give its site SDS_COURSE = 'geog370'; see README.md):
--
--   insert into public.courses (course, title, site_url)
--   values ('geog370', 'GEOG 370: Intro to GIS', 'https://geog370.org');
--
-- Limit an instructor to some classes (null = every class):
--
--   update public.instructors set courses = '{geog370}' where email = 'ta@unc.edu';
--
-- See everyone and whether they have signed in yet:
--
--   select course, term, student_name, email, user_id is not null as signed_in, active
--   from public.roster order by course, term, student_name;
--
-- Lock a student out of a course (on their next page load) / let them back in:
--
--   update public.roster set active = false
--   where course = 'geog215' and term = 'Fall 2026' and email = 'ada@unc.edu';
--
-- End of term: lock out last term's students in one go:
--
--   update public.roster set active = false where course = 'geog215' and term = 'Fall 2026';
--
-- Who has opened what:
--
--   select * from public.instructor_progress order by course, term, student_name, page;

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
    'admin_chapter_quizzes(text, text)', 'admin_chapter_quiz_questions(text, text)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end;
$$;

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

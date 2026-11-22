-- GEOG 215 textbook: students sign in with an emailed one-time code or link
-- (no passwords).
--
-- Run once in the Supabase dashboard: SQL Editor > New query > paste > Run.
-- Safe to re-run. Step-by-step setup is in supabase/README.md.
--
-- How it works
--   1. roster holds one row per student: name and email (plus a random `code`
--      that the admin page uses as the row's id; students never see it).
--      Row-level security is on with no policies, so the browser (anon or
--      signed-in) can never read it. Add students on the admin page
--      (geog215.org/admin/), in Table Editor, or with SQL.
--   2. A student enters their email on the sign-in screen and Supabase emails
--      them a code and link (sent through Resend). The first time, that
--      creates their Supabase account, and a trigger links it to their
--      roster row.
--   3. A trigger on auth.users refuses any new account whose email isn't an
--      active, not-yet-linked roster row or an instructor, so nobody else
--      can get in by asking for a code.
--   4. is_current_user_approved() lets a signed-in student ask "am I still an
--      active student?" (only about themselves). The book calls it on every
--      page load, so setting active = false locks someone out.
--   5. page_progress records which pages each student has opened, keyed by
--      their Supabase user id. Students can only see their own rows; the
--      instructor_progress view and the admin page show it with names.

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

-- 2. The class roster ---------------------------------------------------------
create table if not exists public.roster (
  code         text primary key default public.new_access_code()
               check (code ~ '^[A-Z0-9]{6,16}$'),
  student_name text not null,
  email        text unique                   -- the student's sign-in email
               check (email = lower(btrim(email))),
  note         text,                         -- e.g. section, term, onyen
  active       boolean not null default true, -- false = locked out
  allow_reset  boolean not null default false,-- unused since passwords were retired
  user_id      uuid unique references auth.users (id) on delete set null,
  claimed_at   timestamptz,                  -- when they first signed in
  added_at     timestamptz not null default now()
);

-- Rosters created before email sign-in: add the email column.
alter table public.roster add column if not exists email text;
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.roster'::regclass and conname = 'roster_email_key') then
    alter table public.roster add constraint roster_email_key unique (email);
  end if;
  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.roster'::regclass and conname = 'roster_email_check') then
    alter table public.roster add constraint roster_email_check check (email = lower(btrim(email)));
  end if;
end;
$$;

alter table public.roster enable row level security;
revoke all on table public.roster from anon, authenticated;

-- 2b. Instructors (the admin page at geog215.org/admin/) ----------------------
-- Add your email here, then sign in at geog215.org/admin/ with the emailed
-- code. See supabase/README.md.
create table if not exists public.instructors (
  email    text primary key check (email = lower(btrim(email))),
  added_at timestamptz not null default now()
);

alter table public.instructors enable row level security;
revoke all on table public.instructors from anon, authenticated;

-- "Am I an instructor?" for the signed-in user. Every admin function below
-- checks this, so the admin page can't do anything for anyone else.
create or replace function public.is_instructor()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from public.instructors i
    where i.email = lower(btrim(auth.jwt() ->> 'email'))
  );
$$;

revoke all on function public.is_instructor() from public, anon;
grant execute on function public.is_instructor() to authenticated;

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
    raise exception 'This email is not on the GEOG 215 class list.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_roster_signup on auth.users;
create trigger enforce_roster_signup
  before insert on auth.users
  for each row execute function public.enforce_roster_signup();

-- Link each new account to its roster row.
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

-- Roster rows whose account already exists but isn't linked (for example an
-- account you made by hand in the dashboard).
update public.roster r
set user_id = u.id, claimed_at = coalesce(r.claimed_at, now())
from auth.users u
where r.user_id is null
  and r.email = lower(btrim(u.email))
  and not exists (select 1 from public.roster r2 where r2.user_id = u.id);

-- 4. "Am I an active student?" for the signed-in user only --------------------
-- Instructors count too, so you can read the book while signed in to /admin/.
create or replace function public.is_current_user_approved()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.roster r
    where r.user_id = auth.uid() and r.active
  ) or public.is_instructor();
$$;

revoke all on function public.is_current_user_approved() from public, anon;
grant execute on function public.is_current_user_approved() to authenticated;

-- 5. Progress -----------------------------------------------------------------
create table if not exists public.page_progress (
  user_id     uuid not null default auth.uid()
              references auth.users (id) on delete cascade,
  page        text not null,                 -- e.g. /chapters/census-data-apis.html
  first_visit timestamptz not null default now(),
  last_visit  timestamptz not null default now(),
  visits      integer not null default 1,
  primary key (user_id, page)
);

alter table public.page_progress enable row level security;
revoke all on table public.page_progress from anon, authenticated;
grant select on table public.page_progress to authenticated;

drop policy if exists "Students read their own progress" on public.page_progress;
create policy "Students read their own progress"
  on public.page_progress for select
  to authenticated
  using (user_id = (select auth.uid()));

-- Students write progress only through this function, so they can't edit
-- their own counts or anyone else's.
create or replace function public.record_page_visit(p_page text)
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
begin
  -- Only active students; your own visits as instructor aren't recorded.
  if auth.uid() is null or public.is_instructor()
     or not public.is_current_user_approved() then
    return;
  end if;
  if v_page = '' then v_page := '/'; end if;
  insert into public.page_progress as p (user_id, page)
  values (auth.uid(), v_page)
  on conflict (user_id, page) do update
    set last_visit = now(), visits = p.visits + 1;
end;
$$;

revoke all on function public.record_page_visit(text) from public, anon;
grant execute on function public.record_page_visit(text) to authenticated;

-- For you (SQL Editor / Table Editor only; students can't read it).
create or replace view public.instructor_progress
with (security_invoker = true) as
select r.student_name,
       r.note,
       r.code,
       p.page,
       p.first_visit,
       p.last_visit,
       p.visits
from public.roster r
join public.page_progress p on p.user_id = r.user_id;

revoke all on table public.instructor_progress from anon, authenticated;

-- 5b. Self-check quiz answers and code runs -------------------------------------
-- The book's webexercises questions and webR code cells report here through
-- record_quiz_answer() and record_code_run() (called by assets/auth-gate.html).
-- Like page_progress: one row per student and question (or code cell) with
-- running totals, keyed by Supabase user id; students only see their own rows.
-- Whether an answer was correct is decided in the browser (the answers are in
-- the page), so treat it as a self-check record, not a grade.

create table if not exists public.quiz_responses (
  user_id          uuid not null default auth.uid()
                   references auth.users (id) on delete cascade,
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
  primary key (user_id, page, question)
);

create table if not exists public.code_runs (
  user_id    uuid not null default auth.uid()
             references auth.users (id) on delete cascade,
  page       text not null,
  cell       text not null,                -- id made in the browser from the cell's starting code
  label      text,                         -- section heading and first line of code
  runs       integer not null default 1,
  error_runs integer not null default 0,   -- runs that ended in an R error
  last_code  text,                         -- the code as last run (first 4000 characters)
  last_error boolean not null default false,
  first_run  timestamptz not null default now(),
  last_run   timestamptz not null default now(),
  primary key (user_id, page, cell)
);

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

-- Same rule as record_page_visit: active students only, never instructors.
create or replace function public.record_quiz_answer(
  p_page text, p_question text, p_label text, p_answer text, p_correct boolean)
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
begin
  if auth.uid() is null or public.is_instructor()
     or not public.is_current_user_approved() or v_question = '' then
    return;
  end if;
  insert into public.quiz_responses as q
    (user_id, page, question, label, correct, ever_correct, last_answer, first_correct_at)
  values (auth.uid(), v_page, v_question, left(p_label, 500), v_correct, v_correct,
          left(p_answer, 500), case when v_correct then now() end)
  on conflict (user_id, page, question) do update
    set attempts         = q.attempts + 1,
        label            = coalesce(excluded.label, q.label),
        correct          = excluded.correct,
        ever_correct     = q.ever_correct or excluded.correct,
        last_answer      = excluded.last_answer,
        first_correct_at = coalesce(q.first_correct_at, excluded.first_correct_at),
        last_at          = now();
end;
$$;

create or replace function public.record_code_run(
  p_page text, p_cell text, p_label text, p_code text, p_error boolean)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_page  text := public.normalize_page(left(p_page, 300));
  v_cell  text := left(btrim(coalesce(p_cell, '')), 100);
  v_error boolean := coalesce(p_error, false);
begin
  if auth.uid() is null or public.is_instructor()
     or not public.is_current_user_approved() or v_cell = '' then
    return;
  end if;
  insert into public.code_runs as c
    (user_id, page, cell, label, error_runs, last_code, last_error)
  values (auth.uid(), v_page, v_cell, left(p_label, 300), v_error::int,
          left(p_code, 4000), v_error)
  on conflict (user_id, page, cell) do update
    set runs       = c.runs + 1,
        error_runs = c.error_runs + excluded.error_runs,
        label      = coalesce(excluded.label, c.label),
        last_code  = excluded.last_code,
        last_error = excluded.last_error,
        last_run   = now();
end;
$$;

revoke all on function public.record_quiz_answer(text, text, text, text, boolean) from public, anon;
grant execute on function public.record_quiz_answer(text, text, text, text, boolean) to authenticated;
revoke all on function public.record_code_run(text, text, text, text, boolean) from public, anon;
grant execute on function public.record_code_run(text, text, text, text, boolean) to authenticated;

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

create index if not exists chapter_quiz_sessions_user_idx
  on public.chapter_quiz_sessions (user_id, chapter);

-- Running totals for each student and question, across all their sessions.
create table if not exists public.chapter_quiz_answers (
  user_id           uuid not null default auth.uid()
                    references auth.users (id) on delete cascade,
  chapter           text not null,
  question          text not null,                -- the question's id in the bank
  label             text,                         -- the question text, for the admin page
  correct           integer not null default 0,
  incorrect         integer not null default 0,
  first_try_correct integer not null default 0,
  first_try_total   integer not null default 0,   -- times it was asked fresh
  last_at           timestamptz not null default now(),
  primary key (user_id, chapter, question)
);

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

-- One answer. The first answer of a session creates the session row.
create or replace function public.record_chapter_quiz_answer(
  p_session uuid, p_chapter text, p_chapter_title text, p_size integer,
  p_question text, p_label text, p_correct boolean, p_first_try boolean)
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
begin
  if auth.uid() is null or public.is_instructor()
     or not public.is_current_user_approved()
     or p_session is null or v_chapter = '' or v_question = '' then
    return;
  end if;

  insert into public.chapter_quiz_sessions (id, user_id, chapter, chapter_title, questions)
  values (p_session, auth.uid(), v_chapter, left(p_chapter_title, 200),
          least(greatest(coalesce(p_size, 0), 0), 100))
  on conflict (id) do nothing;

  -- Only the student's own, unfinished session (a session id can't be reused
  -- to add answers to someone else's).
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
  where s.id = p_session and s.user_id = auth.uid() and s.completed_at is null;
  if not found then
    return;
  end if;

  insert into public.chapter_quiz_answers as a
    (user_id, chapter, question, label, correct, incorrect, first_try_correct, first_try_total)
  values (auth.uid(), v_chapter, v_question, left(p_label, 500),
          v_correct::int, (not v_correct)::int, (v_correct and v_first)::int, v_first::int)
  on conflict (user_id, chapter, question) do update
    set correct           = a.correct + excluded.correct,
        incorrect         = a.incorrect + excluded.incorrect,
        first_try_correct = a.first_try_correct + excluded.first_try_correct,
        first_try_total   = a.first_try_total + excluded.first_try_total,
        label             = coalesce(excluded.label, a.label),
        last_at           = now();
end;
$$;

-- Every question answered correctly: the session is finished.
create or replace function public.record_chapter_quiz_finish(p_session uuid)
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

revoke all on function public.record_chapter_quiz_answer(uuid, text, text, integer, text, text, boolean, boolean) from public, anon;
grant execute on function public.record_chapter_quiz_answer(uuid, text, text, integer, text, text, boolean, boolean) to authenticated;
revoke all on function public.record_chapter_quiz_finish(uuid) from public, anon;
grant execute on function public.record_chapter_quiz_finish(uuid) to authenticated;

-- 6. Admin page functions (instructors only) ------------------------------------
-- Used by geog215.org/admin/. Each one stops with "Instructors only." unless
-- the caller is signed in as an instructor, so the admin page can't be used by
-- anyone else even though the page itself is public.

create or replace function public.require_instructor()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_instructor() then
    raise exception 'Instructors only.' using errcode = '42501';
  end if;
end;
$$;

revoke all on function public.require_instructor() from public, anon, authenticated;

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

-- Every student with their status and activity totals.
-- (Dropped first because its columns change from time to time: passwords were
-- retired, then quiz and code totals were added, then chapter quiz scores.)
drop function if exists public.admin_roster();
create or replace function public.admin_roster()
returns table (
  code text, student_name text, email text, note text, active boolean,
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
begin
  perform public.require_instructor();
  return query
    select r.code, r.student_name, r.email, r.note, r.active,
           r.user_id is not null, r.claimed_at, r.added_at,
           count(distinct public.normalize_page(p.page)) filter (where p.page is not null),
           coalesce(sum(p.visits), 0)::bigint,
           greatest(max(p.last_visit),
                    (select max(q.last_at) from public.quiz_responses q where q.user_id = r.user_id),
                    (select max(c.last_run) from public.code_runs c where c.user_id = r.user_id),
                    (select max(s.last_at) from public.chapter_quiz_sessions s where s.user_id = r.user_id)),
           (select count(*) from public.quiz_responses q where q.user_id = r.user_id),
           (select count(*) from public.quiz_responses q where q.user_id = r.user_id and q.ever_correct),
           (select coalesce(sum(c.runs), 0) from public.code_runs c where c.user_id = r.user_id)::bigint,
           (select coalesce(sum(c.error_runs), 0) from public.code_runs c where c.user_id = r.user_id)::bigint,
           (select coalesce(sum(s.correct), 0) from public.chapter_quiz_sessions s where s.user_id = r.user_id)::bigint,
           (select coalesce(sum(s.incorrect), 0) from public.chapter_quiz_sessions s where s.user_id = r.user_id)::bigint,
           (select count(*) from public.chapter_quiz_sessions s where s.user_id = r.user_id and s.completed_at is not null),
           (select coalesce(sum(s.score), 0) from public.chapter_quiz_sessions s where s.user_id = r.user_id)::bigint
    from public.roster r
    left join public.page_progress p on p.user_id = r.user_id
    group by r.code
    order by r.student_name, r.code;
end;
$$;

-- Add students. p_students is a JSON array like
--   [{"name": "Ada Lovelace", "email": "ada@unc.edu"}, ...]
-- Returns each new student. Emails already on the roster are skipped (not
-- returned).
drop function if exists public.admin_add_students(text[], text);
create or replace function public.admin_add_students(p_students jsonb, p_note text default null)
returns table (student_name text, email text, code text)
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  bad text;
begin
  perform public.require_instructor();
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
    insert into public.roster as r (student_name, email, note)
    select coalesce(nullif(btrim(t.el ->> 'name'), ''), split_part(lower(btrim(t.el ->> 'email')), '@', 1)),
           lower(btrim(t.el ->> 'email')),
           nullif(btrim(coalesce(p_note, '')), '')
    from jsonb_array_elements(p_students) with ordinality as t(el, ord)
    order by t.ord
    on conflict (email) do nothing
    returning r.student_name, r.email, r.code;
end;
$$;

-- Lock a student out (false) or let them back in (true).
create or replace function public.admin_set_active(p_code text, p_active boolean)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform public.require_instructor();
  update public.roster r set active = p_active where r.code = upper(btrim(p_code));
  if not found then raise exception 'No student has the code %.', p_code; end if;
end;
$$;

-- Password resets were retired with passwords.
drop function if exists public.admin_allow_reset(text, boolean);

-- Remove a student completely: roster row, account, and progress.
create or replace function public.admin_delete_student(p_code text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user uuid;
begin
  perform public.require_instructor();
  delete from public.roster r
  where r.code = upper(btrim(p_code))
  returning r.user_id into v_user;
  if not found then raise exception 'No student has the code %.', p_code; end if;
  if v_user is not null then
    delete from auth.users u where u.id = v_user;   -- also deletes their progress
  end if;
end;
$$;

-- Most recent page visits across the class.
create or replace function public.admin_activity(p_limit integer default 200)
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
begin
  perform public.require_instructor();
  return query
    select r.student_name, r.code, public.normalize_page(p.page),
           p.first_visit, p.last_visit, p.visits
    from public.page_progress p
    join public.roster r on r.user_id = p.user_id
    order by p.last_visit desc
    limit least(greatest(coalesce(p_limit, 200), 1), 2000);
end;
$$;

-- Each page: how many students have opened it, and how often.
create or replace function public.admin_pages()
returns table (page text, students bigint, visits bigint, last_visit timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  perform public.require_instructor();
  return query
    select public.normalize_page(p.page) as pg,
           count(distinct p.user_id),
           sum(p.visits)::bigint,
           max(p.last_visit)
    from public.page_progress p
    join public.roster r on r.user_id = p.user_id
    group by pg
    order by pg;
end;
$$;

-- Each quiz question: how many students answered it and got it right.
create or replace function public.admin_quiz()
returns table (
  page text, question text, label text, students bigint,
  students_correct bigint, attempts bigint, last_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  perform public.require_instructor();
  return query
    select q.page, q.question, max(q.label),
           count(*), count(*) filter (where q.ever_correct),
           sum(q.attempts)::bigint, max(q.last_at)
    from public.quiz_responses q
    join public.roster r on r.user_id = q.user_id
    group by q.page, q.question
    order by q.page, min(q.first_at);
end;
$$;

-- Quiz answers, newest first: one student's (p_code) or everyone's.
create or replace function public.admin_quiz_responses(p_code text default null, p_limit integer default 1000)
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
begin
  perform public.require_instructor();
  return query
    select r.student_name, r.code, q.page, q.question, q.label,
           q.attempts, q.correct, q.ever_correct, q.last_answer, q.first_at, q.last_at
    from public.quiz_responses q
    join public.roster r on r.user_id = q.user_id
    where p_code is null or r.code = upper(btrim(p_code))
    order by q.last_at desc
    limit least(greatest(coalesce(p_limit, 1000), 1), 5000);
end;
$$;

-- Each code cell: how many students ran it, how often, and how often it errored.
create or replace function public.admin_code()
returns table (
  page text, cell text, label text, students bigint,
  runs bigint, error_runs bigint, last_run timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  perform public.require_instructor();
  return query
    select c.page, c.cell, max(c.label), count(*),
           sum(c.runs)::bigint, sum(c.error_runs)::bigint, max(c.last_run)
    from public.code_runs c
    join public.roster r on r.user_id = c.user_id
    group by c.page, c.cell
    order by c.page, min(c.first_run);
end;
$$;

-- Code runs, newest first: one student's (p_code) or everyone's.
create or replace function public.admin_code_runs(p_code text default null, p_limit integer default 1000)
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
begin
  perform public.require_instructor();
  return query
    select r.student_name, r.code, c.page, c.cell, c.label,
           c.runs, c.error_runs, c.last_code, c.last_error, c.first_run, c.last_run
    from public.code_runs c
    join public.roster r on r.user_id = c.user_id
    where p_code is null or r.code = upper(btrim(p_code))
    order by c.last_run desc
    limit least(greatest(coalesce(p_limit, 1000), 1), 5000);
end;
$$;

-- Chapter quizzes: one row per student and chapter. score is the sum over all
-- of that student's quizzes for the chapter; best_score is their best one quiz.
-- (Dropped first because scores were added to its columns.)
drop function if exists public.admin_chapter_quizzes();
create or replace function public.admin_chapter_quizzes()
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
begin
  perform public.require_instructor();
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
    join public.roster r on r.user_id = s.user_id
    group by r.code, r.student_name, s.chapter
    order by r.student_name, s.chapter;
end;
$$;

-- Chapter quizzes: each question's totals across the class.
create or replace function public.admin_chapter_quiz_questions()
returns table (
  chapter text, question text, label text, students bigint,
  correct bigint, incorrect bigint, first_try_correct bigint, first_try_total bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  perform public.require_instructor();
  return query
    select a.chapter, a.question, max(a.label), count(*),
           sum(a.correct)::bigint, sum(a.incorrect)::bigint,
           sum(a.first_try_correct)::bigint, sum(a.first_try_total)::bigint
    from public.chapter_quiz_answers a
    join public.roster r on r.user_id = a.user_id
    group by a.chapter, a.question
    order by a.chapter, a.question;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'admin_roster()', 'admin_add_students(jsonb, text)',
    'admin_set_active(text, boolean)',
    'admin_delete_student(text)', 'admin_activity(integer)', 'admin_pages()',
    'admin_quiz()', 'admin_quiz_responses(text, integer)',
    'admin_code()', 'admin_code_runs(text, integer)',
    'admin_chapter_quizzes()', 'admin_chapter_quiz_questions()'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end;
$$;

-- Everyday tasks (the admin page at geog215.org/admin/ does all of these) ---
--
-- Add students (they can sign in with that email straight away):
--
--   insert into public.roster (student_name, email, note) values
--     ('Ada Lovelace', 'ada@unc.edu',   'Spring 2027'),
--     ('Grace Hopper', 'grace@unc.edu', 'Spring 2027');
--
-- See everyone and whether they have signed in yet:
--
--   select student_name, email, note, user_id is not null as signed_in, active
--   from public.roster order by student_name;
--
-- Lock a student out (on their next page load) / let them back in:
--
--   update public.roster set active = false where email = 'ada@unc.edu';
--
-- Who has opened what:
--
--   select * from public.instructor_progress order by student_name, page;

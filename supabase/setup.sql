-- GEOG 215 textbook: students sign in with their email and a password.
--
-- Run once in the Supabase dashboard: SQL Editor > New query > paste > Run.
-- Safe to re-run. Step-by-step setup is in supabase/README.md.
--
-- How it works
--   1. roster holds one row per student: name, email, and a random one-time
--      setup code. Row-level security is on with no policies, so the browser
--      (anon or signed-in) can never read it. Add students on the admin page
--      (geog215.org/admin/), in Table Editor, or with SQL.
--   2. The first time, a student enters their email, their setup code and a
--      new password. The redeem-code Edge Function
--      (supabase/functions/redeem-code) checks that the email and code match,
--      creates a Supabase account with that email (already marked confirmed,
--      so no email is ever sent), and links it to the roster row. After that
--      the student signs in with email + password.
--   3. A trigger on auth.users refuses any new account that the redeem
--      function did not set up for a roster row (or that isn't an
--      instructor), so nobody can sign up around it.
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
  allow_reset  boolean not null default false,-- true = may pick a new password
  user_id      uuid unique references auth.users (id) on delete set null,
  claimed_at   timestamptz,                  -- when the code was first used
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
-- Add your email here, then create your account in the dashboard
-- (Authentication > Users > Add user > Create new user, with "Auto Confirm
-- User" ticked). See supabase/README.md.
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

-- 3. Only the redeem function can create accounts -----------------------------
-- The redeem function marks the roster row (claimed_at set, user_id still
-- empty) just before it creates the account. Any other insert into
-- auth.users, such as a direct sign-up from the browser, is refused.
create or replace function public.enforce_roster_signup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Instructor accounts, created by you in the dashboard.
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
      and r.claimed_at is not null
  ) then
    raise exception 'Accounts for the GEOG 215 textbook are created from a setup code.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_roster_signup on auth.users;
create trigger enforce_roster_signup
  before insert on auth.users
  for each row execute function public.enforce_roster_signup();

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
-- (Dropped first because its columns changed when email sign-in was added.)
drop function if exists public.admin_roster();
create or replace function public.admin_roster()
returns table (
  code text, student_name text, email text, note text, active boolean, allow_reset boolean,
  set_up boolean, claimed_at timestamptz, added_at timestamptz,
  pages_opened bigint, total_visits bigint, last_active timestamptz
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
    select r.code, r.student_name, r.email, r.note, r.active, r.allow_reset,
           r.user_id is not null, r.claimed_at, r.added_at,
           count(distinct public.normalize_page(p.page)) filter (where p.page is not null),
           coalesce(sum(p.visits), 0)::bigint,
           max(p.last_visit)
    from public.roster r
    left join public.page_progress p on p.user_id = r.user_id
    group by r.code
    order by r.student_name, r.code;
end;
$$;

-- Add students. p_students is a JSON array like
--   [{"name": "Ada Lovelace", "email": "ada@unc.edu"}, ...]
-- Returns each new student with their setup code. Emails already on the
-- roster are skipped (not returned).
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

-- Let a student choose a new password with their code ("First time here?").
create or replace function public.admin_allow_reset(p_code text, p_allow boolean default true)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform public.require_instructor();
  update public.roster r set allow_reset = p_allow where r.code = upper(btrim(p_code));
  if not found then raise exception 'No student has the code %.', p_code; end if;
end;
$$;

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

do $$
declare f text;
begin
  foreach f in array array[
    'admin_roster()', 'admin_add_students(jsonb, text)',
    'admin_set_active(text, boolean)', 'admin_allow_reset(text, boolean)',
    'admin_delete_student(text)', 'admin_activity(integer)', 'admin_pages()'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end;
$$;

-- Everyday tasks (the admin page at geog215.org/admin/ does all of these) ---
--
-- Add students; each gets a random setup code. Send each student their code:
--
--   insert into public.roster (student_name, email, note) values
--     ('Ada Lovelace', 'ada@unc.edu',   'Spring 2027'),
--     ('Grace Hopper', 'grace@unc.edu', 'Spring 2027')
--   returning student_name, email, code;
--
-- See everyone and whether they have set up a password:
--
--   select student_name, email, note, code, user_id is not null as set_up, active
--   from public.roster order by student_name;
--
-- Forgotten password: let the student pick a new one with their email and
-- setup code ("First time here?" on the sign-in page):
--
--   update public.roster set allow_reset = true where email = 'ada@unc.edu';
--
-- Lock a student out (on their next page load) / let them back in:
--
--   update public.roster set active = false where email = 'ada@unc.edu';
--
-- Who has opened what:
--
--   select * from public.instructor_progress order by student_name, page;

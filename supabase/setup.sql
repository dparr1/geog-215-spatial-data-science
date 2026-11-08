-- GEOG 215 textbook: students sign in with an instructor-issued access code.
--
-- Run once in the Supabase dashboard: SQL Editor > New query > paste > Run.
-- Safe to re-run. Step-by-step setup is in supabase/README.md.
--
-- How it works
--   1. roster holds one random access code per student. Row-level security is
--      on with no policies, so the browser (anon or signed-in) can never read
--      it. Edit it from the dashboard (Table Editor) or the SQL editor.
--   2. The first time, a student enters their code and picks a password. The
--      redeem-code Edge Function (supabase/functions/redeem-code) checks the
--      code, creates a Supabase account for it with a made-up address
--      (<code>@students.geog215.org, already marked confirmed, so no email is
--      ever sent), and links that account to the roster row. After that the
--      student signs in with code + password.
--   3. A trigger on auth.users refuses any new account that the redeem
--      function did not set up for a roster code, so nobody can sign up
--      around it.
--   4. is_current_user_approved() lets a signed-in student ask "am I still an
--      active student?" (only about themselves). The book calls it on every
--      page load, so setting active = false locks someone out.
--   5. page_progress records which pages each student has opened, keyed by
--      their Supabase user id. Students can only see their own rows; the
--      instructor_progress view joins it to student names for you.

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
  note         text,                         -- e.g. section, term, onyen
  active       boolean not null default true, -- false = locked out
  allow_reset  boolean not null default false,-- true = may pick a new password
  user_id      uuid unique references auth.users (id) on delete set null,
  claimed_at   timestamptz,                  -- when the code was first used
  added_at     timestamptz not null default now()
);

alter table public.roster enable row level security;
revoke all on table public.roster from anon, authenticated;

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
  if not exists (
    select 1 from public.roster r
    where lower(btrim(new.email)) = lower(r.code) || '@students.geog215.org'
      and r.active
      and r.user_id is null
      and r.claimed_at is not null
  ) then
    raise exception 'Accounts for the GEOG 215 textbook are created from an access code.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_roster_signup on auth.users;
create trigger enforce_roster_signup
  before insert on auth.users
  for each row execute function public.enforce_roster_signup();

-- 4. "Am I an active student?" for the signed-in user only --------------------
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
  );
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
begin
  if auth.uid() is null or not public.is_current_user_approved() then
    return;
  end if;
  insert into public.page_progress as p (user_id, page)
  values (auth.uid(), left(p_page, 300))
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

-- Everyday tasks (copy into the SQL editor) ------------------------------------
--
-- Add students; each gets a random code. Copy the result into Canvas:
--
--   insert into public.roster (student_name, note) values
--     ('Ada Lovelace', 'Spring 2027'),
--     ('Grace Hopper', 'Spring 2027')
--   returning student_name, code;
--
-- See every code and whether it has been used:
--
--   select student_name, note, code, claimed_at is not null as set_up, active
--   from public.roster order by student_name;
--
-- Forgotten password: let the student pick a new one with the same code
-- ("First time here?" on the sign-in page):
--
--   update public.roster set allow_reset = true where code = 'ABCD2345';
--
-- Lock a student out (on their next page load) / let them back in:
--
--   update public.roster set active = false where code = 'ABCD2345';
--
-- Who has opened what:
--
--   select * from public.instructor_progress order by student_name, page;

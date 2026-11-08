-- GEOG 215 textbook: only pre-approved emails can sign in.
--
-- Run once in the Supabase dashboard: SQL Editor > New query > paste > Run.
-- Safe to re-run.
--
-- How it works
--   1. approved_emails holds the class list. Row-level security is on with no
--      policies, so the browser (anon or signed-in) can never read the list.
--      Edit it from the dashboard (Table Editor) or the SQL editor.
--   2. A trigger on auth.users refuses to create an account for any email not
--      on the list, so unapproved addresses never receive a sign-in code.
--   3. is_current_user_approved() lets a signed-in student ask "am I still on
--      the list?" (only about themselves). The book calls it after every
--      sign-in and page load, so removing someone locks them out.

-- 1. The class list --------------------------------------------------------
create table if not exists public.approved_emails (
  email    text primary key check (email = lower(btrim(email))),
  note     text,                                  -- e.g. section, term
  added_at timestamptz not null default now()
);

alter table public.approved_emails enable row level security;
revoke all on table public.approved_emails from anon, authenticated;

-- 2. Block sign-ups from emails not on the list ----------------------------
create or replace function public.enforce_approved_signup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.approved_emails a
    where a.email = lower(btrim(new.email))
  ) then
    raise exception 'This email is not approved for the GEOG 215 textbook.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_approved_signup on auth.users;
create trigger enforce_approved_signup
  before insert on auth.users
  for each row execute function public.enforce_approved_signup();

-- 3. "Am I approved?" for the signed-in user only ---------------------------
create or replace function public.is_current_user_approved()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.approved_emails a
    where a.email = lower(btrim(auth.jwt() ->> 'email'))
  );
$$;

revoke all on function public.is_current_user_approved() from public, anon;
grant execute on function public.is_current_user_approved() to authenticated;

-- Adding students ------------------------------------------------------------
-- Emails must be lowercase. Example:
--
-- insert into public.approved_emails (email, note) values
--   ('student1@unc.edu', 'Spring 2027'),
--   ('student2@unc.edu', 'Spring 2027')
-- on conflict (email) do nothing;
--
-- Removing a student (they are locked out on their next page load):
--
-- delete from public.approved_emails where email = 'student1@unc.edu';

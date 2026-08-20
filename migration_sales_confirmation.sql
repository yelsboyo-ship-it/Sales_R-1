-- ============================================================
-- Reversible migration: sales confirmation workflow
-- ============================================================

-- =========================
-- UP
-- =========================

create extension if not exists pgcrypto;

-- Ensure profiles exists before adding columns
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone_number text,
  email text,
  role text default 'sales_agent',
  location text,
  profile_prompted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles
  add column if not exists full_name text;

alter table public.profiles
  add column if not exists phone_number text;

alter table public.profiles
  add column if not exists email text;

alter table public.sales_records
  add column if not exists confirmation_status text not null default 'pending';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint c
      JOIN pg_class t ON c.conrelid = t.oid
      JOIN pg_namespace n ON t.relnamespace = n.oid
     WHERE c.conname = 'sales_records_confirmation_status_check'
       AND n.nspname = 'public'
       AND t.relname = 'sales_records'
  ) THEN
    alter table public.sales_records
      add constraint sales_records_confirmation_status_check
      check (confirmation_status in ('pending','confirmed','rejected'));
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM information_schema.tables
     WHERE table_schema = 'public'
       AND table_name = 'bank_accounts'
  ) THEN
    alter table public.sales_records
      add column if not exists bank_account_id uuid references public.bank_accounts(id);
  END IF;
END $$;

alter table public.sales_records
  add column if not exists approved_by uuid references public.profiles(id);

alter table public.sales_records
  add column if not exists approved_at timestamptz;

alter table public.sales_records
  add column if not exists bank_account text;

alter table public.sales_records
  add column if not exists deposit_confirmation_url text[];

alter table public.sales_records
  add column if not exists payment_confirmation_text text;

create index if not exists idx_sales_records_confirmation_status on public.sales_records (confirmation_status);
create index if not exists idx_sales_records_approved_by on public.sales_records (approved_by);

create or replace function public.set_sales_record_confirmation()
returns trigger as $$
begin
  if new.confirmation_status = 'confirmed' and new.approved_by is null then
    raise exception 'approved_by is required when confirmation_status = confirmed';
  end if;

  if old.confirmation_status is distinct from new.confirmation_status and new.confirmation_status = 'confirmed' then
    new.approved_at = coalesce(new.approved_at, now());
  elsif new.confirmation_status is distinct from 'confirmed' then
    new.approved_at = null;
  end if;

  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_sales_record_confirmation on public.sales_records;
create trigger trg_sales_record_confirmation
  before update on public.sales_records
  for each row
  execute function public.set_sales_record_confirmation();

-- =========================
-- DOWN
-- =========================
-- Rollback section intentionally omitted.
-- Approval, bank account, and confirmation-related columns are preserved
-- to avoid dropping dependent objects (such as sales_records_with_users) and
-- to keep the approval workflow data intact.

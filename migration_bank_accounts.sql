-- Migration: bank_accounts table, link to sales_records, and balance tracking
-- NOTE: Run in order against the existing Supabase/Postgres schema.

-- ============================================================
-- A. Create bank_accounts table
-- ============================================================
create extension if not exists pgcrypto;

create table if not exists public.bank_accounts (
  id uuid primary key default gen_random_uuid(),
  account_name text not null,
  bank_name text not null,
  account_number text not null,
  branch text,
  currency text not null default 'KES',
  current_balance numeric(14,2) not null default 0,
  is_active boolean not null default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bank_accounts_unique_account unique (bank_name, account_number)
);

create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_bank_accounts_set_updated_at on public.bank_accounts;
create trigger trg_bank_accounts_set_updated_at
before update on public.bank_accounts
for each row
execute function public.set_updated_at();

-- ============================================================
-- B. Link sales_records to bank_accounts
-- ============================================================
alter table public.sales_records
  add column if not exists bank_account_id uuid references public.bank_accounts(id);

-- Best-effort data migration from old text values.
-- Existing text values are mapped to bank_accounts.account_name first, then bank_name.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'sales_records' and column_name = 'bank_account'
  ) then
    update public.sales_records sr
    set bank_account_id = ba.id
    from public.bank_accounts ba
    where sr.bank_account_id is null
      and (
        lower(trim(coalesce(sr.bank_account, ''))) = lower(trim(ba.account_name))
        or lower(trim(coalesce(sr.bank_account, ''))) = lower(trim(ba.bank_name))
      );
  end if;
end $$;

-- Optional: if the old text column exists, leave it in place for now.
-- The following step can be run later after you confirm the mapping is correct:
-- alter table public.sales_records drop column if exists bank_account;

-- ============================================================
-- C. Legacy compatibility helpers
-- ============================================================
create table if not exists public.bank_account_adjustments (
  id uuid primary key default gen_random_uuid(),
  bank_account_id uuid not null references public.bank_accounts(id) on delete cascade,
  adjustment_amount numeric(14,2) not null,
  reason text not null,
  old_balance numeric(14,2) not null,
  new_balance numeric(14,2) not null,
  adjusted_by uuid references public.profiles(id),
  adjusted_at timestamptz not null default now()
);

drop trigger if exists trg_sales_record_confirmation_balance on public.sales_records;
-- Intentionally not recreated: sales approval must post to the bank balance in
-- exactly one place (approve_sales_record -> post_to_bank_account).

create or replace function public.adjust_bank_account_balance(
  p_bank_account_id uuid,
  p_adjustment_amount numeric,
  p_reason text,
  p_adjusted_by uuid
)
returns void as $$
declare
begin
  if p_bank_account_id is null then
    raise exception 'bank_account_id is required';
  end if;

  perform public.post_to_bank_account(
    p_bank_account_id,
    coalesce(p_adjustment_amount, 0),
    'manual_adjustment',
    coalesce(p_reason, 'Manual adjustment'),
    'Legacy adjust_bank_account_balance wrapper',
    coalesce(p_adjusted_by::text, 'system'),
    coalesce(p_reason, 'Manual adjustment')
  );
end;
$$ language plpgsql security definer set search_path = public;

-- ============================================================
-- D. RLS for bank_accounts and bank_account_adjustments
-- ============================================================
alter table public.bank_accounts enable row level security;
alter table public.bank_account_adjustments enable row level security;

create or replace function public.is_manager_or_supervisor_role()
returns boolean as $$
begin
  return public.profiles_current_role() in ('manager', 'supervisor');
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.is_accountant_role()
returns boolean as $$
begin
  return public.profiles_current_role() = 'accountant';
end;
$$ language plpgsql security definer set search_path = public;

drop policy if exists bank_accounts_select_manager_supervisor on public.bank_accounts;
create policy bank_accounts_select_manager_supervisor
  on public.bank_accounts
  for select
  to authenticated
  using (public.profiles_current_role() in ('admin','manager','supervisor','accountant','sales_agent','staff'));

drop policy if exists bank_accounts_select_accountant on public.bank_accounts;
create policy bank_accounts_select_accountant
  on public.bank_accounts
  for select
  to authenticated
  using (public.is_accountant_role());

drop policy if exists bank_accounts_insert_manager_supervisor_accountant on public.bank_accounts;
create policy bank_accounts_insert_manager_supervisor_accountant
  on public.bank_accounts
  for insert
  to authenticated
  with check (public.profiles_current_role() in ('admin','manager','supervisor','accountant'));

drop policy if exists bank_accounts_update_manager_supervisor_accountant on public.bank_accounts;
create policy bank_accounts_update_manager_supervisor_accountant
  on public.bank_accounts
  for update
  to authenticated
  using (public.profiles_current_role() in ('admin','manager','supervisor','accountant'))
  with check (public.profiles_current_role() in ('admin','manager','supervisor','accountant'));

drop policy if exists bank_accounts_no_sales_agent on public.bank_accounts;
create policy bank_accounts_no_sales_agent
  on public.bank_accounts
  for all
  to authenticated
  using (false)
  with check (false);

drop policy if exists bank_account_adjustments_select_manager_supervisor on public.bank_account_adjustments;
create policy bank_account_adjustments_select_manager_supervisor
  on public.bank_account_adjustments
  for select
  to authenticated
  using (public.is_manager_or_supervisor_role() or public.is_accountant_role());

drop policy if exists bank_account_adjustments_insert_manager_accountant on public.bank_account_adjustments;
create policy bank_account_adjustments_insert_manager_accountant
  on public.bank_account_adjustments
  for insert
  to authenticated
  with check (public.is_manager_or_supervisor_role() or public.is_accountant_role());

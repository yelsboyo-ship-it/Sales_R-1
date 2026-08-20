-- ============================================================
-- Sales Data Records — Supabase schema
-- Run this in: Supabase Dashboard → SQL Editor → New Query
-- ============================================================

-- Safe migration for existing databases: create tables only when absent.
create extension if not exists pgcrypto;

create table if not exists sales_records (
  id                   bigint generated always as identity primary key,
  sno                  integer generated always as identity unique,
  sale_date            date,
  customer_name        text not null,
  particulars          text,
  branch_location      text not null,
  recorded_by_email    text not null,
  recorded_by_user_id  uuid references auth.users(id),
  recorded_by_full_name text,
  total_dispatch_kg    numeric(10,2) not null default 0,
  kgs_supplied         numeric(10,2) not null default 0,
  rejects_kg           numeric(10,2) not null default 0,
  unit_price           numeric(10,2) not null default 0,
  amount_deposited     numeric(12,2) not null default 0,
  expenses             numeric(12,2) not null default 0,
  price_mismatch       boolean not null default false,
  expected_amount      numeric(12,2) generated always as (kgs_supplied * unit_price) stored,
  kgs_paid_for         numeric(10,2) generated always as (case when unit_price > 0 then amount_deposited / unit_price else 0 end) stored,
  excess_less          numeric(12,2) generated always as ((amount_deposited + expenses) - (kgs_supplied * unit_price)) stored,
  balance_to_be_paid   numeric(12,2) generated always as ((kgs_supplied * unit_price) - (amount_deposited + expenses)) stored,
  missing_in_kgs       numeric(10,2) generated always as (total_dispatch_kg - (kgs_supplied + rejects_kg)) stored,
  missing_amount       numeric(12,2) generated always as ((total_dispatch_kg - (kgs_supplied + rejects_kg)) * unit_price) stored,
  kgs_to_be_paid       numeric(10,2) generated always as (case when unit_price > 0 then (((kgs_supplied * unit_price) - (amount_deposited + expenses)) / unit_price) else 0 end) stored,
  status               text generated always as (case 
                         when ((kgs_supplied * unit_price) - (amount_deposited + expenses)) = 0
                         then 'cleared' 
                         else 'pending' 
                       end) stored,
  remarks              text,
  bank_account         text,
  bank_account_id      uuid references public.bank_accounts(id),
  deposit_confirmation_url text[],
  payment_confirmation_text text,
  is_deleted           boolean not null default false,
  deleted_at           timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  customer_name text not null,
  customer_type text,
  phone_number text not null unique,
  alt_phone_number text,
  email text,
  id_number text,
  kra_pin text,
  location text,
  town text,
  county text,
  default_sales_agent_id uuid references public.profiles(id),
  status text not null default 'active' check (status in ('active','inactive','blacklisted')),
  notes text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  is_deleted boolean not null default false
);

alter table public.customers enable row level security;

create or replace function public.set_customer_created_by()
returns trigger as $$
begin
  if tg_op = 'INSERT' and new.created_by is null then
    new.created_by = auth.uid();
  end if;
  return new;
end;
$$ language plpgsql security definer set row_security = off;

drop trigger if exists trg_customers_set_created_by on public.customers;
create trigger trg_customers_set_created_by
  before insert on public.customers
  for each row execute function public.set_customer_created_by();

drop policy if exists "customers insert authenticated" on public.customers;
create policy "customers insert authenticated"
  on public.customers
  for insert
  to authenticated
  with check (
    created_by = auth.uid()
    or public.profiles_current_role() in ('admin','manager','supervisor','accountant')
  );

drop policy if exists "customers select privileged" on public.customers;
create policy "customers select privileged"
  on public.customers
  for select
  to authenticated
  using (
    created_by = auth.uid()
    or public.profiles_current_role() in ('admin','manager','supervisor','accountant')
  );

drop policy if exists "customers update privileged" on public.customers;
create policy "customers update privileged"
  on public.customers
  for update
  to authenticated
  using (
    created_by = auth.uid()
    or public.profiles_current_role() in ('admin','manager','supervisor','accountant')
  )
  with check (
    created_by = auth.uid()
    or public.profiles_current_role() in ('admin','manager','supervisor','accountant')
  );

drop policy if exists "customers delete privileged" on public.customers;
create policy "customers delete privileged"
  on public.customers
  for delete
  to authenticated
  using (
    created_by = auth.uid()
    or public.profiles_current_role() in ('admin','manager','supervisor','accountant')
  );

-- Keep updated_at fresh on every edit
create table if not exists public.bank_accounts (
  id uuid primary key default gen_random_uuid(),
  account_name text not null,
  bank_name text not null,
  account_number text not null,
  branch text,
  currency text not null default 'KES',
  current_balance numeric(14,2) not null default 0,
  is_active boolean not null default true,
  is_order_now_active boolean not null default false,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bank_accounts_unique_account unique (bank_name, account_number)
);

alter table public.bank_accounts
  add column if not exists is_order_now_active boolean not null default false;

create index if not exists idx_bank_accounts_order_now_active
  on public.bank_accounts (is_order_now_active, is_active);

create or replace function public.clear_order_now_active_on_inactive()
returns trigger as $$
begin
  if new.is_active is false and old.is_active is not false then
    new.is_order_now_active = false;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_bank_accounts_clear_order_now_active on public.bank_accounts;
create trigger trg_bank_accounts_clear_order_now_active
before update on public.bank_accounts
for each row
execute function public.clear_order_now_active_on_inactive();

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

create table if not exists public.produce (
  id bigint generated always as identity primary key,
  particulars text not null unique,
  amount_kg numeric(10,2) not null default 0,
  unit_price numeric(10,2) not null default 0,
  is_available boolean not null default true,
  image_url text,
  ready_date date,
  low_stock_threshold_kg numeric(10,2) not null default 10,
  last_restocked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.produce_stock_log (
  id bigint generated always as identity primary key,
  produce_id bigint not null references public.produce(id) on delete cascade,
  action_type text not null check (action_type in ('restock','sale_deduction','adjustment')),
  quantity_kg numeric(10,2) not null default 0,
  unit_price numeric(10,2) not null default 0,
  notes text,
  created_by uuid references auth.users(id),
  created_by_email text,
  related_sale_id bigint references sales_records(id),
  created_at timestamptz not null default now()
);

alter table public.produce_stock_log enable row level security;

drop policy if exists "authenticated read produce stock logs" on public.produce_stock_log;
create policy "authenticated read produce stock logs"
  on public.produce_stock_log
  for select
  to authenticated
  using (public.profiles_current_role() in ('admin','manager','supervisor','accountant'));

drop policy if exists "managers manage produce stock logs" on public.produce_stock_log;
create policy "managers manage produce stock logs"
  on public.produce_stock_log
  for insert
  to authenticated
  with check (public.profiles_is_manager_or_supervisor());

drop policy if exists "managers update produce stock logs" on public.produce_stock_log;
create policy "managers update produce stock logs"
  on public.produce_stock_log
  for update
  to authenticated
  using (public.profiles_is_manager_or_supervisor())
  with check (public.profiles_is_manager_or_supervisor());

drop policy if exists "managers delete produce stock logs" on public.produce_stock_log;
create policy "managers delete produce stock logs"
  on public.produce_stock_log
  for delete
  to authenticated
  using (public.profiles_is_manager_or_supervisor());

create table if not exists public.employees (
  id bigint generated always as identity primary key,
  full_name text not null,
  date_of_birth text,
  sex text,
  national_id text,
  physical_address text,
  phone_number text,
  next_of_kin text,
  employee_id text unique,
  job_title text,
  department text,
  employment_start_date date,
  employment_type text,
  wages numeric(12,2) not null default 0,
  advance_pay numeric(12,2) not null default 0,
  final_wages numeric(12,2) not null default 0,
  kra_pin text,
  nssf_number text,
  shif_number text,
  bank_account text,
  photo_url text,
  assigned_shift text,
  status text not null default 'Present',
  group_leader_name_or_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.produce_price_history (
  id bigint generated always as identity primary key,
  produce_id bigint not null references public.produce(id) on delete cascade,
  old_unit_price numeric(10,2) not null default 0,
  new_unit_price numeric(10,2) not null default 0,
  changed_by uuid references auth.users(id),
  changed_by_email text,
  reason text,
  created_at timestamptz not null default now()
);

alter table sales_records
  add column if not exists price_mismatch boolean not null default false;

alter table sales_records
  add column if not exists bank_account text;

alter table sales_records
  add column if not exists bank_account_id uuid references public.bank_accounts(id);

alter table sales_records
  add column if not exists confirmation_status text not null default 'pending';

alter table sales_records
  add column if not exists approved_by uuid references public.profiles(id);

alter table sales_records
  add column if not exists approved_at timestamptz;

alter table sales_records
  drop constraint if exists sales_records_confirmation_status_check;

alter table sales_records
  add constraint sales_records_confirmation_status_check
  check (confirmation_status in ('pending','confirmed','rejected'));

alter table sales_records
  alter column confirmation_status set default 'pending';

-- Normalize any legacy rows that violate the dispatch invariant before validating the new constraint.
update sales_records
set kgs_supplied = total_dispatch_kg
where kgs_supplied > total_dispatch_kg;

update sales_records
set rejects_kg = total_dispatch_kg - kgs_supplied
where rejects_kg > (total_dispatch_kg - kgs_supplied);

alter table sales_records
  drop constraint if exists sales_records_kgs_supplied_check;

alter table sales_records
  add constraint sales_records_kgs_supplied_check
  check (
    kgs_supplied <= total_dispatch_kg
    and kgs_supplied + rejects_kg <= total_dispatch_kg
  ) not valid;

alter table sales_records
  validate constraint sales_records_kgs_supplied_check;

alter table public.produce
  add column if not exists low_stock_threshold_kg numeric(10,2) not null default 10;

alter table public.produce
  add column if not exists last_restocked_at timestamptz;

alter table public.produce
  add column if not exists image_url text;

alter table sales_records
  add column if not exists recorded_by_user_id uuid references auth.users(id);

alter table sales_records
  add column if not exists recorded_by_full_name text;

alter table sales_records
  add column if not exists expenses numeric(12,2) not null default 0;

alter table sales_records
  add column if not exists customer_id uuid references public.customers(id);

alter table sales_records
  add column if not exists receipt_no text unique;

alter table public.employees
  add column if not exists photo_url text;

alter table public.employees
  add column if not exists assigned_shift text;

alter table public.employees
  add column if not exists group_leader_name_or_id text;

create or replace view public.customer_ledger as
select
  sr.id as sales_record_id,
  sr.customer_id,
  coalesce(c.customer_name, sr.customer_name) as customer_name,
  sr.sale_date,
  sr.receipt_no,
  sr.particulars,
  sr.total_dispatch_kg,
  sr.kgs_supplied,
  sr.rejects_kg,
  sr.unit_price,
  sr.expected_amount,
  sr.amount_deposited,
  (coalesce(sr.expected_amount, 0) - (coalesce(sr.amount_deposited, 0) + coalesce(sr.expenses, 0)))::numeric(12,2) as balance_to_be_paid,
  sum((coalesce(sr.expected_amount, 0) - (coalesce(sr.amount_deposited, 0) + coalesce(sr.expenses, 0)))::numeric(12,2)) over (partition by sr.customer_id order by sr.sale_date, sr.id rows between unbounded preceding and current row) as running_balance,
  sr.remarks,
  sr.created_at,
  sr.expenses
from public.sales_records sr
left join public.customers c on c.id = sr.customer_id
where sr.customer_id is not null
  and sr.is_deleted = false;

create or replace view public.sales_receipt as
select
  sr.id,
  sr.sale_date,
  sr.receipt_no,
  sr.customer_id,
  coalesce(c.customer_name, sr.customer_name) as customer_name,
  c.customer_type,
  c.phone_number,
  c.email,
  c.location,
  c.town,
  c.county,
  sr.particulars,
  sr.total_dispatch_kg,
  sr.kgs_supplied,
  sr.rejects_kg,
  sr.unit_price,
  sr.expected_amount,
  sr.amount_deposited,
  (coalesce(sr.expected_amount, 0) - (coalesce(sr.amount_deposited, 0) + coalesce(sr.expenses, 0)))::numeric(12,2) as balance_to_be_paid,
  sr.remarks,
  sr.created_at,
  sr.expenses
from public.sales_records sr
left join public.customers c on c.id = sr.customer_id;

create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create or replace function public.set_produce_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create or replace function public.prevent_edit_after_approval()
returns trigger as $$
begin
  -- Approval is a terminal state for this workflow. The narrow exceptions are
  -- the accountant reject path (confirmed -> pending), the manager-only
  -- unapprove reversal path, and the internal carry-forward close-out update
  -- that shrinks a previous record's dispatch when the next record is saved.
  if old.confirmation_status = 'confirmed' then
    if new.confirmation_status = 'pending'
       and public.profiles_current_role() in ('accountant', 'manager', 'supervisor') then
      return new;
    end if;

    if old.total_dispatch_kg is distinct from new.total_dispatch_kg
       and old.kgs_supplied is not distinct from new.kgs_supplied
       and old.rejects_kg is not distinct from new.rejects_kg
       and coalesce(new.total_dispatch_kg, 0) = coalesce(new.kgs_supplied, 0) + coalesce(new.rejects_kg, 0)
       and coalesce(new.missing_in_kgs, 0) = 0 then
      return new;
    end if;

    raise exception 'This record was approved on % and can no longer be edited or deleted.', coalesce(old.approved_at::text, 'an unknown date');
  end if;

  if new.confirmation_status = 'confirmed' and coalesce(new.missing_in_kgs, 0) > 0 then
    if coalesce(nullif(current_setting('app.allow_approve_with_missing_kg', true), ''), 'false') = 'true'
       and public.profiles_current_role() = 'accountant' then
      return new;
    end if;

    raise exception 'Only accountants can approve records that still have carried shortfall (missing_in_kgs > 0).';
  end if;

  return new;
end;
$$ language plpgsql;

create or replace function public.prevent_delete_approved_sales_record()
returns trigger as $$
begin
  if old.confirmation_status = 'confirmed' then
    raise exception 'This record was approved on % and can no longer be edited or deleted.', coalesce(old.approved_at::text, 'an unknown date');
  end if;

  return old;
end;
$$ language plpgsql;

create or replace function public.log_bank_account_balance_change()
returns trigger as $$
declare
  v_has_existing_row boolean;
begin
  -- Opening-balance mirror only: ongoing balance movements must go through
  -- post_to_bank_account so they cannot drift from current_balance.
  if tg_op <> 'INSERT' then
    return new;
  end if;

  select exists(
    select 1
    from public.accounting_cash_book
    where bank_account_id = new.id
  ) into v_has_existing_row;

  if v_has_existing_row or new.current_balance is null then
    return new;
  end if;

  insert into public.accounting_cash_book(
    entry_date,
    description,
    reference_no,
    money_in,
    money_out,
    balance,
    recorded_by,
    notes,
    entry_type,
    bank_account_id
  ) values (
    now(),
    'Opening balance',
    null,
    0,
    0,
    coalesce(new.current_balance, 0),
    'system',
    'Initial bank account balance mirror',
    'opening_balance',
    new.id
  );

  insert into public.bank_account_adjustments(
    bank_account_id,
    adjustment_amount,
    reason,
    old_balance,
    new_balance,
    adjusted_by
  ) values (
    new.id,
    coalesce(new.current_balance, 0),
    'Opening balance',
    0,
    coalesce(new.current_balance, 0),
    null
  );

  return new;
end;
$$ language plpgsql;

create or replace function public.prevent_direct_bank_balance_update()
returns trigger as $$
begin
  if old.current_balance is distinct from new.current_balance
     and coalesce(nullif(current_setting('app.allow_direct_bank_balance_update', true), ''), 'false') <> 'true' then
    raise exception 'Direct updates to bank_accounts.current_balance are not allowed. Use post_to_bank_account().';
  end if;

  return new;
end;
$$ language plpgsql;

create or replace function public.post_to_bank_account(
  p_bank_account_id uuid,
  p_amount_delta numeric(14,2),
  p_entry_type text default 'balance_update',
  p_description text default null,
  p_notes text default null,
  p_recorded_by text default null,
  p_adjustment_reason text default null,
  p_transfer_from_bank_account_id uuid default null,
  p_transfer_to_bank_account_id uuid default null,
  p_transfer_amount numeric(12,2) default null
)
returns numeric(14,2)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_balance numeric(14,2);
  v_new_balance numeric(14,2);
  v_delta numeric(14,2);
  v_money_in numeric(12,2);
  v_money_out numeric(12,2);
  v_recorded_by text;
  v_adjusted_by uuid;
  v_latest_cash_book_balance numeric(14,2);
  v_latest_adjustment_balance numeric(14,2);
begin
  -- This is the single source of truth for bank balance updates.
  -- Do not update current_balance/balance/new_balance anywhere else.
  if p_bank_account_id is null then
    raise exception 'bank_account_id is required';
  end if;

  v_delta := coalesce(p_amount_delta, 0);
  if v_delta = 0 then
    select current_balance
      into v_old_balance
    from public.bank_accounts
    where id = p_bank_account_id
    limit 1;

    if not found then
      raise exception 'Bank account not found';
    end if;

    return coalesce(v_old_balance, 0);
  end if;

  select current_balance
    into v_old_balance
  from public.bank_accounts
  where id = p_bank_account_id
  for update;

  if not found then
    raise exception 'Bank account not found';
  end if;

  v_old_balance := coalesce(v_old_balance, 0);
  v_new_balance := v_old_balance + v_delta;

  if v_new_balance < 0 then
    raise exception 'Bank balance cannot go below zero. Current balance %, requested delta %.', v_old_balance, v_delta;
  end if;

  v_money_in := case when v_delta > 0 then v_delta else 0 end;
  v_money_out := case when v_delta < 0 then abs(v_delta) else 0 end;
  v_recorded_by := coalesce(nullif(trim(p_recorded_by), ''), 'system');

  if v_recorded_by ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    v_adjusted_by := v_recorded_by::uuid;
  else
    v_adjusted_by := null;
  end if;

  perform set_config('app.allow_direct_bank_balance_update', 'true', true);
  perform set_config('app.skip_bank_account_balance_log', 'true', true);

  update public.bank_accounts
     set current_balance = v_new_balance,
         updated_at = now()
   where id = p_bank_account_id;

  insert into public.accounting_cash_book(
    entry_date,
    description,
    reference_no,
    money_in,
    money_out,
    balance,
    recorded_by,
    notes,
    entry_type,
    transfer_from_bank_account_id,
    transfer_to_bank_account_id,
    transfer_amount,
    bank_account_id
  ) values (
    now(),
    coalesce(nullif(trim(p_description), ''), 'Bank account balance update'),
    null,
    v_money_in,
    v_money_out,
    v_new_balance,
    v_recorded_by,
    coalesce(nullif(trim(p_notes), ''), 'Auto-synced from bank_accounts.current_balance'),
    coalesce(nullif(trim(p_entry_type), ''), 'balance_update'),
    p_transfer_from_bank_account_id,
    p_transfer_to_bank_account_id,
    coalesce(p_transfer_amount, 0),
    p_bank_account_id
  );

  insert into public.bank_account_adjustments(
    bank_account_id,
    adjustment_amount,
    reason,
    old_balance,
    new_balance,
    adjusted_by
  ) values (
    p_bank_account_id,
    v_delta,
    coalesce(nullif(trim(p_adjustment_reason), ''), coalesce(nullif(trim(p_description), ''), 'Bank account balance update')),
    v_old_balance,
    v_new_balance,
    v_adjusted_by
  );

  select balance
    into v_latest_cash_book_balance
  from public.accounting_cash_book
  where bank_account_id = p_bank_account_id
  order by entry_date desc, id desc
  limit 1;

  select new_balance
    into v_latest_adjustment_balance
  from public.bank_account_adjustments
  where bank_account_id = p_bank_account_id
  order by adjusted_at desc, id desc
  limit 1;

  if v_latest_cash_book_balance is distinct from v_new_balance
     or v_latest_adjustment_balance is distinct from v_new_balance then
    raise exception 'Balance mirror invariant failed for account %', p_bank_account_id;
  end if;

  perform set_config('app.skip_bank_account_balance_log', 'false', true);
  perform set_config('app.allow_direct_bank_balance_update', 'false', true);

  return v_new_balance;
end;
$$;

create or replace function public.prevent_accounting_cash_book_modification()
returns trigger as $$
begin
  raise exception 'accounting_cash_book is append-only and cannot be edited or deleted.';
end;
$$ language plpgsql;

create or replace function public.seed_accounting_cash_book_from_bank_accounts()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if to_regclass('public.accounting_cash_book') is null then
    return;
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'accounting_cash_book'
      and column_name in ('entry_type', 'bank_account_id')
  ) then
    return;
  end if;

  execute $sql$
    insert into public.accounting_cash_book(
      entry_date,
      description,
      reference_no,
      money_in,
      money_out,
      balance,
      recorded_by,
      notes,
      entry_type,
      bank_account_id
    )
    select
      now(),
      'Opening balance',
      null,
      0,
      0,
      coalesce(ba.current_balance, 0),
      'system',
      'Initial bank account balance import',
      'opening_balance',
      ba.id
    from public.bank_accounts ba
    where not exists (
      select 1
      from public.accounting_cash_book acb
      where acb.bank_account_id = ba.id
    );
  $sql$;
end;
$$;

create or replace function public.transfer_bank_account_funds(
  p_from_bank_account_id uuid,
  p_to_bank_account_id uuid,
  p_amount numeric(14,2),
  p_description text default null,
  p_notes text default null,
  p_recorded_by text default null
)
returns table (success boolean, error_message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_from_bank_account public.bank_accounts%rowtype;
  v_to_bank_account public.bank_accounts%rowtype;
  v_amount numeric(14,2);
begin
  if p_from_bank_account_id is null then
    return query select false, 'Source bank account is required.';
    return;
  end if;

  if p_to_bank_account_id is null then
    return query select false, 'Destination bank account is required.';
    return;
  end if;

  if p_from_bank_account_id = p_to_bank_account_id then
    return query select false, 'Source and destination bank accounts must be different.';
    return;
  end if;

  v_amount := coalesce(p_amount, 0);
  if v_amount <= 0 then
    return query select false, 'Transfer amount must be greater than zero.';
    return;
  end if;

  select *
    into v_from_bank_account
  from public.bank_accounts
  where id = p_from_bank_account_id
  for update;

  if not found then
    return query select false, 'Source bank account was not found.';
    return;
  end if;

  select *
    into v_to_bank_account
  from public.bank_accounts
  where id = p_to_bank_account_id
  for update;

  if not found then
    return query select false, 'Destination bank account was not found.';
    return;
  end if;

  if v_from_bank_account.is_active is not true then
    return query select false, 'Source bank account is inactive.';
    return;
  end if;

  if v_to_bank_account.is_active is not true then
    return query select false, 'Destination bank account is inactive.';
    return;
  end if;

  if coalesce(v_from_bank_account.current_balance, 0) < v_amount then
    return query select false, 'Insufficient funds in source account.';
    return;
  end if;

  perform public.post_to_bank_account(
    p_from_bank_account_id,
    -v_amount,
    'transfer',
    coalesce(nullif(trim(p_description), ''), 'Bank transfer'),
    coalesce(nullif(trim(p_notes), ''), 'Transfer from ' || coalesce(v_from_bank_account.account_name, 'source') || ' to ' || coalesce(v_to_bank_account.account_name, 'destination')),
    coalesce(nullif(trim(p_recorded_by), ''), 'system'),
    'Transfer debit from ' || coalesce(v_from_bank_account.account_name, 'source') || ' to ' || coalesce(v_to_bank_account.account_name, 'destination'),
    p_from_bank_account_id,
    p_to_bank_account_id,
    v_amount
  );

  perform public.post_to_bank_account(
    p_to_bank_account_id,
    v_amount,
    'transfer',
    coalesce(nullif(trim(p_description), ''), 'Bank transfer'),
    coalesce(nullif(trim(p_notes), ''), 'Transfer from ' || coalesce(v_from_bank_account.account_name, 'source') || ' to ' || coalesce(v_to_bank_account.account_name, 'destination')),
    coalesce(nullif(trim(p_recorded_by), ''), 'system'),
    'Transfer credit from ' || coalesce(v_from_bank_account.account_name, 'source') || ' to ' || coalesce(v_to_bank_account.account_name, 'destination'),
    p_from_bank_account_id,
    p_to_bank_account_id,
    v_amount
  );

  return query select true, null;
end;
$$;

create or replace function public.get_last_missing_kg(p_particulars text)
returns numeric
language sql
stable
set search_path = public
as $$
  select coalesce(
    (
      select missing_in_kgs
      from sales_records
      where is_deleted = false
        and lower(trim(coalesce(particulars, ''))) = lower(trim(coalesce(p_particulars, '')))
      order by updated_at desc nulls last, sno desc nulls last
      limit 1
    ),
    0
  )::numeric;
$$;

create or replace function public.get_employee_stock_allocation(p_produce_id bigint)
returns numeric(10,2)
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(sum(allocated_kg), 0)::numeric(10,2)
  from public.employee_stock_allocations
  where employee_id = auth.uid()
    and produce_id = p_produce_id;
$$;

create or replace function public.carry_forward_missing_kg_to_next_record()
returns trigger as $$
begin
  -- Preserve the incoming dispatch value that the UI or caller selected for the
  -- new record. The prior record is closed out during the save RPC when the
  -- next record is persisted, so this trigger must not accumulate dispatch.
  return new;
end;
$$ language plpgsql;

create or replace function public.log_produce_price_change()
returns trigger as $$
begin
  if new.unit_price is distinct from old.unit_price then
    insert into public.produce_price_history(
      produce_id,
      old_unit_price,
      new_unit_price,
      changed_by,
      changed_by_email,
      reason
    ) values (
      new.id,
      old.unit_price,
      new.unit_price,
      auth.uid(),
      lower(coalesce(auth.email(), 'unknown')),
      'price updated'
    );
  end if;
  return new;
end;
$$ language plpgsql security definer set row_security = off;

drop trigger if exists trg_sales_records_updated_at on sales_records;
create trigger trg_sales_records_updated_at
  before update on sales_records
  for each row execute function public.set_updated_at();

drop trigger if exists trg_produce_updated_at on public.produce;
create trigger trg_produce_updated_at
  before update on public.produce
  for each row execute function public.set_produce_updated_at();

drop trigger if exists trg_produce_price_history on public.produce;
create trigger trg_produce_price_history
  after update on public.produce
  for each row execute function public.log_produce_price_change();

create or replace function public.normalize_profile_role(raw_role text)
returns text as $$
begin
  if raw_role is null or trim(raw_role) = '' then
    return 'sales_agent';
  end if;

  case lower(trim(raw_role))
    when 'admin' then return 'admin';
    when 'manager' then return 'manager';
    when 'supervisor' then return 'supervisor';
    when 'accountant' then return 'accountant';
    when 'sales_agent', 'sales-agent', 'sales agent', 'sales' then return 'sales_agent';
    when 'staff' then return 'staff';
    when 'group_leader', 'group-leader', 'group leader' then return 'group_leader';
    when 'driver' then return 'driver';
    else return 'sales_agent';
  end case;
end;
$$ language plpgsql;

create or replace function public.normalize_case()
returns trigger as $$
begin
  if tg_relid = 'public.sales_records'::regclass then
    if new.customer_name is not null then
      new.customer_name = initcap(trim(new.customer_name));
    end if;
    if new.particulars is not null then
      new.particulars = initcap(trim(new.particulars));
    end if;
    if new.branch_location is not null then
      new.branch_location = initcap(trim(new.branch_location));
    end if;
    if new.recorded_by_email is not null then
      new.recorded_by_email = lower(trim(new.recorded_by_email));
    end if;
  elsif tg_relid = 'public.profiles'::regclass then
    if new.full_name is not null then
      new.full_name = initcap(trim(new.full_name));
    end if;
    if new.email is not null then
      new.email = lower(trim(new.email));
    end if;
    if new.role is not null then
      new.role = public.normalize_profile_role(new.role);
    end if;
    if new.location is not null then
      new.location = initcap(trim(new.location));
    end if;
  end if;
  return new;
end;
$$ language plpgsql;

create or replace function public.sales_records_set_defaults()
returns trigger as $$
declare
  v_catalog_price numeric(10,2);
begin
  if tg_op = 'INSERT' then
    new.recorded_by_email = lower(coalesce(auth.email(), 'unknown'));
    new.recorded_by_user_id = auth.uid();
    new.recorded_by_full_name = coalesce(
      new.recorded_by_full_name,
      (
        select initcap(trim(full_name))
        from public.profiles
        where id = auth.uid()
        limit 1
      ),
      initcap(split_part(coalesce(auth.email(), 'unknown'), '@', 1))
    );
    new.branch_location = (
      select initcap(location)
      from public.profiles
      where id = auth.uid()
      limit 1
    );
    if new.branch_location is null then
      new.branch_location = 'Unknown';
    end if;

    if public.profiles_current_role() = 'staff' then
      new.rejects_kg = 0;
      new.total_dispatch_kg = coalesce(new.kgs_supplied, 0);
    end if;

    if trim(coalesce(new.particulars, '')) <> '' then
      select unit_price
        into v_catalog_price
        from public.produce
       where lower(particulars) = lower(trim(new.particulars))
         and is_available is not false
       limit 1;

      if v_catalog_price is not null and new.unit_price is not null and abs(new.unit_price - v_catalog_price) > 0.0001 then
        new.price_mismatch = true;
      else
        new.price_mismatch = false;
      end if;
    else
      new.price_mismatch = false;
    end if;
  end if;
  return new;
end;
$$ language plpgsql;

drop function if exists public.reject_sales_record(bigint, uuid);

create or replace function public.reject_sales_record(
  p_sale_id bigint,
  p_accountant_user_id uuid
)
returns public.sales_records
language plpgsql
security definer
set search_path = public
as $$
declare
  v_confirmation_status text;
  v_record public.sales_records%rowtype;
begin
  if p_sale_id is null then
    raise exception 'sale_id is required';
  end if;

  if p_accountant_user_id is null then
    raise exception 'accountant_user_id is required';
  end if;

  if public.profiles_current_role() not in ('accountant', 'manager', 'supervisor') then
    raise exception 'Only an accountant or accounting manager can reject a sales record for re-editing.';
  end if;

  select *
    into v_record
  from public.sales_records
  where id = p_sale_id
  for update;

  if not found then
    raise exception 'Sales record not found';
  end if;

  v_confirmation_status := lower(coalesce(v_record.confirmation_status, 'pending'));

  if v_confirmation_status = 'pending' then
    raise exception 'Record is already pending and waiting for approval.';
  end if;

  update public.sales_records
     set confirmation_status = 'pending',
         approved_by = null,
         approved_at = null,
         bank_account_id = null,
         bank_account = null,
         updated_at = now()
   where id = p_sale_id;

  select *
    into v_record
  from public.sales_records
  where id = p_sale_id;

  return v_record;
end;
$$;

create or replace function public.reconcile_bank_ledger(p_bank_account_id uuid)
returns table (is_consistent boolean, bank_balance numeric(14,2), ledger_balance numeric(14,2), discrepancy numeric(14,2))
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bank_balance numeric(14,2);
  v_ledger_balance numeric(14,2);
begin
  select current_balance
    into v_bank_balance
  from public.bank_accounts
  where id = p_bank_account_id;

  if not found then
    raise exception 'Bank account not found';
  end if;

  select balance
    into v_ledger_balance
  from public.accounting_cash_book
  where bank_account_id = p_bank_account_id
  order by entry_date desc, id desc
  limit 1;

  if v_ledger_balance is null then
    v_ledger_balance := 0;
  end if;

  return query
  select
    (v_bank_balance = v_ledger_balance) as is_consistent,
    v_bank_balance as bank_balance,
    v_ledger_balance as ledger_balance,
    (v_bank_balance - v_ledger_balance) as discrepancy;
end;
$$;

drop function if exists public.unapprove_sales_record(bigint, uuid, text);

create or replace function public.unapprove_sales_record(
  p_sale_id bigint,
  p_manager_user_id uuid,
  p_reason text
)
returns table (success boolean, error_message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_record public.sales_records%rowtype;
  v_role text;
  v_bank_account_id uuid;
  v_amount_deposited numeric(12,2);
  v_previous_balance numeric(14,2);
  v_new_balance numeric(14,2);
  v_bank_balance numeric(14,2);
  v_ledger_row public.accounting_cash_book%rowtype;
  v_user_email text;
begin
  if p_sale_id is null then
    return query select false, 'sale_id is required';
    return;
  end if;

  if p_manager_user_id is null then
    return query select false, 'manager_user_id is required';
    return;
  end if;

  if nullif(trim(coalesce(p_reason, '')), '') is null then
    return query select false, 'reason is required';
    return;
  end if;

  select lower(role) into v_role from public.profiles where id = p_manager_user_id limit 1;
  v_role := coalesce(v_role, 'sales_agent');

  if v_role <> 'manager' then
    insert into public.edit_history(record_id, field_changed, old_value, new_value, edited_by_email, edited_successfully, note)
    values (p_sale_id, 'confirmation_status', 'approved', 'approved', lower(coalesce(auth.email(), 'unknown')), false, 'Unauthorized unapprove attempt, role was: ' || v_role);
    return query select false, 'Only managers can unapprove a sales record.';
    return;
  end if;

  select *
    into v_record
  from public.sales_records
  where id = p_sale_id
  for update;

  if not found then
    return query select false, 'Sales record not found';
    return;
  end if;

  if lower(coalesce(v_record.confirmation_status, 'pending')) <> 'confirmed' then
    return query select false, 'Record is not currently approved, cannot unapprove.';
    return;
  end if;

  v_bank_account_id := v_record.bank_account_id;
  v_amount_deposited := coalesce(v_record.amount_deposited, 0);

  if v_bank_account_id is null then
    insert into public.edit_history(record_id, field_changed, old_value, new_value, edited_by_email, edited_successfully, note)
    values (p_sale_id, 'confirmation_status', 'approved', 'approved', lower(coalesce(auth.email(), 'unknown')), false, 'Unapprove blocked: missing bank_account_id for sale ' || p_sale_id);
    return query select false, 'Bank account is missing for this approved record.';
    return;
  end if;

  select current_balance
    into v_bank_balance
  from public.bank_accounts
  where id = v_bank_account_id
  for update;

  if not found then
    insert into public.edit_history(record_id, field_changed, old_value, new_value, edited_by_email, edited_successfully, note)
    values (p_sale_id, 'confirmation_status', 'approved', 'approved', lower(coalesce(auth.email(), 'unknown')), false, 'Unapprove blocked: bank account not found ' || v_bank_account_id);
    return query select false, 'Bank account not found.';
    return;
  end if;

  select *
    into v_ledger_row
  from public.accounting_cash_book
  where bank_account_id = v_bank_account_id
  order by entry_date desc, id desc
  limit 1
  for update;

  v_previous_balance := coalesce(v_ledger_row.balance, v_bank_balance);

  if v_previous_balance is null then
    v_previous_balance := coalesce(v_bank_balance, 0);
  end if;

  v_new_balance := v_previous_balance - v_amount_deposited;

  if v_new_balance < 0 then
    insert into public.edit_history(record_id, field_changed, old_value, new_value, edited_by_email, edited_successfully, note)
    values (p_sale_id, 'confirmation_status', 'approved', 'approved', lower(coalesce(auth.email(), 'unknown')), false, 'Unapprove blocked: would result in negative balance (' || v_new_balance || ') for bank_account_id ' || v_bank_account_id || '. Reason given: ' || p_reason);
    return query select false, 'Cannot unapprove: this would reduce the account balance to ' || v_new_balance || ', below zero. Current balance is ' || v_previous_balance || ', reversal amount is ' || v_amount_deposited || '. Resolve other pending transactions on this account first.';
    return;
  end if;

  perform public.post_to_bank_account(
    v_bank_account_id,
    -coalesce(v_amount_deposited, 0),
    'sales_unapprove_reversal',
    'Sales deposit UNAPPROVED/reversed - ' || coalesce(v_record.customer_name, '') || ' - ' || coalesce(v_record.particulars, ''),
    'Reversal of approval on sales_record id ' || p_sale_id || '. Reason: ' || p_reason,
    p_manager_user_id::text,
    'Sales record unapproval reversal for sale_id ' || p_sale_id
  );

  update public.sales_records
     set confirmation_status = 'pending',
         approved_by = null,
         approved_at = null,
         remarks = concat(coalesce(remarks, ''), ' [UNAPPROVED by manager, reverted to pending: ', p_reason, ' on ', now(), ']'),
         updated_at = now()
   where id = p_sale_id;

  insert into public.edit_history(record_id, field_changed, old_value, new_value, edited_by_email, edited_successfully, note)
  values (p_sale_id, 'confirmation_status', 'approved', 'pending', lower(coalesce(auth.email(), 'unknown')), true, p_reason);

  return query select true, null;
end;
$$;

drop function if exists public.approve_sales_record(bigint, uuid, uuid, text, text);

create or replace function public.approve_sales_record(
  p_sale_id bigint,
  p_accountant_user_id uuid,
  p_bank_account_id uuid default null,
  p_bank_account text default null,
  p_payment_confirmation_text text default null
)
returns table (success boolean, error_message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_record public.sales_records%rowtype;
  v_accountant_role text;
  v_can_approve_with_missing boolean;
  v_bank_account_id uuid;
  v_amount_deposited numeric(12,2);
  v_bank_balance numeric(14,2);
  v_previous_balance numeric(14,2);
  v_new_balance numeric(14,2);
  v_is_active boolean;
  v_user_email text;
  v_payment_confirmation_text text;
  v_has_confirmation_file boolean;
begin
  if p_sale_id is null then
    return query select false, 'sale_id is required';
    return;
  end if;

  if p_accountant_user_id is null then
    return query select false, 'accountant_user_id is required';
    return;
  end if;

  select lower(role) into v_accountant_role from public.profiles where id = p_accountant_user_id limit 1;
  v_accountant_role := coalesce(v_accountant_role, 'sales_agent');
  v_can_approve_with_missing := v_accountant_role = 'accountant';

  if v_accountant_role not in ('accountant', 'manager', 'supervisor') then
    return query select false, 'Only accountants or accounting managers can approve a sales record.';
    return;
  end if;

  select *
    into v_record
  from public.sales_records
  where id = p_sale_id
  for update;

  if not found then
    return query select false, 'Sales record not found';
    return;
  end if;

  v_bank_account_id := coalesce(p_bank_account_id, v_record.bank_account_id);
  v_amount_deposited := coalesce(v_record.amount_deposited, 0);

  if lower(coalesce(v_record.confirmation_status, 'pending')) = 'confirmed' then
    return query select false, 'Record already approved, balance not incremented again.';
    return;
  end if;

  v_payment_confirmation_text := trim(coalesce(NULLIF(trim(p_payment_confirmation_text), ''), v_record.payment_confirmation_text, ''));
  v_has_confirmation_file := coalesce(array_length(coalesce(v_record.deposit_confirmation_url, ARRAY[]::text[]), 1), 0) > 0;

  if v_payment_confirmation_text = '' and not v_has_confirmation_file then
    return query select false, 'Provide payment confirmation text or upload supporting evidence before approval can be confirmed.';
    return;
  end if;

  if v_bank_account_id is null then
    return query select false, 'No bank account selected.';
    return;
  end if;

  select is_active
    into v_is_active
  from public.bank_accounts
  where id = v_bank_account_id
  for update;

  if not found then
    return query select false, 'Selected bank account was not found.';
    return;
  end if;

  if v_is_active is not true then
    return query select false, 'Selected bank account is inactive.';
    return;
  end if;

  if v_amount_deposited is null or v_amount_deposited <= 0 then
    return query select false, 'Invalid deposit amount.';
    return;
  end if;

  if coalesce(v_record.missing_in_kgs, 0) > 0 and not v_can_approve_with_missing then
    return query select false, 'Only accountants can approve records that still have carried shortfall (missing_in_kgs > 0).';
    return;
  end if;

  if v_can_approve_with_missing then
    perform set_config('app.allow_approve_with_missing_kg', 'true', true);
  end if;

  select current_balance
    into v_bank_balance
  from public.bank_accounts
  where id = v_bank_account_id
  for update;

  v_previous_balance := coalesce(v_bank_balance, 0);
  v_new_balance := v_previous_balance + v_amount_deposited;

  update public.sales_records
     set confirmation_status = 'confirmed',
         approved_by = p_accountant_user_id,
         approved_at = now(),
         bank_account_id = v_bank_account_id,
         bank_account = coalesce(p_bank_account, bank_account),
         payment_confirmation_text = v_payment_confirmation_text,
         updated_at = now()
   where id = p_sale_id;

  perform public.post_to_bank_account(
    v_bank_account_id,
    coalesce(v_amount_deposited, 0),
    'sales_approval',
    'Sales deposit approved - ' || coalesce(v_record.customer_name, '') || ' - ' || coalesce(v_record.particulars, ''),
    'Auto-logged on approval of sales_record id ' || p_sale_id,
    p_accountant_user_id::text,
    'Sales record approval for sale_id ' || p_sale_id
  );

  perform public.upsert_sales_record_accounting_obligation(p_sale_id);

  if v_can_approve_with_missing then
    perform set_config('app.allow_approve_with_missing_kg', 'false', true);
  end if;

  return query select true, null;
end;
$$;

create or replace function public.upsert_sales_record_accounting_obligation(
  p_sale_id bigint
)
returns table (success boolean, error_message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_record public.sales_records%rowtype;
  v_balance numeric(12,2);
  v_customer public.customers%rowtype;
  v_display_contact text;
  v_amount numeric(12,2);
begin
  if p_sale_id is null then
    return query select false, 'sale_id is required';
    return;
  end if;

  select *
    into v_record
  from public.sales_records
  where id = p_sale_id
  for update;

  if not found then
    return query select false, 'Sales record not found';
    return;
  end if;

  v_balance := coalesce(v_record.balance_to_be_paid, 0);
  v_amount := abs(v_balance);

  select *
    into v_customer
  from public.customers
  where id = v_record.customer_id
  limit 1;

  if not found and v_record.customer_id is null then
    select *
      into v_customer
    from public.customers
    where lower(trim(customer_name)) = lower(trim(coalesce(v_record.customer_name, 'Walk-in')))
    order by created_at desc
    limit 1;
  end if;

  v_display_contact := coalesce(nullif(trim(v_customer.phone_number), ''), nullif(trim(v_customer.alt_phone_number), ''));

  if v_balance > 0 then
    delete from public.accounting_creditors where sales_record_id = p_sale_id;

    insert into public.accounting_debtors (
      sales_record_id,
      customer_id,
      customer_name,
      contact,
      date_of_sale,
      amount_owed,
      due_date,
      amount_paid,
      balance,
      status,
      notes
    ) values (
      p_sale_id,
      v_record.customer_id,
      coalesce(v_customer.customer_name, v_record.customer_name, 'Walk-in'),
      v_display_contact,
      coalesce(v_record.sale_date, current_date),
      v_amount,
      coalesce(v_record.sale_date, current_date),
      0,
      v_amount,
      'Pending',
      'Auto-created debtor obligation from approved sales record #' || p_sale_id
    )
    on conflict (sales_record_id) do update
      set customer_id = excluded.customer_id,
          customer_name = excluded.customer_name,
          contact = excluded.contact,
          date_of_sale = excluded.date_of_sale,
          amount_owed = excluded.amount_owed,
          due_date = excluded.due_date,
          amount_paid = excluded.amount_paid,
          balance = excluded.balance,
          status = excluded.status,
          notes = excluded.notes,
          updated_at = now();
  elsif v_balance < 0 then
    delete from public.accounting_debtors where sales_record_id = p_sale_id;

    insert into public.accounting_creditors (
      sales_record_id,
      customer_id,
      supplier_name,
      contact,
      date_of_purchase,
      amount_owed,
      due_date,
      amount_paid,
      balance,
      status,
      notes
    ) values (
      p_sale_id,
      v_record.customer_id,
      coalesce(v_customer.customer_name, v_record.customer_name, 'Walk-in'),
      v_display_contact,
      coalesce(v_record.sale_date, current_date),
      v_amount,
      coalesce(v_record.sale_date, current_date),
      0,
      v_amount,
      'Pending',
      'Auto-created creditor/customer credit obligation from approved sales record #' || p_sale_id
    )
    on conflict (sales_record_id) do update
      set customer_id = excluded.customer_id,
          supplier_name = excluded.supplier_name,
          contact = excluded.contact,
          date_of_purchase = excluded.date_of_purchase,
          amount_owed = excluded.amount_owed,
          due_date = excluded.due_date,
          amount_paid = excluded.amount_paid,
          balance = excluded.balance,
          status = excluded.status,
          notes = excluded.notes,
          updated_at = now();
  else
    delete from public.accounting_debtors where sales_record_id = p_sale_id;
    delete from public.accounting_creditors where sales_record_id = p_sale_id;
  end if;

  return query select true, null;
end;
$$;

-- Keep the stock transfer audit table aligned with the allocation insert below.
alter table public.stock_transfer_log
  add column if not exists triggered_by_record_id bigint references public.sales_records(id);

alter table public.stock_transfer_log
  drop constraint if exists stock_transfer_log_transfer_type_check;

alter table public.stock_transfer_log
  add constraint stock_transfer_log_transfer_type_check
  check (transfer_type in ('warehouse_to_employee', 'employee_to_employee', 'employee_to_warehouse', 'sales_agent_allocation', 'warehouse_to_location', 'employee_to_location', 'location_to_location'));

create or replace function public.create_sales_record_with_inventory(
  p_sale_date date,
  p_customer_name text,
  p_particulars text,
  p_total_dispatch_kg numeric,
  p_kgs_supplied numeric,
  p_rejects_kg numeric,
  p_unit_price numeric,
  p_amount_deposited numeric,
  p_bank_account_id uuid,
  p_bank_account text,
  p_receipt_no text,
  p_remarks text,
  p_draft_session_id uuid default null,
  p_edited_by_email text default null
)
returns setof public.sales_records
language plpgsql
security definer
set search_path = public
as $$
declare
  v_particulars text := trim(coalesce(p_particulars, ''));
  v_catalog_price numeric(10,2);
  v_catalog_amount numeric(10,2);
  v_price_mismatch boolean := false;
  v_new_id bigint;
  v_produce_id bigint;
  v_existing_amount numeric(10,2);
  v_source_record_id bigint;
  v_source_total_dispatch_kg numeric(10,2);
  v_source_kgs_supplied numeric(10,2);
  v_source_rejects_kg numeric(10,2);
  v_source_missing_kg numeric(10,2);
  v_source_rows_closed integer := 0;
  v_bank_account_active boolean;
begin
  if p_amount_deposited > 0 and p_bank_account_id is null then
    raise exception 'Bank account is required when amount deposited is greater than zero.';
  end if;

  if p_bank_account_id is not null then
    select is_active
      into v_bank_account_active
    from public.bank_accounts
    where id = p_bank_account_id
    limit 1;

    if v_bank_account_active is not true then
      raise exception 'Selected bank account is inactive.';
    end if;
  end if;

  if v_particulars <> '' then
    select id, unit_price, amount_kg
      into v_produce_id, v_catalog_price, v_catalog_amount
      from public.produce
     where lower(particulars) = lower(v_particulars)
       and is_available is not false
     limit 1
     for update;

    if v_catalog_price is null then
      raise exception 'Produce % is not available in inventory', v_particulars;
    end if;

    if coalesce(p_kgs_supplied, 0) > coalesce(v_catalog_amount, 0) then
      raise exception 'Not enough stock available for %. Available: % kg.', v_particulars, coalesce(v_catalog_amount, 0);
    end if;

    if abs(coalesce(p_unit_price, 0) - coalesce(v_catalog_price, 0)) > 0.0001 then
      v_price_mismatch := true;
    end if;
  end if;

  select id, total_dispatch_kg, kgs_supplied, rejects_kg, missing_in_kgs
    into v_source_record_id, v_source_total_dispatch_kg, v_source_kgs_supplied, v_source_rejects_kg, v_source_missing_kg
  from public.sales_records
  where is_deleted = false
    and lower(trim(coalesce(particulars, ''))) = lower(trim(coalesce(v_particulars, '')))
  order by
    case
      when coalesce(total_dispatch_kg, 0) is distinct from (coalesce(kgs_supplied, 0) + coalesce(rejects_kg, 0)) then 0
      else 1
    end,
    updated_at desc nulls last,
    sno desc nulls last
  limit 1;

  insert into public.sales_records (
    sale_date,
    customer_name,
    particulars,
    total_dispatch_kg,
    kgs_supplied,
    rejects_kg,
    unit_price,
    amount_deposited,
    bank_account_id,
    bank_account,
    receipt_no,
    remarks,
    price_mismatch
  ) values (
    p_sale_date,
    p_customer_name,
    v_particulars,
    coalesce(p_total_dispatch_kg, 0),
    coalesce(p_kgs_supplied, 0),
    coalesce(p_rejects_kg, 0),
    coalesce(p_unit_price, 0),
    coalesce(p_amount_deposited, 0),
    p_bank_account_id,
    p_bank_account,
    p_receipt_no,
    p_remarks,
    v_price_mismatch
  ) returning id into v_new_id;

  if v_source_record_id is not null then
    update public.sales_records
       set total_dispatch_kg = coalesce(v_source_kgs_supplied, 0) + coalesce(v_source_rejects_kg, 0),
           updated_at = now()
     where id = v_source_record_id
       and total_dispatch_kg is distinct from (coalesce(v_source_kgs_supplied, 0) + coalesce(v_source_rejects_kg, 0))
       and is_deleted = false;

    get diagnostics v_source_rows_closed = row_count;

    if v_source_rows_closed > 0 then
      insert into public.edit_history (
        record_id,
        sale_id,
        draft_session_id,
        field_changed,
        old_value,
        new_value,
        edited_by_email,
        edited_successfully,
        edited_at,
        created_at,
        edited_by,
        note
      ) values (
        v_source_record_id,
        v_source_record_id,
        null,
        'total_dispatch_kg',
        coalesce(v_source_total_dispatch_kg, 0)::text,
        (coalesce(v_source_kgs_supplied, 0) + coalesce(v_source_rejects_kg, 0))::text,
        lower(coalesce(p_edited_by_email, 'system')),
        true,
        now(),
        now(),
        auth.uid(),
        format('closed out on save of record_id %s', v_new_id)
      );

      insert into public.edit_history (
        record_id,
        sale_id,
        draft_session_id,
        field_changed,
        old_value,
        new_value,
        edited_by_email,
        edited_successfully,
        edited_at,
        created_at,
        edited_by,
        note
      ) values (
        v_source_record_id,
        v_source_record_id,
        null,
        'missing_in_kgs',
        coalesce(v_source_missing_kg, 0)::text,
        '0',
        lower(coalesce(p_edited_by_email, 'system')),
        true,
        now(),
        now(),
        auth.uid(),
        format('consumed by record_id %s', v_new_id)
      );
    end if;
  end if;

  update edit_history
     set sale_id = v_new_id,
         record_id = v_new_id
   where sale_id = 0
     and draft_session_id = p_draft_session_id
     and lower(coalesce(edited_by_email, '')) = lower(coalesce(p_edited_by_email, ''));

  if v_produce_id is not null then
    v_existing_amount := coalesce(v_catalog_amount, 0) - coalesce(p_kgs_supplied, 0);

    update public.produce
       set amount_kg = v_existing_amount,
           is_available = case when v_existing_amount > 0 then true else false end,
           updated_at = now()
     where id = v_produce_id;

    insert into public.produce_stock_log (
      produce_id,
      action_type,
      quantity_kg,
      unit_price,
      created_by,
      created_by_email,
      related_sale_id,
      notes
    ) values (
      v_produce_id,
      'sale_deduction',
      -coalesce(p_kgs_supplied, 0),
      coalesce(p_unit_price, 0),
      auth.uid(),
      lower(coalesce(auth.email(), 'unknown')),
      v_new_id,
      'Stock deducted for sales record'
    );
  end if;

  -- Allocate shortfall to the sales agent who created the record
  declare
    v_missing_kg numeric(10,2);
    v_agent_id uuid;
    v_agent_email text;
  begin
    if v_produce_id is not null then
      select missing_in_kgs into v_missing_kg from public.sales_records where id = v_new_id limit 1;
      
      if coalesce(v_missing_kg, 0) > 0 then
        v_agent_id := auth.uid();
        v_agent_email := lower(coalesce(auth.email(), 'unknown'));
        
        insert into public.employee_stock_allocations (employee_id, produce_id, allocated_kg)
        values (v_agent_id, v_produce_id, v_missing_kg)
        on conflict(employee_id, produce_id) do update 
        set allocated_kg = employee_stock_allocations.allocated_kg + v_missing_kg, updated_at = now();
        
        insert into public.stock_transfer_log (
          transfer_type,
          source_type,
          source_employee_id,
          destination_type,
          destination_employee_id,
          produce_id,
          quantity_kg,
          performed_by,
          performed_by_email,
          triggered_by_record_id,
          remarks
        ) values (
          'sales_agent_allocation',
          'sales_record',
          null,
          'employee',
          v_agent_id,
          v_produce_id,
          v_missing_kg,
          v_agent_id,
          v_agent_email,
          v_new_id,
          format('Shortfall from sales record #%s', v_new_id)
        );
      end if;
    end if;
  end;

  return query
  select *
    from public.sales_records
   where id = v_new_id;
end;
$$;

create or replace function public.restock_produce(
  p_produce_id bigint,
  p_amount_added numeric,
  p_new_unit_price numeric default null,
  p_added_by uuid default null,
  p_note text default null
)
returns public.produce
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current public.produce%rowtype;
  v_new_amount numeric(10,2);
  v_new_price numeric(10,2);
  v_added_by uuid := coalesce(p_added_by, auth.uid());
  v_added_by_email text;
begin
  if coalesce(p_amount_added, 0) <= 0 then
    raise exception 'Restock amount must be greater than zero';
  end if;

  select * into v_current
  from public.produce
  where id = p_produce_id
  for update;

  if not found then
    raise exception 'Produce not found';
  end if;

  v_new_amount := coalesce(v_current.amount_kg, 0) + coalesce(p_amount_added, 0);
  v_new_price := coalesce(p_new_unit_price, v_current.unit_price);

  update public.produce
     set amount_kg = v_new_amount,
         unit_price = v_new_price,
         is_available = true,
         ready_date = null,
         last_restocked_at = now(),
         updated_at = now()
   where id = p_produce_id;

  select lower(coalesce(
    (select email from public.profiles where id = v_added_by limit 1),
    (select email from auth.users where id = v_added_by limit 1),
    'unknown'
  )) into v_added_by_email;

  insert into public.produce_stock_log (
    produce_id,
    action_type,
    quantity_kg,
    unit_price,
    notes,
    created_by,
    created_by_email
  ) values (
    p_produce_id,
    'restock',
    coalesce(p_amount_added, 0),
    v_new_price,
    coalesce(p_note, 'Restock recorded'),
    v_added_by,
    v_added_by_email
  );

  return (select * from public.produce where id = p_produce_id);
end;
$$;

create or replace function public.get_inventory_reports(p_period text default 'month')
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period text := lower(coalesce(p_period, 'month'));
  v_by_period json;
  v_by_produce json;
begin
  select coalesce(json_agg(
    json_build_object(
      'period', period,
      'kg_sold', kg_sold,
      'revenue', revenue
    ) order by period
  ), '[]'::json)
    into v_by_period
  from (
    select
      to_char(date_trunc(case
        when v_period = 'day' then 'day'
        when v_period = 'week' then 'week'
        when v_period = 'year' then 'year'
        else 'month'
      end, sale_date), case
        when v_period = 'day' then 'YYYY-MM-DD'
        when v_period = 'week' then 'YYYY-MM-DD'
        when v_period = 'year' then 'YYYY'
        else 'YYYY-MM'
      end) as period,
      coalesce(sum(kgs_supplied), 0)::numeric as kg_sold,
      coalesce(sum(expected_amount), 0)::numeric as revenue
    from sales_records
    where is_deleted = false
    group by date_trunc(case
      when v_period = 'day' then 'day'
      when v_period = 'week' then 'week'
      when v_period = 'year' then 'year'
      else 'month'
    end, sale_date)
  ) d;

  select coalesce(json_agg(
    json_build_object(
      'produce', produce,
      'kg_sold', kg_sold,
      'revenue', revenue,
      'remaining_stock', remaining_stock
    ) order by revenue desc
  ), '[]'::json)
    into v_by_produce
  from (
    select
      s.particulars as produce,
      coalesce(sum(s.kgs_supplied), 0)::numeric as kg_sold,
      coalesce(sum(s.expected_amount), 0)::numeric as revenue,
      coalesce(p.amount_kg, 0)::numeric as remaining_stock
    from sales_records s
    left join public.produce p
      on lower(p.particulars) = lower(s.particulars)
    where s.is_deleted = false
    group by s.particulars, p.amount_kg
  ) d2;

  return json_build_object(
    'by_period', v_by_period,
    'by_produce', v_by_produce
  );
end;
$$;

create or replace function public.record_sales_edit_audit(
  p_field_changed text,
  p_old_value text,
  p_new_value text,
  p_edited_by_email text,
  p_sale_id bigint default 0,
  p_draft_session_id uuid default null,
  p_edited_successfully boolean default true,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inserted_id uuid;
begin
  insert into edit_history (
    record_id,
    sale_id,
    draft_session_id,
    field_changed,
    old_value,
    new_value,
    edited_by_email,
    edited_successfully,
    edited_at,
    created_at,
    note
  ) values (
    0,
    coalesce(p_sale_id, 0),
    p_draft_session_id,
    p_field_changed,
    p_old_value,
    p_new_value,
    lower(coalesce(p_edited_by_email, 'unknown')),
    coalesce(p_edited_successfully, true),
    now(),
    now(),
    p_note
  ) returning id into v_inserted_id;

  return v_inserted_id;
end;
$$;

create or replace function public.backfill_edit_history_sale_id(
  p_sale_id bigint,
  p_draft_session_id uuid,
  p_edited_by_email text default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows_updated integer;
begin
  update edit_history
     set sale_id = p_sale_id,
         record_id = p_sale_id,
         edited_by_email = lower(coalesce(p_edited_by_email, edited_by_email))
   where sale_id = 0
     and draft_session_id = p_draft_session_id
     and coalesce(edited_by_email, '') = lower(coalesce(p_edited_by_email, coalesce(edited_by_email, '')));

  get diagnostics v_rows_updated = row_count;
  return v_rows_updated;
end;
$$;

create or replace function public.validate_consecutive_records(p_particulars text)
returns json
language plpgsql
stable
set search_path = public
as $$
declare
  v_result json;
begin
  select coalesce(json_agg(row_to_json(t) order by record_date, sale_sno), '[]'::json)
    into v_result
  from (
    with ordered as (
      select
        id,
        sale_date as record_date,
        sno as sale_sno,
        particulars,
        total_dispatch_kg,
        kgs_supplied,
        rejects_kg,
        missing_in_kgs,
        row_number() over (
          order by sale_date, sno
        ) as rn
      from sales_records
      where is_deleted = false
        and lower(trim(coalesce(particulars, ''))) = lower(trim(coalesce(p_particulars, '')))
    ),
    paired as (
      select
        cur.id as current_id,
        cur.record_date,
        cur.sale_sno,
        cur.particulars,
        cur.total_dispatch_kg as current_total_dispatch_kg,
        cur.kgs_supplied as current_kgs_supplied,
        cur.rejects_kg as current_rejects_kg,
        cur.missing_in_kgs as current_missing_kg,
        next.id as next_id,
        next.total_dispatch_kg as next_total_dispatch_kg,
        next.kgs_supplied as next_kgs_supplied,
        next.rejects_kg as next_rejects_kg,
        next.missing_in_kgs as next_missing_kg,
        ov.old_value as override_old_value,
        ov.new_value as override_new_value
      from ordered cur
      left join ordered next
        on next.rn = cur.rn + 1
      left join lateral (
        select eh.old_value, eh.new_value
        from edit_history eh
        where eh.sale_id = next.id
          and eh.record_id = next.id
          and eh.sale_id <> 0
          and eh.edited_successfully = true
          and lower(eh.field_changed) = 'total_dispatch_kg'
        order by eh.edited_at desc, eh.created_at desc
        limit 1
      ) ov on true
    )
    select
      current_id as record_id,
      next_id,
      current_missing_kg,
      next_total_dispatch_kg,
      override_old_value,
      override_new_value,
      case
        when next_id is null then 'no_next_record'
        when override_new_value is null then
          case when next_total_dispatch_kg = current_missing_kg then 'pass' else 'fail' end
        else
          case
            when override_old_value::numeric = current_missing_kg
             and next_total_dispatch_kg::numeric = override_new_value::numeric then 'pass'
            else 'fail'
          end
      end as validation_status,
      case
        when next_id is null then null
        when override_new_value is null then
          case when next_total_dispatch_kg = current_missing_kg then 'No override detected; dispatch matches carried missing kg.'
               else 'Mismatch: next record dispatch does not equal carried missing kg.'
          end
        else
          case
            when override_old_value::numeric = current_missing_kg
             and next_total_dispatch_kg::numeric = override_new_value::numeric then 'Override path validated against the saved audit entry.'
            else 'Mismatch: saved override audit does not match the carried missing kg or final dispatch.'
          end
      end as message
    from paired
    where next_id is not null
  ) t;

  return v_result;
end;
$$;

create or replace function public.sales_records_audit_history()
returns trigger as $$
declare
  user_email text := lower(coalesce(auth.email(), 'unknown'));
begin
  if old.sale_date is distinct from new.sale_date then
    insert into edit_history(record_id, field_changed, old_value, new_value, edited_by_email)
    values (old.id, 'sale_date', old.sale_date::text, new.sale_date::text, user_email);
  end if;
  if old.customer_name is distinct from new.customer_name then
    insert into edit_history(record_id, field_changed, old_value, new_value, edited_by_email)
    values (old.id, 'customer_name', old.customer_name, new.customer_name, user_email);
  end if;
  if old.particulars is distinct from new.particulars then
    insert into edit_history(record_id, field_changed, old_value, new_value, edited_by_email)
    values (old.id, 'particulars', old.particulars, new.particulars, user_email);
  end if;
  if old.confirmation_status is distinct from new.confirmation_status then
    insert into edit_history(record_id, field_changed, old_value, new_value, edited_by_email)
    values (old.id, 'confirmation_status', old.confirmation_status::text, new.confirmation_status::text, user_email);
  end if;
  if old.total_dispatch_kg is distinct from new.total_dispatch_kg then
    insert into edit_history(record_id, field_changed, old_value, new_value, edited_by_email)
    values (old.id, 'total_dispatch_kg', old.total_dispatch_kg::text, new.total_dispatch_kg::text, user_email);
  end if;
  if old.kgs_supplied is distinct from new.kgs_supplied then
    insert into edit_history(record_id, field_changed, old_value, new_value, edited_by_email)
    values (old.id, 'kgs_supplied', old.kgs_supplied::text, new.kgs_supplied::text, user_email);
  end if;
  if old.rejects_kg is distinct from new.rejects_kg then
    insert into edit_history(record_id, field_changed, old_value, new_value, edited_by_email)
    values (old.id, 'rejects_kg', old.rejects_kg::text, new.rejects_kg::text, user_email);
  end if;
  if old.unit_price is distinct from new.unit_price then
    insert into edit_history(record_id, field_changed, old_value, new_value, edited_by_email)
    values (old.id, 'unit_price', old.unit_price::text, new.unit_price::text, user_email);
  end if;
  if old.amount_deposited is distinct from new.amount_deposited then
    insert into edit_history(record_id, field_changed, old_value, new_value, edited_by_email)
    values (old.id, 'amount_deposited', old.amount_deposited::text, new.amount_deposited::text, user_email);
  end if;
  if old.remarks is distinct from new.remarks then
    insert into edit_history(record_id, field_changed, old_value, new_value, edited_by_email)
    values (old.id, 'remarks', old.remarks, new.remarks, user_email);
  end if;
  if old.branch_location is distinct from new.branch_location then
    insert into edit_history(record_id, field_changed, old_value, new_value, edited_by_email)
    values (old.id, 'branch_location', old.branch_location, new.branch_location, user_email);
  end if;
  if old.recorded_by_email is distinct from new.recorded_by_email then
    insert into edit_history(record_id, field_changed, old_value, new_value, edited_by_email)
    values (old.id, 'recorded_by_email', old.recorded_by_email, new.recorded_by_email, user_email);
  end if;
  if old.is_deleted is distinct from new.is_deleted then
    insert into edit_history(record_id, field_changed, old_value, new_value, edited_by_email)
    values (old.id, 'is_deleted', old.is_deleted::text, new.is_deleted::text, user_email);
  end if;
  if old.deleted_at is distinct from new.deleted_at then
    insert into edit_history(record_id, field_changed, old_value, new_value, edited_by_email)
    values (old.id, 'deleted_at', old.deleted_at::text, new.deleted_at::text, user_email);
  end if;
  return new;
end;
$$ language plpgsql;

-- Helpful indexes
create index if not exists idx_sales_records_customer on sales_records (customer_name);
create index if not exists idx_sales_records_customer_id on sales_records (customer_id, is_deleted, sale_date, id);
create index if not exists idx_sales_records_status on sales_records (status);
create index if not exists idx_sales_records_date on sales_records (sale_date);
create index if not exists idx_sales_records_recorded_by_user on sales_records (recorded_by_user_id, is_deleted, sale_date, id);
create index if not exists idx_sales_records_recorded_by_email on sales_records (recorded_by_email);
create index if not exists idx_sales_records_branch_location on sales_records (branch_location);
create index if not exists idx_sales_records_bank_account_id on sales_records (bank_account_id);
create index if not exists idx_sales_records_confirmation_status on sales_records (confirmation_status);
create index if not exists idx_sales_records_is_deleted on sales_records (is_deleted);
create index if not exists idx_customers_created_by on public.customers (created_by);
create index if not exists idx_customers_default_sales_agent_id on public.customers (default_sales_agent_id);
create index if not exists idx_bank_accounts_created_by on public.bank_accounts (created_by);
create index if not exists idx_bank_account_adjustments_bank_account_id on public.bank_account_adjustments (bank_account_id);
create index if not exists idx_produce_particulars on public.produce (particulars);
create index if not exists idx_produce_available on public.produce (is_available, amount_kg);

create or replace view active_sales_records as
select * from sales_records
where is_deleted = false;

-- ============================================================
-- User Profiles Table — Links Auth users to metadata
-- Automatically created when a new Auth user is added
-- ============================================================
create table if not exists public.profiles (
  id                 uuid primary key references auth.users(id) on delete cascade,
  full_name          text not null,
  email              text not null unique,
  phone_number       text not null check (phone_number ~ '^\+254[0-9]{9}$'),
  avatar_url         text,
  role               text not null default 'sales_agent',
  location           text not null,
  profile_prompted   boolean not null default false,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

update public.profiles
set role = 'sales_agent'
where role is null
   or lower(trim(role)) not in ('admin','manager','supervisor','accountant','sales_agent','staff','group_leader','driver');

alter table public.profiles
  drop constraint if exists profiles_role_check;

alter table public.profiles
  add constraint profiles_role_check
  check (lower(role) in ('admin','manager','supervisor','accountant','sales_agent','staff','group_leader','driver'));

-- Ensure the column exists in the live database (idempotent migration).
-- Run this if your Supabase DB was not migrated and you see PostgREST schema-cache errors.
alter table public.profiles
  add column if not exists profile_prompted boolean not null default false;

alter table public.profiles
  add column if not exists avatar_url text;

-- View for joined sales records and user profile metadata
-- Includes payment confirmation text used by the sales agent UI.
drop view if exists public.sales_records_with_users cascade;
create or replace view public.sales_records_with_users (
  id,
  sno,
  sale_date,
  customer_name,
  customer_id,
  receipt_no,
  particulars,
  branch_location,
  recorded_by_email,
  recorded_by_user_id,
  recorded_by_full_name,
  total_dispatch_kg,
  kgs_supplied,
  rejects_kg,
  unit_price,
  amount_deposited,
  expenses,
  price_mismatch,
  expected_amount,
  kgs_paid_for,
  excess_less,
  balance_to_be_paid,
  missing_in_kgs,
  missing_amount,
  kgs_to_be_paid,
  status,
  confirmation_status,
  approved_by,
  approved_at,
  bank_account_id,
  bank_account,
  deposit_confirmation_url,
  payment_confirmation_text,
  remarks,
  is_deleted,
  deleted_at,
  created_at,
  updated_at,
  recorded_by_user,
  approved_by_user,
  customer_name_particulars
) as
select
  sr.id,
  sr.sno,
  sr.sale_date,
  sr.customer_name,
  sr.customer_id,
  sr.receipt_no,
  sr.particulars,
  sr.branch_location,
  sr.recorded_by_email,
  sr.recorded_by_user_id,
  sr.recorded_by_full_name,
  sr.total_dispatch_kg,
  sr.kgs_supplied,
  sr.rejects_kg,
  sr.unit_price,
  sr.amount_deposited,
  coalesce(sr.expenses, 0)::numeric(12,2) as expenses,
  sr.price_mismatch,
  sr.expected_amount,
  sr.kgs_paid_for,
  (coalesce(sr.amount_deposited, 0) + coalesce(sr.expenses, 0) - coalesce(sr.expected_amount, 0))::numeric(12,2) as excess_less,
  (coalesce(sr.expected_amount, 0) - (coalesce(sr.amount_deposited, 0) + coalesce(sr.expenses, 0)))::numeric(12,2) as balance_to_be_paid,
  sr.missing_in_kgs,
  sr.missing_amount,
  sr.kgs_to_be_paid,
  sr.status,
  sr.confirmation_status,
  sr.approved_by,
  sr.approved_at,
  sr.bank_account_id,
  sr.bank_account,
  sr.deposit_confirmation_url,
  sr.payment_confirmation_text,
  sr.remarks,
  sr.is_deleted,
  sr.deleted_at,
  sr.created_at,
  sr.updated_at,
  jsonb_build_object(
    'full_name', rp.full_name,
    'phone_number', rp.phone_number,
    'email', rp.email
  ) as recorded_by_user,
  jsonb_build_object(
    'full_name', ap.full_name,
    'phone_number', ap.phone_number,
    'email', ap.email
  ) as approved_by_user,
  concat_ws(' / ', nullif(sr.customer_name, ''), nullif(sr.particulars, '')) as customer_name_particulars
from public.sales_records sr
left join public.profiles rp on rp.id = sr.recorded_by_user_id
left join public.profiles ap on ap.id = sr.approved_by;

-- Auto-update last_login on each login (tracked via updated_at)
create or replace function set_profiles_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create or replace function public.profiles_current_role()
returns text as $$
declare
  v_role text;
begin
  select public.normalize_profile_role(role)
    into v_role
    from public.profiles
   where id = auth.uid()
   limit 1;
  return coalesce(v_role, 'sales_agent');
exception when no_data_found then
  return 'sales_agent';
end;
$$ language plpgsql security definer set row_security = off;

create or replace function public.profiles_has_full_access()
returns boolean as $$
begin
  return public.profiles_current_role() in ('admin', 'manager', 'supervisor', 'accountant');
end;
$$ language plpgsql security definer set row_security = off;

create or replace function public.profiles_is_manager_or_supervisor()
returns boolean as $$
begin
  return public.profiles_current_role() in ('admin', 'manager', 'supervisor');
end;
$$ language plpgsql security definer set row_security = off;

create or replace function public.profiles_is_group_leader()
returns boolean as $$
begin
  return public.profiles_current_role() = 'group_leader';
end;
$$ language plpgsql security definer set row_security = off;

create or replace function public.profiles_can_manage_roles()
returns boolean as $$
begin
  return public.profiles_current_role() in ('admin', 'manager');
end;
$$ language plpgsql security definer set row_security = off;

create table if not exists public.profile_role_changes (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles(id) on delete set null,
  previous_role text not null,
  new_role text not null,
  changed_by uuid references public.profiles(id) on delete set null,
  changed_at timestamptz not null default now()
);

alter table public.profile_role_changes enable row level security;

drop policy if exists "managers read profile role changes" on public.profile_role_changes;
create policy "managers read profile role changes"
  on public.profile_role_changes
  for select
  to authenticated
  using (public.profiles_can_manage_roles());

create or replace function public.profiles_restrict_sensitive_updates()
returns trigger as $$
begin
  -- Role changes are permitted only through set_profile_role(), which sets this
  -- transaction-local flag after checking the caller's manager/admin role.
  if new.role is distinct from old.role
     and current_setting('app.profile_role_change', true) is distinct from 'allowed' then
    raise exception 'Permission denied: roles can only be changed through the approved role-management function';
  end if;

  -- A user editing their own profile may only alter non-privileged profile data.
  -- Managers can still maintain staff profiles, but cannot bypass the role rule above.
  if auth.uid() = old.id
     and not public.profiles_can_manage_roles()
     and current_setting('app.profile_self_service_update', true) is distinct from 'allowed' then
    if new.email is distinct from old.email
       or new.location is distinct from old.location
       or new.profile_prompted is distinct from old.profile_prompted
       or new.created_at is distinct from old.created_at
       or new.id is distinct from old.id then
      raise exception 'Permission denied: only name, phone number, and avatar can be updated on your profile';
    end if;
  end if;
  return new;
end;
$$ language plpgsql security definer set row_security = off;

create or replace function public.set_profile_role(
  p_profile_id uuid,
  p_new_role text
)
returns public.profiles
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  v_role text := lower(trim(coalesce(p_new_role, '')));
  v_profile public.profiles%rowtype;
  v_previous_role text;
begin
  if auth.uid() is null or not public.profiles_can_manage_roles() then
    raise exception 'Only managers and administrators can change user roles.';
  end if;

  if p_profile_id is null then
    raise exception 'A profile is required.';
  end if;

  if v_role not in ('admin', 'manager', 'supervisor', 'accountant', 'sales_agent', 'staff', 'group_leader', 'driver') then
    raise exception 'Invalid role.';
  end if;

  -- Managers can manage operational roles, while only an administrator can grant
  -- administrator access.
  if v_role = 'admin' and public.profiles_current_role() <> 'admin' then
    raise exception 'Only an administrator can grant administrator access.';
  end if;

  select * into v_profile
  from public.profiles
  where id = p_profile_id
  for update;

  if not found then
    raise exception 'Profile not found.';
  end if;

  if v_profile.role is distinct from v_role then
    v_previous_role := v_profile.role;
    perform set_config('app.profile_role_change', 'allowed', true);

    update public.profiles
       set role = v_role,
           updated_at = now()
     where id = p_profile_id
     returning * into v_profile;

    insert into public.profile_role_changes(profile_id, previous_role, new_role, changed_by)
    values (p_profile_id, v_previous_role, v_role, auth.uid());
  end if;

  return v_profile;
end;
$$;

revoke all on function public.set_profile_role(uuid, text) from public, anon;
grant execute on function public.set_profile_role(uuid, text) to authenticated;

create or replace function public.update_own_profile(
  p_full_name text default null,
  p_phone_number text default null,
  p_location text default null,
  p_avatar_url text default null,
  p_profile_prompted boolean default null
)
returns public.profiles
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  v_profile public.profiles%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to update your profile.';
  end if;

  if p_phone_number is not null and p_phone_number !~ '^\+254[0-9]{9}$' then
    raise exception 'Enter a valid Kenya phone number starting with +254.';
  end if;

  perform set_config('app.profile_self_service_update', 'allowed', true);
  update public.profiles
     set full_name = coalesce(nullif(trim(p_full_name), ''), full_name),
         phone_number = coalesce(nullif(trim(p_phone_number), ''), phone_number),
         location = coalesce(nullif(trim(p_location), ''), location),
         avatar_url = coalesce(nullif(trim(p_avatar_url), ''), avatar_url),
         profile_prompted = coalesce(p_profile_prompted, profile_prompted),
         updated_at = now()
   where id = auth.uid()
   returning * into v_profile;

  if not found then
    raise exception 'Profile not found.';
  end if;

  return v_profile;
end;
$$;

revoke all on function public.update_own_profile(text, text, text, text, boolean) from public, anon;
grant execute on function public.update_own_profile(text, text, text, text, boolean) to authenticated;

create or replace function public.auth_users_insert_profile()
returns trigger as $$
declare
  v_full_name text;
  v_email text;
  v_phone_number text;
  v_role text;
  v_location text;
begin
  v_email := lower(trim(coalesce(new.email, '')));
  v_full_name := initcap(split_part(v_email, '@', 1));
  v_phone_number := coalesce(nullif(trim(coalesce(new.raw_user_meta_data->>'phone_number', '+254000000000')), ''), '+254000000000');
  if v_phone_number !~ '^\+254[0-9]{9}$' then
    v_phone_number := '+254000000000';
  end if;

  -- Signup metadata is user-controlled. New accounts always start as
  -- sales_agent and must be promoted through set_profile_role().
  v_role := 'sales_agent';
  v_location := coalesce(nullif(trim(coalesce(new.raw_user_meta_data->>'location', 'Unknown')), ''), 'Unknown');

  insert into public.profiles(
    id,
    full_name,
    email,
    phone_number,
    role,
    location
  ) values (
    new.id,
    v_full_name,
    v_email,
    v_phone_number,
    v_role,
    initcap(v_location)
  ) on conflict (id) do update set
    full_name = excluded.full_name,
    email = excluded.email,
    phone_number = excluded.phone_number,
    role = excluded.role,
    location = excluded.location,
    updated_at = now();

  return new;
end;
$$ language plpgsql security definer set row_security = off;

drop trigger if exists trg_auth_users_after_insert_profile on auth.users;
create trigger trg_auth_users_after_insert_profile
  after insert on auth.users
  for each row execute function public.auth_users_insert_profile();

-- Enable RLS on profiles
alter table public.profiles enable row level security;

-- Users can read their own profile, and managers/supervisors/accountants can read all
drop policy if exists "Users read own profile" on public.profiles;
create policy "Users read own profile"
  on public.profiles
  for select
  to authenticated
  using (
    auth.uid() = id
    or public.profiles_has_full_access()
  );

-- Users can update their own profile; managers/supervisors can update staff profiles too
drop policy if exists "Users update own profile" on public.profiles;
create policy "Users update own profile"
  on public.profiles
  for update
  to authenticated
  using (
    auth.uid() = id
    or public.profiles_is_manager_or_supervisor()
  )
  with check (
    auth.uid() = id
    or public.profiles_is_manager_or_supervisor()
  );

-- Users can insert their own profile; managers/supervisors can create sales_agent/accountant profiles
drop policy if exists "Users insert own profile" on public.profiles;
create policy "Users insert own profile"
  on public.profiles
  for insert
  to authenticated
  with check (
    (auth.uid() = id and lower(role) = 'sales_agent')
    or (
      public.profiles_is_manager_or_supervisor()
      and lower(role) in ('sales_agent', 'accountant', 'staff', 'group_leader', 'driver', 'manager', 'supervisor')
    )
  );

-- Managers/supervisors can delete profiles
drop policy if exists "Users delete own profile" on public.profiles;
create policy "Users delete own profile"
  on public.profiles
  for delete
  to authenticated
  using (
    auth.uid() = id
    or public.profiles_is_manager_or_supervisor()
  );

-- Auto-create profile when new auth user is added
-- This trigger ensures every new authenticated user gets a matching profile row
-- with default role = sales_agent and location = 'Unknown'.

-- ============================================================
-- Create triggers to normalize casing and set defaults

drop trigger if exists trg_sales_records_normalize_case on sales_records;
create trigger trg_sales_records_normalize_case
  before insert or update on sales_records
  for each row execute function public.normalize_case();

drop trigger if exists trg_profiles_normalize_case on public.profiles;
create trigger trg_profiles_normalize_case
  before insert or update on public.profiles
  for each row execute function public.normalize_case();

drop trigger if exists trg_profiles_restrict_role_location_updates on public.profiles;
drop trigger if exists trg_profiles_restrict_sensitive_updates on public.profiles;
create trigger trg_profiles_restrict_sensitive_updates
  before update on public.profiles
  for each row execute function public.profiles_restrict_sensitive_updates();

drop trigger if exists trg_sales_records_set_defaults on sales_records;
create trigger trg_sales_records_set_defaults
  before insert on sales_records
  for each row execute function public.sales_records_set_defaults();

drop trigger if exists trg_sales_records_audit_history on sales_records;
create trigger trg_sales_records_audit_history
  before update on sales_records
  for each row execute function public.sales_records_audit_history();

drop trigger if exists trg_sales_records_lock_after_approval on sales_records;
create trigger trg_sales_records_lock_after_approval
  before update on sales_records
  for each row execute function public.prevent_edit_after_approval();

drop trigger if exists trg_sales_records_prevent_delete_approved on sales_records;
create trigger trg_sales_records_prevent_delete_approved
  before delete on sales_records
  for each row execute function public.prevent_delete_approved_sales_record();

drop trigger if exists trg_sales_records_carry_forward_missing_kg on sales_records;
create trigger trg_sales_records_carry_forward_missing_kg
  before insert on sales_records
  for each row execute function public.carry_forward_missing_kg_to_next_record();

drop trigger if exists trg_bank_accounts_log_balance_change on public.bank_accounts;
create trigger trg_bank_accounts_log_balance_change
  after insert on public.bank_accounts
  for each row execute function public.log_bank_account_balance_change();

drop trigger if exists trg_bank_accounts_enforce_single_balance_writer on public.bank_accounts;
create trigger trg_bank_accounts_enforce_single_balance_writer
  before update on public.bank_accounts
  for each row execute function public.prevent_direct_bank_balance_update();

drop trigger if exists trg_bank_accounts_prevent_delete on public.bank_accounts;
create trigger trg_bank_accounts_prevent_delete
  before delete on public.bank_accounts
  for each row execute function public.log_bank_account_balance_change();

drop trigger if exists trg_accounting_cash_book_append_only on public.accounting_cash_book;
create trigger trg_accounting_cash_book_append_only
  before update or delete on public.accounting_cash_book
  for each row execute function public.prevent_accounting_cash_book_modification();

-- Retire the legacy approval-trigger balance updater if it exists from older migrations.
drop trigger if exists trg_sales_record_confirmation_balance on public.sales_records;
drop function if exists public.handle_sales_record_confirmation_balance();
drop function if exists public.adjust_bank_account_balance(uuid, numeric, text, uuid);

-- ============================================================
-- Row Level Security
-- Locked down to logged-in users only. The "anon" key is still
-- used by the app to talk to Supabase, but with RLS like this,
-- anon (not-logged-in) requests are rejected outright — only a
-- request carrying a valid Supabase Auth session (the
-- "authenticated" role) can read or write.
-- ============================================================
alter table sales_records enable row level security;

drop policy if exists "public full access" on sales_records;
drop policy if exists "authenticated full access" on sales_records;
drop policy if exists "authenticated sales_records access" on sales_records;
drop policy if exists "select sales_records by role" on sales_records;
drop policy if exists "insert sales_records by role" on sales_records;
drop policy if exists "update sales_records by role" on sales_records;
drop policy if exists "delete sales_records by role" on sales_records;

create policy "select sales_records by role"
  on sales_records
  for select
  to authenticated
  using (
    public.profiles_has_full_access()
    or (
      public.profiles_current_role() in ('sales_agent', 'staff')
      and recorded_by_email = lower(auth.email())
    )
  );

create policy "insert sales_records by role"
  on sales_records
  for insert
  to authenticated
  with check (
    public.profiles_has_full_access()
    or (
      public.profiles_current_role() in ('sales_agent', 'staff')
      and recorded_by_email = lower(auth.email())
    )
  );

create policy "update sales_records by role"
  on sales_records
  for update
  to authenticated
  using (
    public.profiles_has_full_access()
    or (
      public.profiles_current_role() in ('sales_agent', 'staff')
      and recorded_by_email = lower(auth.email())
    )
  )
  with check (
    public.profiles_has_full_access()
    or (
      public.profiles_current_role() in ('sales_agent', 'staff')
      and recorded_by_email = lower(auth.email())
    )
  );

create policy "delete sales_records by role"
  on sales_records
  for delete
  to authenticated
  using (
    public.profiles_has_full_access()
    or (
      public.profiles_current_role() in ('sales_agent', 'staff')
      and recorded_by_email = lower(auth.email())
    )
  );
-- ============================================================
-- Employee records access
-- ============================================================
alter table public.employees enable row level security;

drop policy if exists "authenticated read employees" on public.employees;
create policy "authenticated read employees"
  on public.employees
  for select
  to authenticated
  using (public.profiles_current_role() in ('admin','manager','supervisor','group_leader'));

drop policy if exists "managers manage employees" on public.employees;
create policy "managers manage employees"
  on public.employees
  for insert
  to authenticated
  with check (public.profiles_is_manager_or_supervisor() or public.profiles_is_group_leader());

drop policy if exists "managers update employees" on public.employees;
create policy "managers update employees"
  on public.employees
  for update
  to authenticated
  using (public.profiles_is_manager_or_supervisor() or public.profiles_is_group_leader())
  with check (public.profiles_is_manager_or_supervisor() or public.profiles_is_group_leader());

drop policy if exists "managers delete employees" on public.employees;
create policy "managers delete employees"
  on public.employees
  for delete
  to authenticated
  using (public.profiles_is_manager_or_supervisor() or public.profiles_is_group_leader());

-- ============================================================
-- Produce inventory access
-- ============================================================
alter table public.produce enable row level security;

drop policy if exists "authenticated read produce" on public.produce;
create policy "authenticated read produce"
  on public.produce
  for select
  to authenticated
  using (true);

drop policy if exists "managers manage produce" on public.produce;
create policy "managers manage produce"
  on public.produce
  for insert
  to authenticated
  with check (public.profiles_is_manager_or_supervisor());

drop policy if exists "managers update produce" on public.produce;
create policy "managers update produce"
  on public.produce
  for update
  to authenticated
  using (public.profiles_is_manager_or_supervisor())
  with check (public.profiles_is_manager_or_supervisor());

drop policy if exists "managers delete produce" on public.produce;
create policy "managers delete produce"
  on public.produce
  for delete
  to authenticated
  using (public.profiles_is_manager_or_supervisor());

-- ============================================================
-- Accounting module (accountant / manager / supervisor)
-- ============================================================
create or replace function public.profiles_can_manage_accounting()
returns boolean as $$
begin
  return public.profiles_current_role() in ('accountant', 'manager', 'supervisor');
end;
$$ language plpgsql security definer set row_security = off;

create or replace function public.profiles_can_access_accounting()
returns boolean as $$
begin
  return public.profiles_current_role() in ('accountant', 'manager', 'supervisor', 'sales_agent', 'staff', 'group_leader');
end;
$$ language plpgsql security definer set row_security = off;

-- Sales records are now sourced directly from sales_records instead of the legacy accounting_sales table.
create table if not exists public.accounting_purchases (
  id bigint generated always as identity primary key,
  entry_date date not null,
  supplier_name text not null,
  invoice_receipt_no text,
  item_purchased text not null,
  quantity numeric(10,2) not null default 0,
  unit_cost numeric(12,2) not null default 0,
  total_cost numeric(12,2) not null default 0,
  payment_method text not null default 'Cash',
  amount_paid numeric(12,2) not null default 0,
  balance_owed numeric(12,2) not null default 0,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.accounting_inventory (
  id bigint generated always as identity primary key,
  item_name text not null,
  item_code text,
  category text,
  opening_stock numeric(10,2) not null default 0,
  stock_in numeric(10,2) not null default 0,
  stock_out numeric(10,2) not null default 0,
  closing_stock numeric(10,2) not null default 0,
  unit_cost numeric(12,2) not null default 0,
  unit_selling_price numeric(12,2) not null default 0,
  reorder_level numeric(10,2) not null default 0,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.accounting_cash_book (
  id bigint generated always as identity primary key,
  entry_date timestamptz not null default now(),
  description text not null,
  reference_no text,
  money_in numeric(12,2) not null default 0,
  money_out numeric(12,2) not null default 0,
  balance numeric(12,2) not null default 0,
  recorded_by text,
  notes text,
  entry_type text not null default 'balance_update',
  transfer_from_bank_account_id uuid references public.bank_accounts(id) on delete set null,
  transfer_to_bank_account_id uuid references public.bank_accounts(id) on delete set null,
  transfer_amount numeric(12,2) not null default 0,
  bank_account_id uuid references public.bank_accounts(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.accounting_cash_book
  add column if not exists entry_type text not null default 'balance_update';

alter table public.accounting_cash_book
  add column if not exists transfer_from_bank_account_id uuid references public.bank_accounts(id) on delete set null;

alter table public.accounting_cash_book
  add column if not exists transfer_to_bank_account_id uuid references public.bank_accounts(id) on delete set null;

alter table public.accounting_cash_book
  add column if not exists transfer_amount numeric(12,2) not null default 0;

alter table public.accounting_cash_book
  add column if not exists bank_account_id uuid references public.bank_accounts(id) on delete set null;

create index if not exists idx_accounting_cash_book_bank_account_id on public.accounting_cash_book(bank_account_id, entry_date, id);

-- ============================================================
-- Initialize the accounting cash book from existing bank accounts
-- after the cash-book table and columns are available.
-- ============================================================
select public.seed_accounting_cash_book_from_bank_accounts();

create table if not exists public.accounting_expenses (
  id bigint generated always as identity primary key,
  entry_date date not null,
  expense_category text not null,
  description text not null,
  amount numeric(12,2) not null default 0,
  payment_method text not null default 'Cash',
  receipt_no text,
  sales_record_id bigint references public.sales_records(id) on delete set null,
  submitted_by_user_id uuid references auth.users(id),
  submitted_by_email text,
  status text not null default 'pending',
  approved_by_user_id uuid references public.profiles(id),
  approved_at timestamptz,
  rejected_by_user_id uuid references public.profiles(id),
  rejected_at timestamptz,
  approval_confirmation_url text,
  approval_note text,
  approved_by text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint accounting_expenses_status_check check (status in ('pending','approved','rejected'))
);

alter table public.accounting_expenses
  add column if not exists sales_record_id bigint references public.sales_records(id) on delete set null;

alter table public.accounting_expenses
  add column if not exists submitted_by_user_id uuid references auth.users(id);

alter table public.accounting_expenses
  add column if not exists submitted_by_email text;

alter table public.accounting_expenses
  add column if not exists status text not null default 'pending';

alter table public.accounting_expenses
  add column if not exists approved_by_user_id uuid references public.profiles(id);

alter table public.accounting_expenses
  add column if not exists approved_at timestamptz;

alter table public.accounting_expenses
  add column if not exists rejected_by_user_id uuid references public.profiles(id);

alter table public.accounting_expenses
  add column if not exists rejected_at timestamptz;

alter table public.accounting_expenses
  add column if not exists approval_confirmation_url text;

alter table public.accounting_expenses
  add column if not exists approval_note text;

alter table public.accounting_expenses
  add column if not exists approved_by text;

alter table public.accounting_expenses
  drop constraint if exists accounting_expenses_category_check;

alter table public.accounting_expenses
  add constraint accounting_expenses_category_check
  check (
    lower(trim(expense_category)) in (
      'rent',
      'utilities',
      'fuel',
      'transport',
      'wages',
      'salaries',
      'loading_offloading',
      'packaging',
      'maintenance_repairs',
      'security',
      'internet_communication',
      'office_supplies',
      'licenses_fees',
      'taxes_levies',
      'bank_charges',
      'cleaning_sanitation',
      'marketing_promotion',
      'insurance',
      'miscellaneous',
      'other'
    )
  ) not valid;

alter table public.accounting_expenses
  drop constraint if exists accounting_expenses_status_check;

alter table public.accounting_expenses
  add constraint accounting_expenses_status_check
  check (status in ('pending','approved','rejected'));

create index if not exists idx_accounting_expenses_sales_record on public.accounting_expenses(sales_record_id, status);
create index if not exists idx_accounting_expenses_submitted_by on public.accounting_expenses(submitted_by_user_id, created_at desc);

create or replace function public.review_expense_request(
  p_expense_id bigint,
  p_action text,
  p_accountant_user_id uuid,
  p_approval_note text default null,
  p_approval_confirmation_url text default null
)
returns table (success boolean, error_message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action text := lower(trim(coalesce(p_action, '')));
  v_role text;
  v_expense public.accounting_expenses%rowtype;
  v_sales public.sales_records%rowtype;
  v_available_amount numeric(12,2);
  v_expense_note text;
begin
  if p_expense_id is null then
    return query select false, 'expense_id is required';
    return;
  end if;

  if p_accountant_user_id is null then
    return query select false, 'accountant_user_id is required';
    return;
  end if;

  if v_action not in ('approve', 'reject') then
    return query select false, 'action must be approve or reject';
    return;
  end if;

  select lower(role) into v_role
  from public.profiles
  where id = p_accountant_user_id
  limit 1;

  if coalesce(v_role, 'sales_agent') <> 'accountant' then
    return query select false, 'Only accountants can approve or reject expense requests.';
    return;
  end if;

  select *
    into v_expense
  from public.accounting_expenses
  where id = p_expense_id
  for update;

  if not found then
    return query select false, 'Expense request not found';
    return;
  end if;

  if lower(coalesce(v_expense.status, 'pending')) <> 'pending' then
    return query select false, 'Only pending expense requests can be reviewed.';
    return;
  end if;

  if v_expense.sales_record_id is null then
    return query select false, 'Expense request must be linked to a sales record.';
    return;
  end if;

  if v_action = 'approve' and nullif(trim(coalesce(p_approval_confirmation_url, '')), '') is null then
    return query select false, 'Approval confirmation file is required.';
    return;
  end if;

  if v_action = 'reject' and nullif(trim(coalesce(p_approval_note, '')), '') is null then
    return query select false, 'Rejection reason is required.';
    return;
  end if;

  if v_action = 'approve' then
    select *
      into v_sales
    from public.sales_records
    where id = v_expense.sales_record_id
    for update;

    if not found then
      return query select false, 'Linked sales record was not found.';
      return;
    end if;

    v_available_amount := greatest(
      coalesce(v_sales.expected_amount, 0)
      - (coalesce(v_sales.amount_deposited, 0) + coalesce(v_sales.expenses, 0)),
      0
    );

    if coalesce(v_expense.amount, 0) <= 0 then
      return query select false, 'Expense amount must be greater than zero.';
      return;
    end if;

    if coalesce(v_expense.amount, 0) > v_available_amount then
      return query select false, format(
        'Expense amount exceeds pending balance. Available amount is %s.',
        v_available_amount
      );
      return;
    end if;

    if v_sales.bank_account_id is null then
      return query select false, 'Linked sales record has no bank account selected for expense settlement.';
      return;
    end if;

    v_expense_note := coalesce(nullif(trim(v_expense.description), ''), coalesce(nullif(trim(v_expense.expense_category), ''), 'Expense approval'));

    perform public.post_to_bank_account(
      v_sales.bank_account_id,
      -coalesce(v_expense.amount, 0),
      'expense_approval',
      'Expense approved for sales record #' || v_sales.id,
      v_expense_note,
      p_accountant_user_id::text,
      'Approved expense request #' || p_expense_id
    );

    update public.sales_records
       set expenses = coalesce(expenses, 0) + coalesce(v_expense.amount, 0),
           updated_at = now()
     where id = v_sales.id;

    update public.accounting_expenses
       set status = 'approved',
           approved_by = lower(coalesce(auth.email(), 'unknown')),
           approved_by_user_id = p_accountant_user_id,
           approved_at = now(),
           approval_confirmation_url = p_approval_confirmation_url,
           approval_note = p_approval_note,
           rejected_by_user_id = null,
           rejected_at = null,
           updated_at = now()
     where id = p_expense_id;
  else
    update public.accounting_expenses
       set status = 'rejected',
           approved_by = null,
           approved_by_user_id = null,
           approved_at = null,
           rejected_by_user_id = p_accountant_user_id,
           rejected_at = now(),
           approval_note = p_approval_note,
           approval_confirmation_url = null,
           updated_at = now()
     where id = p_expense_id;
  end if;

  return query select true, null;
end;
$$;

create table if not exists public.accounting_debtors (
  id bigint generated always as identity primary key,
  sales_record_id bigint references public.sales_records(id) on delete set null,
  customer_id uuid references public.customers(id),
  customer_name text not null,
  contact text,
  date_of_sale date not null,
  amount_owed numeric(12,2) not null default 0,
  due_date date,
  amount_paid numeric(12,2) not null default 0,
  balance numeric(12,2) not null default 0,
  status text not null default 'Pending',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.accounting_creditors (
  id bigint generated always as identity primary key,
  sales_record_id bigint references public.sales_records(id) on delete set null,
  customer_id uuid references public.customers(id),
  supplier_name text not null,
  contact text,
  date_of_purchase date not null,
  amount_owed numeric(12,2) not null default 0,
  due_date date,
  amount_paid numeric(12,2) not null default 0,
  balance numeric(12,2) not null default 0,
  status text not null default 'Pending',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.accounting_debtors
  add column if not exists sales_record_id bigint references public.sales_records(id) on delete set null;

alter table public.accounting_debtors
  add column if not exists customer_id uuid references public.customers(id);

alter table public.accounting_creditors
  add column if not exists sales_record_id bigint references public.sales_records(id) on delete set null;

alter table public.accounting_creditors
  add column if not exists customer_id uuid references public.customers(id);

create unique index if not exists idx_accounting_debtors_sales_record_unique
  on public.accounting_debtors (sales_record_id)
  where sales_record_id is not null;

create unique index if not exists idx_accounting_creditors_sales_record_unique
  on public.accounting_creditors (sales_record_id)
  where sales_record_id is not null;

drop table if exists public.accounting_sales cascade;

alter table public.accounting_purchases enable row level security;
alter table public.accounting_inventory enable row level security;
alter table public.accounting_cash_book enable row level security;
alter table public.accounting_expenses enable row level security;
alter table public.accounting_debtors enable row level security;
alter table public.accounting_creditors enable row level security;

-- accounting_sales is deprecated; sales are now represented using sales_records.

drop policy if exists "accounting purchases read" on public.accounting_purchases;
drop policy if exists "accounting purchases write" on public.accounting_purchases;
drop policy if exists "accounting purchases update" on public.accounting_purchases;
drop policy if exists "accounting purchases delete" on public.accounting_purchases;
create policy "accounting purchases read" on public.accounting_purchases for select to authenticated using (public.profiles_can_manage_accounting());
create policy "accounting purchases write" on public.accounting_purchases for insert to authenticated with check (public.profiles_can_manage_accounting());
create policy "accounting purchases update" on public.accounting_purchases for update to authenticated using (public.profiles_can_manage_accounting()) with check (public.profiles_can_manage_accounting());
create policy "accounting purchases delete" on public.accounting_purchases for delete to authenticated using (public.profiles_can_manage_accounting());

drop policy if exists "accounting inventory read" on public.accounting_inventory;
drop policy if exists "accounting inventory write" on public.accounting_inventory;
drop policy if exists "accounting inventory update" on public.accounting_inventory;
drop policy if exists "accounting inventory delete" on public.accounting_inventory;
create policy "accounting inventory read" on public.accounting_inventory for select to authenticated using (public.profiles_can_manage_accounting());
create policy "accounting inventory write" on public.accounting_inventory for insert to authenticated with check (public.profiles_can_manage_accounting());
create policy "accounting inventory update" on public.accounting_inventory for update to authenticated using (public.profiles_can_manage_accounting()) with check (public.profiles_can_manage_accounting());
create policy "accounting inventory delete" on public.accounting_inventory for delete to authenticated using (public.profiles_can_manage_accounting());

drop policy if exists "accounting cash book read" on public.accounting_cash_book;
drop policy if exists "accounting cash book write" on public.accounting_cash_book;
drop policy if exists "accounting cash book update" on public.accounting_cash_book;
drop policy if exists "accounting cash book delete" on public.accounting_cash_book;
create policy "accounting cash book read" on public.accounting_cash_book for select to authenticated using (public.profiles_can_manage_accounting());
create policy "accounting cash book write" on public.accounting_cash_book for insert to authenticated with check (public.profiles_can_manage_accounting());
create policy "accounting cash book update" on public.accounting_cash_book for update to authenticated using (false) with check (false);
create policy "accounting cash book delete" on public.accounting_cash_book for delete to authenticated using (false);

drop policy if exists "accounting expenses read" on public.accounting_expenses;
drop policy if exists "accounting expenses write" on public.accounting_expenses;
drop policy if exists "accounting expenses update" on public.accounting_expenses;
drop policy if exists "accounting expenses delete" on public.accounting_expenses;
create policy "accounting expenses read" on public.accounting_expenses for select to authenticated using (
  public.profiles_can_manage_accounting()
  or (
    public.profiles_current_role() in ('sales_agent', 'staff', 'group_leader')
    and submitted_by_user_id = auth.uid()
  )
);
create policy "accounting expenses write" on public.accounting_expenses for insert to authenticated with check (
  public.profiles_can_access_accounting()
  and lower(coalesce(status, 'pending')) = 'pending'
  and coalesce(approved_by, '') = ''
  and (submitted_by_user_id is null or submitted_by_user_id = auth.uid())
  and (submitted_by_email is null or lower(submitted_by_email) = lower(auth.email()))
);
create policy "accounting expenses update" on public.accounting_expenses for update to authenticated using (public.profiles_can_manage_accounting()) with check (public.profiles_can_manage_accounting());
create policy "accounting expenses delete" on public.accounting_expenses for delete to authenticated using (public.profiles_can_manage_accounting());

drop policy if exists "accounting debtors read" on public.accounting_debtors;
drop policy if exists "accounting debtors write" on public.accounting_debtors;
drop policy if exists "accounting debtors update" on public.accounting_debtors;
drop policy if exists "accounting debtors delete" on public.accounting_debtors;
create policy "accounting debtors read" on public.accounting_debtors for select to authenticated using (public.profiles_can_manage_accounting());
create policy "accounting debtors write" on public.accounting_debtors for insert to authenticated with check (public.profiles_can_access_accounting());
create policy "accounting debtors update" on public.accounting_debtors for update to authenticated using (public.profiles_can_access_accounting()) with check (public.profiles_can_access_accounting());
create policy "accounting debtors delete" on public.accounting_debtors for delete to authenticated using (public.profiles_can_access_accounting());

drop policy if exists "accounting creditors read" on public.accounting_creditors;
drop policy if exists "accounting creditors write" on public.accounting_creditors;
drop policy if exists "accounting creditors update" on public.accounting_creditors;
drop policy if exists "accounting creditors delete" on public.accounting_creditors;
create policy "accounting creditors read" on public.accounting_creditors for select to authenticated using (public.profiles_can_manage_accounting());
create policy "accounting creditors write" on public.accounting_creditors for insert to authenticated with check (public.profiles_can_access_accounting());
create policy "accounting creditors update" on public.accounting_creditors for update to authenticated using (public.profiles_can_access_accounting()) with check (public.profiles_can_access_accounting());
create policy "accounting creditors delete" on public.accounting_creditors for delete to authenticated using (public.profiles_can_access_accounting());

-- User provisioning must be performed through Supabase Auth and the
-- approved role-management workflow. Never place credentials in migrations.

-- ============================================================
-- Edit history (audit) for sales_records
-- ============================================================
create table if not exists edit_history (
  id uuid primary key default gen_random_uuid(),
  record_id bigint default 0,
  sale_id bigint not null default 0,
  draft_session_id uuid,
  field_changed text not null,
  old_value text,
  new_value text,
  edited_by_email text not null,
  edited_successfully boolean not null default true,
  edited_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  edited_by uuid references auth.users(id),
  note text
);

alter table edit_history
  add column if not exists sale_id bigint not null default 0;

alter table edit_history
  add column if not exists draft_session_id uuid;

alter table edit_history
  add column if not exists edited_successfully boolean not null default true;

alter table edit_history
  add column if not exists created_at timestamptz not null default now();

alter table edit_history
  add column if not exists edited_by uuid references auth.users(id);

alter table edit_history
  add column if not exists note text;

alter table edit_history
  drop constraint if exists edit_history_record_id_fkey;

alter table edit_history
  alter column record_id drop not null;

alter table edit_history enable row level security;

drop policy if exists "authenticated insert edit history" on edit_history;
create policy "authenticated insert edit history"
  on edit_history
  for insert
  to authenticated
  with check (edited_by = auth.uid() and lower(edited_by_email) = lower(auth.email()));

drop policy if exists "authenticated read edit history" on edit_history;
create policy "authenticated read edit history"
  on edit_history
  for select
  to authenticated
  using (public.profiles_has_full_access());

drop policy if exists "authenticated update edit history" on edit_history;

drop policy if exists "authenticated delete edit history" on edit_history;

create index if not exists idx_edit_history_record_id on edit_history(record_id);
create index if not exists idx_edit_history_edited_by on edit_history(edited_by_email);
create index if not exists idx_edit_history_draft_session on edit_history(draft_session_id);
create index if not exists idx_edit_history_sale_id on edit_history(sale_id);

-- ============================================================
-- RPC: get_sales_analytics
-- Returns aggregated analytics for active_sales_records using provided filters
-- ============================================================
create or replace function get_sales_analytics(
  p_date_from date default null,
  p_date_to date default null,
  p_customer_name text default null,
  p_produce text default null,
  p_status text default null,
  p_has_rejects boolean default null,
  p_has_missing boolean default null,
  p_has_balance boolean default null,
  p_recorded_by_email text default null
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_grp text := 'day';
  v_totals json;
  v_by_produce json;
  v_by_customer json;
  v_by_period json;
begin
  if p_date_from is not null and p_date_to is not null and (p_date_to - p_date_from) > 90 then
    v_grp := 'month';
  end if;

  select json_build_object(
    'total_dispatch_kg', coalesce(sum(total_dispatch_kg),0),
    'total_supplied_kg', coalesce(sum(kgs_supplied),0),
    'total_rejects_kg', coalesce(sum(rejects_kg),0),
    'total_missing_kg', coalesce(sum(missing_in_kgs),0),
    'total_expected_amount', coalesce(sum(expected_amount),0),
    'total_deposited_amount', coalesce(sum(amount_deposited),0),
    'total_approved_expenses', coalesce(sum(coalesce(expenses, 0)),0),
    'total_balance_to_pay', coalesce(sum(coalesce(expected_amount, 0) - (coalesce(amount_deposited, 0) + coalesce(expenses, 0))),0),
    'total_missing_ksh', coalesce(sum(missing_amount),0),
    'total_excess_less_ksh', coalesce(sum(excess_less),0),
    'collection_rate_pct', case when sum(expected_amount) > 0 then round(100.0 * sum(amount_deposited)/sum(expected_amount),2) else 0 end,
    'reject_rate_pct', case when sum(total_dispatch_kg) > 0 then round(100.0 * sum(rejects_kg)/sum(total_dispatch_kg),2) else 0 end,
    'missing_rate_pct', case when sum(total_dispatch_kg) > 0 then round(100.0 * sum(missing_in_kgs)/sum(total_dispatch_kg),2) else 0 end,
    'record_count', count(*),
    'cleared_count', count(*) filter (where status = 'cleared'),
    'pending_count', count(*) filter (where status = 'pending')
  ) into v_totals
  from active_sales_records ar
  where (p_date_from is null or ar.sale_date >= p_date_from)
    and (p_date_to is null or ar.sale_date <= p_date_to)
    and (p_customer_name is null or ar.customer_name ilike ('%'||p_customer_name||'%'))
    and (p_produce is null or ar.particulars ilike ('%'||p_produce||'%'))
    and (p_status is null or ar.status = lower(p_status))
    and (p_has_rejects is null or (p_has_rejects = true and ar.rejects_kg > 0) or (p_has_rejects = false and ar.rejects_kg = 0))
    and (p_has_missing is null or (p_has_missing = true and ar.missing_in_kgs > 0) or (p_has_missing = false and ar.missing_in_kgs = 0))
    and (p_has_balance is null or (p_has_balance = true and (coalesce(ar.expected_amount, 0) - (coalesce(ar.amount_deposited, 0) + coalesce(ar.expenses, 0))) > 0) or (p_has_balance = false and (coalesce(ar.expected_amount, 0) - (coalesce(ar.amount_deposited, 0) + coalesce(ar.expenses, 0))) = 0))
    and (p_recorded_by_email is null or ar.recorded_by_email = lower(p_recorded_by_email));

  select coalesce(
    (
      select json_agg(row_to_json(t))
      from (
        select
          particulars as produce,
          coalesce(sum(kgs_supplied),0) as total_kg,
          coalesce(sum(expected_amount),0) as total_revenue,
          round(avg(unit_price)::numeric,2) as avg_unit_price,
          case when (coalesce(sum(kgs_supplied),0)+coalesce(sum(rejects_kg),0)) > 0
               then round(100.0 * sum(rejects_kg) / (sum(kgs_supplied) + sum(rejects_kg)), 2)
               else 0 end as reject_rate_pct
        from active_sales_records ar
        where (p_date_from is null or ar.sale_date >= p_date_from)
          and (p_date_to is null or ar.sale_date <= p_date_to)
          and (p_customer_name is null or ar.customer_name ilike ('%'||p_customer_name||'%'))
          and (p_produce is null or ar.particulars ilike ('%'||p_produce||'%'))
          and (p_status is null or ar.status = lower(p_status))
          and (p_has_rejects is null or (p_has_rejects = true and ar.rejects_kg > 0) or (p_has_rejects = false and ar.rejects_kg = 0))
          and (p_has_missing is null or (p_has_missing = true and ar.missing_in_kgs > 0) or (p_has_missing = false and ar.missing_in_kgs = 0))
          and (p_has_balance is null or (p_has_balance = true and (coalesce(ar.expected_amount, 0) - (coalesce(ar.amount_deposited, 0) + coalesce(ar.expenses, 0))) > 0) or (p_has_balance = false and (coalesce(ar.expected_amount, 0) - (coalesce(ar.amount_deposited, 0) + coalesce(ar.expenses, 0))) = 0))
          and (p_recorded_by_email is null or ar.recorded_by_email = lower(p_recorded_by_email))
        group by particulars
        order by sum(expected_amount) desc
      ) t
    ),
    '[]'::json
  ) into v_by_produce;

  select coalesce(
    (
      select json_agg(row_to_json(t))
      from (
        select
          customer_name,
          coalesce(sum(expected_amount),0) as total_business,
          coalesce(sum(coalesce(expected_amount, 0) - (coalesce(amount_deposited, 0) + coalesce(expenses, 0))),0) as total_balance_outstanding,
          case when sum(total_dispatch_kg) > 0
               then round(100.0 * sum(rejects_kg) / sum(total_dispatch_kg), 2)
               else 0 end as reject_rate_pct
        from active_sales_records ar
        where (p_date_from is null or ar.sale_date >= p_date_from)
          and (p_date_to is null or ar.sale_date <= p_date_to)
          and (p_customer_name is null or ar.customer_name ilike ('%'||p_customer_name||'%'))
          and (p_produce is null or ar.particulars ilike ('%'||p_produce||'%'))
          and (p_status is null or ar.status = lower(p_status))
          and (p_has_rejects is null or (p_has_rejects = true and ar.rejects_kg > 0) or (p_has_rejects = false and ar.rejects_kg = 0))
          and (p_has_missing is null or (p_has_missing = true and ar.missing_in_kgs > 0) or (p_has_missing = false and ar.missing_in_kgs = 0))
          and (p_has_balance is null or (p_has_balance = true and (coalesce(ar.expected_amount, 0) - (coalesce(ar.amount_deposited, 0) + coalesce(ar.expenses, 0))) > 0) or (p_has_balance = false and (coalesce(ar.expected_amount, 0) - (coalesce(ar.amount_deposited, 0) + coalesce(ar.expenses, 0))) = 0))
          and (p_recorded_by_email is null or ar.recorded_by_email = lower(p_recorded_by_email))
        group by customer_name
        order by sum(expected_amount) desc
      ) t
    ),
    '[]'::json
  ) into v_by_customer;

  select coalesce(
    (
      select json_agg(row_to_json(t))
      from (
        select
          to_char(date_trunc(case when v_grp = 'month' then 'month' else 'day' end, sale_date), case when v_grp = 'month' then 'YYYY-MM' else 'YYYY-MM-DD' end) as period,
          coalesce(sum(expected_amount),0) as total_revenue,
          coalesce(sum(amount_deposited),0) as total_deposited
        from active_sales_records ar
        where (p_date_from is null or ar.sale_date >= p_date_from)
          and (p_date_to is null or ar.sale_date <= p_date_to)
          and (p_customer_name is null or ar.customer_name ilike ('%'||p_customer_name||'%'))
          and (p_produce is null or ar.particulars ilike ('%'||p_produce||'%'))
          and (p_status is null or ar.status = lower(p_status))
          and (p_has_rejects is null or (p_has_rejects = true and ar.rejects_kg > 0) or (p_has_rejects = false and ar.rejects_kg = 0))
          and (p_has_missing is null or (p_has_missing = true and ar.missing_in_kgs > 0) or (p_has_missing = false and ar.missing_in_kgs = 0))
          and (p_has_balance is null or (p_has_balance = true and (coalesce(ar.expected_amount, 0) - (coalesce(ar.amount_deposited, 0) + coalesce(ar.expenses, 0))) > 0) or (p_has_balance = false and (coalesce(ar.expected_amount, 0) - (coalesce(ar.amount_deposited, 0) + coalesce(ar.expenses, 0))) = 0))
          and (p_recorded_by_email is null or ar.recorded_by_email = lower(p_recorded_by_email))
        group by date_trunc(case when v_grp = 'month' then 'month' else 'day' end, sale_date)
        order by date_trunc(case when v_grp = 'month' then 'month' else 'day' end, sale_date)
      ) t
    ),
    '[]'::json
  ) into v_by_period;

  return json_build_object(
    'totals', v_totals,
    'by_produce', v_by_produce,
    'by_customer', v_by_customer,
    'by_period', v_by_period
  );
end;
$$;


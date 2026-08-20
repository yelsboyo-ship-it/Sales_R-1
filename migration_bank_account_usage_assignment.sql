-- Migration: bank account usage assignment model
-- Keeps public.bank_accounts as the source of truth for the account itself,
-- and records where that account is used via an assignment table.

create table if not exists public.bank_account_usage_assignments (
  id uuid primary key default gen_random_uuid(),
  bank_account_id uuid not null unique references public.bank_accounts(id) on delete cascade,
  usage_type text not null check (usage_type in ('customer_order', 'branch_location', 'not_assigned')),
  location_name text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_bank_account_usage_assignments_usage
  on public.bank_account_usage_assignments (usage_type, location_name);

create unique index if not exists idx_bank_account_usage_assignments_customer_order_global
  on public.bank_account_usage_assignments (bank_account_id)
  where usage_type = 'customer_order';

create unique index if not exists idx_bank_account_usage_assignments_branch_location
  on public.bank_account_usage_assignments (location_name)
  where usage_type = 'branch_location' and location_name is not null;

create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_bank_account_usage_assignments_updated_at on public.bank_account_usage_assignments;
create trigger trg_bank_account_usage_assignments_updated_at
before update on public.bank_account_usage_assignments
for each row
execute function public.set_updated_at();

create or replace function public.set_bank_account_usage_assignment(
  p_bank_account_id uuid,
  p_usage_type text,
  p_location_name text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account public.bank_accounts%rowtype;
  v_existing public.bank_account_usage_assignments%rowtype;
  v_location_exists boolean;
begin
  if not public.profiles_current_role() in ('admin', 'manager', 'supervisor', 'accountant') then
    raise exception 'Only managers, accountants, and supervisors can manage bank account usage assignments.';
  end if;

  if p_bank_account_id is null then
    raise exception 'bank_account_id is required.';
  end if;

  if p_usage_type is null then
    raise exception 'usage_type is required.';
  end if;

  if p_usage_type not in ('customer_order', 'branch_location', 'not_assigned') then
    raise exception 'usage_type must be one of customer_order, branch_location, or not_assigned.';
  end if;

  select *
    into v_account
  from public.bank_accounts
  where id = p_bank_account_id
  limit 1;

  if not found then
    raise exception 'Bank account not found.';
  end if;

  if v_account.is_active is not true then
    raise exception 'Only active bank accounts can receive usage assignments.';
  end if;

  if p_usage_type = 'branch_location' then
    if nullif(trim(coalesce(p_location_name, '')), '') is null then
      raise exception 'A business location is required when assigning Branch / Location.';
    end if;

    select exists (
      select 1
      from public.profiles p
      where lower(trim(p.location)) = lower(trim(p_location_name))
      limit 1
    )
    or exists (
      select 1
      from public.location_stock_allocations l
      where lower(trim(l.location_name)) = lower(trim(p_location_name))
      limit 1
    )
    into v_location_exists;

    if not v_location_exists then
      raise exception 'Selected location does not exist in the current location directory.';
    end if;
  end if;

  if p_usage_type = 'customer_order' then
    update public.bank_accounts
       set is_order_now_active = false
     where is_order_now_active is true;

    update public.bank_accounts
       set is_order_now_active = true
     where id = p_bank_account_id;
  elsif p_usage_type in ('branch_location', 'not_assigned') then
    update public.bank_accounts
       set is_order_now_active = false
     where id = p_bank_account_id;
  end if;

  if p_usage_type = 'not_assigned' then
    delete from public.bank_account_usage_assignments
     where bank_account_id = p_bank_account_id;
  else
    insert into public.bank_account_usage_assignments (
      bank_account_id,
      usage_type,
      location_name,
      created_by
    )
    values (
      p_bank_account_id,
      p_usage_type,
      case when p_usage_type = 'branch_location' then p_location_name else null end,
      auth.uid()
    )
    on conflict (bank_account_id)
    do update set
      usage_type = excluded.usage_type,
      location_name = excluded.location_name,
      updated_at = now(),
      created_by = coalesce(public.bank_account_usage_assignments.created_by, auth.uid())
    where public.bank_account_usage_assignments.bank_account_id = excluded.bank_account_id;
  end if;

  if p_usage_type = 'customer_order' then
    delete from public.bank_account_usage_assignments
     where usage_type = 'customer_order'
       and bank_account_id <> p_bank_account_id;
  end if;

  return json_build_object(
    'success', true,
    'bank_account_id', p_bank_account_id,
    'usage_type', p_usage_type,
    'location_name', case when p_usage_type = 'branch_location' then p_location_name else null end
  );
end;
$$;

grant execute on function public.set_bank_account_usage_assignment(uuid, text, text) to authenticated;

create or replace function public.get_public_order_now_account(p_location_name text default null)
returns table (
  id uuid,
  bank_name text,
  account_name text,
  account_number text,
  branch text,
  currency text
)
language sql
security definer
stable
set search_path = public
as $$
  select
    ba.id,
    ba.bank_name,
    ba.account_name,
    ba.account_number,
    ba.branch,
    ba.currency
  from public.bank_accounts ba
  left join public.bank_account_usage_assignments bua_customer
    on bua_customer.bank_account_id = ba.id
   and bua_customer.usage_type = 'customer_order'
  left join public.bank_account_usage_assignments bua_branch
    on bua_branch.bank_account_id = ba.id
   and bua_branch.usage_type = 'branch_location'
   and p_location_name is not null
   and lower(trim(bua_branch.location_name)) = lower(trim(p_location_name))
  where ba.is_active is true
    and (
      bua_branch.bank_account_id is not null
      or bua_customer.bank_account_id is not null
      or ba.is_order_now_active is true
    )
  order by
    case
      when bua_branch.bank_account_id is not null then 0
      when bua_customer.bank_account_id is not null then 1
      else 2
    end,
    ba.bank_name asc,
    ba.account_name asc
  limit 1;
$$;

grant execute on function public.get_public_order_now_account(text) to anon, authenticated;

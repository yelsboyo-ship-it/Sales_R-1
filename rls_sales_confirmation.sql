-- ============================================================
-- RLS policies for sales records and profiles
-- ============================================================

-- Ensure RLS is enabled on the relevant tables
alter table public.sales_records enable row level security;
alter table public.profiles enable row level security;

-- Helper: role checks
create or replace function public.current_profile_role()
returns text as $$
  select lower(coalesce(role, 'sales_agent'))
  from public.profiles
  where id = auth.uid()
  limit 1;
$$ language sql security definer set search_path = public;

create or replace function public.is_sales_agent_role()
returns boolean as $$
begin
  return coalesce(public.current_profile_role(), 'sales_agent') in ('sales_agent', 'staff');
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.is_accountant_role()
returns boolean as $$
begin
  return coalesce(public.current_profile_role(), 'sales_agent') = 'accountant';
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.is_manager_or_supervisor_role()
returns boolean as $$
begin
  return coalesce(public.current_profile_role(), 'sales_agent') in ('manager','supervisor');
end;
$$ language plpgsql security definer set search_path = public;

-- Sales agent policies
-- 1) Sales agents can insert their own rows.
drop policy if exists sales_agents_insert_own_sales_records on public.sales_records;
create policy sales_agents_insert_own_sales_records
  on public.sales_records
  for insert
  to authenticated
  with check (
    public.is_sales_agent_role() and recorded_by_user_id = auth.uid()
  );

-- 2) Sales agents can read only their own rows.
drop policy if exists sales_agents_select_own_sales_records on public.sales_records;
create policy sales_agents_select_own_sales_records
  on public.sales_records
  for select
  to authenticated
  using (
    public.is_sales_agent_role() and recorded_by_user_id = auth.uid()
  );

-- 3) Sales agents cannot update approval-related fields.
drop policy if exists sales_agents_update_sales_records_restricted on public.sales_records;
create policy sales_agents_update_sales_records_restricted
  on public.sales_records
  for update
  to authenticated
  using (
    public.is_sales_agent_role() and recorded_by_user_id = auth.uid()
  )
  with check (
    public.is_sales_agent_role() and recorded_by_user_id = auth.uid()
  );

create or replace function public.enforce_sales_agent_approval_field_updates()
returns trigger as $$
begin
  if public.is_sales_agent_role() and old.recorded_by_user_id = auth.uid() then
    if (
      new.confirmation_status is distinct from old.confirmation_status
      or new.approved_by is distinct from old.approved_by
      or new.approved_at is distinct from old.approved_at
      or new.bank_account is distinct from old.bank_account
      or new.deposit_confirmation_url is distinct from old.deposit_confirmation_url
      or new.payment_confirmation_text is distinct from old.payment_confirmation_text
    ) then
      raise exception 'Sales agents cannot update approval fields';
    end if;
  end if;

  return new;
end;
$$ language plpgsql security definer set row_security = off;

drop trigger if exists trg_sales_agent_approval_field_updates on public.sales_records;
create trigger trg_sales_agent_approval_field_updates
  before update on public.sales_records
  for each row
  execute function public.enforce_sales_agent_approval_field_updates();

-- Accountant policies
-- 1) Accountants can update approval fields on any row.
drop policy if exists accountants_update_sales_records_approval on public.sales_records;
create policy accountants_update_sales_records_approval
  on public.sales_records
  for update
  to authenticated
  using (public.is_accountant_role())
  with check (public.is_accountant_role());

-- 2) Accountants can read all rows.
drop policy if exists accountants_select_sales_records on public.sales_records;
create policy accountants_select_sales_records
  on public.sales_records
  for select
  to authenticated
  using (public.is_accountant_role());

-- Manager and supervisor policies
-- 1) Managers and supervisors can read all rows and see approval fields.
drop policy if exists managers_supervisors_select_sales_records on public.sales_records;
create policy managers_supervisors_select_sales_records
  on public.sales_records
  for select
  to authenticated
  using (public.is_manager_or_supervisor_role());

-- 2) They are read-only and cannot update approval fields.
drop policy if exists managers_supervisors_update_sales_records_read_only on public.sales_records;
create policy managers_supervisors_update_sales_records_read_only
  on public.sales_records
  for update
  to authenticated
  using (public.is_manager_or_supervisor_role())
  with check (false);

-- Profiles access policy
-- Allow users to read their own profile and role-based access for visible metadata
 drop policy if exists profiles_select_own on public.profiles;
 create policy profiles_select_own
   on public.profiles
   for select
   to authenticated
   using (id = auth.uid() or public.is_manager_or_supervisor_role() or public.is_accountant_role());

 drop policy if exists profiles_update_own on public.profiles;
 create policy profiles_update_own
   on public.profiles
   for update
   to authenticated
   using (id = auth.uid())
   with check (id = auth.uid());

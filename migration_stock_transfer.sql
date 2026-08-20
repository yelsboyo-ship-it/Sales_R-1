-- Migration: Stock Transfer / Assignment Feature
-- Tables for employee-allocated stock and transfer audit log
-- RPC function for atomic transfers (warehouse ↔ employee, employee ↔ employee)
-- RLS policies restricting to manager/supervisor roles

-- 1. Table: employee_stock_allocations
-- Tracks stock allocated to specific employees
create table if not exists public.employee_stock_allocations (
  id bigint generated always as identity primary key,
  employee_id uuid not null references auth.users(id) on delete cascade,
  produce_id bigint not null references public.produce(id) on delete cascade,
  allocated_kg numeric(10,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(employee_id, produce_id)
);

create table if not exists public.location_stock_allocations (
  id bigint generated always as identity primary key,
  location_name text not null,
  produce_id bigint not null references public.produce(id) on delete cascade,
  allocated_kg numeric(10,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(location_name, produce_id)
);

alter table public.employee_stock_allocations enable row level security;
alter table public.location_stock_allocations enable row level security;

drop policy if exists "manager/supervisor read employee stock allocations" on public.employee_stock_allocations;
create policy "manager/supervisor read employee stock allocations"
  on public.employee_stock_allocations
  for select
  to authenticated
  using (
    public.profiles_is_manager_or_supervisor()
    or employee_id = auth.uid()
  );

drop policy if exists "manager/supervisor insert employee stock allocations" on public.employee_stock_allocations;
create policy "manager/supervisor insert employee stock allocations"
  on public.employee_stock_allocations
  for insert
  to authenticated
  with check (public.profiles_is_manager_or_supervisor());

drop policy if exists "manager/supervisor update employee stock allocations" on public.employee_stock_allocations;
create policy "manager/supervisor update employee stock allocations"
  on public.employee_stock_allocations
  for update
  to authenticated
  using (public.profiles_is_manager_or_supervisor())
  with check (public.profiles_is_manager_or_supervisor());

drop policy if exists "manager/supervisor delete employee stock allocations" on public.employee_stock_allocations;
create policy "manager/supervisor delete employee stock allocations"
  on public.employee_stock_allocations
  for delete
  to authenticated
  using (public.profiles_is_manager_or_supervisor());

drop policy if exists "manager/supervisor read location stock allocations" on public.location_stock_allocations;
create policy "manager/supervisor read location stock allocations"
  on public.location_stock_allocations
  for select
  to authenticated
  using (public.profiles_is_manager_or_supervisor());

drop policy if exists "manager/supervisor insert location stock allocations" on public.location_stock_allocations;
create policy "manager/supervisor insert location stock allocations"
  on public.location_stock_allocations
  for insert
  to authenticated
  with check (public.profiles_is_manager_or_supervisor());

drop policy if exists "manager/supervisor update location stock allocations" on public.location_stock_allocations;
create policy "manager/supervisor update location stock allocations"
  on public.location_stock_allocations
  for update
  to authenticated
  using (public.profiles_is_manager_or_supervisor())
  with check (public.profiles_is_manager_or_supervisor());

drop policy if exists "manager/supervisor delete location stock allocations" on public.location_stock_allocations;
create policy "manager/supervisor delete location stock allocations"
  on public.location_stock_allocations
  for delete
  to authenticated
  using (public.profiles_is_manager_or_supervisor());

-- 2. Table: stock_transfer_log
-- Audit log of all stock transfers
create table if not exists public.stock_transfer_log (
  id bigint generated always as identity primary key,
  transfer_type text not null check (transfer_type in ('warehouse_to_employee', 'employee_to_employee', 'employee_to_warehouse', 'sales_agent_allocation', 'warehouse_to_location', 'employee_to_location', 'location_to_location')),
  source_type text,
  source_employee_id uuid,
  source_location text,
  destination_type text,
  destination_employee_id uuid,
  destination_location text,
  produce_id bigint not null references public.produce(id),
  quantity_kg numeric(10,2) not null,
  performed_by uuid not null references auth.users(id),
  performed_by_email text not null,
  triggered_by_record_id bigint references public.sales_records(id),
  transfer_status text not null default 'confirmed' check (transfer_status in ('pending','confirmed','cancelled')),
  destination_response_note text,
  requested_at timestamptz not null default now(),
  confirmed_at timestamptz,
  cancelled_at timestamptz,
  source_notified boolean not null default false,
  remarks text,
  created_at timestamptz not null default now()
);

alter table public.stock_transfer_log
  add column if not exists transfer_status text not null default 'confirmed';

alter table public.stock_transfer_log
  add column if not exists destination_response_note text;

alter table public.stock_transfer_log
  add column if not exists requested_at timestamptz not null default now();

alter table public.stock_transfer_log
  add column if not exists confirmed_at timestamptz;

alter table public.stock_transfer_log
  add column if not exists cancelled_at timestamptz;

alter table public.stock_transfer_log
  add column if not exists source_notified boolean not null default false;

alter table public.stock_transfer_log
  add column if not exists source_location text;

alter table public.stock_transfer_log
  add column if not exists destination_location text;

alter table public.stock_transfer_log
  drop constraint if exists stock_transfer_log_transfer_status_check;

alter table public.stock_transfer_log
  add constraint stock_transfer_log_transfer_status_check
  check (transfer_status in ('pending','confirmed','cancelled'));

alter table public.stock_transfer_log
  drop constraint if exists stock_transfer_log_transfer_type_check;

alter table public.stock_transfer_log
  add constraint stock_transfer_log_transfer_type_check
  check (transfer_type in ('warehouse_to_employee', 'employee_to_employee', 'employee_to_warehouse', 'sales_agent_allocation', 'warehouse_to_location', 'employee_to_location', 'location_to_location'));

alter table public.stock_transfer_log enable row level security;

drop policy if exists "manager/supervisor read stock transfer log" on public.stock_transfer_log;
create policy "manager/supervisor read stock transfer log"
  on public.stock_transfer_log
  for select
  to authenticated
  using (
    public.profiles_is_manager_or_supervisor()
    or destination_employee_id = auth.uid()
    or performed_by = auth.uid()
  );

drop policy if exists "manager/supervisor insert stock transfer log" on public.stock_transfer_log;
create policy "manager/supervisor insert stock transfer log"
  on public.stock_transfer_log
  for insert
  to authenticated
  with check (public.profiles_is_manager_or_supervisor());

drop policy if exists "destination/source update stock transfer log" on public.stock_transfer_log;
create policy "destination/source update stock transfer log"
  on public.stock_transfer_log
  for update
  to authenticated
  using (
    public.profiles_is_manager_or_supervisor()
    or destination_employee_id = auth.uid()
    or performed_by = auth.uid()
  )
  with check (
    public.profiles_is_manager_or_supervisor()
    or destination_employee_id = auth.uid()
    or performed_by = auth.uid()
  );

-- 3. RPC Function: transfer_stock()
-- Atomic transfer handling all three movement types
drop function if exists public.transfer_stock(text, uuid, text, uuid, bigint, numeric, uuid, text, text, text);

create or replace function public.transfer_stock(
  p_source_type text,
  p_source_employee_id uuid,
  p_destination_type text,
  p_destination_employee_id uuid,
  p_produce_id bigint,
  p_quantity_kg numeric,
  p_performed_by uuid,
  p_remarks text,
  p_source_location text default null,
  p_destination_location text default null
)
returns json
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  v_performer_role text;
  v_source_qty numeric;
  v_source_employee_role text;
  v_destination_employee_role text;
  v_source_location text;
  v_destination_location text;
  v_performer_email text;
  v_transfer_type text;
  v_log_id bigint;
begin
  -- The authenticated session is authoritative. Never trust a caller-supplied
  -- performer ID or mutable auth metadata for authorization.
  if auth.uid() is null or p_performed_by is distinct from auth.uid() then
    raise exception 'STOCK_TRANSFER_FORBIDDEN: performer must match auth.uid()';
  end if;

  select lower(role) into v_performer_role
  from public.profiles
  where id = auth.uid();

  if v_performer_role not in ('admin', 'manager', 'supervisor') then
    raise exception 'STOCK_TRANSFER_FORBIDDEN: only managers and supervisors can transfer stock';
  end if;

  v_source_location := nullif(trim(coalesce(p_source_location, '')), '');
  v_destination_location := nullif(trim(coalesce(p_destination_location, '')), '');

  if p_source_type not in ('warehouse', 'employee', 'location') then
    raise exception 'STOCK_TRANSFER_INVALID: source type must be warehouse, employee, or location';
  end if;

  if p_destination_type not in ('warehouse', 'employee', 'location') then
    raise exception 'STOCK_TRANSFER_INVALID: destination type must be warehouse, employee, or location';
  end if;

  if p_source_type = 'employee' and p_source_employee_id is null then
    raise exception 'STOCK_TRANSFER_INVALID: source employee is required';
  end if;

  if p_destination_type = 'employee' and p_destination_employee_id is null then
    raise exception 'STOCK_TRANSFER_INVALID: destination employee is required';
  end if;

  if p_source_type = 'location' and v_source_location is null then
    raise exception 'STOCK_TRANSFER_INVALID: source location is required';
  end if;

  if p_destination_type = 'location' and v_destination_location is null then
    raise exception 'STOCK_TRANSFER_INVALID: destination location is required';
  end if;

  -- Employee endpoints are restricted to sales agents only.
  if p_source_type = 'employee' then
    select lower(role)
      into v_source_employee_role
    from public.profiles
    where id = p_source_employee_id
    limit 1;

    if coalesce(v_source_employee_role, '') <> 'sales_agent' then
      raise exception 'STOCK_TRANSFER_INVALID: source employee must be a sales agent';
    end if;
  end if;

  if p_destination_type = 'employee' then
    select lower(role)
      into v_destination_employee_role
    from public.profiles
    where id = p_destination_employee_id
    limit 1;

    if coalesce(v_destination_employee_role, '') <> 'sales_agent' then
      raise exception 'STOCK_TRANSFER_INVALID: destination employee must be a sales agent';
    end if;
  end if;
  
  -- 2. Validate source ≠ destination (prevent self-transfer)
  if p_source_type = p_destination_type then
    if p_source_type = 'warehouse' then
      raise exception 'STOCK_TRANSFER_INVALID: source and destination cannot both be warehouse';
    end if;
    if p_source_type = 'employee' and p_source_employee_id = p_destination_employee_id then
      raise exception 'STOCK_TRANSFER_INVALID: source and destination employee cannot be the same';
    end if;
    if p_source_type = 'location' and lower(v_source_location) = lower(v_destination_location) then
      raise exception 'STOCK_TRANSFER_INVALID: source and destination location cannot be the same';
    end if;
  end if;
  
  -- 3. Validate quantity > 0
  if p_quantity_kg <= 0 then
    raise exception 'STOCK_TRANSFER_INVALID: quantity must be greater than 0';
  end if;
  
  -- 4. Check produce exists
  if not exists(select 1 from public.produce where id = p_produce_id) then
    raise exception 'STOCK_TRANSFER_INVALID: produce not found';
  end if;
  
  -- 5. Check source has sufficient stock
  if p_source_type = 'warehouse' then
    select amount_kg into v_source_qty from public.produce where id = p_produce_id;
    if coalesce(v_source_qty, 0) < p_quantity_kg then
      raise exception 'STOCK_TRANSFER_INSUFFICIENT: warehouse has only % kg available', coalesce(v_source_qty, 0);
    end if;
  elsif p_source_type = 'employee' then
    select allocated_kg into v_source_qty 
    from public.employee_stock_allocations 
    where employee_id = p_source_employee_id and produce_id = p_produce_id;
    if coalesce(v_source_qty, 0) < p_quantity_kg then
      raise exception 'STOCK_TRANSFER_INSUFFICIENT: employee has only % kg available', coalesce(v_source_qty, 0);
    end if;
  else -- p_source_type = 'location'
    select allocated_kg into v_source_qty
    from public.location_stock_allocations
    where lower(location_name) = lower(v_source_location)
      and produce_id = p_produce_id;
    if coalesce(v_source_qty, 0) < p_quantity_kg then
      raise exception 'STOCK_TRANSFER_INSUFFICIENT: location has only % kg available', coalesce(v_source_qty, 0);
    end if;
  end if;
  
  v_transfer_type := case
    when p_source_type = 'warehouse' and p_destination_type = 'employee' then 'warehouse_to_employee'
    when p_source_type = 'employee' and p_destination_type = 'warehouse' then 'employee_to_warehouse'
    when p_source_type = 'employee' and p_destination_type = 'employee' then 'employee_to_employee'
    when p_source_type = 'warehouse' and p_destination_type = 'location' then 'warehouse_to_location'
    when p_source_type = 'employee' and p_destination_type = 'location' then 'employee_to_location'
    when p_source_type = 'location' and p_destination_type = 'location' then 'location_to_location'
    else null
  end;

  if v_transfer_type is null then
    raise exception 'STOCK_TRANSFER_INVALID: unsupported source/destination combination';
  end if;

  select email into v_performer_email from auth.users where id = p_performed_by;

  if p_destination_type = 'employee' then
    insert into public.stock_transfer_log (
      transfer_type,
      source_type,
      source_employee_id,
      source_location,
      destination_type,
      destination_employee_id,
      destination_location,
      produce_id,
      quantity_kg,
      performed_by,
      performed_by_email,
      transfer_status,
      requested_at,
      source_notified,
      remarks
    ) values (
      v_transfer_type,
      p_source_type,
      p_source_employee_id,
      v_source_location,
      p_destination_type,
      p_destination_employee_id,
      v_destination_location,
      p_produce_id,
      p_quantity_kg,
      p_performed_by,
      coalesce(v_performer_email, 'unknown'),
      'pending',
      now(),
      false,
      p_remarks
    ) returning id into v_log_id;

    return json_build_object(
      'success', true,
      'status', 'pending',
      'transfer_id', v_log_id,
      'message', 'Transfer request sent. Waiting for destination confirmation.'
    );
  end if;

  -- Destination is warehouse: apply immediately.
  if p_source_type = 'warehouse' then
    update public.produce
       set amount_kg = amount_kg - p_quantity_kg,
           updated_at = now()
     where id = p_produce_id;
  elsif p_source_type = 'employee' then
    update public.employee_stock_allocations 
       set allocated_kg = allocated_kg - p_quantity_kg,
           updated_at = now()
     where employee_id = p_source_employee_id
       and produce_id = p_produce_id;
  else
    update public.location_stock_allocations
       set allocated_kg = allocated_kg - p_quantity_kg,
           updated_at = now()
     where lower(location_name) = lower(v_source_location)
       and produce_id = p_produce_id;
  end if;

  if p_destination_type = 'warehouse' then
    update public.produce
       set amount_kg = amount_kg + p_quantity_kg,
           updated_at = now()
     where id = p_produce_id;
  elsif p_destination_type = 'location' then
    insert into public.location_stock_allocations(location_name, produce_id, allocated_kg)
    values (v_destination_location, p_produce_id, p_quantity_kg)
    on conflict(location_name, produce_id) do update
      set allocated_kg = public.location_stock_allocations.allocated_kg + excluded.allocated_kg,
          updated_at = now();
  end if;

  insert into public.stock_transfer_log (
    transfer_type,
    source_type,
    source_employee_id,
    source_location,
    destination_type,
    destination_employee_id,
    destination_location,
    produce_id,
    quantity_kg,
    performed_by,
    performed_by_email,
    transfer_status,
    requested_at,
    confirmed_at,
    source_notified,
    remarks
  ) values (
    v_transfer_type,
    p_source_type,
    p_source_employee_id,
    v_source_location,
    p_destination_type,
    p_destination_employee_id,
    v_destination_location,
    p_produce_id,
    p_quantity_kg,
    p_performed_by,
    coalesce(v_performer_email, 'unknown'),
    'confirmed',
    now(),
    now(),
    true,
    p_remarks
  );

  return json_build_object('success', true, 'status', 'confirmed', 'message', 'Stock transferred successfully');
end;
$$;

drop function if exists public.confirm_pending_stock_transfer(bigint, uuid, text);

create or replace function public.confirm_pending_stock_transfer(
  p_transfer_id bigint,
  p_destination_user_id uuid,
  p_confirmation_note text default null
)
returns json
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  v_transfer public.stock_transfer_log%rowtype;
  v_source_qty numeric;
begin
  if p_transfer_id is null then
    raise exception 'transfer_id is required';
  end if;

  if p_destination_user_id is null then
    raise exception 'destination_user_id is required';
  end if;

  if auth.uid() is distinct from p_destination_user_id then
    raise exception 'Only the destination user can confirm this transfer';
  end if;

  select *
    into v_transfer
  from public.stock_transfer_log
  where id = p_transfer_id
  for update;

  if not found then
    raise exception 'Transfer request not found';
  end if;

  if v_transfer.transfer_status <> 'pending' then
    raise exception 'Transfer request is no longer pending';
  end if;

  if v_transfer.destination_type <> 'employee'
     or v_transfer.destination_employee_id is distinct from p_destination_user_id then
    raise exception 'You are not the destination for this transfer request';
  end if;

  if v_transfer.source_type = 'warehouse' then
    select amount_kg
      into v_source_qty
    from public.produce
    where id = v_transfer.produce_id
    for update;

    if coalesce(v_source_qty, 0) < coalesce(v_transfer.quantity_kg, 0) then
      raise exception 'Source warehouse no longer has enough stock to confirm this transfer';
    end if;

    update public.produce
       set amount_kg = amount_kg - v_transfer.quantity_kg,
           updated_at = now()
     where id = v_transfer.produce_id;
  else
    select allocated_kg
      into v_source_qty
    from public.employee_stock_allocations
    where employee_id = v_transfer.source_employee_id
      and produce_id = v_transfer.produce_id
    for update;

    if coalesce(v_source_qty, 0) < coalesce(v_transfer.quantity_kg, 0) then
      raise exception 'Source employee no longer has enough allocated stock to confirm this transfer';
    end if;

    update public.employee_stock_allocations
       set allocated_kg = allocated_kg - v_transfer.quantity_kg,
           updated_at = now()
     where employee_id = v_transfer.source_employee_id
       and produce_id = v_transfer.produce_id;
  end if;

  insert into public.employee_stock_allocations(employee_id, produce_id, allocated_kg)
  values (v_transfer.destination_employee_id, v_transfer.produce_id, v_transfer.quantity_kg)
  on conflict(employee_id, produce_id) do update
    set allocated_kg = employee_stock_allocations.allocated_kg + excluded.allocated_kg,
        updated_at = now();

  update public.stock_transfer_log
     set transfer_status = 'confirmed',
         confirmed_at = now(),
         destination_response_note = nullif(trim(coalesce(p_confirmation_note, '')), ''),
         source_notified = true
   where id = p_transfer_id;

  return json_build_object('success', true, 'status', 'confirmed', 'message', 'Transfer confirmed and allocation updated.');
end;
$$;

drop function if exists public.cancel_pending_stock_transfer(bigint, uuid, text);

create or replace function public.cancel_pending_stock_transfer(
  p_transfer_id bigint,
  p_destination_user_id uuid,
  p_cancellation_reason text default null
)
returns json
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  v_transfer public.stock_transfer_log%rowtype;
begin
  if p_transfer_id is null then
    raise exception 'transfer_id is required';
  end if;

  if p_destination_user_id is null then
    raise exception 'destination_user_id is required';
  end if;

  if auth.uid() is distinct from p_destination_user_id then
    raise exception 'Only the destination user can cancel this transfer';
  end if;

  select *
    into v_transfer
  from public.stock_transfer_log
  where id = p_transfer_id
  for update;

  if not found then
    raise exception 'Transfer request not found';
  end if;

  if v_transfer.transfer_status <> 'pending' then
    raise exception 'Transfer request is no longer pending';
  end if;

  if v_transfer.destination_type <> 'employee'
     or v_transfer.destination_employee_id is distinct from p_destination_user_id then
    raise exception 'You are not the destination for this transfer request';
  end if;

  update public.stock_transfer_log
     set transfer_status = 'cancelled',
         cancelled_at = now(),
         destination_response_note = nullif(trim(coalesce(p_cancellation_reason, '')), ''),
         source_notified = false
   where id = p_transfer_id;

  return json_build_object('success', true, 'status', 'cancelled', 'message', 'Transfer request cancelled. Source has been notified.');
end;
$$;

drop function if exists public.acknowledge_cancelled_stock_transfer(bigint, uuid);

create or replace function public.acknowledge_cancelled_stock_transfer(
  p_transfer_id bigint,
  p_source_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
begin
  if p_transfer_id is null then
    raise exception 'transfer_id is required';
  end if;

  if p_source_user_id is null then
    raise exception 'source_user_id is required';
  end if;

  if auth.uid() is distinct from p_source_user_id then
    raise exception 'Only the source user can acknowledge this cancellation';
  end if;

  update public.stock_transfer_log
     set source_notified = true
   where id = p_transfer_id
     and performed_by = p_source_user_id
     and transfer_status = 'cancelled';

  if not found then
    raise exception 'Cancelled transfer notice not found for this user';
  end if;

  return json_build_object('success', true, 'message', 'Cancellation acknowledged.');
end;
$$;

drop function if exists public.get_location_stock_overview();

create or replace function public.get_location_stock_overview()
returns table (
  location_name text,
  produce_id bigint,
  produce_name text,
  sales_agent_missing_kg numeric(10,2),
  location_allocated_kg numeric(10,2),
  current_location_stock_kg numeric(10,2)
)
language sql
security definer
set search_path = public
set row_security = off
as $$
  with missing as (
    select
      lower(trim(coalesce(pr.location, 'Unknown'))) as location_name,
      p.id as produce_id,
      p.particulars as produce_name,
      coalesce(sum(sr.missing_in_kgs), 0)::numeric(10,2) as sales_agent_missing_kg
    from public.sales_records sr
    join public.profiles pr
      on pr.id = sr.recorded_by_user_id
    join public.produce p
      on lower(trim(coalesce(p.particulars, ''))) = lower(trim(coalesce(sr.particulars, '')))
    where coalesce(sr.is_deleted, false) = false
      and lower(coalesce(pr.role, '')) = 'sales_agent'
    group by lower(trim(coalesce(pr.location, 'Unknown'))), p.id, p.particulars
  ),
  loc as (
    select
      lower(trim(coalesce(location_name, 'Unknown'))) as location_name,
      produce_id,
      coalesce(sum(allocated_kg), 0)::numeric(10,2) as location_allocated_kg
    from public.location_stock_allocations
    group by lower(trim(coalesce(location_name, 'Unknown'))), produce_id
  ),
  combined as (
    select
      coalesce(m.location_name, l.location_name) as location_name,
      coalesce(m.produce_id, l.produce_id) as produce_id,
      coalesce(m.produce_name, p.particulars, 'Unknown') as produce_name,
      coalesce(m.sales_agent_missing_kg, 0)::numeric(10,2) as sales_agent_missing_kg,
      coalesce(l.location_allocated_kg, 0)::numeric(10,2) as location_allocated_kg
    from missing m
    full outer join loc l
      on m.location_name = l.location_name
     and m.produce_id = l.produce_id
    left join public.produce p
      on p.id = coalesce(m.produce_id, l.produce_id)
  )
  select
    location_name,
    produce_id,
    produce_name,
    sales_agent_missing_kg,
    location_allocated_kg,
    (sales_agent_missing_kg + location_allocated_kg)::numeric(10,2) as current_location_stock_kg
  from combined
  order by location_name, produce_name;
$$;

-- Reload PostgREST schema cache
notify pgrst, 'reload schema';

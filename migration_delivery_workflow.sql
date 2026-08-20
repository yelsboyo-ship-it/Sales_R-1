-- Delivery workflow extension for pay-on-delivery sales
-- Run after sales_approval_workflow.sql and sales_records_with_users.sql

create table if not exists public.transport_drivers (
  id bigint generated always as identity primary key,
  driver_id text unique,
  driver_name text not null,
  phone_number text,
  vehicle_registration text,
  vehicle_type text,
  vehicle_capacity_kg numeric(10,2) not null default 0,
  driver_status text not null default 'Available',
  current_gps_location text,
  license_information text,
  emergency_contact text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.delivery_assignments (
  id bigint generated always as identity primary key,
  submission_id bigint references public.sales_record_submissions(id) on delete set null,
  sales_record_id bigint references public.sales_records(id) on delete set null,
  delivery_number text unique,
  customer_name text not null,
  customer_phone text,
  destination text,
  address text,
  products text,
  quantity_kg numeric(10,2) not null default 0,
  amount_to_collect numeric(12,2) not null default 0,
  payment_method text not null default 'Payment on Delivery',
  delivery_instructions text,
  assigned_driver text,
  scheduled_at timestamptz not null default now(),
  delivery_status text not null default 'pending',
  delivery_notes text,
  delivery_started_at timestamptz,
  delivery_completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint delivery_assignments_status_check check (delivery_status in ('pending','assigned','in_transit','delivered','cancelled','not_applicable'))
);

alter table public.sales_records
  add column if not exists payment_option text not null default 'payment_on_delivery';

alter table public.sales_records
  add column if not exists delivery_status text not null default 'pending';

alter table public.sales_records
  add column if not exists delivery_assigned_to text;

alter table public.sales_records
  add column if not exists delivery_transport_details text;

alter table public.sales_records
  add column if not exists delivery_note text;

alter table public.sales_record_submissions
  add column if not exists payment_option text not null default 'payment_on_delivery';

alter table public.sales_record_submissions
  add column if not exists delivery_status text not null default 'pending';

alter table public.sales_record_submissions
  add column if not exists delivery_assigned_to text;

alter table public.sales_record_submissions
  add column if not exists delivery_transport_details text;

alter table public.sales_record_submissions
  add column if not exists delivery_note text;

alter table public.sales_records
  drop constraint if exists sales_records_payment_option_check;

alter table public.sales_records
  add constraint sales_records_payment_option_check
  check (payment_option in ('payment_on_delivery','pay_now'));

alter table public.sales_records
  drop constraint if exists sales_records_delivery_status_check;

alter table public.sales_records
  add constraint sales_records_delivery_status_check
  check (delivery_status in ('pending','assigned','in_transit','delivered','cancelled','not_applicable'));

alter table public.sales_record_submissions
  drop constraint if exists sales_record_submissions_payment_option_check;

alter table public.sales_record_submissions
  add constraint sales_record_submissions_payment_option_check
  check (payment_option in ('payment_on_delivery','pay_now'));

alter table public.sales_record_submissions
  drop constraint if exists sales_record_submissions_delivery_status_check;

alter table public.sales_record_submissions
  add constraint sales_record_submissions_delivery_status_check
  check (delivery_status in ('pending','assigned','in_transit','delivered','cancelled','not_applicable'));

alter table public.transport_drivers enable row level security;
alter table public.delivery_assignments enable row level security;

create or replace function public.create_delivery_assignment_for_submission(
  p_submission_id bigint,
  p_sales_record_id bigint default null,
  p_delivery_number text default null,
  p_customer_name text default null,
  p_customer_phone text default null,
  p_destination text default null,
  p_address text default null,
  p_products text default null,
  p_quantity_kg numeric default null,
  p_amount_to_collect numeric default null,
  p_payment_method text default null,
  p_delivery_instructions text default null,
  p_assigned_driver text default null,
  p_delivery_status text default 'pending'
)
returns public.delivery_assignments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_submission public.sales_record_submissions%rowtype;
  v_assignment public.delivery_assignments%rowtype;
  v_status text := lower(trim(coalesce(p_delivery_status, 'pending')));
begin
  select * into v_submission
  from public.sales_record_submissions
  where id = p_submission_id
  limit 1;

  if not found then
    raise exception 'Submission not found';
  end if;

  if v_status not in ('pending','assigned','in_transit','delivered','cancelled','not_applicable') then
    raise exception 'delivery_status is invalid';
  end if;

  insert into public.delivery_assignments (
    submission_id,
    sales_record_id,
    delivery_number,
    customer_name,
    customer_phone,
    destination,
    address,
    products,
    quantity_kg,
    amount_to_collect,
    payment_method,
    delivery_instructions,
    assigned_driver,
    scheduled_at,
    delivery_status,
    created_at,
    updated_at
  ) values (
    p_submission_id,
    p_sales_record_id,
    coalesce(nullif(trim(p_delivery_number), ''), 'DEL-' || p_submission_id),
    coalesce(nullif(trim(p_customer_name), ''), v_submission.customer_name),
    nullif(trim(coalesce(p_customer_phone, v_submission.phone_number, '')), ''),
    nullif(trim(coalesce(p_destination, v_submission.location, '')), ''),
    nullif(trim(coalesce(p_address, p_destination, v_submission.location, '')), ''),
    coalesce(nullif(trim(p_products), ''), v_submission.particulars),
    coalesce(p_quantity_kg, coalesce(v_submission.kgs_supplied, v_submission.total_dispatch_kg, 0)),
    coalesce(p_amount_to_collect, coalesce(v_submission.unit_price, 0) * coalesce(v_submission.kgs_supplied, v_submission.total_dispatch_kg, 0)),
    coalesce(nullif(trim(p_payment_method), ''), case when lower(coalesce(v_submission.payment_option, 'payment_on_delivery')) = 'pay_now' then 'Pay Now' else 'Payment on Delivery' end),
    nullif(trim(coalesce(p_delivery_instructions, v_submission.notes, '')), ''),
    nullif(trim(coalesce(p_assigned_driver, '')), ''),
    now(),
    v_status,
    now(),
    now()
  ) returning * into v_assignment;

  return v_assignment;
end;
$$;

create or replace function public.update_sales_record_delivery_status(
  p_record_id bigint,
  p_delivery_status text,
  p_delivery_note text default null,
  p_delivery_assigned_to text default null,
  p_delivery_transport_details text default null,
  p_updated_by_user_id uuid default null
)
returns public.sales_records
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text := lower(trim(coalesce(p_delivery_status, 'pending')));
  v_record public.sales_records%rowtype;
begin
  if p_record_id is null then
    raise exception 'record_id is required';
  end if;

  if v_status not in ('pending','assigned','in_transit','delivered','cancelled','not_applicable') then
    raise exception 'delivery_status is invalid';
  end if;

  select * into v_record
  from public.sales_records
  where id = p_record_id
  limit 1;

  if not found then
    raise exception 'Sales record not found';
  end if;

  update public.sales_records
     set delivery_status = v_status,
         delivery_assigned_to = nullif(trim(coalesce(p_delivery_assigned_to, delivery_assigned_to, '')), ''),
         delivery_transport_details = nullif(trim(coalesce(p_delivery_transport_details, delivery_transport_details, '')), ''),
         delivery_note = nullif(trim(coalesce(p_delivery_note, delivery_note, '')), ''),
         updated_at = now()
   where id = p_record_id;

  return v_record;
end;
$$;

create or replace function public.review_sales_record_submission(
  p_submission_id bigint,
  p_action text,
  p_reviewer_user_id uuid,
  p_review_note text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action text := lower(trim(coalesce(p_action, '')));
  v_role text;
  v_submission public.sales_record_submissions%rowtype;
  v_final_sales_record public.sales_records%rowtype;
  v_delivery_assignment public.delivery_assignments%rowtype;
begin
  if p_submission_id is null then
    raise exception 'submission_id is required';
  end if;

  if p_reviewer_user_id is null then
    raise exception 'reviewer_user_id is required';
  end if;

  if v_action not in ('approve', 'reject') then
    raise exception 'action must be approve or reject';
  end if;

  select lower(role)
    into v_role
  from public.profiles
  where id = p_reviewer_user_id
  limit 1;

  if coalesce(v_role, 'sales_agent') not in ('manager', 'supervisor') then
    raise exception 'Only managers or supervisors can review sales submissions.';
  end if;

  select *
    into v_submission
  from public.sales_record_submissions
  where id = p_submission_id
  for update;

  if not found then
    raise exception 'Sales submission not found.';
  end if;

  if lower(coalesce(v_submission.status, 'pending')) <> 'pending' then
    raise exception 'Only pending submissions can be reviewed.';
  end if;

  if v_action = 'approve' then
    select *
      into v_final_sales_record
    from public.create_sales_record_with_inventory(
      coalesce(v_submission.sale_date, current_date),
      v_submission.customer_name,
      v_submission.particulars,
      coalesce(v_submission.total_dispatch_kg, v_submission.kgs_supplied, 0),
      coalesce(v_submission.kgs_supplied, 0),
      coalesce(v_submission.rejects_kg, 0),
      coalesce(v_submission.unit_price, 0),
      coalesce(v_submission.amount_deposited, 0),
      v_submission.bank_account_id,
      v_submission.bank_account,
      null,
      coalesce(v_submission.notes, '')
    )
    limit 1;

    update public.sales_records
       set payment_option = lower(coalesce(v_submission.payment_option, 'payment_on_delivery')),
           delivery_status = case when lower(coalesce(v_submission.payment_option, 'payment_on_delivery')) = 'pay_now' then 'not_applicable' else 'pending' end,
           delivery_assigned_to = null,
           delivery_note = null,
           updated_at = now()
     where id = v_final_sales_record.id;

    update public.sales_record_submissions
       set status = 'approved',
           reviewed_by = p_reviewer_user_id,
           reviewed_at = now(),
           review_note = p_review_note,
           approved_sales_record_id = v_final_sales_record.id,
           payment_option = lower(coalesce(v_submission.payment_option, 'payment_on_delivery')),
           delivery_status = case when lower(coalesce(v_submission.payment_option, 'payment_on_delivery')) = 'pay_now' then 'not_applicable' else 'pending' end,
           updated_at = now()
     where id = p_submission_id;

    if lower(coalesce(v_submission.payment_option, 'payment_on_delivery')) = 'payment_on_delivery' then
      select * into v_delivery_assignment
      from public.create_delivery_assignment_for_submission(
        p_submission_id => p_submission_id,
        p_sales_record_id => v_final_sales_record.id,
        p_delivery_number => 'DEL-' || p_submission_id,
        p_customer_name => v_submission.customer_name,
        p_customer_phone => v_submission.phone_number,
        p_destination => v_submission.location,
        p_address => v_submission.location,
        p_products => v_submission.particulars,
        p_quantity_kg => coalesce(v_submission.kgs_supplied, v_submission.total_dispatch_kg, 0),
        p_amount_to_collect => coalesce(v_submission.unit_price, 0) * coalesce(v_submission.kgs_supplied, v_submission.total_dispatch_kg, 0),
        p_payment_method => case when lower(coalesce(v_submission.payment_option, 'payment_on_delivery')) = 'pay_now' then 'Pay Now' else 'Payment on Delivery' end,
        p_delivery_instructions => coalesce(v_submission.notes, 'Please confirm delivery details on arrival.'),
        p_delivery_status => 'pending'
      );

      perform public.queue_notification(
        'driver',
        'New delivery assignment #' || v_delivery_assignment.id || ' is ready for pickup.',
        'delivery_assignments',
        v_delivery_assignment.id,
        jsonb_build_object('delivery_id', v_delivery_assignment.id, 'customer_name', v_submission.customer_name)
      );
      perform public.queue_notification(
        'manager',
        'Delivery assignment #' || v_delivery_assignment.id || ' created for ' || v_submission.customer_name || '.',
        'delivery_assignments',
        v_delivery_assignment.id,
        jsonb_build_object('delivery_id', v_delivery_assignment.id, 'customer_name', v_submission.customer_name)
      );
      perform public.queue_notification(
        'supervisor',
        'Delivery assignment #' || v_delivery_assignment.id || ' created for ' || v_submission.customer_name || '.',
        'delivery_assignments',
        v_delivery_assignment.id,
        jsonb_build_object('delivery_id', v_delivery_assignment.id, 'customer_name', v_submission.customer_name)
      );
      perform public.queue_notification(
        'accountant',
        'Delivery completed for submission #' || p_submission_id || '. Payment confirmation is still required.',
        'delivery_assignments',
        v_delivery_assignment.id,
        jsonb_build_object('delivery_id', v_delivery_assignment.id, 'submission_id', p_submission_id)
      );
    end if;

    perform public.queue_notification(
      'accountant',
      'Sales record #' || v_final_sales_record.id || ' is ready for payment approval.',
      'sales_records',
      v_final_sales_record.id,
      jsonb_build_object('submission_id', v_submission.id, 'customer_name', v_submission.customer_name, 'particulars', v_submission.particulars)
    );

    return json_build_object(
      'success', true,
      'submission_id', p_submission_id,
      'sales_record_id', v_final_sales_record.id,
      'status', 'approved'
    );
  end if;

  update public.sales_record_submissions
     set status = 'rejected',
         reviewed_by = p_reviewer_user_id,
         reviewed_at = now(),
         review_note = p_review_note,
         updated_at = now()
   where id = p_submission_id;

  return json_build_object(
    'success', true,
    'submission_id', p_submission_id,
    'status', 'rejected'
  );
end;
$$;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'transport_drivers'
      and policyname = 'transport drivers read'
  ) then
    create policy "transport drivers read"
      on public.transport_drivers
      for select
      to authenticated
      using (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'transport_drivers'
      and policyname = 'transport drivers write'
  ) then
    create policy "transport drivers write"
      on public.transport_drivers
      for all
      to authenticated
      using (public.profiles_current_role() in ('manager', 'supervisor'))
      with check (public.profiles_current_role() in ('manager', 'supervisor'));
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'delivery_assignments'
      and policyname = 'delivery assignments read'
  ) then
    create policy "delivery assignments read"
      on public.delivery_assignments
      for select
      to authenticated
      using (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'delivery_assignments'
      and policyname = 'delivery assignments write'
  ) then
    create policy "delivery assignments write"
      on public.delivery_assignments
      for all
      to authenticated
      using (public.profiles_current_role() in ('manager', 'supervisor', 'driver'))
      with check (public.profiles_current_role() in ('manager', 'supervisor', 'driver'));
  end if;
end $$;

drop trigger if exists trg_transport_drivers_updated_at on public.transport_drivers;
create trigger trg_transport_drivers_updated_at
  before update on public.transport_drivers
  for each row execute function public.set_updated_at();

drop trigger if exists trg_delivery_assignments_updated_at on public.delivery_assignments;
create trigger trg_delivery_assignments_updated_at
  before update on public.delivery_assignments
  for each row execute function public.set_updated_at();

grant execute on function public.create_delivery_assignment_for_submission(bigint, bigint, text, text, text, text, text, text, numeric, numeric, text, text, text, text) to authenticated;
grant execute on function public.update_sales_record_delivery_status(bigint, text, text, text, text, uuid) to authenticated;
grant execute on function public.review_sales_record_submission(bigint, text, uuid, text) to authenticated;

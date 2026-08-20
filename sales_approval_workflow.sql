-- ============================================================
-- Two-stage sales approval workflow
-- Run after supabase_schema.sql
-- ============================================================

create table if not exists public.sales_record_submissions (
  id bigint generated always as identity primary key,
  sale_date date not null default current_date,
  customer_id uuid references public.customers(id) on delete set null,
  customer_name text not null,
  email text,
  phone_number text not null,
  location text,
  produce_id bigint references public.produce(id) on delete set null,
  particulars text not null,
  total_dispatch_kg numeric(10,2) not null default 0,
  kgs_supplied numeric(10,2) not null default 0,
  rejects_kg numeric(10,2) not null default 0,
  unit_price numeric(10,2) not null default 0,
  payment_option text not null default 'payment_on_delivery',
  amount_deposited numeric(12,2) not null default 0,
  bank_account_id uuid references public.bank_accounts(id) on delete set null,
  bank_account text,
  notes text,
  status text not null default 'pending',
  submitted_by_email text,
  submitted_by_user_id uuid references auth.users(id),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  review_note text,
  approved_sales_record_id bigint references public.sales_records(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sales_record_submissions_status_check check (status in ('pending','approved','rejected')),
  constraint sales_record_submissions_payment_option_check check (payment_option in ('payment_on_delivery','pay_now'))
);

create table if not exists public.notifications (
  id bigint generated always as identity primary key,
  role text not null,
  message text not null,
  reference_type text,
  reference_id bigint,
  status text not null default 'unread',
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  constraint notifications_status_check check (status in ('unread','read'))
);

alter table public.sales_record_submissions enable row level security;
alter table public.notifications enable row level security;

drop trigger if exists trg_sales_record_submissions_updated_at on public.sales_record_submissions;
create trigger trg_sales_record_submissions_updated_at
  before update on public.sales_record_submissions
  for each row execute function public.set_updated_at();

create or replace function public.queue_notification(
  p_role text,
  p_message text,
  p_reference_type text default null,
  p_reference_id bigint default null,
  p_payload jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_notification_id bigint;
  v_role text := lower(trim(coalesce(p_role, '')));
  v_message text := coalesce(nullif(trim(p_message), ''), 'Notification');
  v_reference_type text := nullif(trim(coalesce(p_reference_type, '')), '');
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
begin
  if v_role = '' then
    raise exception 'role is required';
  end if;
    if auth.uid() is not null then
      if public.profiles_current_role() not in ('admin', 'manager', 'supervisor', 'accountant', 'driver') then
        raise exception 'Only operational roles can create notifications';
      end if;
      if v_role not in ('admin', 'manager', 'supervisor', 'accountant', 'driver') then
        raise exception 'Notification target role is invalid';
      end if;
      if public.profiles_current_role() = 'driver' and v_role <> 'accountant' then
        raise exception 'Drivers may only create accounting delivery notifications';
      end if;
    end if;

  select id
    into v_notification_id
  from public.notifications
  where lower(role) = v_role
    and lower(message) = lower(v_message)
    and coalesce(reference_type, '') is not distinct from coalesce(v_reference_type, '')
    and coalesce(reference_id, -1) is not distinct from coalesce(p_reference_id, -1)
    and status = 'unread'
  order by created_at desc, id desc
  limit 1;

  if v_notification_id is not null then
    return v_notification_id;
  end if;

  insert into public.notifications(
    role,
    message,
    reference_type,
    reference_id,
    status,
    payload
  ) values (
    v_role,
    v_message,
    v_reference_type,
    p_reference_id,
    'unread',
    v_payload
  ) returning id into v_notification_id;

  return v_notification_id;
end;
$$;

create or replace function public.submit_sales_record_submission(
  p_sale_date date,
  p_customer_name text,
  p_email text,
  p_phone_number text,
  p_location text,
  p_produce_id bigint,
  p_particulars text,
  p_total_dispatch_kg numeric,
  p_kgs_supplied numeric,
  p_rejects_kg numeric,
  p_unit_price numeric,
  p_payment_option text,
  p_bank_account_id uuid default null,
  p_bank_account text default null,
  p_notes text default null,
  p_submitted_by_email text default null,
  p_submitted_by_user_id uuid default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer public.customers%rowtype;
  v_produce public.produce%rowtype;
  v_submission public.sales_record_submissions%rowtype;
  v_clean_payment_option text := lower(trim(coalesce(p_payment_option, 'payment_on_delivery')));
  v_clean_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
  v_clean_phone text := nullif(trim(coalesce(p_phone_number, '')), '');
  v_clean_location text := nullif(trim(coalesce(p_location, '')), '');
  v_clean_name text := nullif(initcap(trim(coalesce(p_customer_name, ''))), '');
  v_clean_particulars text := nullif(initcap(trim(coalesce(p_particulars, ''))), '');
  v_expected_amount numeric(12,2);
  v_amount_deposited numeric(12,2);
  v_customer_notes text;
begin
  if auth.uid() is not null then
    if p_submitted_by_user_id is not null and p_submitted_by_user_id is distinct from auth.uid() then
      raise exception 'submitted_by_user_id must match auth.uid()';
    end if;
    if p_submitted_by_email is not null and lower(trim(p_submitted_by_email)) <> lower(coalesce(auth.email(), '')) then
      raise exception 'submitted_by_email must match the authenticated user';
    end if;
  elsif p_submitted_by_user_id is not null or p_submitted_by_email is not null then
    raise exception 'Anonymous submissions cannot provide a user identity';
  end if;

  if v_clean_name is null then
    raise exception 'customer_name is required';
  end if;

  if v_clean_phone is null then
    raise exception 'phone_number is required';
  end if;

  if v_clean_email is null or length(v_clean_email) > 254 or v_clean_email !~ '^[^\\s@]+@[^\\s@]+\\.[^\\s@]{2,254}$' then
    raise exception 'email is invalid';
  end if;

  if p_produce_id is null then
    raise exception 'produce_id is required';
  end if;

  if coalesce(p_kgs_supplied, 0) <= 0 then
    raise exception 'kgs_supplied must be greater than zero';
  end if;

  if v_clean_payment_option not in ('payment_on_delivery', 'pay_now') then
    raise exception 'payment_option must be payment_on_delivery or pay_now';
  end if;

  select *
    into v_produce
  from public.produce
  where id = p_produce_id
  limit 1;

  if not found then
    raise exception 'Selected produce was not found.';
  end if;

  if v_clean_particulars is null then
    v_clean_particulars := v_produce.particulars;
  end if;

  v_expected_amount := round(coalesce(v_produce.unit_price, 0) * coalesce(p_kgs_supplied, 0), 2);
  v_amount_deposited := case when v_clean_payment_option = 'pay_now' then v_expected_amount else 0 end;

  if v_clean_payment_option = 'pay_now' then
    if p_bank_account_id is null then
      raise exception 'bank_account_id is required when payment_option is pay_now';
    end if;

    if nullif(trim(coalesce(p_bank_account, '')), '') is null then
      raise exception 'bank_account is required when payment_option is pay_now';
    end if;
  end if;

  insert into public.customers (
    customer_name,
    phone_number,
    email,
    location,
    notes,
    status
  ) values (
    v_clean_name,
    v_clean_phone,
    v_clean_email,
    v_clean_location,
    nullif(trim(coalesce(p_notes, '')), ''),
    'active'
  )
  on conflict (phone_number) do update
    set customer_name = excluded.customer_name,
        email = coalesce(excluded.email, public.customers.email),
        location = coalesce(excluded.location, public.customers.location),
        notes = case
          when nullif(trim(coalesce(excluded.notes, '')), '') is null then public.customers.notes
          when nullif(trim(coalesce(public.customers.notes, '')), '') is null then excluded.notes
          else public.customers.notes || E'\n\n' || excluded.notes
        end,
        updated_at = now()
  returning * into v_customer;

  v_customer_notes := concat_ws(
    E'\n',
    'Website submission pending approval',
    'Payment option: ' || case when v_clean_payment_option = 'pay_now' then 'Pay Now' else 'Payment on Delivery' end,
    case when v_clean_email is not null then 'Email: ' || v_clean_email end,
    'Phone: ' || v_clean_phone,
    case when v_clean_location is not null then 'Pinned location: ' || v_clean_location end,
    case when nullif(trim(coalesce(p_notes, '')), '') is not null then 'Notes: ' || trim(p_notes) end
  );

  insert into public.sales_record_submissions (
    sale_date,
    customer_id,
    customer_name,
    email,
    phone_number,
    location,
    produce_id,
    particulars,
    total_dispatch_kg,
    kgs_supplied,
    rejects_kg,
    unit_price,
    payment_option,
    amount_deposited,
    bank_account_id,
    bank_account,
    notes,
    status,
    submitted_by_email,
    submitted_by_user_id
  ) values (
    coalesce(p_sale_date, current_date),
    v_customer.id,
    v_customer.customer_name,
    v_clean_email,
    v_clean_phone,
    v_clean_location,
    p_produce_id,
    v_clean_particulars,
    coalesce(p_total_dispatch_kg, p_kgs_supplied, 0),
    coalesce(p_kgs_supplied, 0),
    coalesce(p_rejects_kg, 0),
    coalesce(v_produce.unit_price, p_unit_price, 0),
    v_clean_payment_option,
    v_amount_deposited,
    case when v_clean_payment_option = 'pay_now' then p_bank_account_id else null end,
    case when v_clean_payment_option = 'pay_now' then p_bank_account else null end,
    v_customer_notes,
    'pending',
    case when auth.uid() is null then lower(coalesce(v_clean_email, 'website@onestopveggies.local')) else lower(coalesce(auth.email(), '')) end,
    auth.uid()
  ) returning * into v_submission;

  perform public.queue_notification(
    'manager',
    'New sales record submission #' || v_submission.id || ' needs your approval.',
    'sales_record_submissions',
    v_submission.id,
    jsonb_build_object('status', v_submission.status, 'customer_name', v_submission.customer_name, 'particulars', v_submission.particulars)
  );
  perform public.queue_notification(
    'supervisor',
    'New sales record submission #' || v_submission.id || ' needs your approval.',
    'sales_record_submissions',
    v_submission.id,
    jsonb_build_object('status', v_submission.status, 'customer_name', v_submission.customer_name, 'particulars', v_submission.particulars)
  );

  return json_build_object(
    'success', true,
    'submission_id', v_submission.id,
    'customer_id', v_customer.id,
    'status', v_submission.status,
    'expected_amount', v_expected_amount
  );
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

    update public.sales_record_submissions
       set status = 'approved',
           reviewed_by = p_reviewer_user_id,
           reviewed_at = now(),
           review_note = p_review_note,
           approved_sales_record_id = v_final_sales_record.id,
           updated_at = now()
     where id = p_submission_id;

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

drop policy if exists "sales submissions manager read" on public.sales_record_submissions;
create policy "sales submissions manager read"
  on public.sales_record_submissions
  for select
  to authenticated
  using (public.profiles_current_role() in ('manager', 'supervisor', 'accountant'));

drop policy if exists "sales submissions manager write" on public.sales_record_submissions;
create policy "sales submissions manager write"
  on public.sales_record_submissions
  for update
  to authenticated
  using (public.profiles_current_role() in ('manager', 'supervisor'))
  with check (public.profiles_current_role() in ('manager', 'supervisor'));

drop policy if exists "notifications role read" on public.notifications;
create policy "notifications role read"
  on public.notifications
  for select
  to authenticated
  using (lower(role) = public.profiles_current_role());

drop policy if exists "notifications role write" on public.notifications;
create policy "notifications role write"
  on public.notifications
  for update
  to authenticated
  using (lower(role) = public.profiles_current_role())
  with check (lower(role) = public.profiles_current_role());

grant execute on function public.queue_notification(text, text, text, bigint, jsonb) to authenticated;
grant execute on function public.submit_sales_record_submission(date, text, text, text, text, bigint, text, numeric, numeric, numeric, numeric, text, uuid, text, text, text, uuid) to anon, authenticated;
grant execute on function public.review_sales_record_submission(bigint, text, uuid, text) to authenticated;
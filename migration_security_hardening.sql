-- Production security hardening for the existing sales-management schema.
-- Run after supabase_schema.sql and all feature migrations.
-- Anonymous callers reach this helper only through the validated public-order
-- SECURITY DEFINER function; direct anonymous execution is not allowed.
revoke all on function public.queue_notification(text, text, text, bigint, jsonb) from public, anon;

alter table public.sales_record_submissions enable row level security;

alter table public.sales_record_submissions
  drop constraint if exists sales_record_submissions_kgs_supplied_positive;
alter table public.sales_record_submissions
  add constraint sales_record_submissions_kgs_supplied_positive
  check (kgs_supplied > 0 and kgs_supplied <= 10000) not valid;

alter table public.sales_record_submissions
  drop constraint if exists sales_record_submissions_phone_format;
alter table public.sales_record_submissions
  add constraint sales_record_submissions_phone_format
  check (phone_number ~ '^\\+?[0-9][0-9 .()-]{7,24}$') not valid;

create or replace function public.validate_sales_record_submission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_produce public.produce%rowtype;
  v_duplicate boolean;
begin
  if new.customer_name is null or length(trim(new.customer_name)) not between 2 and 160 then
    raise exception 'customer_name is invalid';
  end if;
  if new.phone_number is null or new.phone_number !~ '^\\+?[0-9][0-9 .()-]{7,24}$' then
    raise exception 'phone_number is invalid';
  end if;
  if new.email is null or length(trim(new.email)) > 254 or new.email !~ '^[^\\s@]+@[^\\s@]+\\.[^\\s@]{2,254}$' then
    raise exception 'email is invalid';
  end if;
  if new.location is not null and length(trim(new.location)) > 500 then
    raise exception 'location is too long';
  end if;
  if new.notes is not null and length(new.notes) > 4000 then
    raise exception 'notes are too long';
  end if;
  if coalesce(new.kgs_supplied, 0) <= 0 or new.kgs_supplied > 10000 then
    raise exception 'kgs_supplied must be greater than zero and no more than 10000 kg';
  end if;
  if lower(coalesce(new.payment_option, 'payment_on_delivery')) not in ('payment_on_delivery', 'pay_now') then
    raise exception 'payment_option is invalid';
  end if;

  select * into v_produce
  from public.produce
  where id = new.produce_id
  for share;
  if not found or v_produce.is_available is false or coalesce(v_produce.amount_kg, 0) < new.kgs_supplied then
    raise exception 'Selected produce is unavailable for the requested quantity';
  end if;

  select exists (
    select 1
    from public.sales_record_submissions s
    where lower(trim(s.phone_number)) = lower(trim(new.phone_number))
      and s.produce_id = new.produce_id
      and s.created_at > now() - interval '2 minutes'
  ) into v_duplicate;
  if v_duplicate then
    raise exception 'A similar order was submitted recently. Please wait before trying again.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_sales_record_submission on public.sales_record_submissions;
create trigger trg_validate_sales_record_submission
  before insert on public.sales_record_submissions
  for each row execute function public.validate_sales_record_submission();

-- ---------------------------------------------------------------------------
-- 2. Remove broad reads from sensitive tables
-- ---------------------------------------------------------------------------

alter table public.bank_account_usage_assignments enable row level security;
alter table public.produce_price_history enable row level security;
alter table public.edit_history enable row level security;

-- Bank balances and assignments are never readable from base tables by
-- ordinary staff. Public ordering uses the deliberately limited RPCs.
drop policy if exists bank_accounts_select_manager_supervisor on public.bank_accounts;
drop policy if exists bank_accounts_select_accountant on public.bank_accounts;
drop policy if exists bank_accounts_no_sales_agent on public.bank_accounts;
create policy bank_accounts_select_privileged
  on public.bank_accounts for select to authenticated
  using (public.profiles_current_role() in ('admin', 'manager', 'supervisor', 'accountant'));

-- Assignment metadata is administrative; location-specific public account
-- lookup remains available through get_public_* RPCs.
drop policy if exists bank_account_usage_assignments_read on public.bank_account_usage_assignments;
create policy bank_account_usage_assignments_read
  on public.bank_account_usage_assignments for select to authenticated
  using (public.profiles_current_role() in ('admin', 'manager', 'accountant'));
drop policy if exists bank_account_usage_assignments_write on public.bank_account_usage_assignments;
create policy bank_account_usage_assignments_write
  on public.bank_account_usage_assignments for all to authenticated
  using (public.profiles_current_role() in ('admin', 'manager', 'accountant'))
  with check (public.profiles_current_role() in ('admin', 'manager', 'accountant'));

-- Operational inventory logs are restricted to operational supervisors and
-- accounting roles; direct writes remain denied for ordinary users.
drop policy if exists "authenticated read produce stock logs" on public.produce_stock_log;
create policy "privileged read produce stock logs"
  on public.produce_stock_log for select to authenticated
  using (public.profiles_current_role() in ('admin', 'manager', 'supervisor', 'accountant'));

-- Employee records contain personal information.
drop policy if exists "authenticated read employees" on public.employees;
create policy "privileged read employees"
  on public.employees for select to authenticated
  using (public.profiles_current_role() in ('admin', 'manager', 'supervisor', 'group_leader'));

-- Accounting data is restricted to accounting leadership. Sales agents retain
-- only their own expense-submission access through the existing expense policy.
drop policy if exists "accounting purchases read" on public.accounting_purchases;
create policy "accounting purchases read"
  on public.accounting_purchases for select to authenticated
  using (public.profiles_can_manage_accounting());
drop policy if exists "accounting inventory read" on public.accounting_inventory;
create policy "accounting inventory read"
  on public.accounting_inventory for select to authenticated
  using (public.profiles_can_manage_accounting());
drop policy if exists "accounting cash book read" on public.accounting_cash_book;
create policy "accounting cash book read"
  on public.accounting_cash_book for select to authenticated
  using (public.profiles_can_manage_accounting());
drop policy if exists "accounting debtors read" on public.accounting_debtors;
create policy "accounting debtors read"
  on public.accounting_debtors for select to authenticated
  using (public.profiles_can_manage_accounting());
drop policy if exists "accounting creditors read" on public.accounting_creditors;
create policy "accounting creditors read"
  on public.accounting_creditors for select to authenticated
  using (public.profiles_can_manage_accounting());

-- Audit history is append-only and visible only to privileged reviewers.
drop policy if exists "authenticated insert edit history" on public.edit_history;
create policy "own edit history insert"
  on public.edit_history for insert to authenticated
  with check (edited_by = auth.uid() and lower(edited_by_email) = lower(auth.email()));
drop policy if exists "authenticated read edit history" on public.edit_history;
create policy "privileged read edit history"
  on public.edit_history for select to authenticated
  using (public.profiles_has_full_access());
drop policy if exists "authenticated update edit history" on public.edit_history;
drop policy if exists "authenticated delete edit history" on public.edit_history;

-- Price history is generated by triggers and read-only to privileged users.
drop policy if exists "produce price history read" on public.produce_price_history;
create policy "produce price history read"
  on public.produce_price_history for select to authenticated
  using (public.profiles_has_full_access());

-- ---------------------------------------------------------------------------
-- 3. Delivery authorization
-- ---------------------------------------------------------------------------

-- Keep pending deliveries visible to drivers so they can accept work, but a
-- driver can only update a pending or already-owned assignment.
drop policy if exists "delivery assignments read" on public.delivery_assignments;
create policy "delivery assignments read"
  on public.delivery_assignments for select to authenticated
  using (
    public.profiles_current_role() in ('admin', 'manager', 'supervisor')
    or (
      public.profiles_current_role() = 'driver'
      and (assigned_driver is null or lower(trim(assigned_driver)) = lower(trim(auth.email())))
    )
  );
drop policy if exists "delivery assignments write" on public.delivery_assignments;
create policy "delivery assignments write"
  on public.delivery_assignments for update to authenticated
  using (
    public.profiles_current_role() in ('admin', 'manager', 'supervisor')
    or (
      public.profiles_current_role() = 'driver'
      and (assigned_driver is null or lower(trim(assigned_driver)) = lower(trim(auth.email())))
    )
  )
  with check (
    public.profiles_current_role() in ('admin', 'manager', 'supervisor')
    or (
      public.profiles_current_role() = 'driver'
      and lower(trim(assigned_driver)) = lower(trim(auth.email()))
    )
  );

-- ---------------------------------------------------------------------------
-- 4. SECURITY DEFINER actor binding for approval and delivery RPCs
-- ---------------------------------------------------------------------------

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
  if auth.uid() is null or public.profiles_current_role() not in ('admin','manager','supervisor') then
    raise exception 'Only managers or supervisors can create delivery assignments';
  end if;
  select * into v_submission from public.sales_record_submissions where id = p_submission_id limit 1;
  if not found then raise exception 'Submission not found'; end if;
  if v_status not in ('pending','assigned','in_transit','delivered','cancelled','not_applicable') then
    raise exception 'delivery_status is invalid';
  end if;
  if coalesce(p_quantity_kg, v_submission.kgs_supplied, 0) <= 0 then
    raise exception 'Delivery quantity must be greater than zero';
  end if;
  insert into public.delivery_assignments (
    submission_id, sales_record_id, delivery_number, customer_name, customer_phone,
    destination, address, products, quantity_kg, amount_to_collect, payment_method,
    delivery_instructions, assigned_driver, scheduled_at, delivery_status, created_at, updated_at
  ) values (
    p_submission_id, p_sales_record_id, coalesce(nullif(trim(p_delivery_number), ''), 'DEL-' || p_submission_id),
    coalesce(nullif(trim(p_customer_name), ''), v_submission.customer_name),
    nullif(trim(coalesce(p_customer_phone, v_submission.phone_number, '')), ''),
    nullif(trim(coalesce(p_destination, v_submission.location, '')), ''),
    nullif(trim(coalesce(p_address, p_destination, v_submission.location, '')), ''),
    coalesce(nullif(trim(p_products), ''), v_submission.particulars),
    coalesce(p_quantity_kg, v_submission.kgs_supplied, v_submission.total_dispatch_kg, 0),
    coalesce(p_amount_to_collect, coalesce(v_submission.unit_price, 0) * coalesce(v_submission.kgs_supplied, v_submission.total_dispatch_kg, 0)),
    coalesce(nullif(trim(p_payment_method), ''), 'Payment on Delivery'),
    nullif(trim(coalesce(p_delivery_instructions, v_submission.notes, '')), ''),
    nullif(trim(coalesce(p_assigned_driver, '')), ''), now(), v_status, now(), now()
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
  v_record public.sales_records%rowtype;
  v_role text := public.profiles_current_role();
  v_assigned text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_record_id is null then raise exception 'record_id is required'; end if;
  if lower(coalesce(p_delivery_status, '')) not in ('pending','assigned','in_transit','delivered','cancelled','not_applicable') then
    raise exception 'delivery_status is invalid';
  end if;
  select * into v_record from public.sales_records where id = p_record_id for update;
  if not found then raise exception 'Sales record not found'; end if;
  v_assigned := lower(trim(coalesce(v_record.delivery_assigned_to, p_delivery_assigned_to, '')));
  if v_role not in ('admin','manager','supervisor')
     and not (v_role = 'driver' and v_assigned = lower(trim(auth.email()))) then
    raise exception 'You are not authorized to update this delivery';
  end if;
  update public.sales_records
     set delivery_status = lower(trim(p_delivery_status)),
         delivery_assigned_to = coalesce(nullif(trim(p_delivery_assigned_to), ''), delivery_assigned_to),
         delivery_transport_details = coalesce(nullif(trim(p_delivery_transport_details), ''), delivery_transport_details),
         delivery_note = coalesce(nullif(trim(p_delivery_note), ''), delivery_note),
         updated_at = now()
   where id = p_record_id;
  return (select sr from public.sales_records sr where sr.id = p_record_id);
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
  v_submission public.sales_record_submissions%rowtype;
  v_final_sales_record public.sales_records%rowtype;
  v_delivery_assignment public.delivery_assignments%rowtype;
  v_role text := public.profiles_current_role();
begin
  if auth.uid() is null or p_reviewer_user_id is distinct from auth.uid() then
    raise exception 'Reviewer identity must match the authenticated user';
  end if;
  if v_role not in ('admin','manager','supervisor') then
    raise exception 'Only managers or supervisors can review sales submissions';
  end if;
  if p_submission_id is null or v_action not in ('approve','reject') then
    raise exception 'Invalid submission review request';
  end if;
  select * into v_submission from public.sales_record_submissions where id = p_submission_id for update;
  if not found then raise exception 'Sales submission not found'; end if;
  if v_submission.submitted_by_user_id is not null and v_submission.submitted_by_user_id = auth.uid() then
    raise exception 'A user cannot approve or reject their own submission';
  end if;
  if lower(coalesce(v_submission.status, 'pending')) <> 'pending' then
    raise exception 'Only pending submissions can be reviewed';
  end if;

  if v_action = 'reject' then
    update public.sales_record_submissions
       set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), review_note = nullif(trim(p_review_note), ''), updated_at = now()
     where id = p_submission_id;
    return json_build_object('success', true, 'submission_id', p_submission_id, 'status', 'rejected');
  end if;

  select * into v_final_sales_record
  from public.create_sales_record_with_inventory(
    coalesce(v_submission.sale_date, current_date), v_submission.customer_name, v_submission.particulars,
    coalesce(v_submission.total_dispatch_kg, v_submission.kgs_supplied, 0), coalesce(v_submission.kgs_supplied, 0),
    coalesce(v_submission.rejects_kg, 0), coalesce(v_submission.unit_price, 0), coalesce(v_submission.amount_deposited, 0),
    v_submission.bank_account_id, v_submission.bank_account, null, coalesce(v_submission.notes, '')
  ) limit 1;

  update public.sales_record_submissions
     set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), review_note = nullif(trim(p_review_note), ''),
         approved_sales_record_id = v_final_sales_record.id,
         payment_option = lower(coalesce(v_submission.payment_option, 'payment_on_delivery')),
         delivery_status = case when lower(coalesce(v_submission.payment_option, 'payment_on_delivery')) = 'pay_now' then 'not_applicable' else 'pending' end,
         updated_at = now()
   where id = p_submission_id;

  update public.sales_records
     set payment_option = lower(coalesce(v_submission.payment_option, 'payment_on_delivery')),
         delivery_status = case when lower(coalesce(v_submission.payment_option, 'payment_on_delivery')) = 'pay_now' then 'not_applicable' else 'pending' end,
         delivery_assigned_to = null,
         delivery_note = null,
         updated_at = now()
   where id = v_final_sales_record.id;

  if lower(coalesce(v_submission.payment_option, 'payment_on_delivery')) = 'payment_on_delivery' then
    select * into v_delivery_assignment
    from public.create_delivery_assignment_for_submission(
      p_submission_id, v_final_sales_record.id, 'DEL-' || p_submission_id, v_submission.customer_name,
      v_submission.phone_number, v_submission.location, v_submission.location, v_submission.particulars,
      coalesce(v_submission.kgs_supplied, v_submission.total_dispatch_kg, 0),
      coalesce(v_submission.unit_price, 0) * coalesce(v_submission.kgs_supplied, v_submission.total_dispatch_kg, 0),
      'Payment on Delivery', coalesce(v_submission.notes, 'Please confirm delivery details on arrival.'), null, 'pending'
    );
    perform public.queue_notification('driver', 'New delivery assignment #' || v_delivery_assignment.id || ' is ready for pickup.', 'delivery_assignments', v_delivery_assignment.id, jsonb_build_object('delivery_id', v_delivery_assignment.id, 'customer_name', v_submission.customer_name));
    perform public.queue_notification('manager', 'Delivery assignment #' || v_delivery_assignment.id || ' created for ' || v_submission.customer_name || '.', 'delivery_assignments', v_delivery_assignment.id, jsonb_build_object('delivery_id', v_delivery_assignment.id, 'customer_name', v_submission.customer_name));
    perform public.queue_notification('supervisor', 'Delivery assignment #' || v_delivery_assignment.id || ' created for ' || v_submission.customer_name || '.', 'delivery_assignments', v_delivery_assignment.id, jsonb_build_object('delivery_id', v_delivery_assignment.id, 'customer_name', v_submission.customer_name));
  end if;

  perform public.queue_notification('accountant', 'Sales record #' || v_final_sales_record.id || ' is ready for payment approval.', 'sales_records', v_final_sales_record.id, jsonb_build_object('submission_id', v_submission.id, 'customer_name', v_submission.customer_name, 'particulars', v_submission.particulars));

  return json_build_object('success', true, 'submission_id', p_submission_id, 'sales_record_id', v_final_sales_record.id, 'status', 'approved');
end;
$$;

-- Never expose administrative mutation helpers to anonymous/public callers.
revoke all on function public.set_bank_account_usage_assignment(uuid, text, text) from public, anon;
revoke all on function public.set_order_now_active_account(uuid) from public, anon;
revoke all on function public.create_delivery_assignment_for_submission(bigint, bigint, text, text, text, text, text, text, numeric, numeric, text, text, text, text) from public, anon;
revoke all on function public.update_sales_record_delivery_status(bigint, text, text, text, text, uuid) from public, anon;
revoke all on function public.review_sales_record_submission(bigint, text, uuid, text) from public, anon;
revoke all on function public.adjust_bank_account_balance(uuid, numeric, text, uuid) from public, anon;
revoke all on function public.transfer_bank_account_funds(uuid, uuid, numeric, text, text, text) from public, anon;
revoke all on function public.transfer_stock(text, uuid, text, uuid, bigint, numeric, uuid, text, text, text) from public, anon;

grant execute on function public.update_sales_record_delivery_status(bigint, text, text, text, text, uuid) to authenticated;
grant execute on function public.review_sales_record_submission(bigint, text, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Prevent client-controlled signup privilege escalation
-- ---------------------------------------------------------------------------

create or replace function public.auth_users_insert_profile()
returns trigger
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  v_email text := lower(trim(coalesce(new.email, '')));
  v_full_name text := initcap(split_part(v_email, '@', 1));
  v_phone text := coalesce(nullif(trim(new.raw_user_meta_data->>'phone_number'), ''), '+254000000000');
  v_location text := coalesce(nullif(trim(new.raw_user_meta_data->>'location'), ''), 'Unknown');
begin
  if v_phone !~ '^\\+254[0-9]{9}$' then v_phone := '+254000000000'; end if;
  insert into public.profiles(id, full_name, email, phone_number, role, location)
  values (new.id, v_full_name, v_email, v_phone, 'sales_agent', initcap(v_location))
  on conflict (id) do update set full_name = excluded.full_name, email = excluded.email,
    phone_number = excluded.phone_number, updated_at = now();
  return new;
end;
$$;

-- Ensure SECURITY DEFINER helpers have no accidental public execute privilege.
revoke all on function public.auth_users_insert_profile() from public, anon, authenticated;
revoke all on function public.validate_sales_record_submission() from public, anon, authenticated;

-- Prevent direct manipulation of audit rows by ordinary clients.
revoke all on table public.edit_history from anon;
revoke update, delete on table public.edit_history from authenticated;

-- ---------------------------------------------------------------------------
-- 6. Security posture notes
-- ---------------------------------------------------------------------------
-- HTTPS, HSTS, CSP, Supabase Auth email settings, leaked-key rotation, and
-- database backups are deployment/dashboard controls and are documented in the
-- audit report. The public website-gallery bucket remains intentionally public;
-- deposit-confirmations remains private.

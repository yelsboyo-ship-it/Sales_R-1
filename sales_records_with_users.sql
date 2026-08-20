-- ============================================================
-- View for joined sales records and profile data
-- ============================================================

alter table public.sales_records
  add column if not exists confirmation_status text not null default 'pending';

alter table public.sales_records
  drop constraint if exists sales_records_confirmation_status_check;

alter table public.sales_records
  add constraint sales_records_confirmation_status_check
  check (confirmation_status in ('pending','confirmed','rejected'));

alter table public.sales_records
  add column if not exists approved_by uuid references public.profiles(id);

alter table public.sales_records
  add column if not exists approved_at timestamptz;

alter table public.sales_records
  add column if not exists bank_account_id uuid references public.bank_accounts(id);

alter table public.sales_records
  add column if not exists customer_id uuid references public.customers(id);

alter table public.sales_records
  add column if not exists receipt_no text;

alter table public.sales_records
  add column if not exists bank_account text;

alter table public.sales_records
  add column if not exists deposit_confirmation_url text[];

alter table public.sales_records
  add column if not exists payment_confirmation_text text;

alter table public.sales_records
  add column if not exists expenses numeric(12,2) not null default 0;

drop view if exists public.sales_records_with_users cascade;

create view public.sales_records_with_users (
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

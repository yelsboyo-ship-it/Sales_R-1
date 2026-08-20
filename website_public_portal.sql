-- ============================================================
-- Public website portal support for Onestop_Veggies
-- Run after supabase_schema.sql
-- ============================================================

create table if not exists public.gallery (
  id uuid primary key default gen_random_uuid(),
  title text,
  caption text,
  alt_text text,
  image_url text not null,
  storage_path text,
  sort_order integer not null default 0,
  is_published boolean not null default true,
  uploaded_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.gallery
  add column if not exists alt_text text;

alter table public.gallery
  add column if not exists storage_path text;

alter table public.gallery enable row level security;

drop trigger if exists trg_gallery_updated_at on public.gallery;
create trigger trg_gallery_updated_at
  before update on public.gallery
  for each row execute function public.set_updated_at();

drop policy if exists "gallery public read" on public.gallery;
create policy "gallery public read"
  on public.gallery
  for select
  to anon, authenticated
  using (
    is_published = true
    or public.profiles_is_manager_or_supervisor()
  );

drop policy if exists "gallery managers insert" on public.gallery;
create policy "gallery managers insert"
  on public.gallery
  for insert
  to authenticated
  with check (public.profiles_is_manager_or_supervisor());

drop policy if exists "gallery managers update" on public.gallery;
create policy "gallery managers update"
  on public.gallery
  for update
  to authenticated
  using (public.profiles_is_manager_or_supervisor())
  with check (public.profiles_is_manager_or_supervisor());

drop policy if exists "gallery managers delete" on public.gallery;
create policy "gallery managers delete"
  on public.gallery
  for delete
  to authenticated
  using (public.profiles_is_manager_or_supervisor());

insert into storage.buckets (id, name, public)
values ('website-gallery', 'website-gallery', true)
on conflict (id) do update
set public = excluded.public,
    name = excluded.name;

drop policy if exists "website gallery public read" on storage.objects;
create policy "website gallery public read"
  on storage.objects
  for select
  to public
  using (bucket_id = 'website-gallery');

drop policy if exists "website gallery managers insert" on storage.objects;
create policy "website gallery managers insert"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'website-gallery'
    and public.profiles_is_manager_or_supervisor()
  );

drop policy if exists "website gallery managers update" on storage.objects;
create policy "website gallery managers update"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'website-gallery'
    and public.profiles_is_manager_or_supervisor()
  )
  with check (
    bucket_id = 'website-gallery'
    and public.profiles_is_manager_or_supervisor()
  );

drop policy if exists "website gallery managers delete" on storage.objects;
create policy "website gallery managers delete"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'website-gallery'
    and public.profiles_is_manager_or_supervisor()
  );

drop policy if exists "anon read produce" on public.produce;
create policy "anon read produce"
  on public.produce
  for select
  to anon
  using (true);

drop index if exists idx_produce_public_listing;
create index if not exists idx_produce_public_listing
  on public.produce (particulars asc);

create index if not exists idx_gallery_public_listing
  on public.gallery (is_published, sort_order asc, created_at desc);

create index if not exists idx_bank_accounts_public_active
  on public.bank_accounts (is_active, bank_name asc, account_name asc)
  include (account_number, branch, currency);

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

create or replace function public.set_order_now_active_account(p_bank_account_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account public.bank_accounts%rowtype;
  v_row_count int;
begin
  if not public.profiles_can_manage_roles() then
    raise exception 'Only managers can change the active Order Now account.';
  end if;

  if p_bank_account_id is null then
    raise exception 'bank_account_id is required.';
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
    raise exception 'The selected account must be active.';
  end if;

  update public.bank_accounts
     set is_order_now_active = false
   where is_order_now_active is true;

  update public.bank_accounts
     set is_order_now_active = true
   where id = p_bank_account_id;

  get diagnostics v_row_count = row_count;
  if v_row_count <> 1 then
    raise exception 'Unable to set the selected account as active for Order Now.';
  end if;

  return json_build_object('success', true, 'bank_account_id', p_bank_account_id);
end;
$$;

grant execute on function public.set_order_now_active_account(uuid) to authenticated;

create or replace function public.get_public_bank_accounts(p_location_name text default null)
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
    ba.account_name asc;
$$;

grant execute on function public.get_public_bank_accounts(text) to anon, authenticated;

drop function if exists public.submit_public_customer_order(text, text, text, text, text, bigint, numeric, text, uuid);

create or replace function public.submit_public_customer_order(
  p_customer_name text,
  p_email text,
  p_phone_number text,
  p_location text,
  p_notes text,
  p_produce_id bigint,
  p_kgs_supplied numeric,
  p_payment_option text default 'payment_on_delivery',
  p_bank_account_id uuid default null,
  p_bank_account text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result json;
  v_particulars text;
  v_order_now_account record;
  v_selected_bank_account_id uuid;
  v_selected_bank_account text;
begin
  select particulars
    into v_particulars
  from public.produce
  where id = p_produce_id
  limit 1;

  if v_particulars is null then
    raise exception 'Selected produce was not found.';
  end if;

  v_selected_bank_account_id := p_bank_account_id;
  v_selected_bank_account := nullif(trim(coalesce(p_bank_account, '')), '');

  if lower(trim(coalesce(p_payment_option, 'payment_on_delivery'))) = 'pay_now' then
    if v_selected_bank_account_id is not null then
      select ba.id, ba.bank_name, ba.account_name
        into v_order_now_account
      from public.bank_accounts ba
      left join public.bank_account_usage_assignments bua_customer
        on bua_customer.bank_account_id = ba.id
       and bua_customer.usage_type = 'customer_order'
      left join public.bank_account_usage_assignments bua_branch
        on bua_branch.bank_account_id = ba.id
       and bua_branch.usage_type = 'branch_location'
       and p_location is not null
       and lower(trim(bua_branch.location_name)) = lower(trim(p_location))
      where ba.is_active is true
        and ba.id = v_selected_bank_account_id
        and (
          bua_branch.bank_account_id is not null
          or bua_customer.bank_account_id is not null
          or ba.is_order_now_active is true
        )
      limit 1;

      if not found then
        raise exception 'Selected payment account is not available for Pay Now. Please choose a valid payment account.';
      end if;
    else
      select ba.id, ba.bank_name, ba.account_name
        into v_order_now_account
      from public.bank_accounts ba
      left join public.bank_account_usage_assignments bua_customer
        on bua_customer.bank_account_id = ba.id
       and bua_customer.usage_type = 'customer_order'
      left join public.bank_account_usage_assignments bua_branch
        on bua_branch.bank_account_id = ba.id
       and bua_branch.usage_type = 'branch_location'
       and p_location is not null
       and lower(trim(bua_branch.location_name)) = lower(trim(p_location))
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

      if not found then
        raise exception 'Payment account is currently unavailable. Please choose Pay on Delivery.';
      end if;
    end if;

    v_selected_bank_account_id := v_order_now_account.id;
    v_selected_bank_account := concat_ws(
      ' · ',
      nullif(trim(coalesce(v_order_now_account.bank_name, '')), ''),
      nullif(trim(coalesce(v_order_now_account.account_name, '')), '')
    );
  end if;

  v_result := public.submit_sales_record_submission(
    current_date,
    p_customer_name,
    p_email,
    p_phone_number,
    p_location,
    p_produce_id,
    v_particulars,
    coalesce(p_kgs_supplied, 0),
    coalesce(p_kgs_supplied, 0),
    0,
    0,
    p_payment_option,
    v_selected_bank_account_id,
    v_selected_bank_account,
    p_notes,
    null,
    null
  );

  return v_result;
end;
$$;

grant execute on function public.submit_public_customer_order(text, text, text, text, text, bigint, numeric, text, uuid, text) to anon, authenticated;
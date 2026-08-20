-- ============================================================
-- Storage bucket setup for deposit confirmations
-- ============================================================

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
  return coalesce(public.current_profile_role(), 'sales_agent') = 'sales_agent';
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

-- Create the private bucket (not public)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'deposit-confirmations',
  'deposit-confirmations',
  false,
  10485760,
  ARRAY['image/png','image/jpeg','image/jpg','image/webp','application/pdf','text/plain','text/csv']
)
on conflict (id) do nothing;

-- Storage policies
-- Accountant can upload and update confirmation objects.
drop policy if exists accountants_manage_deposit_confirmations on storage.objects;
create policy accountants_manage_deposit_confirmations
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'deposit-confirmations' and public.is_accountant_role()
  );

drop policy if exists accountants_update_deposit_confirmations on storage.objects;
create policy accountants_update_deposit_confirmations
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'deposit-confirmations' and public.is_accountant_role()
  )
  with check (
    bucket_id = 'deposit-confirmations' and public.is_accountant_role()
  );

-- Manager, supervisor, and accountant can view confirmation objects.
drop policy if exists managers_supervisors_accountants_select_deposit_confirmations on storage.objects;
create policy managers_supervisors_accountants_select_deposit_confirmations
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'deposit-confirmations' and (
      public.is_accountant_role() or public.is_manager_or_supervisor_role()
    )
  );

-- Sales agents can only view objects linked to their own sales records.
drop policy if exists sales_agents_select_own_deposit_confirmations on storage.objects;
create policy sales_agents_select_own_deposit_confirmations
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'deposit-confirmations'
    and public.is_sales_agent_role()
    and (
      split_part(name, '/', 1) ~ '^\d+$'
      and split_part(name, '/', 1)::bigint in (
        select id
        from public.sales_records
        where recorded_by_user_id = auth.uid()
      )
    )
  );

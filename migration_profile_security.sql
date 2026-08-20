-- Profile privilege-escalation fix
-- Run this once in Supabase Dashboard -> SQL Editor.

alter table public.profiles
  add column if not exists avatar_url text;

create or replace function public.normalize_profile_role(raw_role text)
returns text as $$
begin
  if raw_role is null or trim(raw_role) = '' then return 'sales_agent'; end if;
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
  on public.profile_role_changes for select to authenticated
  using (public.profiles_can_manage_roles());

create or replace function public.profiles_restrict_sensitive_updates()
returns trigger as $$
begin
  if new.role is distinct from old.role
     and current_setting('app.profile_role_change', true) is distinct from 'allowed' then
    raise exception 'Permission denied: roles can only be changed through the approved role-management function';
  end if;

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

drop trigger if exists trg_profiles_restrict_role_location_updates on public.profiles;
drop trigger if exists trg_profiles_restrict_sensitive_updates on public.profiles;
create trigger trg_profiles_restrict_sensitive_updates
  before update on public.profiles
  for each row execute function public.profiles_restrict_sensitive_updates();

create or replace function public.set_profile_role(p_profile_id uuid, p_new_role text)
returns public.profiles
language plpgsql security definer set search_path = public set row_security = off
as $$
declare
  v_role text := public.normalize_profile_role(p_new_role);
  v_profile public.profiles%rowtype;
  v_previous_role text;
begin
  if auth.uid() is null or not public.profiles_can_manage_roles() then
    raise exception 'Only managers and administrators can change user roles.';
  end if;
  if p_profile_id is null then raise exception 'A profile is required.'; end if;
  if v_role not in ('admin', 'manager', 'supervisor', 'accountant', 'sales_agent', 'staff', 'group_leader', 'driver') then
    raise exception 'Invalid role.';
  end if;
  if v_role = 'admin' and public.profiles_current_role() <> 'admin' then
    raise exception 'Only an administrator can grant administrator access.';
  end if;

  select * into v_profile from public.profiles where id = p_profile_id for update;
  if not found then raise exception 'Profile not found.'; end if;

  if v_profile.role is distinct from v_role then
    v_previous_role := v_profile.role;
    perform set_config('app.profile_role_change', 'allowed', true);
    update public.profiles set role = v_role, updated_at = now()
      where id = p_profile_id returning * into v_profile;
    insert into public.profile_role_changes(profile_id, previous_role, new_role, changed_by)
    values (p_profile_id, v_previous_role, v_role, auth.uid());
  end if;
  return v_profile;
end;
$$;

revoke all on function public.set_profile_role(uuid, text) from public, anon;
grant execute on function public.set_profile_role(uuid, text) to authenticated;

create or replace function public.update_own_profile(
  p_full_name text default null, p_phone_number text default null,
  p_location text default null, p_avatar_url text default null,
  p_profile_prompted boolean default null
)
returns public.profiles
language plpgsql security definer set search_path = public set row_security = off
as $$
declare v_profile public.profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'You must be signed in to update your profile.'; end if;
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
  if not found then raise exception 'Profile not found.'; end if;
  return v_profile;
end;
$$;

revoke all on function public.update_own_profile(text, text, text, text, boolean) from public, anon;
grant execute on function public.update_own_profile(text, text, text, text, boolean) to authenticated;

-- New users must not receive a role from untrusted signup metadata.
create or replace function public.auth_users_insert_profile()
returns trigger as $$
declare
  v_full_name text;
  v_email text;
  v_phone_number text;
  v_location text;
begin
  v_email := lower(trim(coalesce(new.email, '')));
  v_full_name := initcap(split_part(v_email, '@', 1));
  v_phone_number := coalesce(nullif(trim(coalesce(new.raw_user_meta_data->>'phone_number', '+254000000000')), ''), '+254000000000');
  if v_phone_number !~ '^\+254[0-9]{9}$' then v_phone_number := '+254000000000'; end if;
  v_location := coalesce(nullif(trim(coalesce(new.raw_user_meta_data->>'location', 'Unknown')), ''), 'Unknown');

  insert into public.profiles(id, full_name, email, phone_number, role, location)
  values (
    new.id,
    v_full_name,
    v_email,
    v_phone_number,
    'sales_agent',
    initcap(v_location)
  )
  on conflict (id) do update set
    full_name = excluded.full_name, email = excluded.email,
    phone_number = excluded.phone_number, location = excluded.location,
    updated_at = now();
  return new;
end;
$$ language plpgsql security definer set row_security = off;

drop policy if exists "Users insert own profile" on public.profiles;
create policy "Users insert own profile"
  on public.profiles for insert to authenticated
  with check (
    (auth.uid() = id and lower(role) = 'sales_agent')
    or (public.profiles_is_manager_or_supervisor() and lower(role) in ('sales_agent', 'accountant', 'staff', 'group_leader', 'driver', 'manager', 'supervisor'))
  );

-- ============================================================
-- Migration: Add available_now column to produce table
-- Supports dynamic availability based on ready_date
-- Run this in: Supabase Dashboard → SQL Editor → New Query
-- ============================================================

-- Add the available_now column if it doesn't exist
alter table public.produce
  add column if not exists available_now boolean not null default false;

-- Create or replace a function to sync availability based on ready_date
create or replace function public.sync_produce_availability()
returns void
language sql
security definer
set row_security = off
as $$
  update public.produce
  set available_now = true
  where
    available_now = false
    and ready_date is not null
    and ready_date <= current_date;
$$;

-- Create a trigger to automatically sync availability on select
-- Note: This is for demonstration. In practice, call sync_produce_availability() 
-- as needed from your application.

comment on column public.produce.available_now is 'Indicates if produce is available for ordering now (true) or waiting for ready_date (false)';

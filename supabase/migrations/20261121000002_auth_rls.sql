-- =====================================================================
-- Roles, profile bootstrap and Row Level Security
-- =====================================================================

create or replace function private.my_role()
returns text language sql stable security definer set search_path = ''
as $$ select role from public.profiles where id = auth.uid() $$;

create or replace function private.is_staff()
returns boolean language sql stable security definer set search_path = ''
as $$ select coalesce(private.my_role() in ('admin', 'staff'), false) $$;

create or replace function private.is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$ select coalesce(private.my_role() = 'admin', false) $$;

revoke all on function private.my_role(), private.is_staff(), private.is_admin() from public, anon;
grant execute on function private.my_role(), private.is_staff(), private.is_admin() to authenticated;
grant execute on function private.norm_code(text), private.num(text), private.truthy(text), private.ar_norm(text) to authenticated, service_role;

-- New auth user => profile. The very first user becomes admin; everyone else
-- starts as 'pending' until an admin approves (safe even if public sign-up is on).
create or replace function private.handle_new_user()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    case when exists (select 1 from public.profiles where role = 'admin') then 'pending' else 'admin' end
  )
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.profiles           enable row level security;
alter table public.erp_warehouses     enable row level security;
alter table public.erp_products       enable row level security;
alter table public.erp_barcodes       enable row level security;
alter table public.erp_stock          enable row level security;
alter table public.erp_sales          enable row level security;
alter table public.locations          enable row level security;
alter table public.product_locations  enable row level security;
alter table public.location_movements enable row level security;
alter table public.sync_runs          enable row level security;
alter table private.sync_config       enable row level security;

-- profiles: you see yourself; admins see everyone. Role changes go through set_user_role().
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select private.is_admin()));

-- erp_*: staff read; nobody writes through the API (only erp_ingest, security definer).
create policy erp_warehouses_read on public.erp_warehouses for select to authenticated using ((select private.is_staff()));
create policy erp_products_read   on public.erp_products   for select to authenticated using ((select private.is_staff()));
create policy erp_barcodes_read   on public.erp_barcodes   for select to authenticated using ((select private.is_staff()));
create policy erp_stock_read      on public.erp_stock      for select to authenticated using ((select private.is_staff()));
create policy erp_sales_read      on public.erp_sales      for select to authenticated using ((select private.is_staff()));

-- locations: staff read, admins manage.
create policy locations_read   on public.locations for select to authenticated using ((select private.is_staff()));
create policy locations_insert on public.locations for insert to authenticated with check ((select private.is_admin()));
create policy locations_update on public.locations for update to authenticated using ((select private.is_admin())) with check ((select private.is_admin()));
create policy locations_delete on public.locations for delete to authenticated using ((select private.is_admin()));

-- product_locations / movements: staff read; writes only via the location RPCs (which log to movements).
create policy product_locations_read  on public.product_locations  for select to authenticated using ((select private.is_staff()));
create policy location_movements_read on public.location_movements for select to authenticated using ((select private.is_staff()));

create policy sync_runs_read on public.sync_runs for select to authenticated using ((select private.is_staff()));

-- Table privileges: read for authenticated, nothing for anon.
revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate on public.erp_warehouses, public.erp_products, public.erp_barcodes,
  public.erp_stock, public.erp_sales, public.product_locations, public.location_movements,
  public.sync_runs, public.profiles from authenticated;

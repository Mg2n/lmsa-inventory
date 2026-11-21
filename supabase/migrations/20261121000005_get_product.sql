-- Open a product by its exact item code (no barcode matching).
create or replace function public.get_product(p_itmcode text)
returns jsonb language sql stable set search_path = ''
as $$ select private.product_json(p_itmcode) where private.is_staff() $$;
revoke execute on function public.get_product(text) from public, anon;
grant execute on function public.get_product(text) to authenticated;

-- =====================================================================
-- Daily review per branch / warehouse (decided 2026-11-24): for any day,
-- each branch's sales totals plus a "reviewed" mark recording who checked
-- that day's bills and when. Admin only.
-- =====================================================================

create table public.sales_day_reviews (
  brnid       text not null,
  whsno       text not null,
  day         date not null,
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz not null default now(),
  note        text,
  primary key (brnid, whsno, day)
);
alter table public.sales_day_reviews enable row level security;
create policy sales_day_reviews_admin_read on public.sales_day_reviews for select to authenticated using ((select private.is_admin()));
revoke all on public.sales_day_reviews from anon;
revoke insert, update, delete, truncate on public.sales_day_reviews from authenticated;
grant select on public.sales_day_reviews to authenticated;

-- One row per branch/warehouse that had documents on p_day (store time), or was reviewed.
create or replace function public.sales_daily(p_day date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  with bounds as (
    select (p_day::timestamp at time zone 'Asia/Riyadh') as t0,
           ((p_day + 1)::timestamp at time zone 'Asia/Riyadh') as t1
  ), h as (
    select h.*, coalesce((select sum(l.saleqty) from public.erp_sales_lines l
                           where l.brnid = h.brnid and l.gltype = h.gltype and l.vouno = h.vouno), 0) as line_qty
    from public.erp_sales_heads h, bounds
    where private.is_admin() and h.whsno is not null and h.voudate >= bounds.t0 and h.voudate < bounds.t1
  ), keys as (
    select distinct brnid, whsno from h
    union
    select brnid, whsno from public.sales_day_reviews where day = p_day and private.is_admin()
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'brnid', k.brnid, 'whsno', k.whsno, 'name', coalesce(wn.name, ew.name),
      'sales_net',    coalesce((select sum(invnetamt) from h where h.brnid = k.brnid and h.whsno = k.whsno and h.is_active and h.gltype <> '108'), 0),
      'sales_bills',  (select count(*) from h where h.brnid = k.brnid and h.whsno = k.whsno and h.is_active and h.gltype <> '108'),
      'returns_net',  coalesce((select sum(invnetamt) from h where h.brnid = k.brnid and h.whsno = k.whsno and h.is_active and h.gltype = '108'), 0),
      'return_bills', (select count(*) from h where h.brnid = k.brnid and h.whsno = k.whsno and h.is_active and h.gltype = '108'),
      'qty',          coalesce((select sum(line_qty) from h where h.brnid = k.brnid and h.whsno = k.whsno and h.is_active and h.gltype <> '108'), 0),
      'discount',     coalesce((select sum(disctotal) from h where h.brnid = k.brnid and h.whsno = k.whsno and h.is_active and h.gltype <> '108'), 0),
      'cancelled',    (select count(*) from h where h.brnid = k.brnid and h.whsno = k.whsno and not h.is_active),
      'first_at',     (select min(voudate) from h where h.brnid = k.brnid and h.whsno = k.whsno),
      'last_at',      (select max(voudate) from h where h.brnid = k.brnid and h.whsno = k.whsno),
      'review', (select jsonb_build_object('by', coalesce(pr.full_name, pr.email), 'at', r.reviewed_at, 'note', r.note)
                   from public.sales_day_reviews r left join public.profiles pr on pr.id = r.reviewed_by
                  where r.brnid = k.brnid and r.whsno = k.whsno and r.day = p_day))
      order by case when k.whsno ~ '^[0-9]+$' then k.whsno::int end, k.whsno), '[]'::jsonb)
  from keys k
  left join public.warehouse_names wn on wn.brnid = k.brnid and wn.whsno = k.whsno
  left join public.erp_warehouses ew on ew.brnid = k.brnid and ew.whsno = k.whsno
$$;
revoke execute on function public.sales_daily(date) from public, anon;
grant execute on function public.sales_daily(date) to authenticated;

-- Mark / unmark a branch-day as reviewed (admin only).
create or replace function public.set_day_review(p_brnid text, p_whsno text, p_day date, p_reviewed boolean, p_note text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  if p_reviewed then
    insert into public.sales_day_reviews (brnid, whsno, day, reviewed_by, reviewed_at, note)
    values (p_brnid, p_whsno, p_day, auth.uid(), now(), nullif(btrim(p_note), ''))
    on conflict (brnid, whsno, day) do update set reviewed_by = excluded.reviewed_by, reviewed_at = now(), note = excluded.note;
  else
    delete from public.sales_day_reviews where brnid = p_brnid and whsno = p_whsno and day = p_day;
  end if;
end $$;
revoke execute on function public.set_day_review(text, text, date, boolean, text) from public, anon;
grant execute on function public.set_day_review(text, text, date, boolean, text) to authenticated;

-- ============================================================
-- SISTEM ELQUIRAZH ADV — SUPABASE DATABASE SCHEMA
-- Turunan dari struktur aplikasi v13 yang sudah LOCK.
-- Tahap: database pusat, belum mengubah rumus HPP.
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- ENUMS ----------
do $$ begin
  create type public.order_status as enum ('Baru','Produksi','Selesai');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.payment_status as enum ('Belum bayar','DP 50%','Lunas');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.production_status as enum ('Menunggu Produksi','Produksi','Selesai');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.priority_status as enum ('Normal','Tinggi','Urgent');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.transaction_type as enum ('Masuk','Keluar');
exception when duplicate_object then null; end $$;

-- ---------- COMMON ----------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------- MASTER BAHAN ----------
create table if not exists public.materials (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  size text,
  unit text not null default 'meter',
  stock numeric(14,4) not null default 0,
  used numeric(14,4) not null default 0,
  min_stock numeric(14,4) not null default 0,
  price numeric(14,2) not null default 0,
  roll_price numeric(14,2) not null default 0,
  roll_length numeric(14,4) not null default 0,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint materials_stock_nonnegative check (stock >= 0),
  constraint materials_used_nonnegative check (used >= 0),
  constraint materials_min_nonnegative check (min_stock >= 0)
);

-- Mesin/proses yang boleh menggunakan material.
create table if not exists public.material_processes (
  material_id uuid not null references public.materials(id) on delete cascade,
  process text not null,
  primary key (material_id, process)
);

-- Sisa dan status dibuat sebagai view agar tidak disimpan ganda.
create or replace view public.material_stock_view as
select
  m.*,
  greatest(m.stock - m.used, 0) as remaining_stock,
  case
    when greatest(m.stock - m.used, 0) <= m.min_stock then 'Kritis'
    when greatest(m.stock - m.used, 0) <= m.min_stock * 1.5 then 'Menipis'
    else 'Aman'
  end as stock_status
from public.materials m;

create trigger trg_materials_updated_at
before update on public.materials
for each row execute function public.set_updated_at();

-- ---------- ORDER ----------
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_no text not null unique,
  customer text not null,
  phone text,
  product text,
  value numeric(14,2) not null default 0,
  hpp numeric(14,2) not null default 0,
  payment payment_status not null default 'Belum bayar',
  status order_status not null default 'Baru',
  note text,
  discount numeric(14,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  created_by uuid references auth.users(id)
);

create index if not exists idx_orders_status on public.orders(status);
create index if not exists idx_orders_payment on public.orders(payment);
create index if not exists idx_orders_created_at on public.orders(created_at desc);

create trigger trg_orders_updated_at
before update on public.orders
for each row execute function public.set_updated_at();

-- ---------- ORDER ITEMS / HASIL HPP ----------
-- raw_hpp disimpan agar detail hasil HPP tidak hilang saat migrasi.
-- Rumus HPP tetap berada di aplikasi HPP; database hanya menyimpan hasilnya.
create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  item_no integer not null default 1,
  name text not null default 'Pekerjaan',
  process text,
  process_label text,
  machine text,
  material text,
  material_id uuid references public.materials(id) on delete set null,
  size text,
  qty numeric(14,4) not null default 1,
  unit text default 'pcs',
  harga_per_unit numeric(14,2) not null default 0,
  harga_jual numeric(14,2) not null default 0,
  total_hpp numeric(14,2) not null default 0,
  area_cm2_per_pc numeric(16,4),
  area_cm2_total numeric(16,4),
  estimated_usage numeric(14,4),
  raw_hpp jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(order_id, item_no)
);

create index if not exists idx_order_items_order on public.order_items(order_id);
create index if not exists idx_order_items_material on public.order_items(material_id);

-- ---------- QUEUE PRODUKSI ----------
create table if not exists public.production_queue (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  order_item_id uuid references public.order_items(id) on delete set null,
  order_no text,
  customer text,
  job text,
  process text,
  material text,
  material_id uuid references public.materials(id) on delete set null,
  size text,
  qty numeric(14,4) not null default 1,
  status production_status not null default 'Menunggu Produksi',
  priority priority_status not null default 'Normal',
  hpp numeric(14,2) not null default 0,
  value numeric(14,2) not null default 0,
  estimated_usage numeric(14,4) not null default 0,
  actual_usage numeric(14,4) not null default 0,
  actual_usage_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_production_order on public.production_queue(order_id);
create index if not exists idx_production_status on public.production_queue(status);
create index if not exists idx_production_material on public.production_queue(material_id);

create trigger trg_production_updated_at
before update on public.production_queue
for each row execute function public.set_updated_at();

-- ---------- PEMAKAIAN BAHAN / AUDIT STOK ----------
-- Ini penting supaya pengurangan stok tidak hanya berupa angka akhir.
create table if not exists public.material_usage (
  id uuid primary key default gen_random_uuid(),
  material_id uuid not null references public.materials(id) on delete restrict,
  order_id uuid references public.orders(id) on delete set null,
  order_item_id uuid references public.order_items(id) on delete set null,
  production_id uuid references public.production_queue(id) on delete set null,
  usage_type text not null default 'Produksi',
  estimated_usage numeric(14,4) not null default 0,
  actual_usage numeric(14,4) not null,
  unit text not null,
  note text,
  used_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  constraint material_usage_positive check (actual_usage > 0)
);

create index if not exists idx_material_usage_material on public.material_usage(material_id);
create index if not exists idx_material_usage_order on public.material_usage(order_id);
create index if not exists idx_material_usage_used_at on public.material_usage(used_at desc);

-- ---------- PEMBELIAN / RIWAYAT HARGA MATERIAL ----------
-- Harga aktif tetap di materials.price.
-- Tabel ini menjaga histori harga supaya order lama tidak berubah.
create table if not exists public.material_purchases (
  id uuid primary key default gen_random_uuid(),
  material_id uuid not null references public.materials(id) on delete restrict,
  purchase_date date not null default current_date,
  quantity numeric(14,4) not null default 0,
  unit text not null default 'meter',
  price_per_unit numeric(14,2) not null default 0,
  roll_price numeric(14,2) not null default 0,
  roll_length numeric(14,4) not null default 0,
  supplier text,
  purchase_note text,
  source_note text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id)
);

create index if not exists idx_material_purchases_material_date
on public.material_purchases(material_id, purchase_date desc);

-- ---------- KEUANGAN ----------
create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  type transaction_type not null,
  category text not null default 'Lain-lain',
  value numeric(14,2) not null default 0,
  transaction_date date not null default current_date,
  note text,
  source text,
  order_id uuid references public.orders(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  constraint transactions_value_nonnegative check (value >= 0)
);

create index if not exists idx_transactions_date on public.transactions(transaction_date desc);
create index if not exists idx_transactions_type on public.transactions(type);
create index if not exists idx_transactions_order on public.transactions(order_id);

create trigger trg_transactions_updated_at
before update on public.transactions
for each row execute function public.set_updated_at();

-- ---------- RIWAYAT ORDER ----------
-- Queue selesai tidak perlu menyimpan salinan order.
-- Riwayat menunjuk ke order yang sama agar nota dan pembayaran tetap konsisten.
create table if not exists public.order_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  completed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique(order_id)
);

create index if not exists idx_order_history_completed
on public.order_history(completed_at desc);

-- ---------- PENGATURAN SISTEM ----------
create table if not exists public.system_settings (
  id uuid primary key default gen_random_uuid(),
  business_name text not null default 'Elquirazh ADV',
  system_title text not null default 'Sistem Elquirazh ADV',
  tagline text default 'Digital Printing • Advertising • Production System',
  owner text,
  phone text,
  address text,
  email text,
  greeting text default 'Selamat datang',
  dashboard_note text default 'Pantau operasional usaha dari satu sistem.',
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

create trigger trg_system_settings_updated_at
before update on public.system_settings
for each row execute function public.set_updated_at();

-- ---------- PENGATURAN NOTA ----------
create table if not exists public.note_settings (
  id uuid primary key default gen_random_uuid(),
  title text not null default 'INVOICE',
  subtitle text not null default 'NOTA TAGIHAN',
  tagline text default 'PERCETAKAN & DIGITAL PRINTING',
  show_process boolean not null default true,
  show_material boolean not null default true,
  show_size boolean not null default true,
  show_machine boolean not null default true,
  show_qty boolean not null default true,
  show_unit boolean not null default true,
  show_unit_price boolean not null default true,
  show_subtotal boolean not null default true,
  show_discount boolean not null default false,
  show_payment boolean not null default true,
  show_remaining boolean not null default true,
  show_note boolean not null default true,
  note_text text default 'Terima kasih atas kepercayaan Anda.',
  show_address boolean not null default true,
  show_phone boolean not null default true,
  show_email boolean not null default true,
  show_footer boolean not null default true,
  footer_text text default 'Percetakan • Digital Printing • Sticker • Banner • Advertising',
  watermark boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

create trigger trg_note_settings_updated_at
before update on public.note_settings
for each row execute function public.set_updated_at();

-- ---------- VIEW OPERASIONAL ----------
create or replace view public.order_operational_view as
select
  o.*,
  coalesce(sum(oi.harga_jual),0) as calculated_item_total,
  count(oi.id) as item_count,
  count(pq.id) filter (where pq.status <> 'Selesai') as active_production_count
from public.orders o
left join public.order_items oi on oi.order_id = o.id
left join public.production_queue pq on pq.order_id = o.id
group by o.id;

create or replace view public.finance_summary_view as
select
  coalesce(sum(value) filter (where type='Masuk'),0) as total_income,
  coalesce(sum(value) filter (where type='Keluar'),0) as total_expense,
  coalesce(sum(value) filter (where type='Masuk'),0)
    - coalesce(sum(value) filter (where type='Keluar'),0) as net_cash
from public.transactions;

-- ---------- STOCK UPDATE FUNCTION ----------
-- Dipanggil aplikasi saat produksi benar-benar selesai.
-- Mengurangi/menambah "used" berdasarkan pemakaian aktual dan membuat audit log.
create or replace function public.record_material_usage(
  p_material_id uuid,
  p_actual_usage numeric,
  p_order_id uuid default null,
  p_order_item_id uuid default null,
  p_production_id uuid default null,
  p_estimated_usage numeric default 0,
  p_note text default null
)
returns public.material_usage
language plpgsql
security invoker
as $$
declare
  m public.materials;
  u public.material_usage;
begin
  if p_actual_usage is null or p_actual_usage <= 0 then
    raise exception 'Pemakaian bahan harus lebih dari 0';
  end if;

  select * into m
  from public.materials
  where id = p_material_id
  for update;

  if not found then
    raise exception 'Material tidak ditemukan';
  end if;

  insert into public.material_usage(
    material_id, order_id, order_item_id, production_id,
    estimated_usage, actual_usage, unit, note
  )
  values(
    p_material_id, p_order_id, p_order_item_id, p_production_id,
    coalesce(p_estimated_usage,0), p_actual_usage, m.unit, p_note
  )
  returning * into u;

  update public.materials
  set used = coalesce(used,0) + p_actual_usage
  where id = p_material_id;

  return u;
end;
$$;

-- ---------- BASIC RLS ----------
-- Aktifkan RLS. Untuk tahap web dengan Supabase Auth,
-- user yang login dapat membaca/menulis data aplikasi.
alter table public.materials enable row level security;
alter table public.material_processes enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.production_queue enable row level security;
alter table public.material_usage enable row level security;
alter table public.material_purchases enable row level security;
alter table public.transactions enable row level security;
alter table public.order_history enable row level security;
alter table public.system_settings enable row level security;
alter table public.note_settings enable row level security;

-- Helper policy creator. Drop first so schema can be re-run safely.
do $$
declare
  t text;
begin
  foreach t in array array[
    'materials','material_processes','orders','order_items',
    'production_queue','material_usage','material_purchases',
    'transactions','order_history','system_settings','note_settings'
  ] loop
    execute format('drop policy if exists "authenticated full access" on public.%I', t);
    execute format(
      'create policy "authenticated full access" on public.%I
       for all to authenticated
       using (true) with check (true)', t
    );
  end loop;
end $$;

-- ---------- INITIAL SETTINGS ROWS ----------
insert into public.system_settings (business_name, system_title)
select 'Elquirazh ADV', 'Sistem Elquirazh ADV'
where not exists (select 1 from public.system_settings);

insert into public.note_settings
select
  gen_random_uuid(),
  'INVOICE',
  'NOTA TAGIHAN',
  'PERCETAKAN & DIGITAL PRINTING',
  true,true,true,true,true,true,true,true,
  false,true,true,true,
  'Terima kasih atas kepercayaan Anda.',
  true,true,true,true,
  'Percetakan • Digital Printing • Sticker • Banner • Advertising',
  false,now(),null
where not exists (select 1 from public.note_settings);

-- ============================================================
-- CATATAN MIGRASI
-- ============================================================
-- 1. HPP TIDAK dihitung di SQL. Rumus HPP tetap di aplikasi.
-- 2. order_items.raw_hpp menyimpan hasil/detail HPP agar tidak hilang.
-- 3. materials.stock adalah stok masuk/acuan stok yang disimpan sistem.
-- 4. materials.used adalah akumulasi bahan terpakai.
-- 5. remaining_stock dan stock_status berasal dari material_stock_view.
-- 6. material_usage menjadi audit trail pemakaian bahan.
-- 7. Untuk produksi selesai, aplikasi sebaiknya memanggil
--    record_material_usage(...) satu kali untuk setiap material.
-- 8. Order lama menyimpan harga jual/HPP pada order_items, sehingga
--    perubahan Master Bahan tidak mengubah transaksi lama.
-- 9. RLS saat ini mengizinkan user yang sudah login (authenticated)
--    untuk mengakses data. Hak akses admin/operator dapat diperketat
--    pada tahap auth/role berikutnya.

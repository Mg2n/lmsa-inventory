export type Role = "admin" | "staff" | "pending";

export interface Profile {
  id: string;
  email: string | null;
  full_name: string | null;
  role: Role;
  created_at?: string;
}

export interface ProductLocation {
  location_id: string;
  code: string;
  description: string | null;
  qty: number;
  updated_at: string;
}

export interface ProductBarcode {
  barcode: string;
  unit_name: string | null;
  unit_factor: number | null;
  unit_price: number | null;
}

/** Shape returned by private.product_json (lookup + location RPCs). */
export interface Product {
  brnid: string;
  itmcode: string;
  name_ar: string | null;
  name_en: string | null;
  category: string | null;
  subcategory: string | null;
  sale_price: number | null;
  reorder_level: number | null;
  is_active: boolean;
  is_stopped: boolean;
  total_qty: number;
  reserved_qty: number;
  located_qty: number;
  locations: ProductLocation[];
  barcodes: ProductBarcode[];
  negative_stock: boolean;
  mismatch: boolean;
  synced_at: string;
}

export interface SyncRun {
  id: number;
  started_at: string;
  finished_at: string | null;
  status: "running" | "ok" | "error" | "abandoned";
  full_sync: boolean;
  agent_version: string | null;
  host: string | null;
  rows_read: Record<string, number>;
  rows_upserted: Record<string, number>;
  rows_deleted: Record<string, unknown>;
  duration_ms: number | null;
  error_message: string | null;
}

export interface LastSync {
  last_ok_at: string | null;
  last_run: SyncRun | null;
}

export interface LookupResult {
  found: boolean;
  matched_by: "barcode" | "itmcode" | null;
  code_norm: string | null;
  products: Product[];
  last_sync: LastSync | null;
}

/** Row of public.v_products / search_products(). */
export interface ProductRow {
  brnid: string;
  itmcode: string;
  name_ar: string | null;
  name_en: string | null;
  category: string | null;
  subcategory: string | null;
  sale_price: number | null;
  reorder_level: number | null;
  is_active: boolean;
  is_stopped: boolean;
  total_qty: number;
  reserved_qty: number;
  located_qty: number;
  location_count: number;
  location_codes: string | null;
  barcode: string | null;
  no_location: boolean;
  negative_stock: boolean;
  below_reorder: boolean;
  mismatch: boolean;
}

export interface Location {
  id: string;
  code: string;
  zone: string | null;
  aisle: string | null;
  shelf: string | null;
  bin: string | null;
  description: string | null;
  is_active: boolean;
}

export interface StockRow {
  brnid: string;
  itmcode: string;
  whsno: string;
  batchno: string;
  beginqty: number;
  purchqty: number;
  saleqty: number;
  purchrtn: number;
  salertn: number;
  inqty: number;
  outqty: number;
  reserved_qty: number;
  qty_computed: number;
}

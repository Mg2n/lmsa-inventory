import {
  CalendarCheck,
  ClipboardCheck,
  LayoutGrid,
  MapPin,
  Receipt,
  RefreshCw,
  ScanLine,
  Users,
  type LucideIcon,
} from "lucide-react";

export interface NavItem {
  href: string;
  label: string;
  short: string; // label for the phone tab bar
  icon: LucideIcon;
  admin?: boolean;
  /** shown in the phone tab bar (others live under "More") */
  tab?: boolean;
}

export const NAV: NavItem[] = [
  { href: "/dashboard/", label: "الأصناف", short: "الأصناف", icon: LayoutGrid, tab: true },
  { href: "/dashboard/locations/", label: "المواقع والملصقات", short: "المواقع", icon: MapPin, tab: true },
  { href: "/dashboard/daily/", label: "المراجعة اليومية", short: "اليومية", icon: CalendarCheck, admin: true, tab: true },
  { href: "/dashboard/sales/", label: "سجل المبيعات", short: "المبيعات", icon: Receipt, admin: true, tab: true },
  { href: "/dashboard/sync/", label: "المزامنة", short: "المزامنة", icon: RefreshCw },
  { href: "/dashboard/check/", label: "مطابقة الكمية", short: "المطابقة", icon: ClipboardCheck },
  { href: "/dashboard/users/", label: "المستخدمون", short: "المستخدمون", icon: Users, admin: true },
];

export const SCANNER_LINK = { href: "/scan/", label: "الماسح", icon: ScanLine };

export const visibleNav = (isAdmin: boolean) => NAV.filter((n) => !n.admin || isAdmin);

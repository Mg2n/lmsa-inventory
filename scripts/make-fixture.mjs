// Generates sample data shaped exactly like the Spark Tech tables
// (same table + column names, same quirks) -> supabase/fixtures/spark_sample.json
// Usage: node scripts/make-fixture.mjs
import { writeFileSync } from "node:fs";

const BRN = 1;
const WHS = 1;
const kinds = [
  ["قميص رجالي قطن", "Men cotton shirt", "رجالي", "قمصان", 89],
  ["بنطلون جينز", "Jeans trousers", "رجالي", "بناطيل", 129],
  ["فستان سهرة", "Evening dress", "نسائي", "فساتين", 349],
  ["عباية سوداء", "Black abaya", "نسائي", "عبايات", 259],
  ["تيشيرت أطفال", "Kids T-shirt", "أطفال", "تيشيرتات", 39],
  ["ثوب رجالي", "Men thobe", "رجالي", "ثياب", 199],
  ["شماغ أحمر", "Red shemagh", "رجالي", "إكسسوارات", 149],
  ["جاكيت شتوي", "Winter jacket", "رجالي", "جاكيتات", 299],
  ["بيجامة نسائية", "Women pyjama", "نسائي", "ملابس نوم", 119],
  ["جوارب قطن", "Cotton socks", "عام", "إكسسوارات", 15],
];
const sizes = ["S", "M", "L", "XL"];
const suffixes = ["Tr", "la", "Sw", "Ch", "Tk"];

const ITEMES = [], ITMUNIT = [], ITEMSMASTER = [];
let n = 0;
for (const [ar, en, cat, sub, price] of kinds) {
  for (const size of sizes) {
    n++;
    const code = String(10000 + n * 7);
    ITEMES.push({
      BRNID: BRN, ITMCODE: code, ITMDESC: `${ar} مقاس ${size}`, ITMLATIN: `${en} ${size}`,
      ITMCAT: cat, ITMSUBCAT: sub, ITMGROUP: "1", SALEPRICE: price, REORDER: n % 5 === 0 ? 5 : 0,
      ITMSTOP: false, ACTIVATE: true,
    });
    // store's own printed codes: digits + supplier suffix
    const barcode = `0${String(n).padStart(2, "0")}00${String(n * 3).padStart(2, "0")}${suffixes[n % suffixes.length]}`;
    ITMUNIT.push({ BRNID: BRN, ITMCODE: code, UNITCODE: 1, BARCODE: barcode, UNITNAME: "حبة", UFACT: 1, UNITPRICE: price });
    // 6 ITEMSMASTER rows per item; opening qty sits in one, a few sales in another
    for (let b = 0; b < 6; b++) {
      ITEMSMASTER.push({
        BRNID: BRN, ITMCODE: code, WHSNO: WHS, BATCHNO: b === 0 ? "" : String(b),
        BEGINQTY: b === 0 ? (n * 3) % 25 + 2 : 0, PURCHQTY: 0, SALEQTY: b === 1 ? n % 4 : 0,
        PURCHRTN: 0, SALERTN: b === 1 && n % 6 === 0 ? 1 : 0, INQTY: 0, OUTQTY: 0,
        RESERVQTY: n % 9 === 0 ? 1 : 0, LOCATION: "",
      });
    }
  }
}

// --- the quirks seen in the real data ---
function addItem(code, name, price, barcode, beginqty, saleqty, extra = {}) {
  ITEMES.push({ BRNID: BRN, ITMCODE: code, ITMDESC: name, ITMLATIN: null, ITMCAT: "عام", ITMSUBCAT: null,
    ITMGROUP: "1", SALEPRICE: price, REORDER: 0, ITMSTOP: false, ACTIVATE: true, ...extra });
  ITMUNIT.push({ BRNID: BRN, ITMCODE: code, UNITCODE: 1, BARCODE: barcode, UNITNAME: "حبة", UFACT: 1, UNITPRICE: price });
  for (let b = 0; b < 6; b++) {
    ITEMSMASTER.push({ BRNID: BRN, ITMCODE: code, WHSNO: WHS, BATCHNO: b === 0 ? "" : String(b),
      BEGINQTY: b === 0 ? beginqty : 0, PURCHQTY: 0, SALEQTY: b === 0 ? saleqty : 0, PURCHRTN: 0,
      SALERTN: 0, INQTY: 0, OUTQTY: 0, RESERVQTY: 0, LOCATION: "" });
  }
}
// examples quoted from the real data
addItem("90001", "بلوزة نسائية", 79, "010014Tr", 12, 2);
addItem("90002", "تنورة طويلة", 99, "0900044la", 6, 0);
addItem("90003", "سويتشيرت", 139, "07801100013Sw", 9, 1);
// standard EAN-13 (one of ~10 in the store)
addItem("90004", "حزام جلد", 59, "6281234567892", 20, 3);
// generic "various clothes" with negative stock
addItem("90005", "ملابس منوعه", 25, "999", 0, 7);
// zero stock generic
addItem("90006", "ملابس منوعه اطفال", 15, "998", 0, 0);
// leading spaces, 29 characters long
addItem("90007", "شنطة يد", 179, "     ABC1234567890123456789XY", 4, 0);
// empty barcode (must be skipped)
addItem("90008", "منديل قماش", 10, "", 30, 0);
// duplicate barcode used by two items
addItem("90009", "قبعة صيفية", 45, "010014tr", 5, 0);
// item code with trailing spaces like CHAR columns, stopped item
addItem("90010  ", "طقم أطفال (موقوف)", 89, "0500077Ch", 3, 0, { ITMSTOP: true });

const WAREHOUSES = [{ WHSNO: WHS, BRNID: BRN, WHSNAME: "المستودع الرئيسي" }];

const out = { generated_for: "Spark Tech sample (fake data)", ITEMES, ITMUNIT, ITEMSMASTER, WAREHOUSES };
writeFileSync(new URL("../supabase/fixtures/spark_sample.json", import.meta.url), JSON.stringify(out, null, 1));
console.log(`ITEMES ${ITEMES.length}, ITMUNIT ${ITMUNIT.length}, ITEMSMASTER ${ITEMSMASTER.length}`);

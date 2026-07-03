/**
 * Seed data for GV Mart — one org, one login per role, realistic Chennai-area
 * catalog/customer data. Pure data only (no Supabase calls) so it can be
 * imported by both the real seed script and test harnesses.
 *
 * v2.2 compliance: every product/spare gets min_stock=10, reorder_qty=10
 * (Design Deltas §A.1). No incentive/salary rates are seeded — those stay
 * admin-set via the Masters UI (v2.2: "no fixed ₹ figures").
 */

export const SEED_PASSWORD = "GvMart@2026"

export const ORG = { name: "GV Mart", gst_no: "33AAAAA0000A1Z5" }

export const ROLE_USERS = [
  { email: "master@gvmart.test", role: "master", full_name: "Ramesh Kumar", phone: "9840011111" },
  { email: "operation_admin@gvmart.test", role: "operation_admin", full_name: "Suresh Babu", phone: "9840022222" },
  { email: "sales_admin@gvmart.test", role: "sales_admin", full_name: "Priya Dharshini", phone: "9840033333" },
  { email: "technician@gvmart.test", role: "technician", full_name: "Karthik Raja", phone: "9840044444" },
  { email: "customer@gvmart.test", role: "customer", full_name: "Lakshmi Priya", phone: "9840055555" },
] as const

export const TECHNICIAN_SKILLS = ["ro", "ac"]

export const BRANDS = [
  { name: "Voltas", category: "ac" },
  { name: "Blue Star", category: "ac" },
  { name: "Exide", category: "battery" },
  { name: "Amaron", category: "battery" },
  { name: "Luminous", category: "inverter" },
  { name: "Kent", category: "ro" },
  { name: "Aquaguard", category: "ro" },
  { name: "Livpure", category: "ro" },
] as const

export const MODELS = [
  { brand: "Voltas", name: "183V Vectra Elite", type: "split" },
  { brand: "Voltas", name: "182 DZA", type: "window" },
  { brand: "Voltas", name: "243V CZP", type: "split" },
  { brand: "Blue Star", name: "5W12GA", type: "window" },
  { brand: "Blue Star", name: "IC518DNU", type: "split" },
  { brand: "Blue Star", name: "IC312YNU", type: "split" },
  { brand: "Exide", name: "InvaMaster IMTT1500", type: "inverter_battery" },
  { brand: "Exide", name: "InstaBrite IB1000", type: "inverter_battery" },
  { brand: "Amaron", name: "Current AAM-CR-N150", type: "inverter_battery" },
  { brand: "Luminous", name: "Zolt 1100", type: "inverter_unit" },
  { brand: "Luminous", name: "ILTT18048", type: "inverter_battery" },
  { brand: "Kent", name: "Grand Plus", type: "domestic" },
  { brand: "Kent", name: "Supreme", type: "domestic" },
  { brand: "Aquaguard", name: "Enhance RO+UV+UF", type: "domestic" },
  { brand: "Livpure", name: "Glo Star RO+UV", type: "domestic" },
] as const

// brand/model must match an entry above; category matches the brand's category
export const PRODUCTS = [
  { brand: "Voltas", model: "183V Vectra Elite", name: "Voltas 1.5T Split AC (183V Vectra Elite)", category: "ac", price: 34990, hsn_code: "8415" },
  { brand: "Voltas", model: "182 DZA", name: "Voltas 1.5T Window AC (182 DZA)", category: "ac", price: 28490, hsn_code: "8415" },
  { brand: "Voltas", model: "243V CZP", name: "Voltas 2T Split AC (243V CZP)", category: "ac", price: 41990, hsn_code: "8415" },
  { brand: "Blue Star", model: "5W12GA", name: "Blue Star 1T Window AC (5W12GA)", category: "ac", price: 26990, hsn_code: "8415" },
  { brand: "Blue Star", model: "IC518DNU", name: "Blue Star 1.5T Split AC (IC518DNU)", category: "ac", price: 35990, hsn_code: "8415" },
  { brand: "Blue Star", model: "IC312YNU", name: "Blue Star 1T Split AC (IC312YNU)", category: "ac", price: 31490, hsn_code: "8415" },
  { brand: "Exide", model: "InvaMaster IMTT1500", name: "Exide InvaMaster 150Ah Tall Tubular Battery", category: "battery", price: 14200, hsn_code: "8507" },
  { brand: "Exide", model: "InstaBrite IB1000", name: "Exide InstaBrite 100Ah Battery", category: "battery", price: 9800, hsn_code: "8507" },
  { brand: "Amaron", model: "Current AAM-CR-N150", name: "Amaron Current 150Ah Battery", category: "battery", price: 13800, hsn_code: "8507" },
  { brand: "Luminous", model: "Zolt 1100", name: "Luminous Zolt 1100 Inverter", category: "inverter", price: 8500, hsn_code: "8504" },
  { brand: "Luminous", model: "ILTT18048", name: "Luminous ILTT18048 Tall Tubular Battery (150Ah)", category: "inverter", price: 13990, hsn_code: "8507" },
  { brand: "Kent", model: "Grand Plus", name: "Kent Grand Plus RO", category: "ro", price: 16500, hsn_code: "8421" },
  { brand: "Kent", model: "Supreme", name: "Kent Supreme RO", category: "ro", price: 13999, hsn_code: "8421" },
  { brand: "Aquaguard", model: "Enhance RO+UV+UF", name: "Aquaguard Enhance RO+UV+UF", category: "ro", price: 15990, hsn_code: "8421" },
  { brand: "Livpure", model: "Glo Star RO+UV", name: "Livpure Glo Star RO+UV", category: "ro", price: 11499, hsn_code: "8421" },
] as const

export const SPARES = [
  { name: "Sediment Filter (RO)", sku: "SP-RO-SED-01", price: 150, hsn_code: "8421" },
  { name: "Pre-Carbon Filter (RO)", sku: "SP-RO-PCF-01", price: 180, hsn_code: "8421" },
  { name: "Post-Carbon Filter (RO)", sku: "SP-RO-POC-01", price: 200, hsn_code: "8421" },
  { name: "RO Membrane 75 GPD", sku: "SP-RO-MEM-75", price: 950, hsn_code: "8421" },
  { name: "UV Lamp", sku: "SP-RO-UVL-01", price: 450, hsn_code: "8421" },
  { name: "UF Membrane", sku: "SP-RO-UFM-01", price: 700, hsn_code: "8421" },
  { name: "Solenoid Valve", sku: "SP-RO-SOL-01", price: 220, hsn_code: "8421" },
  { name: "Booster Pump", sku: "SP-RO-PMP-01", price: 1100, hsn_code: "8421" },
  { name: "SMPS Adapter 24V", sku: "SP-RO-ADP-24", price: 550, hsn_code: "8504" },
  { name: "TDS Controller", sku: "SP-RO-TDS-01", price: 380, hsn_code: "8421" },
  { name: "Float Valve", sku: "SP-RO-FLV-01", price: 120, hsn_code: "8421" },
  { name: "Storage Tank 8L", sku: "SP-RO-TNK-08", price: 900, hsn_code: "8421" },
  { name: "Non-Return Valve (NRV)", sku: "SP-RO-NRV-01", price: 90, hsn_code: "8421" },
  { name: "AC Compressor Capacitor", sku: "SP-AC-CAP-01", price: 320, hsn_code: "8415" },
  { name: "AC Cooling Coil", sku: "SP-AC-COIL-01", price: 2800, hsn_code: "8415" },
  { name: "AC PCB Board", sku: "SP-AC-PCB-01", price: 1850, hsn_code: "8415" },
  { name: "AC Remote Control", sku: "SP-AC-REM-01", price: 450, hsn_code: "8415" },
  { name: "Gas Refill Can R32 (1kg)", sku: "SP-AC-GAS-R32", price: 650, hsn_code: "2903" },
  { name: "Battery Terminal Connector", sku: "SP-BT-CON-01", price: 80, hsn_code: "8507" },
  { name: "Inverter Fuse", sku: "SP-INV-FUS-01", price: 60, hsn_code: "8536" },
] as const

// v2.2 Design Deltas §A.1: min stock = 10, reorder qty = 10 for every item.
export const DEFAULT_MIN_STOCK = 10
export const DEFAULT_REORDER_QTY = 10

// Deliberately realistic and uneven — a few items sit below min_stock so the
// Low/Out-of-stock states have real demo data once Inventory (ADM-18) ships.
export const PRODUCT_STOCK = [42, 18, 9, 25, 15, 6, 30, 22, 27, 40, 12, 20, 24, 16, 33]
export const SPARE_STOCK = [65, 58, 60, 14, 20, 11, 45, 8, 30, 25, 50, 12, 70, 18, 4, 6, 22, 15, 90, 120]

export const SUPPLIERS = [
  { name: "Chennai Electro Traders", contact: "044-28451122", whatsapp: "9884011001", rating: 4.5 },
  { name: "Sri Ram Cooling Spares", contact: "044-26541234", whatsapp: "9884022002", rating: 4.2 },
]

// Chennai areas with approximate centroid lat/lng and PIN codes.
export const CHENNAI_AREAS = [
  { area: "T. Nagar", pincode: "600017", lat: 13.0418, lng: 80.2341 },
  { area: "Anna Nagar", pincode: "600040", lat: 13.085, lng: 80.2101 },
  { area: "Adyar", pincode: "600020", lat: 13.0012, lng: 80.2565 },
  { area: "Velachery", pincode: "600042", lat: 12.9756, lng: 80.2207 },
  { area: "Mylapore", pincode: "600004", lat: 13.0339, lng: 80.2619 },
  { area: "Porur", pincode: "600116", lat: 13.0381, lng: 80.1564 },
  { area: "Tambaram", pincode: "600045", lat: 12.9249, lng: 80.1 },
  { area: "Chromepet", pincode: "600044", lat: 12.9516, lng: 80.1462 },
  { area: "Ambattur", pincode: "600053", lat: 13.1143, lng: 80.1548 },
  { area: "Kodambakkam", pincode: "600024", lat: 13.0524, lng: 80.2233 },
  { area: "Nungambakkam", pincode: "600034", lat: 13.0569, lng: 80.2425 },
  { area: "Guindy", pincode: "600032", lat: 13.0067, lng: 80.2206 },
  { area: "Perambur", pincode: "600011", lat: 13.1179, lng: 80.25 },
  { area: "Vadapalani", pincode: "600026", lat: 13.0503, lng: 80.2121 },
  { area: "Thiruvanmiyur", pincode: "600041", lat: 12.983, lng: 80.2593 },
  { area: "Royapettah", pincode: "600014", lat: 13.0559, lng: 80.2649 },
  { area: "Egmore", pincode: "600008", lat: 13.0732, lng: 80.2609 },
  { area: "Saidapet", pincode: "600015", lat: 13.0206, lng: 80.2226 },
  { area: "Alwarpet", pincode: "600018", lat: 13.0343, lng: 80.2543 },
  { area: "West Mambalam", pincode: "600033", lat: 13.0389, lng: 80.2183 },
  { area: "K.K. Nagar", pincode: "600078", lat: 13.0378, lng: 80.1998 },
  { area: "Virugambakkam", pincode: "600092", lat: 13.0559, lng: 80.1889 },
  { area: "Pallavaram", pincode: "600043", lat: 12.9675, lng: 80.1491 },
  { area: "Selaiyur", pincode: "600073", lat: 12.9139, lng: 80.1466 },
  { area: "Medavakkam", pincode: "600100", lat: 12.9186, lng: 80.1878 },
] as const

// 25 realistic Chennai customers. #0 is the seeded `customer` login (linked
// to its profile); #1-24 are walk-in customers with no app login yet.
export const CUSTOMERS = [
  { name: "Lakshmi Priya", mobile: "9840055555", profession: "Homemaker", areaIdx: 0, door: "12", street: "Thyagaraya Street" },
  { name: "Muthu Kumar", mobile: "9884012345", profession: "Auto Driver", areaIdx: 1, door: "45B", street: "2nd Avenue" },
  { name: "Kavitha Rani", mobile: "9940023456", profession: "Teacher", areaIdx: 2, door: "7", street: "Gandhi Nagar Main Road" },
  { name: "Senthil Nathan", mobile: "8925034567", profession: "Software Engineer", areaIdx: 3, door: "23", street: "Vijayanagar 1st Street" },
  { name: "Deepa Lakshmi", mobile: "9840145678", profession: "Bank Employee", areaIdx: 4, door: "9", street: "Luz Church Road" },
  { name: "Raja Mohan", mobile: "9884156789", profession: "Shop Owner", areaIdx: 5, door: "56", street: "Kumaran Nagar" },
  { name: "Anitha Devi", mobile: "9940267890", profession: "Retired", areaIdx: 6, door: "18A", street: "GST Road" },
  { name: "Vijay Anand", mobile: "8925378901", profession: "Businessman", areaIdx: 7, door: "31", street: "Anna Salai Cross" },
  { name: "Meena Kumari", mobile: "9840389012", profession: "Homemaker", areaIdx: 8, door: "5", street: "Thirumangalam Road" },
  { name: "Prakash Raj", mobile: "9884490123", profession: "Government Employee", areaIdx: 9, door: "62", street: "Arcot Road" },
  { name: "Saranya Devi", mobile: "9940501234", profession: "Doctor", areaIdx: 10, door: "14", street: "Khader Nawaz Khan Road" },
  { name: "Elango Perumal", mobile: "8925612345", profession: "Auto Driver", areaIdx: 11, door: "27B", street: "Mount Poonamallee Road" },
  { name: "Divya Bharathi", mobile: "9840723456", profession: "Teacher", areaIdx: 12, door: "8", street: "Paper Mills Road" },
  { name: "Gopinath Raman", mobile: "9884834567", profession: "Shop Owner", areaIdx: 13, door: "41", street: "Vadapalani Bus Depot Road" },
  { name: "Revathi Sundaram", mobile: "9940945678", profession: "Homemaker", areaIdx: 14, door: "16", street: "Kalakshetra Road" },
  { name: "Bala Murugan", mobile: "8925056789", profession: "Businessman", areaIdx: 15, door: "3", street: "Royapettah High Road" },
  { name: "Nithya Shree", mobile: "9840167890", profession: "Software Engineer", areaIdx: 16, door: "52", street: "Pantheon Road" },
  { name: "Arun Prasad", mobile: "9884278901", profession: "Bank Employee", areaIdx: 17, door: "19", street: "Anna Salai" },
  { name: "Kalaivani Selvam", mobile: "9940389012", profession: "Retired", areaIdx: 18, door: "11", street: "TTK Road" },
  { name: "Sivakumar Pillai", mobile: "8925490123", profession: "Auto Driver", areaIdx: 19, door: "34", street: "Duraisamy Road" },
  { name: "Uma Maheswari", mobile: "9840501235", profession: "Homemaker", areaIdx: 20, door: "6", street: "Nateson Nagar" },
  { name: "Dinesh Kannan", mobile: "9884612346", profession: "Government Employee", areaIdx: 21, door: "48", street: "Virugambakkam High Road" },
  { name: "Manimegalai Ravi", mobile: "9940723457", profession: "Teacher", areaIdx: 22, door: "22", street: "GST Road" },
  { name: "Kumaresan Vel", mobile: "8925834568", profession: "Businessman", areaIdx: 23, door: "17", street: "Selaiyur Main Road" },
  { name: "Yamuna Devi", mobile: "9840945679", profession: "Homemaker", areaIdx: 24, door: "29", street: "Medavakkam Main Road" },
] as const

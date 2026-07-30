/**
 * GV Mart seed — one org, one login per role, realistic Chennai-area data.
 * Requires SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (service_role — this
 * script only ever runs locally/CI, never in the browser bundle).
 *
 * Run: npm run seed
 */
import { createClient } from "@supabase/supabase-js"
import type { Database } from "../../src/types/database"
import {
  ORG,
  ROLE_USERS,
  SEED_PASSWORD,
  TECHNICIAN_SKILLS,
  BRANDS,
  MODELS,
  PRODUCTS,
  SPARES,
  DEFAULT_MIN_STOCK,
  DEFAULT_MAX_STOCK,
  PRODUCT_STOCK,
  SPARE_STOCK,
  SUPPLIERS,
  CHENNAI_AREAS,
  CUSTOMERS,
} from "./data"

const SUPABASE_URL = process.env.SUPABASE_URL
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY

if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
  console.error(
    "Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY.\n" +
      "Set them (e.g. from `supabase status` for local dev, or your project's API settings) before running `npm run seed`.\n" +
      "The service_role key must never be committed or shipped to the browser — it's for this one-time seed only."
  )
  process.exit(1)
}

const supabase = createClient<Database>(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
})

type Tables = Database["public"]["Tables"]
type Organization = Tables["organizations"]["Row"]
type Technician = Tables["technicians"]["Row"]
type Brand = Tables["brands"]["Row"]
type Model = Tables["models"]["Row"]
type Product = Tables["products"]["Row"]
type Spare = Tables["spares"]["Row"]
type Supplier = Tables["suppliers"]["Row"]
type Customer = Tables["customers"]["Row"]

/**
 * Awaits a Postgrest query and throws with context on error/empty result.
 * Takes T explicitly at each call site — inferring T from Postgrest's
 * response union (data: T | null in the success branch, data: null in the
 * failure branch) widens to `T | null` under the compiler's generic
 * inference, so this deliberately does not rely on inference.
 */
async function must<T>(
  label: string,
  query: PromiseLike<{ data: T | null; error: { message: string } | null }>
): Promise<T> {
  const { data, error } = await query
  if (error) throw new Error(`${label}: ${error.message}`)
  if (data === null) throw new Error(`${label}: no data returned`)
  return data
}

async function main() {
  console.log(`Seeding against ${SUPABASE_URL} ...\n`)

  const org = await must<Organization>("organizations", supabase.from("organizations").insert(ORG).select().single())
  console.log(`org: ${org.name} (${org.id})`)

  await must<Tables["settings"]["Row"]>(
    "settings",
    supabase.from("settings").insert({ org_id: org.id }).select().single()
  )
  console.log("settings: v2.2 defaults (per_km_minutes=5, min/reorder=10/10, referral_point_value=50, ...)")

  // ---- 5 role logins ----
  const profileIdByRole: Record<string, string> = {}
  for (const u of ROLE_USERS) {
    const { data: authUser, error: authError } = await supabase.auth.admin.createUser({
      email: u.email,
      password: SEED_PASSWORD,
      email_confirm: true,
    })
    if (authError) throw new Error(`auth.admin.createUser(${u.email}): ${authError.message}`)

    await must<Tables["profiles"]["Row"]>(
      "profiles",
      supabase
        .from("profiles")
        .insert({
          id: authUser.user.id,
          org_id: org.id,
          full_name: u.full_name,
          phone: u.phone,
          role: u.role,
          language: "en",
        })
        .select()
        .single()
    )
    profileIdByRole[u.role] = authUser.user.id
    console.log(`profile: ${u.role.padEnd(16)} ${u.email}`)
  }

  const technician = await must<Technician>(
    "technicians",
    supabase
      .from("technicians")
      .insert({ org_id: org.id, profile_id: profileIdByRole.technician, skills: TECHNICIAN_SKILLS, is_on_duty: true })
      .select()
      .single()
  )
  console.log(`technician row linked: ${technician.id}`)

  // ---- Catalog: brands -> models -> products, spares ----
  const brandIdByName: Record<string, string> = {}
  for (const b of BRANDS) {
    const row = await must<Brand>(
      "brands",
      supabase.from("brands").insert({ org_id: org.id, name: b.name, category: b.category }).select().single()
    )
    brandIdByName[b.name] = row.id
  }
  console.log(`brands: ${BRANDS.length}`)

  const modelIdByKey: Record<string, string> = {}
  for (const m of MODELS) {
    const row = await must<Model>(
      "models",
      supabase
        .from("models")
        .insert({ org_id: org.id, brand_id: brandIdByName[m.brand], name: m.name, type: m.type })
        .select()
        .single()
    )
    modelIdByKey[`${m.brand}::${m.name}`] = row.id
  }
  console.log(`models: ${MODELS.length}`)

  const productIds: string[] = []
  for (const p of PRODUCTS) {
    const row = await must<Product>(
      "products",
      supabase
        .from("products")
        .insert({
          org_id: org.id,
          brand_id: brandIdByName[p.brand],
          model_id: modelIdByKey[`${p.brand}::${p.model}`],
          name: p.name,
          category: p.category,
          price: p.price,
          hsn_code: p.hsn_code,
        })
        .select()
        .single()
    )
    productIds.push(row.id)
  }
  console.log(`products: ${PRODUCTS.length}`)

  const spareIds: string[] = []
  for (const s of SPARES) {
    const row = await must<Spare>(
      "spares",
      supabase
        .from("spares")
        .insert({ org_id: org.id, name: s.name, sku: s.sku, price: s.price, hsn_code: s.hsn_code })
        .select()
        .single()
    )
    spareIds.push(row.id)
  }
  console.log(`spares: ${SPARES.length}`)

  // ---- Inventory: v2.2 min_stock=10, max_stock=20 for every item ----
  const inventoryRows = [
    ...productIds.map((id, i) => ({
      org_id: org.id,
      item_type: "product" as const,
      item_id: id,
      stock_qty: PRODUCT_STOCK[i],
      min_stock: DEFAULT_MIN_STOCK,
      max_stock: DEFAULT_MAX_STOCK,
      location: "warehouse" as const,
    })),
    ...spareIds.map((id, i) => ({
      org_id: org.id,
      item_type: "spare" as const,
      item_id: id,
      stock_qty: SPARE_STOCK[i],
      min_stock: DEFAULT_MIN_STOCK,
      max_stock: DEFAULT_MAX_STOCK,
      location: "warehouse" as const,
    })),
  ]
  const { error: inventoryError } = await supabase.from("inventory").insert(inventoryRows)
  if (inventoryError) throw new Error(`inventory: ${inventoryError.message}`)
  console.log(`inventory: ${inventoryRows.length} rows (min/max 10/20 everywhere)`)

  // ---- Suppliers, linked to a spread of spares/products ----
  const supplierIds: string[] = []
  for (const s of SUPPLIERS) {
    const row = await must<Supplier>(
      "suppliers",
      supabase.from("suppliers").insert({ org_id: org.id, ...s }).select().single()
    )
    supplierIds.push(row.id)
  }
  const supplierLinks = [
    // supplier 0 (Chennai Electro Traders) carries the RO spares, cheaper/preferred
    ...spareIds.slice(0, 13).map((id, i) => ({
      org_id: org.id,
      supplier_id: supplierIds[0],
      item_type: "spare" as const,
      item_id: id,
      price: Math.round(SPARES[i].price * 0.72),
      lead_time_days: 2,
      is_preferred: true,
    })),
    // supplier 1 (Sri Ram Cooling Spares) carries the AC/battery/inverter spares
    ...spareIds.slice(13).map((id, i) => ({
      org_id: org.id,
      supplier_id: supplierIds[1],
      item_type: "spare" as const,
      item_id: id,
      price: Math.round(SPARES[13 + i].price * 0.7),
      lead_time_days: 3,
      is_preferred: true,
    })),
  ]
  const { error: supplierLinksError } = await supabase.from("supplier_products").insert(supplierLinks)
  if (supplierLinksError) throw new Error(`supplier_products: ${supplierLinksError.message}`)
  console.log(`suppliers: ${SUPPLIERS.length}, supplier_products links: ${supplierLinks.length}`)

  // ---- Customers (#0 = the seeded customer login) + addresses ----
  for (let i = 0; i < CUSTOMERS.length; i++) {
    const c = CUSTOMERS[i]
    const area = CHENNAI_AREAS[c.areaIdx]
    const customer = await must<Customer>(
      "customers",
      supabase
        .from("customers")
        .insert({
          org_id: org.id,
          primary_profile_id: i === 0 ? profileIdByRole.customer : null,
          name: c.name,
          mobile: c.mobile,
          profession: c.profession,
          source: "other",
        })
        .select()
        .single()
    )
    await must<Tables["addresses"]["Row"]>(
      "addresses",
      supabase
        .from("addresses")
        .insert({
          org_id: org.id,
          customer_id: customer.id,
          door_no: c.door,
          street_cross: c.street,
          area: area.area,
          pincode: area.pincode,
          district: "Chennai",
          state: "Tamil Nadu",
          lat: area.lat,
          lng: area.lng,
          address_type: "residential",
          ownership: "own",
          is_primary: true,
        })
        .select()
        .single()
    )
  }
  console.log(`customers: ${CUSTOMERS.length} (with primary addresses)`)

  console.log("\nSeed complete.\n")
  console.log(`Test logins (password: ${SEED_PASSWORD}):`)
  for (const u of ROLE_USERS) console.log(`  ${u.role.padEnd(16)} ${u.email}`)
}

main().catch((err) => {
  console.error("\nSeed failed:", err.message)
  process.exit(1)
})

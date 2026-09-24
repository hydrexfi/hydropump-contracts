/**
 * CI guard: verify every committed storage-layout snapshot still matches its contract.
 *
 * Usage:
 *   node scripts/checkStorageSnapshots.js                     # check all snapshotted contracts
 *   node scripts/checkStorageSnapshots.js HydropumpLocker     # check one contract
 *
 * Discovers contracts from artifacts-storage/storage_layout_<Contract>_v<semver>.json,
 * compares each against the highest-versioned snapshot for that contract, and exits
 * non-zero if any layout has drifted.
 *
 * Why it exists: HydropumpLauncher, HydropumpLocker, PairDirectory and FeeUseRegistry sit
 * behind UUPS proxies. An upgrade whose storage layout differs from the live one reads live
 * data from the wrong slots. v1.0.0 snapshots were taken from main at d7e0c6a, whose layouts
 * for these four contracts are unchanged since the deployed commit 24eb16c.
 *
 * Non-destructive: never checks out commits or writes to the working tree.
 *
 * What is compared, and why:
 *   - Top-level slots: label, slot, offset and resolved type label.
 *   - Struct members: same fields, keyed by struct type label. Reordering fields inside a
 *     struct changes where live data is read from while leaving the top-level entry identical.
 *   - astId is deliberately NOT compared. It shifts whenever unrelated code is added earlier
 *     in the file and has no bearing on storage compatibility.
 *
 * It also fails if any contract under contracts/ that inherits UUPSUpgradeable has no snapshot,
 * so a new proxied contract cannot go unchecked. That editing or deleting a committed snapshot
 * is refused is enforced separately, by the storage job in .github/workflows/ci.yml.
 *
 * A deliberate storage change adds a NEW versioned snapshot file (e.g. _v1.1.0.json), which
 * then becomes the highest version and the comparison target.
 *
 * Ported from hydrexfi/hydrex-contracts scripts/checkStorageSnapshots.js, without its
 * legacy-import allowlist (every snapshot here is enforced).
 */

const { execFileSync } = require('child_process')
const fs = require('fs')
const path = require('path')

const REPO_ROOT = path.join(__dirname, '..')
const SNAPSHOT_DIR = path.join(REPO_ROOT, 'artifacts-storage')
const CONTRACTS_DIR = path.join(REPO_ROOT, 'contracts')
const SNAPSHOT_RE = /^storage_layout_(.+)_v(\d+\.\d+\.\d+)\.json$/

const onlyContract = process.argv.slice(2).find((a) => !a.startsWith('--'))

/** Every contract under contracts/ that inherits UUPSUpgradeable, i.e. sits behind an upgradeable proxy. */
function findUpgradeableContracts(dir = CONTRACTS_DIR, found = []) {
  const re = /\bcontract\s+(\w+)\s+is\s+[^{]*\bUUPSUpgradeable\b/g
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) findUpgradeableContracts(full, found)
    else if (entry.isFile() && entry.name.endsWith('.sol')) {
      for (const m of fs.readFileSync(full, 'utf8').matchAll(re)) found.push(m[1])
    }
  }
  return found
}

/** Locate the .sol file declaring `contract <name>`. */
function findContractFile(contractName, dir = CONTRACTS_DIR) {
  const re = new RegExp(`\\bcontract\\s+${contractName}\\b`)
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) {
      const found = findContractFile(contractName, full)
      if (found) return found
    } else if (entry.isFile() && entry.name.endsWith('.sol')) {
      if (re.test(fs.readFileSync(full, 'utf8'))) return full
    }
  }
  return null
}

const cmpSemver = (a, b) => {
  const pa = a.split('.').map(Number)
  const pb = b.split('.').map(Number)
  for (let i = 0; i < 3; i++) if (pa[i] !== pb[i]) return pa[i] - pb[i]
  return 0
}

/** Reduce a forge layout to the fields that actually determine storage compatibility. */
function canonical(layout) {
  const typeLabel = (id) => (layout.types && layout.types[id] ? layout.types[id].label : id)

  const slots = layout.storage.map((s) => ({
    label: s.label,
    slot: String(s.slot),
    offset: s.offset,
    type: typeLabel(s.type),
  }))

  // Key struct member layouts by type LABEL, not by the internal t_struct(X)NN_storage id
  // (that id embeds an AST id and drifts for reasons unrelated to layout).
  const structs = {}
  for (const id of Object.keys(layout.types || {})) {
    const t = layout.types[id]
    if (!t.members) continue
    structs[t.label] = t.members.map((m) => ({
      label: m.label,
      slot: String(m.slot),
      offset: m.offset,
      type: typeLabel(m.type),
    }))
  }
  return { slots, structs }
}

function diffRows(expected, actual, context, out) {
  const n = Math.max(expected.length, actual.length)
  for (let i = 0; i < n; i++) {
    const e = expected[i]
    const a = actual[i]
    const fmt = (r) => (r ? `${r.label} @ slot ${r.slot} offset ${r.offset} :: ${r.type}` : '<missing>')
    if (!e || !a || e.label !== a.label || e.slot !== a.slot || e.offset !== a.offset || e.type !== a.type) {
      out.push(`    ${context}[${i}]`)
      out.push(`      snapshot: ${fmt(e)}`)
      out.push(`      current : ${fmt(a)}`)
    }
  }
}

function check(contractName, snapshotFile, version) {
  const solPath = findContractFile(contractName)
  if (!solPath) {
    return { contractName, status: 'error', version, message: `no .sol declaring "contract ${contractName}"` }
  }

  const rel = path.relative(REPO_ROOT, solPath)
  let raw
  try {
    raw = execFileSync('forge', ['inspect', `${rel}:${contractName}`, 'storage', '--json'], {
      cwd: REPO_ROOT,
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'pipe'],
    })
  } catch (e) {
    const detail = String(e.stderr || e.message).trim().split('\n').slice(-5).join(' | ')
    return { contractName, status: 'error', version, message: `forge inspect failed: ${detail}` }
  }

  const current = canonical(JSON.parse(raw))
  const snapshot = canonical(JSON.parse(fs.readFileSync(path.join(SNAPSHOT_DIR, snapshotFile), 'utf8')))

  const out = []
  if (JSON.stringify(snapshot.slots) !== JSON.stringify(current.slots)) {
    diffRows(snapshot.slots, current.slots, 'slot', out)
  }
  for (const structName of new Set([...Object.keys(snapshot.structs), ...Object.keys(current.structs)])) {
    const e = snapshot.structs[structName]
    const a = current.structs[structName]
    if (!e || !a) {
      out.push(`    struct ${structName}: ${!e ? 'absent in snapshot' : 'absent in current code'}`)
    } else if (JSON.stringify(e) !== JSON.stringify(a)) {
      diffRows(e, a, `struct ${structName}`, out)
    }
  }

  if (out.length) return { contractName, status: 'mismatch', version, snapshotFile, details: out }
  return { contractName, status: 'ok', version, snapshotFile }
}

function main() {
  if (!fs.existsSync(SNAPSHOT_DIR)) {
    console.error(`No snapshot directory at ${SNAPSHOT_DIR}`)
    process.exit(1)
  }

  // contract -> highest versioned snapshot
  const latest = new Map()
  for (const file of fs.readdirSync(SNAPSHOT_DIR)) {
    const m = file.match(SNAPSHOT_RE)
    if (!m) continue
    const [, contractName, version] = m
    const prev = latest.get(contractName)
    if (!prev || cmpSemver(version, prev.version) > 0) latest.set(contractName, { version, file })
  }

  let targets = [...latest.entries()]
  if (onlyContract) {
    targets = targets.filter(([name]) => name === onlyContract)
    if (!targets.length) {
      console.error(`No snapshot found for contract "${onlyContract}" in artifacts-storage/`)
      process.exit(1)
    }
  }
  if (!targets.length) {
    console.error('No storage snapshots found — expected artifacts-storage/storage_layout_<Contract>_v<semver>.json')
    process.exit(1)
  }

  // A proxied contract with no snapshot would otherwise never be checked at all.
  if (!onlyContract) {
    const missing = findUpgradeableContracts().filter((name) => !latest.has(name))
    if (missing.length) {
      console.error(`Upgradeable contract(s) with no storage snapshot: ${missing.join(', ')}`)
      console.error('Add one: forge inspect <path>:<Contract> storage --json > artifacts-storage/storage_layout_<Contract>_v1.0.0.json')
      process.exit(1)
    }
  }

  targets.sort((a, b) => a[0].localeCompare(b[0]))
  console.log(`Checking ${targets.length} storage snapshot(s)\n`)

  const results = targets.map(([name, { version, file }]) => check(name, file, version))

  for (const r of results) {
    const tag = r.status === 'ok' ? 'PASS' : 'FAIL'
    console.log(`  ${tag}  ${r.contractName} (v${r.version})${r.message ? ` — ${r.message}` : ''}`)
    if (r.details) r.details.forEach((line) => console.log(line))
  }

  const failed = results.filter((r) => r.status !== 'ok')
  console.log('')
  if (failed.length) {
    console.error(`${failed.length} storage layout(s) differ from their committed snapshot, or could not be checked.\n`)
    console.error('If the change is intentional:')
    console.error('  1. Add a NEW snapshot file at a bumped version, e.g.')
    console.error('       forge inspect <path>:<Contract> storage --json \\')
    console.error('         > artifacts-storage/storage_layout_<Contract>_v<newVersion>.json')
    console.error('  2. Shrink __gap by exactly the number of slots the new variables consume.')
    console.error('  3. Note the gap change in the commit subject, e.g. "(__gap 46->45)".')
    console.error('  4. Explain the change in the PR — never update a snapshot silently.\n')
    process.exit(1)
  }
  console.log('All storage layouts match their committed snapshots.')
}

main()

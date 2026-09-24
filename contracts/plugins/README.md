# Hydrex plugin working source

The plugin, factory, and internal components live here for Hydropump's launch-fee
implementation. External Algebra dependencies remain unchanged in
`lib/hydrex-base-plugin/dependencies/`.

## Launch behavior

- Starts when a newly created pool calls `afterInitialize`, not when the plugin
  is deployed and not at the first swap.
- Charges 99% in the initialization block, then interpolates linearly to the
  current normal fee over ten **blocks**, not seconds.
- If the normal fee is 1% throughout: block +0 = 99%, +5 = 50%, +9 = 10.8%,
  +10 = normal 1%. Other normal fees produce different intermediate values.
- The normal fee is still calculated on each swap using existing adaptive and
  sliding logic. If neither provides an override, the pool's stored fee is used.
  The effective fee may respond to changing normal-fee settings during the window;
  monotonicity is guaranteed for a fixed normal fee, not arbitrary admin changes.
- Applies to both directions, exact-input/output and prepaid swaps. No creator,
  router or deployment-time buy exemption. The fee is an LP fee override, not an
  additional plugin fee; existing pool accounting and community-fee splits apply.
- Security, oracle updates, sliding state and farming callbacks remain active.
- No reset or duration setter. Initializing the oracle on an already initialized
  pool through `initialize()` does not impose a retroactive launch fee.
- `getCurrentFee()` remains the legacy normal adaptive-fee getter. It does not
  include sliding or launch adjustments; use actual swap simulation for quotes.

`HydropumpLauncher` now creates pools through `HydropumpPoolDeployer`, a dedicated
custom-pool namespace bound to that launcher proxy. Creation, initialization,
liquidity minting/locking and the optional creator buy happen atomically. The
Position Manager initializes the custom pool after the deployer creates it.
All minted positions and swaps use the dedicated deployer address, not zero.
The shared Hydrex default plugin factory and unrelated pools remain unchanged.
An existing standard pool for the same pair does not block the custom launch.

The launcher fails closed until its admin binds the deployer. Binding is one-time
and checks the launcher and Algebra factory identities. The new address consumes
one reserved launcher storage slot (`__gap` 46 to 45); existing fields retain their slots. Existing
launches are not migrated. Frontends/indexers must support custom-pool addresses;
routers and position minting must use the dedicated deployer parameter.
The locker conversion and buyback fee use read the namespace from the launch's
first saved NPM position, so both legacy standard pools and new custom pools work.
Auto-LP continues increasing the existing position IDs without changing its strategy.

## Deployment sequence

1. Deploy the Hydropump contracts using the existing deployment script. Keep the
   launcher proxy address in `LAUNCHER_ADDRESS`.
2. Build/deploy the dedicated factory using the plugins profile:

   ```sh
   FOUNDRY_PROFILE=plugins forge script script/plugins/DeployHydropumpPoolDeployer.s.sol:DeployHydropumpPoolDeployer --rpc-url "$BASE_RPC_URL"
   ```

   This command is a simulation. Add `--broadcast` only for an authorized deployment.
   The script reads `DEPLOYER_KEY`. It snapshots the current default Hydrex plugin
   settings (adaptive/sliding fees, security registry and farming address).
3. Algebra governance grants `CUSTOM_POOL_DEPLOYER` on the existing Algebra factory
   to the new deployer contract. No global default-plugin replacement is needed.
4. The Hydropump admin calls `launcher.setPoolDeployer(newDeployer)`. Configure
   supported quote tokens and complete existing locker ownership setup as usual.

For an existing deployment, upgrade the launcher and locker implementations and
deploy/register the updated BuybackBurnFeeUse before enabling custom launches.
Keep the old launch records and positions: they still resolve to namespace zero.

Only the bound launcher can request creation in this namespace; direct outsiders
and forged callbacks revert. The dedicated factory does not support retrofitting
plugins onto existing pools. Existing Hydrex plugin-manager/admin authorities
still govern normal plugin settings; the launch fee is not an immutable guarantee
against privileged plugin replacement/configuration changes. Governance grants in
tests are impersonated on a local fork, not executed on Base.

## Provenance and licensing

Imported from the BaseScan-verified source bundle for the Base mainnet factory
`0x1c219ba68A9100E4F3475A624cf225ADA02c0F1B` on 2026-09-23:
https://basescan.org/address/0x1c219ba68A9100E4F3475A624cf225ADA02c0F1B#code

The original import contained 41 Solidity files (23 here, 18 external
dependencies). Local changes add the launch schedule and guard in
`HydrexBasePlugin.sol`, and rename private plugin-config constants to avoid
inherited-name collisions in Foundry's linter (no behavior change from renaming).
Original compiler settings are in
`verified-settings.json`. The local plugin profile enables IR optimization to keep
the dedicated factory (which embeds plugin creation bytecode) below EIP-170's
24,576-byte runtime limit. Size assertions are part of the launch fork tests;
also run `FOUNDRY_PROFILE=plugins forge build --sizes` before deployment.
Preserve all SPDX identifiers and attributions:
the bundle mixes BUSL-1.1, GPL-2.0-or-later, and MIT, not just the repository's
MIT license. Complete upstream BUSL grant/change-date terms were not included
in the verified bundle; confirm applicable terms before production deployment
or distribution of derivatives.

## Build

From the repository root:

```sh
FOUNDRY_PROFILE=plugins forge build
FOUNDRY_PROFILE=plugins forge test --no-match-path 'test/plugins/fork/*' --fuzz-runs 1000
FOUNDRY_PROFILE=plugins forge test --match-path 'test/plugins/fork/*'
forge build
forge test --no-match-path 'test/fork/*'
BASE_RPC_URL=https://mainnet.base.org BASE_FORK_BLOCK=51716638 forge test --match-contract '^(LaunchFeeFlow.*ForkTest|HydropumpLaunchForkTest|LaunchCurveForkTest|LaunchB20ForkTest|FeeFlow.*ForkTest|AutoLpRemainders.*ForkTest)$' --threads 1
```

The plugin profile uses Solidity 0.8.20 independently. The default Hydropump
profile stays on 0.8.26 and excludes this directory. Do not directly import the
exact-0.8.20 implementation into a 0.8.26 compilation unit; integration should
use compatible interfaces and separately compiled deployment artifacts.

The commands above pin integration forks to Base block 51716638. Plugin forks
default to the public Base RPC; launcher forks require `BASE_RPC_URL` explicitly
(otherwise Foundry marks them skipped). `BASE_FORK_BLOCK` selects the integration
fork block; when omitted those fixtures use latest state. These tests cover real pool fee charging in both directions, prepaid input and
exact output. Launcher integration tests deploy the compiled 0.8.20 factory against
real Base infrastructure, launch and lock the full curve, execute the creator buy,
buy/sell at every block from 0 through 11 in both token orderings, collect fees,
verify namespace isolation, and reject
missing-role launches atomically. The pinned factory's community fee is 15/1000
of swap fees (also on standard pools), leaving 98.5% of those fees for LPs; tests
check this existing split rather than assuming every fee stays with LPs.
Unit tests first established existing
behavior; four launch regression tests were observed failing before implementation
and passing afterward. Fuzz tests cover fee bounds, fixed-normal-fee monotonicity,
and the exact ten-block cutoff. No lint checks are disabled. These tests do not
constitute an audit. Nothing has been deployed or attached to a live pool.

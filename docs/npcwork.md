# NPC Work — Findings, Current Fixes, and Refactor Plan

## Status

- Active branch: `npc-work`. Phase 1 persistence, NPC sector travel, and the
  first Phase 2 progression slice are committed as `34f6ed6`. The current
  uncommitted milestone completes the Phase 2 gameplay/services slice and adds
  the core Phase 3 utility, perception, self-preservation, and combat behaviors.
- **Phase 2 status:** implementation and focused tests complete; visual/economic
  approval of repair, refit, purchase, trade-in, upkeep, and save/load remains.
- **Phase 3 status:** core implementation is present but the phase is **not
  closed**. Dense-field avoidance still needs tuning, and combat, retreat,
  regroup, repair, station routing, and sector travel need real-play visual
  validation. Global pathfinding and broader mission-driven behavior remain
  future work.
- NPC ship generation was **never missing**. The problems were prototype,
  scale/distance, lifecycle, targeting, and AI-policy issues.
- `python3 configure.py test` passes shader validation, region/sector validation,
  and UI integration. The region/sector validators now include `libphx/script/`
  on `package.path`, so `ffi.Resource` resolves in headless runs.
- Focused verification totals 947 checks across NPC lifecycle/persistence,
  movement, mining, progression, ship equipment/loadout/runtime stats, shields,
  combat, avoidance, and dock services. The latest full
  `python3 configure.py test` run passes, including region/sector and UI
  integration tests; the save/load round-trip also passes.
- Pinned-seed profiler comparison after removing duplicate NPC Economy updates:
  the original six-capital demo improved from ~4.71 ms to ~3.46 ms (about
  212 → 289 fps). The final eight-ship mixed roster with radar averages ~3.74 ms
  (about 267 fps), with `App.onUpdate` at ~0.47 ms. Render submission remains the
  dominant cost.

## What was actually wrong

### 1. NPC ships existed, but were effectively subpixel

`System:spawnAI()` called ordinary `System:spawnShip()`, which instantiated the
same `Gen.Ship.ShipFighter` prototype used by the player at scale 4.

Measured with the pinned startup seed at 1920×1080:

| NPC eye distance | Original fighter diameter | Fighter after ×4 scale |
|---:|---:|---:|
| 11,563 units | 1.11 px | 4.44 px |
| 15,109 units | 0.85 px | 3.40 px |
| 31,115 units | 0.41 px | 1.65 px |

The HUD draws fixed-size boxes and names, so the labels remained obvious while
the hulls were smaller than a few pixels. Dark Metal shading and disabled
TAA/FXAA made those pixels even harder to read.

This was **not**:

- a missing procedural mesh;
- a missing `Event.Render` handler;
- a broken render-tree broadcast;
- CPU frustum culling (`Material.Metal().cullable == false`);
- a zero or stale world matrix.

A direct `Event.Render` delivered to an NPC invoked `mesh:draw()` exactly once.

### 2. The AI brain was active, but only had economy jobs

The brain is added to the system and has an economy, so `Think` runs and assigns
jobs. In testing, caps received `MoveTo`, `DockAt`, mining, and transport jobs.

The repetition comes from policy, not from the engine being off:

- `Think` chooses the highest-payout job from a finite economy job list.
- There is no job cooldown, commitment, novelty, local perception, avoidance,
  personality, or combat decision layer.
- All caps currently have neutral disposition and no hostile targets.

The existing framework is usable, but it is an economy scheduler, not a complete
NPC autonomy system.

### 3. Three concrete crashes were found and fixed

1. **Target info panel crashed in `App.onDraw`.**
   - `NpcInfoPanel` called `player:getRoot():getPos()`.
   - `Player:getRoot()` returns the root of the controlled ship, normally the
     `System`, which has no rigid body.
   - Fixed by measuring from `player:getControlling()` and checking `ship.body`.

2. **Projectile rendering crashed in Mesa.**
   - `Entity:addProjectile()` used `Pulse:new()`, which allocates from the pool
     but does not run the Pulse initializer.
   - `pulse.matrix` was null and passed to `glUniformMatrix4fv`.
   - Fixed by using `Pulse()` and removing an invalid `self:register(...)` call
     from the Pulse initializer (Pulse is a C struct, not an Entity).

3. **J/K/U could select the player's own ship.**
   - The human ship has an owner, so `System:npcTargets()` included it.
   - J selected the ship at distance zero; K/U cycled back onto it.
   - Fixed by excluding the querying ship and filtering dead/bodyless/deleted
     targets.

### 4. The target preview used a known-bad GPU path

`DrawEx.Hologram` / `ui3D` had documented viewport and scissor problems. It was
replaced in the NPC panel with the same deterministic CPU-projected mesh
wireframe used by `NodeGraphInspector`.

## Visibility and lifecycle fixes (committed)

- NPCs now use a distinct cached `Gen.Ship.ShipCapital` prototype at scale 64,
  applied before modules and mass are created.
- `System:spawnShip('capital')` is separate from the player's fighter path.
- The initial two-capital placement was replaced by the deterministic mixed
  eight-ship roster and radius-aware startup placement described below.
- Thrust scales with ship mass and torque scales with approximate inertia, so
  large capital hulls remain mobile instead of inheriting fighter thrust.
- `System:npcTargets(exclude)` filters dead/bodyless/deleted entities and the
  querying ship.
- `NpcInfoPanel` uses the player's controlling ship for distance.
- Projectile construction runs the Pulse initializer.
- The target panel is themed like the sector panel, anchored upper-right with
  the same screen inset, omits the long job line, and shows a contained CPU
  wireframe preview.
- `Math.Impact` now handles the degenerate `a == 0` case and uses the correct
  quadratic denominator for both roots.
- `metal.glsl` has a modest brightness/Fresnel rim improvement for dark hulls.

These fixes are verified by targeted boots and the real J/K/U + fire path, but
still require user visual approval.

## Completed through `80d18b9`

- Added `Game.ShipMovement`: top speed and acceleration now scale with hull
  radius and cargo load. Fighter reference remains 500 u/s; a 600-unit capital
  is ~64.5 u/s empty and slower under load. Thrust, drag, torque, and job travel
  estimates share the model.
- Added explicit NPC identity to `Player` (`isNpc`, stable `npcId`, profile).
- Added `Game.NpcRegistry` and System register/unregister/lookup APIs.
- `spawnAI` now creates seeded NPC identities and registers exactly one brain
  per call, regardless of ship count. Demo startup uses the mixed population
  planner, producing eight independent role-seeded actors.
- `npcTargets` now requires an explicit NPC owner, a live body, and current
  System parenting; human-owned escorts are excluded.
- Deleted ships detach from their owner; deleted brains leave both `players`
  and the NPC registry.
- Removed duplicate `Think`/economy ticks by adding descendant-only
  `Entity:broadcast` and using it in `System:update`.
- Restored `ShipType.scale` propagation in the `Ship` constructor. Capital
  scale 64 now reaches the live rigid body before radius/mass/modules are
  derived; the previous scale-1 hulls were subpixel in the world.
- Added `Game.StartupPlacement`: up to four representative demo ships are
  radius-scaled around the player and hold a five-second `Wait` before normal AI.
- Removed instant-job teleportation from `MoveTo`, `DockAt`, and `MineAt`.
  NPCs now always accelerate with thrust, collide normally, and show engine
  trails; the old local `instantJobs/jobSpeed` overrides are gone.
- Added `Game.NpcPolicy` and route-aware `Think`: profit/travel utility, seeded
  per-ship and exact-route preferences, unseen-route bonus, route memory,
  cooldowns, and cloned job assignment. Equal-value routes now diversify across
  NPC seeds instead of converging on one optimum.
- Mine/Transport now report completion vs cancellation through `Job:onStop`;
  pooled economy templates can no longer retarget an active ship.
- Mining is dt-invariant and resource-specific: a standard hold fills in
  5–40 seconds depending on the ore. Asteroid yields now have finite deposits
  (deterministic per-rock randomness from 120–5,000 units, biased richer for
  larger asteroids), tracked by stable rock keys through stream
  unload/reload and serialized in saves. Target Info shows remaining composition
  and deposit amount; depleted rocks stay in place but become unminable.
  `Game.Entities.MiningBeam` draws three
  thin blue converging beams and `MineAt` emits blue sparks plus a hot contact
  flash. The player shares the same action: target a yielded asteroid with `T`,
  then press `X` within mining range.
- Added active all-axis braking (`Actions.Stop`) before extraction. Both player
  and NPC mining jobs brake to a real stop; moving too fast or losing aim drains
  extraction accuracy, turns the beam red, and fails the attempt. Mining plans
  against remaining cargo capacity, and the HUD/dock screen now show used/free
  mass, item counts, and live extraction progress. Bulk sales itemize what was
  sold.
- Added 5–10 second rotating green/red resource scans (`Actions.Scan` and
  `Game.Entities.ScanEffect`). NPCs approach unscanned asteroids, scan them, and
  only then discover/consider their mining jobs. The player presses `C` to scan
  the current or nearest unscanned asteroid.
- Added the design-spec foundation: `Game.Registry` asset classes/material
  tiers, stable ship registry IDs/names, and per-pilot `Game.ScannerDB` contact
  records with T1–T4 range resolution, yield data, and bounded forensic logs.
- Added `Game.NpcPopulation` and `Game.ShipArchetypes`: deterministic mixed
  rosters with fighters, freighters, industrials, and a capital. The demo now
  spawns eight independent role-seeded actors instead of six duplicate capitals.
- Added normalized Sausage-derived freighter/industrial generator profiles,
  role-specific scale/cargo/registry metadata, variant prototype caches, and
  spawn options that no longer silently turn every role into a fighter.
- Added fighter `Actions.Patrol`; role filtering keeps fighters out of resource
  scanning/economy hauling and gives mine-capable hulls the scan/extract loop.
- Sector entry now reconciles the NPC roster: outgoing actors are explicitly
  despawned (including docked ships/actions/audio) before the destination's
  deterministic roster is created, preventing accumulation across jumps.
- Corrected scanner/mining billboard orientation and surface penetration so
  the rays visibly reach into the asteroid instead of fading beside/behind it.
  Target brackets now use a stable projected sphere rather than eight bounding-
  box corners, preventing close-range drift when corners cross the near plane.
- Added a bottom-left radar and frequency-spectrum scanner HUD driven by a
  bounded passive contact refresh plus ScannerDB records, and a persistent
  registry-style target bracket. Radar includes barren asteroids as well as
  ore, ships, stations, planets, and the system star. Per-category reservations
  prevent crowded ship lists from starving asteroids without sorting the full
  field, the startup ore field is recentered after final ship placement, and
  radar refreshes immediately on HUD re-enable. Radar scans pause behind menus
  and dock screens. Range rings are labeled with their distance from the ship,
  and the readout includes the displayed rock count. `+`/`−`, mouse wheel, and
  Space-over-radar provide zoom/expand controls. Settings includes persisted
  radar category toggles.
- Targeting now performs an input-time ray/sphere pick rather than relying on
  a stale, center-gated screen rectangle. Large asteroids remain selectable
  when their center is off screen, overlapping candidates resolve by nearest
  ray hit, and keyboard input no longer flips KBM aim to gamepad mode. Clearing
  or losing a target also clears the generic Target Info panel. Asteroid panels
  resolve their LOD mesh for a real wireframe preview (including callable FFI
  accessors), use readable names, show both center `Distance` and `Surface gap`,
  and keep `Composition: Unknown`
  until a successful scan reveals the mineral.
- Player `C` scans in place only; distant targets no longer trigger automatic
  approach thrust. The flight HUD remains visible during scan/mine/move actions
  and shows live scan/extraction progress instead of disabling the whole control
  set. Scan range is 2,000 units from the target surface; mining
  range is 250 units. `X` now starts active braking when the ship is in range
  and aligned, while still rejecting misaligned attempts. The HUD shows
  approach/stop/align/ready state plus live extraction count. Spectrum response
  is directional and uses distinct ore, ship, station, planet, and star bands.
- Scanner/mining beams are wider and brighter, with endpoints penetrating the
  target surface so contact reads clearly.
- Ship prototypes now validate generated meshes and retry deterministic nearby
  seeds before BSP construction; rejected native meshes are retained safely to
  avoid allocator corruption on rare invalid hulls.
- Moved the generic Target Info panel to the upper-right with the same 18px
  screen-edge inset as SectorPanel (10px widget inset + 8px HUD padding).
- Removed duplicate per-brain Economy components; all NPCs share the System's
  one economy/job cache instead of rebuilding it six times per frame.
- Added `Game.NpcSafety` and `Actions.Flee`: heavy damage or low hull temporarily
  preempts a job, steers away from the damage source, clears thrust, then resumes
  the job underneath.
- Target locks clear immediately on target destruction/removal. Live world
  removal detaches owner assets, docking reparenting preserves ownership, and
  destroyed/deleted nested ships are swept recursively. Docking now parks ships
  at a safe exterior berth, zeros velocity, clears thrust, and blocks thrust
  updates while detached from physics; undocking restores a clean stationary
  body instead of accumulating minutes of stale force.
- Added a single System simulation clock for policy/cooldown timing. Delta
  bindings are now idempotent within an explicit per-frame clock, so focus and
  child input traversal cannot swallow a target/scan/mine keypress and menu
  input never freezes for the wall-clock second granularity of `Time.GetRaw()`.
- Added organization membership/standing on `Player` and `Game.Directives` for
  capacity-limited shared defense. Two NPCs can accept one objective and execute
  distinct `Attack` actions against the same target.
- Added `Game.Communication`: addressed/ranged messages, organization broadcasts,
  bounded inboxes, TTL expiry, and exactly-once draining. Damage sends a threat
  to nearby organization members; `Think` converts it into a defense directive.
- `Attack` now clones cleanly, suppresses passive fire while preempted or when
  its target is dead, and clears its target lock on cancellation.
- `Trader:buy` is now atomic: a full cargo hold rejects the purchase without
  charging credits or consuming the ask.
- Added additive NPC actor snapshots to save/load: stable id, profile,
  organization, standing, credits, and asset count. Restore matches the
  deterministically regenerated brain by stable id; ship-by-ship state and
  tombstones are not yet persisted.

## Phase 1 persistence complete (committed `34f6ed6`, 2026-11-25)

- Added canonical `Game.StableId`, structural `Game.RouteKey`, planned NPC ship
  IDs, and a System stable-ID index. Pooled mine templates refresh route keys on
  retarget; runtime IDs are explicitly non-persistent.
- Save/load now captures actor standings/primary ship plus each ship's transform,
  hull, capacitor, capacity, cargo, docking parent, policy memory/cooldowns, and
  active economy-job checkpoint. Human and NPC docking restore; simulation time
  and sector index are saved.
- Active jobs rebind by structural endpoint keys, wait for streamed sources, and
  recreate the current `MoveTo`/`Stop`/`MineAt`/`DockAt`/`Undock` subaction even
  when its saved name includes a target. Safety retreat is pushed after restore
  so it preempts the job; depleted, tombstoned, stale, and wrong-sector sources
  cancel cleanly.
- Added bounded `Game.Tombstones`, immediate death recording plus sweep fallback,
  and spawn suppression for startup/streamed asteroids, the main station, region
  places, and planned NPC ships. Asteroid tombstones use the same deposit-aware
  fingerprint as knowledge/jobs. Sector transitions remove outgoing places before
  rebuilding the destination.
- World overlays (deposits, tombstones, simulation time) restore before content
  generation; saved sector content and roster seed now match the saved sector.
- Saved rosters are authoritative under `aiShips` changes. Last-ship death
  permanently retires the actor, and tombstoned actor slots stay suppressed.
- `Game.Knowledge` stores fingerprint-checked scan records by structural key.
  Entity maps are rebuildable caches, so stream unload/reload and save/load do
  not lose discoveries. Live scans register immediately, docking retains the
  registration, and both NPC and human ships rebind; depleted rocks stay scanned
  but stop counting as known usable yields.
- ScannerDB contacts use the same structural/fingerprint keys as the HUD and
  target panel, serialize per pilot (including the human), reject malformed or
  wrong-owner payloads, and never attach old yield data to a replacement rock.
- Safety state includes damage, cooldown, threat-broadcast timing, and durable
  or unresolved source keys. Pending knowledge/jobs no longer block retreat or
  damage-handler installation; runtime-only jobs are discarded.
- Module slots have durable `<ship>:module:<type>:<index>` IDs; saved rosters
  regenerate exactly the occupied sockets, including the player ship. Malformed
  module entries and nested numeric snapshot fields are ignored, and the reserved
  `ship:player` identity cannot be tombstoned.
- Asteroid physical/deposit fingerprints invalidate stale state after density,
  region, seed, position, or deposit-generation changes. Startup fingerprints are
  refreshed after final field translation, then tombstones/deposits are applied.
  Legacy unfingerprinted asteroid overlays fail closed.

### NPC sector travel and Phase 2 progression (committed `34f6ed6`, 2026-11-25)

- NPCs route to the correct wormhole (including multi-hop mission routes) and
  approach through the existing `TravelTo`/`Wormhole` path. Gate entry puts the
  actor in persistent sector transit instead of changing the player's sector.
  NPC routing reads the sector gate graph directly; it does not depend on the
  player's target lock.
- Visible wormholes are now player-targetable with **T** despite having no rigid
  body. Target info shows the destination, and **F** prefers the locked gate when
  it is within normal docking range.
- Outgoing local actors are streamed into sector holds, not deleted. Ownership
  is preserved while detached. Active jobs are checkpointed before departure,
  stale action stacks are cleared on arrival, and `pendingJob` rebinds after
  destination content exists. Duplicate roster IDs are excluded.
- Travel uses ordinary thrust and ordinary simulation `dt`. Automatic NPC boost
  is off (`aiUsesBoost=false`); there is no private NPC time scale. Gate logs show
  distance, normal top speed, ETA, entry, and arrival.
- `Config.game.npcLog` enables periodic action/target/position/speed/ETA/hull/
  credit logs plus job, scan, retreat, upkeep, and progression events.
  `PHX_NPC_LOG=1/0` overrides it. Distance/ETA uses a bodyless-safe surface
  fallback for wormholes.
- Phase 2 adds normal-speed `Repair`, `Refit`, and `PurchaseShip` actions, role
  module/hull policy, hourly upkeep/debt, atomic payment/refund, durable module
  slots, cargo transfer, and stable purchased-ship IDs; capital is the terminal
  hull, so purchase policy cannot oscillate back to a smaller role ship. Think
  prioritizes repair, then refit, then affordable hull progression, then travel;
  due goals interrupt
  fighter patrol instead of waiting forever.
- Purchase serials, purchased-hull NPC roles, job checkpoints, and sector
  transit/hold metadata are additive save state. Cross-sector market contracts
  and missions remain future work; current travel is exploration or a future
  `travelTargetSector` assignment.

### Phase 3 utility, perception, and self-preservation (uncommitted; core implemented, phase open)

- `NpcPolicy.score` blends payout/travel with deterministic seeded personality,
  hull-vs-risk, capacitor reserve, cargo load, role/faction duty, endpoint
  relationship, route novelty/cooldowns, and continuity with the committed job.
  Personality is derived from the saved policy seed.
- `Game.NpcPerception` caches short-lived nearby resources, gates, stations,
  planets, and ships. Relationships include organization/disposition and a
  recent damage source; the cache is ephemeral and rebuilt after load.
- Predicted collisions push a temporary `Avoid` action above the current route.
  It picks a deterministic side, steers past the obstacle, then pops so the
  underlying job resumes. `DockAt` excludes its intended berth; this remains
  local avoidance, not global pathfinding.
- Cargo value lowers the retreat threshold, moderated by the pilot's risk
  tolerance. Hopeless defense assignments are declined/released based on hull,
  weapons, and nearby armed allies. Real combat threats interrupt active jobs
  with a leashed `Defend` action and preserve the job below it.
- When `Flee` completes, `Regroup` rejoins a nearby ally at a safe standoff.
  Critical-hull `Repair` can preempt a job; after repair, `Undock` restores the
  committed job.
- Peer-review hardening: attack/dock/defend targets must have a live rigid body
  and parent before transforms are read; terminal directives are pruned;
  cancelled invalid jobs record a policy outcome; Avoid does not recompute or
  overwrite state while its own action is active; hopeless-defense cleanup no
  longer removes unrelated actions; and NPC perception uses a bounded system
  spatial query instead of scanning every streamed asteroid. Think caches the
  action module and keeps per-asset tables keyed weakly.
- Tunables include `npcAvoidance*`, `npcPerception*`, `npcCargoProtectionValue`,
  `npcRegroup*`, and `npcDefense*` under `Config.game`.
- Ships now have regenerating shields in front of hull health. Role hull/shield
  values are fighter 2,500/2,500, freighter 20,000/15,000, industrial
  40,000/25,000, and capital 150,000/50,000; the player's fighter uses the same
  fighter-scale values. Shield state is saved/restored and shown in Target Info
  and the locked-target HUD bar. Retreat is gated by role and relative combat
  strength: hull threshold, accumulated damage as a fraction of maximum hull,
  and overmatch by the attacker. A capital with guns ignores a single fighter
  hit and returns fire; fragile/non-combat hulls still withdraw after sustained
  damage. A qualifying hull hit immediately pushes `Flee` inside the damage
  handler, before the next AI tick; shield hits still register the attacker for
  retaliation without counting as hull damage.
- Combat power now consumes actual installed weapon DPS, range/projectile speed,
  hull/shield state, and capacitor reserve instead of turret count alone.
  Thruster/turret equipment tiers therefore change both real combat and AI threat
  assessment. NPC roles mount different turret counts (fighter/freighter 1 pair,
  industrial 2, capital 3), so capitals actually bring more guns to an engagement.
  Projectiles snapshot their damage at firing, and firing requires a valid
  in-range lead solution. Combat-capable NPCs remember the attacker and can
  retaliate with `Attack` after retreating; non-combat hulls flee/regroup instead.
- Explosion particles now scale in count, sprite size, debris speed, and lifetime
  with hull scale. A capital no longer produces the same tiny burst as a fighter;
  lethal hull damage is covered by an explosion-emission regression test.
- The dock screen now has a **SHIP SERVICES** tab at shipyards: repair hull and
  shields, install real Mk I–III thruster/turret upgrades, choose from all four
  hulls, and apply condition-adjusted trade-in. A shared progression wallet
  supports NPC actor credits and the human player's ship credits with atomic
  payment/refund. Player purchases preserve residual credits and restore the
  purchased hull/prototype/capacity/equipment/purchase serial on load.
- NPC service selection now validates station capabilities. Refits and purchases
  require a real shipyard; repairs and market needs require a usable station.
  Failed services apply a retry cooldown instead of logging/retrying every frame.
  If no suitable local station exists, NPCs route through the sector gate graph
  to the nearest station/shipyard; idle carriers with goods likewise route to a
  market. Service destination/retry state persists and arrival resumes service
  selection immediately.
- Focused coverage: policy — 26, jobs — 58, safety — 39, cooperation — 44,
  travel — 16, perception — 11, Avoid — 7, Defend — 11, Regroup — 5,
  progression — 67, save — 56, phase-one roster — 29. Shield (6), explosion FX
  (6), progression wallet (6), dock services (14), ship equipment (13),
  equipment runtime (10), ship loadout (7), and Phase 2 services (13) add focused
  coverage. In-game dense-field, combat, repair, routing, and travel behavior
  still needs visual approval and balance tuning.

### Docking UI hardening (committed `34f6ed6`, 2026-11-25)

- `DockAt` and `Undock` synchronize the station screen immediately through the
  app, rather than waiting solely on the next-frame watcher.
- Opening the dock page silently closes any menu/popup above it; HUD gameplay
  actions cannot start while a modal screen has paused the world.
- `DockScreen:undock()` and the `Undock` action are idempotent, so focused/child
  input routing or repeated F presses cannot stack duplicate undocks.
- `[DOCK]` transition logs report state, station, action count, and screen state.

Tests added and passing:

- `tools/validate_ship_movement.lua` — 15 checks.
- `tools/validate_npc_identity.lua` — 16 checks.
- `tools/validate_npc_lifecycle.lua` — 61 checks, including one-update-per-frame,
  target cleanup, ownership transfer, nested death cleanup, and social registry
  lifecycle.
- `tools/validate_npc_policy.lua` — 26 checks.
- `tools/validate_npc_jobs.lua` — 58 checks, including cloned assignments,
  completion/cancellation memory, damage-driven job preemption, and pending-data
  safety/fingerprint handling.
- `tools/validate_npc_safety.lua` — 39 checks.
- `tools/validate_npc_cooperation.lua` — 44 checks.
- `tools/validate_npc_communication.lua` — 13 checks.
- `tools/validate_npc_trade.lua` — 10 checks.
- `tools/validate_npc_save.lua` — 56 checks.
- `tools/validate_npc_actions.lua` — 16 checks.
- `tools/validate_control_delta.lua` — 6 checks.
- `tools/validate_camera_bracket.lua` — 4 checks.
- `tools/validate_hud_lifecycle.lua` — 2 checks.
- `tools/validate_docking.lua` — 15 checks.
- `tools/validate_cargo.lua` — 9 checks.
- `tools/validate_deposits.lua` — 12 checks.
- `tools/validate_stable_id.lua` — 32 checks.
- `tools/validate_module_identity.lua` — 3 checks.
- `tools/validate_tombstones.lua` — 10 checks.
- `tools/validate_asteroid_tombstones.lua` — 4 checks.
- `tools/validate_asteroid_fingerprints.lua` — 14 checks.
- `tools/validate_phase1_roster.lua` — 29 checks.
- `tools/validate_npc_travel.lua` — 16 checks.
- `tools/validate_npc_perception.lua` — 11 checks.
- `tools/validate_npc_avoid.lua` — 7 checks.
- `tools/validate_npc_defend.lua` — 11 checks.
- `tools/validate_npc_regroup.lua` — 5 checks.
- `tools/validate_npc_progression.lua` — 67 checks.
- `tools/validate_knowledge.lua` — 14 checks.
- `tools/validate_startup_field.lua` — 11 checks.
- `tools/validate_player_mining.lua` — 33 checks.
- `tools/validate_stop_action.lua` — 5 checks.
- `tools/validate_scan_action.lua` — 10 checks.
- `tools/validate_scan_effect.lua` — 8 checks.
- `tools/validate_npc_scanning.lua` — 7 checks.
- `tools/validate_npc_population.lua` — 24 checks.
- `tools/validate_patrol_action.lua` — 5 checks.
- `tools/validate_ship_archetypes.lua` — 14 checks.
- `tools/validate_ship_generator_profile.lua` — 4 checks.
- `tools/validate_ship_type_fallback.lua` — 3 checks.
- `tools/validate_radar.lua` — 19 checks.
- `tools/validate_target_info.lua` — 18 checks.
- `tools/validate_wormhole_targeting.lua` — 13 checks.
- `tools/validate_registry_scanner.lua` — 37 checks.
- `tools/validate_mining_beam.lua` — 12 checks.
- `tools/validate_npc_panel.lua` — 4 checks.
- `tools/validate_capital_ship.lua` — 12 checks.
- `tools/validate_shield.lua` — 6 checks.
- `tools/validate_explosion_fx.lua` — 6 checks.
- `tools/validate_progression_wallet.lua` — 6 checks.
- `tools/validate_dock_services.lua` — 14 checks.
- `tools/validate_ship_equipment.lua` — 13 checks.
- `tools/validate_equipment_runtime.lua` — 10 checks.
- `tools/validate_ship_loadout.lua` — 7 checks.
- `tools/validate_phase2_services.lua` — 13 checks.
- `tools/validate_startup_placement.lua` — 8 checks.

Phase 1 is complete. NPC gate travel/sector holds are implemented and tested.
The current uncommitted work completes the Phase 2 ship-progression/services
slice and implements the core Phase 3 autonomy/combat behaviors, but Phase 3 is
not closed: dense-field tuning and real-play validation remain. Later work still
includes cross-sector market contracts, player-facing comms UI, salvage/gas
harvesting, escort/rescue cooperation, and missions. Cooperation currently covers
shared defense only.

## Next steps (NPC standpoint)

1. **Phase 3 tuning and visual sign-off.** Validate dense-field avoidance,
   combat/retaliation, flee/regroup/defend, repair, station routing, and sector
   travel in a real play session; tune thresholds and performance from results.
2. **Phase 2 visual/economic sign-off.** Approve repair/refit/purchase/trade-in
   pricing, upkeep, module upgrades, and the full mine → sell → service loop.
3. **Cross-sector contracts.** Generate deterministic destination-market work
   so `travelTargetSector` is mission-driven rather than exploration-only.
4. **Cooperation beyond shared defense.** Escort, rescue, miner protection,
   pooled contracts, and shared credit/reputation using the existing directive
   and communication buses.
5. **Player-facing communication.** Hails, mission offers, threat warnings, and
   discovery reports built on `Game.Communication`.
6. **Salvage and gas harvesting.** Persistent wreck yields/forensics and
   equipment-gated `Helium3` capture, then let policy choose among mining,
   salvage, trading, and harvesting.
7. **Missions and long-term progression.** Faction/player contracts, reputation,
   unlocks, and recurring relationships.
8. **Ship Generator workflow.** Rebuild/preview/export controls and direct custom
   hull assignment; slider changes currently do not invalidate cached prototypes.

## Ship Generator tool status

NPC hulls are deterministic procedural meshes, not hand-modelled assets. The
population planner supplies a seed per role/variant; `ShipType` generates and
caches one prototype, then live ships are instances of that prototype. The F9
**Ship Generator** section currently exposes the global `genship.*` parameters
only. It does not yet export a mesh or assign a custom generated hull directly
to an NPC, and already-cached prototypes do not rebuild when a slider changes.

## Design-spec review and selected implementation

Implemented from the supplied v1.0 specification:

- Nodal Registry foundation: Class I–IV icons, material tiers, mass multipliers,
  stable ship registry IDs, and `[Icon] [Manufacturer] [Model] Y###` names.
- Scanner Database foundation: per-pilot contacts, highest T1–T4 resolution,
  positions, yield identification, and bounded forensic log entries.
- Visible resource scanning and NPC discovery behavior leading into extraction.

Natural next slices from the document are the Broad-Beam Pulse, persistent
wreck blackboxes/forensic recovery, and the T1→T4 industrial pipeline. The
energy-backed ledger, sovereignty/relay territory, and full research economy
remain larger separate projects.

## Refactor plan

### North star: an NPC is a persistent player

The target design is not a special “NPC script” running beside the player. An
NPC is a persistent `Player`-like entity with:

- a seeded identity, personality, home sector, and faction membership;
- credits, inventory, owned ships, and equipment;
- goals, commitments, cooldowns, memory, and relationships;
- the same actions and world interactions available to a player.

Rendering, physics, trading, mining, docking, combat, and wormhole travel use
the same engine systems for humans and NPCs. NPC-specific code decides **what
to do and why**, not how to exist in the world.

The engine does **not** need a procedural-generation rewrite. The shortest
correct path is to extend `Entity`, `Component`, `ShipType`, `Action`,
`Economy`, and `Think` with identity, lifecycle, policy, and social layers.

### Existing building blocks

Already present and reusable:

- `Entities.Player`, owner/assets, credits, inventory, and dispositions;
- `ShipType` plus procedural fighter/capital generators;
- `Action` stacks: `Think`, `MoveTo`, `MineAt`, `DockAt`, `Undock`, `Escort`,
  `Attack`, and `Wait`;
- economy jobs (`Mine`, `Transport`), markets, traders, yields, and factories;
- asteroid yields and commodity definitions, including nebula gas;
- wormhole docking/transfer between sectors;
- deterministic seeds and the existing save/load framework.

Implemented foundations now available:

- explicit human-vs-NPC identity, stable registry IDs, and lifecycle cleanup;
- organization membership/standing and shared defense directives;
- route-aware utility policy, cooldowns, memory, and cloned committed jobs;
- ranged NPC-to-NPC communication and damage-driven flee;
- mixed procedural role fleet and sector-roster reconciliation;
- authoritative actor/ship rosters, durable module slots, policy/job checkpoints,
  simulation time, saved sector, ScannerDB/safety/knowledge memory, fingerprinted
  asteroid deposits, bounded tombstones, and last-ship actor retirement;
- structural route keys and planned ship IDs.

Still missing or incomplete:

- cross-sector market contracts and mission-driven route selection;
- player-facing communication UI;
- wreck salvage and nebula harvesting actions;
- escort/rescue cooperation beyond shared defense;
- dense-field avoidance tuning and visual combat/travel/repair approval;
  global pathfinding and broader mission-driven goals remain.

### Phase status (2026-11-26)

- **Phase 0 — complete:** visibility, targeting, lifecycle, projectile, and
  movement regressions are covered; real boot and UI integration pass.
- **Phase 1 — complete:** authoritative rosters, stable ship/module IDs,
  physical/cargo snapshots, policy/cooldowns, active-job checkpoints, structural
  routes, simulation time, saved sector, ScannerDB/safety/knowledge memory,
  fingerprinted asteroid overlays, bounded tombstones, and last-ship actor
  retirement are implemented and tested.
- **Phase 2 — implementation complete, visual/economic sign-off pending:** canonical
  four-hull and equipment catalogs, real thruster/turret tiers, normal-speed
  repair/refit/purchase/upkeep, role progression policy, atomic payments,
  condition-adjusted trade-in, cargo/credit transfer, purchase serial and
  equipment persistence, and a player-selectable shipyard catalog are implemented
  and tested.
- **Phase 3 — core implementation complete, phase open:** multidimensional
  utility, local perception, Avoid/Flee/Repair/Regroup/Defend behaviors,
  damage/cargo-aware self-preservation, hopeless-fight avoidance, job
  interruption, route memory, and station-service routing are implemented and
  covered. The phase is not closed: dense-field performance/tuning and in-game
  combat/travel/repair/routing validation remain.
- **Phase 4 — shared defense only:** directives, capacity limits, and
  organization standing exist; escort/rescue/contracts remain.
- **Phase 5 — backend complete:** ranged addressed/broadcast messages, TTL,
  inboxes, and threat/directive flow exist; player-facing comms UI remains.
- **Phase 6 — travel/streaming slice complete:** correct-gate routing,
  normal-speed approach, persistent transit, outgoing sector holds, destination
  restore, duplicate exclusion, and save/load continuity are implemented and
  tested. Cross-sector market contracts remain.
- **Phases 7–8 — open:** salvage/gas harvesting, missions, reputation, and
  long-term progression.

### Phase 0 — Stabilize and prove the current fixes

- Keep all work uncommitted until the user approves it.
- Add focused regression tests for:
  - J/K/U never selecting the human ship;
  - dead/bodyless NPCs excluded from targeting;
  - target panel drawing with a bodyless System root;
  - projectile matrix initialization before first render;
  - capital prototype/scale/module/mass/thrust consistency;
  - nearby capital spawns actually rendering and moving.
- Acceptance: the demo boots cleanly, real capital hulls are visible, J/K/U and
  firing do not crash, and the target panel stays readable and contained.

### Phase 1 — NPC identity, persistence, and lifecycle

- Add an explicit NPC profile/component rather than inferring NPC status from
  `getOwner()`.
- Profile fields: name, personality, faction, home sector, credits, reputation,
  goals, memory, and current ship.
- Maintain a stable NPC registry with add/remove hooks across sector changes.
- Remove destroyed NPCs from owner assets, target lists, tracking lists, and
  the registry in one lifecycle path.
- Clear stale player locks immediately on target death.
- Acceptance: no stale target/body/registry entries after death or sector
  unload; NPC identity survives travel and save/load.

### Phase 2 — Player-like economy and ship progression

Make wealth change what the NPC can do, not just its score:

- NPCs earn credits through mining, trading, contracts, and faction work.
- Add repair, refit, and ship-purchase actions using existing inventory/credits.
- Add ship profiles and shipyard/market integration.
- NPCs buy larger or specialized hulls when profitable: miner, freighter,
  escort, patrol, salvage, gas harvester.
- Add upkeep costs so self-preservation and profit both influence decisions.
- Acceptance: an NPC can mine → sell → repair/upgrade → buy a better ship →
  take on more profitable or dangerous work.

### Phase 2 implementation notes (2026-11-26)

The canonical hull catalog is Fighter (18,000 CR), Freighter (55,000 CR),
Industrial (95,000 CR), and Capital (280,000 CR). Full repairs cost 12%, 15%,
18%, and 20% of hull value respectively; upkeep is 0.02% of hull value per
simulated hour. Trade-in is 35% of hull value adjusted by average hull/shield
condition. Buying replaces the current hull, applies trade-in as a discount,
and returns any excess on a downgrade; there is no sell-last-hull state.

Thrusters and pulse turrets each have Mk I–III definitions. Thruster tiers
change force and torque; turret tiers change per-projectile damage, range, and
speed. NPC combat power consumes actual installed DPS. Module rows persist
`equipmentId` additively, old saves default to Mk I, and malformed/wrong-type
IDs fail closed. Player purchases preserve residual credits and restore the
purchased hull/prototype/capacity/modules/purchase serial on load. Actual turret
layout and upkeep debt/partial-hour progress persist additively; legacy snapshots
use the historical two-pair layout. Saving settles paid unfinished repairs
through the normal refund path instead of losing their prepayment. Refits only
select real shipyards, service failures back off instead of retrying every
frame, and NPCs missing a required local station/shipyard route through the gate
graph to the nearest suitable sector. Service destination/retry state persists,
and arrival resumes service selection immediately. Idle carriers with goods
also route to a market when their current sector has none.

### Phase 3 — Utility goals, memory, and self-preservation

Replace “highest payout every time” with a utility scheduler:

- **Brain:** scores goals using profit, safety, hull state, capacitor, cargo,
  faction duty, personality, relationships, and current commitments.
- **Ship action stack:** executes navigation and tactics.
- Add per-NPC cooldowns, job memory, route novelty, and interruption rules.
- Add local perception for threats, allies, resources, stations, and gates.
- Add `Avoid`, `Flee`, `Repair`, `Regroup`, and `Defend` actions.
- Self-preservation priorities: retreat under heavy damage, avoid hopeless
  fights, seek repair, protect valuable cargo, and avoid collisions.
- Acceptance: caps choose different plausible actions, avoid each other,
  interrupt jobs for real threats, and do not repeat one route indefinitely.

### Phase 4 — Factions, cooperation, and protection

- Add faction/guild records: roster, treasury, standing, home sector,
  shipyard access, contracts, and shared intelligence.
- NPCs can accept faction contracts, pool resources, escort traders, defend
  miners, rescue damaged allies, and coordinate against aggressors.
- Cooperation uses the same action stack plus shared goals/targets.
- Acceptance: two NPCs can perform a coordinated job such as escorting a
  freighter or defending a mining partner, with shared credit/reputation.

### Phase 5 — Communication and shared knowledge

- Add a lightweight simulation message bus for job offers, threats,
  discoveries, mission requests, and faction notices.
- NPC memory stores relevant messages and relationships over time.
- Faction members share local threat/resource intel within communication
  limits.
- Add player-facing comms later: hails, mission offers, threat warnings, and
  discovery reports.
- Acceptance: a threat or rich asteroid seen by one NPC can influence allies;
  the player can eventually receive useful NPC communications.

### Phase 6 — Inter-sector travel

- NPCs choose jobs across sectors when the expected payoff justifies travel.
- Add `TravelToGate`, `DockAtWormhole`, and destination-side continuation
  actions using the existing wormhole transfer path.
- Stream NPCs with sectors without duplicating their persistent identity or
  resetting credits/inventory.
- Acceptance: an NPC can dock at a wormhole, arrive in another sector, and
  continue its job with the same ship, cargo, money, and faction standing.

### Phase 7 — Advanced harvesting and salvage

- Asteroid mining already has yields; extend it with better equipment and
  rarity/value decisions.
- Add ship wrecks as persistent salvage entities with cargo/equipment yields.
- Add nebula gas harvesting as a specialized job/equipment path using the
  existing region/environment field and `Helium3`.
- Acceptance: NPCs choose between asteroid mining, wreck salvage, trading,
  and gas harvesting based on equipment, risk, and profit.

### Phase 8 — Missions and long-term progression

- Generate contracts from faction/player needs: escort, defense, delivery,
  salvage, exploration, and resource acquisition.
- NPCs build reputation, unlock better contracts, and gain access to faction
  ships/equipment.
- Persist NPC/faction state in save/load.
- Acceptance: NPCs have visible long-term progression and can form ongoing
  working relationships with the player and each other.

## First playable milestone — status

1. ✅ Real capital ships are visible and move correctly.
2. ✅ J/K/U, targeting info, and firing are stable.
3. ✅ NPCs choose among several economy jobs without repeating one route.
4. ◐ Damage-driven flee, local avoidance, repair seeking, and regroup are
   implemented; dense-field behavior still needs visual approval.
5. ◐ Two NPCs can cooperate on shared defense; escort/rescue remain.

The core “NPC as player” architecture is proven. Durable ships, sector travel,
the Phase 2 progression/services slice, and core Phase 3 autonomy are implemented.
The next milestone is Phase 3 tuning/visual validation, followed by mission-driven
cross-sector work and broader social gameplay.

### Execution order for `npc-work`

1. **Phase 6 travel/streaming:** complete; cross-sector market contracts remain.
2. **Phase 2 progression:** implementation and focused tests complete; visual and
   economic repair/refit/purchase/trade-in approval remains.
3. **Phase 3:** core implementation is present; tune dense-field avoidance and
   get visual combat/travel/repair/station-routing approval before closing it.
4. Then cross-sector contracts, escort/rescue cooperation, player comms,
   salvage/gas harvesting, and missions as each slice is tested.

Each completed slice must update this document with:
- what changed;
- which tests prove it;
- known limitations;
- what remains for user visual approval.

## Direction notes

- NPC caps are real ships using the same `Ship` archetype as the player.
- Procedural generation, rendering, physics, actions, economy, and wormholes
  already exist.
- Identity/lifecycle, utility policy, durable ships, sector travel, Phase 2
  progression/services, core Phase 3 autonomy, shared defense, and communication
  foundations now exist. Remaining work is **Phase 3 tuning/visual validation,
  cross-sector contracts, and broader social gameplay**.
- Generic targeting for asteroids/stations/factories is implemented and remains
  entity-generic.

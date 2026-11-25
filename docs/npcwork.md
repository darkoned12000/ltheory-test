# NPC Work — Findings, Current Fixes, and Refactor Plan

## Status

- Active branch: `npc-work`, created from merged `main` at `d905da2`.
- All new work remains **uncommitted** until the user has tested and discussed
  it. Existing merged WIP history is intentionally preserved.
- NPC ship generation was **never missing**. The problems were prototype,
  scale/distance, lifecycle, targeting, and AI-policy issues.
- Baseline verification on `npc-work`: `python3 configure.py test` passes,
  including shader validation and the UI integration smoke test.
- Final uncommitted verification: all 462 focused NPC/movement/mining/registry/
  population/radar checks pass; `python3 configure.py test` passes including UI integration; a 25-second
  real LTheory boot on the pinned seed logs no errors/asserts before intentional
  timeout. No new commits have been made.
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

## Current uncommitted fixes

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

## Completed on `npc-work` (uncommitted)

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

Tests added and passing:

- `tools/validate_ship_movement.lua` — 15 checks.
- `tools/validate_npc_identity.lua` — 16 checks.
- `tools/validate_npc_lifecycle.lua` — 59 checks, including one-update-per-frame,
  target cleanup, ownership transfer, nested death cleanup, and social registry
  lifecycle.
- `tools/validate_npc_policy.lua` — 10 checks.
- `tools/validate_npc_jobs.lua` — 28 checks, including cloned assignments,
  completion/cancellation memory, and damage-driven job preemption.
- `tools/validate_npc_safety.lua` — 15 checks.
- `tools/validate_npc_cooperation.lua` — 23 checks.
- `tools/validate_npc_communication.lua` — 13 checks.
- `tools/validate_npc_trade.lua` — 10 checks.
- `tools/validate_npc_save.lua` — 11 checks.
- `tools/validate_npc_actions.lua` — 16 checks.
- `tools/validate_control_delta.lua` — 6 checks.
- `tools/validate_camera_bracket.lua` — 4 checks.
- `tools/validate_hud_lifecycle.lua` — 2 checks.
- `tools/validate_docking.lua` — 12 checks.
- `tools/validate_cargo.lua` — 9 checks.
- `tools/validate_deposits.lua` — 10 checks.
- `tools/validate_startup_field.lua` — 7 checks.
- `tools/validate_player_mining.lua` — 30 checks.
- `tools/validate_stop_action.lua` — 5 checks.
- `tools/validate_scan_action.lua` — 9 checks.
- `tools/validate_scan_effect.lua` — 8 checks.
- `tools/validate_npc_scanning.lua` — 7 checks.
- `tools/validate_npc_population.lua` — 22 checks.
- `tools/validate_patrol_action.lua` — 5 checks.
- `tools/validate_ship_archetypes.lua` — 14 checks.
- `tools/validate_ship_generator_profile.lua` — 4 checks.
- `tools/validate_ship_type_fallback.lua` — 3 checks.
- `tools/validate_radar.lua` — 19 checks.
- `tools/validate_target_info.lua` — 16 checks.
- `tools/validate_registry_scanner.lua` — 23 checks.
- `tools/validate_mining_beam.lua` — 12 checks.
- `tools/validate_npc_panel.lua` — 3 checks.
- `tools/validate_capital_ship.lua` — 8 checks.
- `tools/validate_startup_placement.lua` — 8 checks.

Known remaining work: NPC actor identity/profile/organization/credits and
asteroid deposit remainders are saved, but ship-by-ship state, policy memory,
and destroyed-asteroid tombstones are not. Route keys still use runtime entity
IDs and are therefore session-only. Repair/refit/ship purchases, player-facing
comms UI, salvage/gas harvesting, and true cross-sector job continuation are
not implemented yet. Registry metadata and ScannerDB records are session-only.
NPC ship rosters reconcile on sector entry, but outgoing station/place cleanup
and durable cross-sector actor/ship state remain future work. Cooperation covers
shared defense only. World-space visibility and combat behavior still need the
user's visual approval in a real play session.

## Next steps (NPC standpoint)

1. **Persist ships, not just actors.** Save/restore each NPC's ship, cargo,
   hull/capacitor, equipment, current action/job, policy memory, and destroyed
   entity tombstones. Replace runtime route IDs with stable structural keys.
2. **Cross-sector continuation.** Carry the same NPC and ship through a
   jumpgate, resume the committed job on arrival, and avoid duplicate brains or
   reset credits/inventory. Reconcile outgoing station/place children too.
3. **Repair/refit/purchase loop.** Add repair, refit, upkeep, and shipyard
   actions so wealth changes hull choice and self-preservation has a concrete
   destination.
4. **Local perception and avoidance.** Add obstacle/avoidance steering, repair
   seeking, regroup, and non-hostile combat readability; validate the current
   flee/attack behavior visually.
5. **Cooperation beyond shared defense.** Escort, rescue, miner protection,
   pooled contracts, and shared credit/reputation using the existing directive
   and communication buses.
6. **Player-facing communication.** Hails, mission offers, threat warnings, and
   discovery reports built on `Game.Communication`.
7. **Salvage and gas harvesting.** Persistent wreck yields/forensics and
   equipment-gated `Helium3` capture, then let policy choose among mining,
   salvage, trading, and harvesting.
8. **Missions and long-term progression.** Faction/player contracts, reputation,
   unlocks, and recurring relationships.
9. **Ship Generator workflow.** Rebuild/preview/export controls and direct custom
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
- additive actor and asteroid-deposit save state.

Still missing or incomplete:

- durable ship-by-ship state and cross-sector job continuation;
- ship purchase/upgrade/repair/upkeep economy;
- player-facing communication UI;
- wreck salvage and nebula harvesting actions;
- stable structural route keys and destroyed-entity tombstones;
- escort/rescue cooperation beyond shared defense;
- robust local avoidance, repair/regroup behavior, and visual combat approval.

### Phase status (2026-11-24)

- **Phase 0 — complete:** visibility, targeting, lifecycle, projectile, and
  movement regressions are covered; real boot and UI integration pass.
- **Phase 1 — foundation complete:** identity/registry/lifecycle and additive
  actor snapshots exist; ship-by-ship persistence and tombstones remain.
- **Phase 2 — open:** repair/refit/purchase/upkeep progression.
- **Phase 3 — first slice complete:** utility, route memory, cooldowns,
  commitment, patrol, and damage-driven flee exist; avoidance/repair/regroup and
  broader perception remain.
- **Phase 4 — shared defense only:** directives, capacity limits, and
  organization standing exist; escort/rescue/contracts remain.
- **Phase 5 — backend complete:** ranged addressed/broadcast messages, TTL,
  inboxes, and threat/directive flow exist; player-facing comms UI remains.
- **Phase 6 — roster reconciliation only:** deterministic sector rosters do not
  accumulate, but the same ship/job does not yet continue across sectors.
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
4. ◐ Damage-driven flee is implemented; robust collision avoidance, repair
   seeking, and regroup remain.
5. ◐ Two NPCs can cooperate on shared defense; escort/rescue remain.

The core “NPC as player” architecture is proven. The next milestone is durable
ships and cross-sector continuation, followed by progression and broader social
gameplay.

### Execution order for `npc-work`

1. **Phase 1 completion:** persist ship-by-ship state, stable route keys, and
   destroyed-entity tombstones.
2. **Phase 6:** continue the same NPC/ship/job through jumpgates and reconcile
   outgoing place/station children.
3. **Phase 2:** repair/refit/purchase/upkeep progression.
4. **Phase 3 completion:** local avoidance, repair/regroup, and visual combat
   approval.
5. Then escort/rescue cooperation, player comms, salvage/gas harvesting, and
   missions as each slice is tested.

Each completed slice must update this document with:
- what changed;
- which tests prove it;
- known limitations;
- what remains for user visual approval.

## Direction notes

- NPC caps are real ships using the same `Ship` archetype as the player.
- Procedural generation, rendering, physics, actions, economy, and wormholes
  already exist.
- Identity/lifecycle, utility policy, shared defense, and communication
  foundations now exist; the remaining work is **durable ships, progression,
  cross-sector continuation, and broader social gameplay**.
- Generic targeting for asteroids/stations/factories is implemented and remains
  entity-generic.

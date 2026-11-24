# NPC Work — Findings, Current Fixes, and Refactor Plan

## Status

- All work is currently **uncommitted** and must remain uncommitted until the
  user has play-tested it and explicitly approved it.
- The working tree is based on `main` at `034cff8`; `origin/main` contains the
  earlier AI-economy activation commit `e5c7a42`.
- NPC ship generation was **never missing**. The problems were prototype,
  scale/distance, lifecycle, targeting, and AI-policy issues.

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
- Two AI capitals are placed in the player's forward hemisphere after the
  player's final spawn position is known, so the demo has visible hulls.
- Thrust scales with ship mass and torque scales with approximate inertia, so
  large capital hulls remain mobile instead of inheriting fighter thrust.
- `System:npcTargets(exclude)` filters dead/bodyless/deleted entities and the
  querying ship.
- `NpcInfoPanel` uses the player's controlling ship for distance.
- Projectile construction runs the Pulse initializer.
- The target panel is themed like the sector panel, anchored lower-right, omits
  the long job line, and shows a contained CPU wireframe preview.
- `Math.Impact` now handles the degenerate `a == 0` case and uses the correct
  quadratic denominator for both roots.
- `metal.glsl` has a modest brightness/Fresnel rim improvement for dark hulls.

These fixes are verified by targeted boots and the real J/K/U + fire path, but
still require user visual approval.

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

Missing or incomplete:

- explicit human-vs-NPC identity and persistent NPC registry;
- faction/guild data and shared objectives;
- NPC memory, utility policy, cooldowns, and job commitment;
- NPC-to-NPC and NPC-to-player communication;
- ship purchase/upgrade/repair economy;
- wreck salvage and nebula harvesting actions;
- sector streaming and save/load for NPC/faction state;
- robust threat response and cooperative behavior.

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

## First playable milestone

The first milestone should deliberately be smaller than the full design:

1. Real capital ships are visible and move correctly.
2. J/K/U, targeting info, and firing are stable.
3. NPCs choose among several economy jobs without repeating one route.
4. NPCs avoid collisions and react to damage by fleeing or seeking repair.
5. At least one pair of NPCs can cooperate on an escort or defense task.

That proves the “NPC as player” architecture before adding communication,
ship markets, salvage, and cross-sector progression.

## Direction notes

- NPC caps are real ships using the same `Ship` archetype as the player.
- Procedural generation, rendering, physics, actions, economy, and wormholes
  already exist.
- The remaining work is **identity/lifecycle, AI policy, social systems,
  progression, and persistence**, not turning generation on.
- Generic targeting for asteroids/stations/factories can follow after the NPC
  loop is stable; the target-info architecture should remain entity-generic.

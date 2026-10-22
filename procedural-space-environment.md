Absolutely. I’d save this as a companion design note next to the fog-nebula plan—something like docs/procedural-space-environment.md. I’ve turned the feedback into a repo-ready document and kept the implementation principles explicit so it can serve as a future roadmap rather than just notes.
Procedural Space Environment — Visual Direction & Architecture

    Design note / future roadmap
    Companion to: fog-nebula volumetric dust / nebula / lightning plan
    Goal: make deep space feel endless, alive, enormous, and visually coherent without relying on hand-placed effects.

1. Core Vision

The visual goal is not simply "add more effects."

The goal is to make the player feel that space itself is a continuously generated medium with structure, motion, scale, weather, and environmental history.

The player should be able to travel indefinitely without the world feeling like a sequence of disconnected procedural encounters.

Instead:

    The statistical properties of space continuously change as a function of world position.

There should be no obvious boundary where a "nebula effect starts."

Conceptually:

empty
  ↓
faint dust
  ↓
dust + gas
  ↓
dense cloud
  ↓
nebula
  ↓
storm activity
  ↓
nebula edge
  ↓
dust
  ↓
asteroid field
  ↓
empty space

Everything transitions continuously.
2. The Important Architectural Idea: SpaceField

Create a procedural environmental field above the individual renderers.

Instead of every subsystem independently generating content:

nebula generator → nebula
asteroid generator → asteroids
dust generator → dust
storm generator → lightning

use a shared environmental field:

                    SpaceField
                       │
        ┌──────────────┼──────────────┐
        │              │              │
        ▼              ▼              ▼
     Nebula           Dust         Asteroids
        │              │              │
        └──────────────┼──────────────┘
                       │
                       ▼
                   Storms/Events

Conceptually:

SpaceField(worldPosition, galaxySeed)

returns deterministic environmental properties.

Potential outputs:

macroDensity
nebulaDensity
dustDensity
asteroidDensity
starVisibility
turbulence
temperature
radiation
stormPotential
palette
anisotropy

The renderer, object generator, and event system all consume the same underlying field.

This is what makes procedural environments feel authored rather than random.

It is also what makes §6 and §7 possible at all: because every subsystem
reads the SAME function, they cannot disagree about what kind of place
they are in. See §29a — "a region is a field value, not an object in a
list" is the load-bearing idea here, and it is why the four subsystems that
today own private hash schemes (nebula, asteroids, lightning, dust) are
replaced by one field rather than extended.
3. Procedural Space Should Exist at Multiple Scales

A major source of visual scale is hierarchical spatial frequency.
Macro scale

Millions of kilometers or more:

galactic regions
nebula complexes
empty-space regions
star density
overall dust density
asteroid probability

Meso scale

Hundreds to tens of thousands of kilometers:

dust banks
nebula plumes
asteroid fields
debris streams
ionized regions
turbulence
storm regions

Micro scale

Meters to kilometers:

dust particles
small rocks
sparks
fine volumetric detail
local debris

The combination creates the feeling that the player is moving through an environment with enormous depth rather than flying through a flat skybox.
4. The Universe Should Be Deterministic

The environment should be generated from:

f(worldPosition, seed)

rather than relying on persistent random state.

The same world coordinate should always produce the same environmental identity.

Use hierarchical deterministic seeds:

Galaxy seed
    │
    ├── Region seed
    │      │
    │      ├── Nebula seed
    │      ├── Asteroid seed
    │      ├── Dust seed
    │      └── Storm seed
    │
    └── Local cell seed
           │
           ├── Particle seed
           └── Event seed

Prefer coordinate-derived hashing:

hash(worldCell, subsystem, galaxySeed)

over global random state.

Benefits:

    reproducibility
    stable save/load behavior
    deterministic screenshots
    no popping when crossing cells
    potential future multiplayer synchronization
    deterministic procedural streaming
    easier debugging

Do not use per-frame random state as spatial identity.
5. Infinite Space Through Finite Generation

The game does not need to store an infinite universe.

It only needs to maintain the illusion of one.

Use spatial cells/chunks around the player:

          ┌─────┬─────┬─────┐
          │     │     │     │
          ├─────┼─────┼─────┤
          │     │ 🚀  │     │
          ├─────┼─────┼─────┤
          │     │     │     │
          └─────┴─────┴─────┘

Cells are generated deterministically from their coordinates.

Only nearby content needs to become actual entities/renderable objects.

Farther content can remain a statistical field.

This gives:

near → actual geometry / particles / volumes
mid  → simplified procedural representation
far  → density/statistical representation

This should eventually integrate naturally with the streaming/LOD work in ROADMAP #13.

The same cell structure applies one level up: a SECTOR is the unit that is
generated and named, and a REGION is a named volume inside it. See §29a and
ROADMAP #13i.
6. Give Every Large Region a Personality

A region should not merely have a different color.

It should have a deterministic environmental identity.

Example:

Region
{
    seed
    palette
    density
    turbulence
    dust
    asteroid
    starVisibility
    temperature
    radiation
    anisotropy
    stormChance
}

Possible region archetypes:
Silent Deep

very dark
almost no dust
extremely clear stars
occasional distant nebulae
very low event activity

Violet Veil

purple gas
heavy dust
strong forward scattering
reduced star visibility
frequent lightning

Shattered Belt

low gas
high asteroid density
debris
dust trails
large-scale rock clusters

Solar Graveyard

warm orange haze
strong directional lighting
high radiation
frequent storms
strong sun interaction

The player should feel that they have entered a different environment, not simply crossed an invisible gameplay boundary.

SEE §29a. The archetype list above is a set of PRESETS for a region's
parameters, not an enumeration of what a sector may contain: a sector may
be one vast region with no archetype at all (a belt, a trade hub, contested
space), or six regions that include some of these. Regions are PLACED, and
their boundaries are SOFT — identity is discrete, appearance is continuous.
7. Region Transitions Are as Important as Regions

Avoid hard procedural boundaries.

Bad:

Region A
──────────────
Region B

Better:

Region A
       ╲
        ╲
         ╲
          ╲──── transition ────╲
                                Region B

Continuously interpolate:

density
color
star visibility
asteroid probability
turbulence
radiation
storm probability

over large distances.

The player should think:

    "Something is changing."

not:

    "I entered a new procedural zone."

SEE §29a. "Soft boundary" here means the region IDENTITY is discrete (a
name changes, and later a rule may change) while the APPEARANCE is
continuous (every parameter interpolates across a transition band). One
mechanism, not two: the field is blended toward its neighbours' fields at
the boundary, so §6 and §7 are satisfied by the same thing.

8. Procedural Nebulae Should Be Structures, Not Just Fog

The volumetric fog renderer is the foundation, but large nebulae should eventually become recognizable structures.

A nebula can consist of:

NebulaStructure
    ├── primary volume
    ├── secondary plumes
    ├── wisps
    ├── cavities
    └── turbulence

Conceptually:

                  ███
             █████████
          ██████████████
       ███████
      █████
       ███████
          █████████

The player should be able to:

    fly toward one
    fly around one
    skim an edge
    enter a dense section
    emerge from the other side

This is the difference between:

    "there is fog around me"

and:

    "there is a gigantic thing in space."

9. Nebula Noise Should Be Hierarchical

Avoid relying on expensive high-octave FBM everywhere.

Use multiple scales intentionally:

large-scale noise
       ↓
medium turbulence
       ↓
small wisps
       ↓
erosion
       ↓
density

The large-scale structure is more important than microscopic detail.

Lighting and density boundaries create much of the perceived complexity.

A possible quality ladder:

Q1:
    low-frequency noise
    small modulation

Q2:
    low-frequency noise
    medium turbulence

Q3:
    richer noise
    finer erosion

Do not automatically increase octave count merely because GPU budget allows more steps.
10. Asteroid Fields Should Use the Same SpaceField

Asteroids should not be independent random objects scattered into space.

Use:

SpaceField(position)
        ↓
asteroid probability
        ↓
field / band / cluster structure
        ↓
deterministic individual placement

This permits enormous procedural asteroid fields without storing every object.

Conceptually:

                 ·
       ·     ·        ·
    ·       · ·  ·
       ·  ·       ·
             🚀
    ·       ·     ·
       ·       ·

Only materialize nearby asteroids.

Farther away, represent the field statistically or with simplified geometry.
11. Environmental Motion Is Critical

Procedural generation alone isn't enough.

The environment should slowly move.

Examples:

dust drift
nebula turbulence
asteroid orbital motion
particle streams
gas currents
storm fronts
debris motion

The motion should often be subtle.

The player should occasionally stop and realize:

    "The universe is moving."

Avoid making everything visibly animate all the time.

Large-scale slow motion sells scale better than constant noise.
12. Use Empty Space Deliberately

One of the most important visual rules:

    Not everything should be beautiful all the time.

If every region contains:

nebula
asteroids
dust
lightning
particles
bright stars

then none of those things feels special.

Use strong contrast:

dense nebula
       ↓
EMPTY SPACE
       ↓
clear stars
       ↓
asteroid field
       ↓
thin dust
       ↓
massive nebula wall
       ↓
storm
       ↓
silence

Empty space is not missing content.

Empty space is a visual effect.
13. Distant Structures Should Sell Scale

Not everything needs to be reachable.

Generate distant environmental structures primarily for visual scale:

local dust          → 10–100 km
local nebula        → 1,000–100,000 km
distant structures  → millions of km
stars               → effectively infinite

The player should occasionally see something enormous on the horizon:

       █████████████
    ███████████████████
  ███████████████████████

             🚀

The player doesn't necessarily need to fly into it.

Its purpose is to communicate:

    "This universe is much larger than the thing I'm currently flying through."

14. Star Visibility Should Respond to the Environment

Stars should not be independent of the medium.

Conceptually:

visibleStarIntensity =
    starField
    * volumeTransmittance
    * regionStarVisibility;

This creates natural environmental transitions.
Clear space

✦ ✦ ✦ ✦ ✦ ✦ ✦

Dust

✦   ·    ✦
  ···
     ✦

Dense nebula

    ·
 ·······
········

During lightning:

████████████
████ ⚡ ████
████████████

When the flash fades, stars return.

This is a powerful visual feedback loop.
15. Lightning Probability Should Come From the Environment

Lightning should not simply be a random global timer.

Use something like:

stormPotential(worldPosition)

derived from the same environmental field.

For example:

empty space        → almost never
thin dust          → rare
dense nebula       → occasional
violent nebula     → frequent

This creates environmental storytelling.

The player gradually learns:

    "This kind of cloud is stormy."

No UI is required.
16. Create Environmental Events With Rarity Tiers

Procedural generation needs a distribution of common and rare events.
Common

dust bank
faint plume
small asteroid cluster

Uncommon

dense nebula
debris stream
radiation cloud

Rare

lightning storm
enormous nebula wall
large asteroid vortex

Very rare

massive storm
spectacular multi-branch lightning
enormous glowing cloud

Legendary

Rare events that become memorable player experiences.

The key rule:

    If every five minutes is spectacular, nothing is spectacular.

Rarity creates emotional value.
17. Lightning Should Be a First-Class Event

Treat lightning as a shared event rather than several unrelated visual effects.

Conceptually:

LightningEvent
{
    position
    color
    energy
    radius
    falloff
    startTime
    duration
    seed
}

The same event drives:

        LightningEvent
             │
     ┌───────┼────────┐
     │       │        │
     ▼       ▼        ▼
   Bolt    Volume   Exposure
           Light
             │
             ▼
           Audio

This keeps the systems synchronized.

The lightning bolt, volumetric flash, bloom, exposure response, and eventual audio should all represent the same physical event.
18. Lightning Should Illuminate the Medium Locally

Avoid treating lightning primarily as:

bolt
+
fullscreen additive flash

Instead:

             cloud
       . . . . . . . .
    . .      ⚡      . . .
  . .     bright       . . .
 . .    attenuation      . .
. .                       . .

The cloud should brighten around the strike and fall off with distance.

The flash should be an actual environmental lighting event.

Autoexposure can respond naturally, but it should not be the primary mechanism producing the flash.
19. Make the Ship React to the Environment

The environment should affect the player's ship, not merely exist behind it.

Examples:
Dust

particles streak past hull

Nebula

colored light on ship hull

Lightning

brief rim lighting
ship silhouette
cockpit illumination

Asteroids

moving reflections
local shadows

Dense volume

subtle cockpit/HUD ambient response

Bright nebula

exposure
bloom
lens response

This creates the perception that the ship is physically inside the environment.

Even inexpensive lighting contributions can have a large visual payoff.
20. Make Camera Motion Interact With the Medium

Velocity should be visually perceptible.

At low speed:

·
   ·
      ·

At high speed:

────────>
··········
··········

Possible effects:

dust streaking
particle elongation
forward-scatter response
subtle density changes
cloud-boundary motion

The goal is to make the player feel movement through space rather than merely see the speedometer.
21. Environmental Memory

Eventually, procedural events should be able to leave short-lived traces.

For example:

lightning storm
      ↓
bright flash
      ↓
afterglow
      ↓
residual turbulence
      ↓
dust settles
      ↓
normal space

Likewise:

asteroid encounter
      ↓
debris
      ↓
dust wake
      ↓
gradual dissipation

This does not require full simulation.

A lightweight deterministic event history can provide the illusion of persistent environmental memory.
22. Palette Coherency

The existing nebula generator should remain the source of truth for environmental palette.

Prefer:

Nebula generator
      │
      ├── envMap → sky
      ├── irMap → ambient medium illumination
      └── palette → medium/volume coloration

rather than allowing each renderer to invent unrelated colors.

This creates a coherent visual identity:

sky
 ↓
nebula
 ↓
dust
 ↓
asteroids
 ↓
ship lighting
 ↓
lightning

all feel like they belong to the same environment.

Avoid arbitrary hand-picked hues in individual effects.
23. Separate Palette From Illumination

The environment's palette and its physical illumination should remain conceptually separate.

Palette:
    generator / region identity

Illumination:
    sun
    ambient
    irMap
    local events

This avoids making the volume simply become a sampled copy of the sky.

Use:

mediumAlbedo = generatorPalette(seed);
lighting     = sun + ambient + localEvents;

rather than deriving all volume radiance directly from envMap.
24. Volume Rendering Should Support Both Global and Local Medium

The volumetric renderer should eventually support:

global / regional medium
        +
localized anchor volumes

Conceptually:

SpaceField density
        +
NebulaVolume density
        +
local event lighting
        ↓
volume renderer

This allows:

    infinite low-density dust
    large regional nebulae
    localized plumes
    ship-scale clouds
    storm clouds

to share the same renderer.
25. Spatial Culling Is Essential

For localized volumes:

camera
  ↓
find nearby active volumes
  ↓
upload compact volume list
  ↓
raymarch only relevant volumes

Avoid an ever-growing shader loop over every nebula in the sector.

A future-friendly structure:

NebulaVolume
    center
    halfExtent
    seed
    density
    tint
    noiseScale

The CPU/world system determines which volumes are relevant.

The GPU evaluates only the bounded active set.

This will integrate well with future streaming/LOD work.
26. Empty-Space Skipping

For local volumes, raymarch termination should account for:

scene depth
volume distance
volume bounds

Conceptually:

tEnd = min(
    sceneDepth,
    volumeDist,
    volumeIntersectionEnd
);

tStart = volumeIntersectionStart;

This avoids spending raymarch steps through empty space before the ray actually enters a nebula.

As anchor volumes become more numerous, this becomes increasingly important.
27. Performance Philosophy

The procedural environment must not become an excuse to destroy the renderer budget.

Use different representations by scale:

near:
    geometry
    particles
    detailed volumes

mid:
    simplified volumes
    instancing
    lower-frequency procedural fields

far:
    statistical fields
    impostors
    sky/environment representation

The player should perceive one continuous environment even though the renderer changes representation underneath.
28. Recommended Procedural Environment Architecture

Long-term architecture:

                     GALAXY SEED
                          │
                          ▼
                   ┌──────────────┐
                   │  SpaceField  │
                   │              │
                   │ density      │
                   │ palette      │
                   │ turbulence   │
                   │ temperature  │
                   │ asteroid     │
                   │ dust         │
                   │ storm        │
                   │ starVisibility
                   └──────┬───────┘
                          │
             ┌────────────┼────────────┐
             ▼            ▼            ▼
          Volumes       Objects       Events
             │            │            │
             ▼            ▼            ▼
          Renderer     Asteroids     Lightning
             │            │            │
             └────────────┼────────────┘
                          ▼
                    Ship Response
                          │
                          ▼
                     Final Image

This should become the long-term environmental foundation.
29. Proposed Roadmap Expansion

The current volumetric nebula work can become the presentation layer of a larger procedural-space system.

Suggested roadmap structure:

#13 — Procedural Space Environment

#13a — Continuous SpaceField
    deterministic spatial environmental field

#13b — Volumetric Dust / Nebula
    participating medium
    anisotropic scattering
    star occlusion

#13c — Procedural Asteroid Fields
    deterministic fields
    clusters
    bands
    debris

#13d — Environmental Motion
    dust drift
    gas turbulence
    asteroid motion

#13e — Environmental Events
    lightning
    radiation events
    debris events
    rare encounters

#13f — Region Transitions
    continuous environmental parameter blending

#13g — Streaming / LOD
    near/mid/far representations
    cell streaming
    crossfade

#13h — Ship/Environment Interaction
    local lighting
    reflections
    cockpit response
    particle interaction

#13i — Sectors, Regions and Places
    the named hierarchy: sector → region → place
    sector seeds pinned in the player's map
    region generation (placed count, soft boundaries)
    category-aware naming

#13j — Inter-Sector Travel
    jumpgates as shared edges between sectors
    the sector graph as a whole, generated from the galaxy seed
    fly-in acceleration, tunnel transition, arrival
    FTL warp drive for long intra-sector travel

The existing fog-nebula branch should primarily establish #13b, while keeping the interfaces compatible with the larger system.

#13i and #13j were added after the decision log in §29a. They are listed
separately from #13a–#13h because they are a different KIND of work:
#13a–#13h change how the ENVIRONMENT looks, while #13i–#13j change what
the world CONTAINS and how you move through it. The environment can be
built without them — and the environment is the part everything else
depends on — but a sector with named regions and no way to leave it is
not yet a galaxy.

29a. Decision Log — what was actually decided, and why
---------------------------------------------------------

This section records decisions taken in design discussion, so the reasoning
survives. They are decisions, not proposals; the open questions are listed in
§29b.

**Regions are PLACED, and their boundaries are SOFT.**

A region is a named volume that is generated (not carved out of a noise
field), so the number of regions in a sector is a design parameter: one vast
region, or five or six smaller ones. But the *visual* transition across a
boundary is continuous — you fly into a new region and the environment
changes around you rather than at you.

These two are not in conflict, and the resolution is to separate the two
concerns that §6 and §7 were conflating:

    * IDENTITY is discrete. A region has a name, an archetype, a seed, and
      (later) rules. Flying from the Shattered Belt into the Violet Veil
      changes the name on your HUD, and may change what is legal there.
    * APPEARANCE is continuous. The environmental parameters (density,
      palette, star visibility, turbulence, radiation, storm potential) are
      interpolated across a boundary band, so there is no visible seam.

Concretely: each region owns a field, and the field is blended toward its
neighbours' fields over a transition band at the boundary. Walking into a
region is therefore a slow fade of every parameter at once, which is what
§7 asks for, while the region itself remains an addressable object with a
name.

Note that this means "region" is NOT the same thing as §6's "region
archetype". The archetype (Silent Deep / Violet Veil / …) is a *descriptor*
of a region, and a region is not limited to the archetype list — a sector
with one region may simply be a vast asteroid field, and a sector with six
may contain a trade hub and a contested space among them. The archetype
list is a set of *presets* for a region's parameters, not an enumeration of
what a sector may contain.

**A region is a FIELD VALUE, not an object in a list.**

This is the single most important architectural correction to the original
text, and it is what makes §6 and §7 work with one mechanism instead of two.

The original §6 reads as though a region is a thing you generate, populate
with content, store, and transition between. That requires a region
generator, a region store, a membership test, a transition system and a
save format — and it still cannot guarantee that the nebula in region A
and the asteroids in region A agree with each other, because they were
placed by different systems.

Instead:

    SpaceField(worldPosition, galaxySeed) → parameters

and every subsystem — nebula, asteroids, dust, lightning, star visibility
— reads the SAME function. Regions are then a coarse description of where
that function's output changes character. A "Violet Veil" is simply a
place where the field's palette happens to sit at violet and its
nebulaDensity is high.

The practical consequence: the four subsystems that today each own a
private hash scheme (NebulaVolumes' per-cell hash, AsteroidField's per-chunk
seed, LightningStorm's vapor gate, Dust's single global stream) are
replaced by one shared field. That is what makes correlated placement
possible at all — and correlation is the thing random placement cannot
give you, no matter how it is seeded.

Concretely, the failure this fixes: today the asteroid field has no
reference to the nebula whatsoever. A nebula-heavy chunk next to an
asteroid-heavy chunk produces a beautiful clear void next to a rock field
purely by chance, and a chunk where BOTH are dense produces rocks that are
invisible inside the gas — you paid for ten thousand rocks and see none of
them. With a shared field, "rocks in the clear" and "rocks lost in the fog"
become choices rather than coincidences.

**Inter-sector travel: jumpgates only, sector to sector.**

Jumpgates are the ONLY inter-sector movement. There are no intra-sector
gates: travelling within a sector is the ship's own business, and a later
FTL warp drive is what makes long intra-sector trips bearable. That keeps
the gate graph a simple thing — a fully-connected mesh of sectors, with
each gate a shared edge between exactly two sectors.

A gate is therefore a PLACE that belongs to two sectors at once, which is
what makes the sector structure a graph rather than a tree. This has one
big consequence: **sectors cannot be generated independently.** If
sector A has a gate to sector B, then B must exist and be consistent, so
the sector graph has to be generated as a whole (or at least as a connected
component) from the galaxy seed before any individual sector is entered.

Travel is intended to be physical: fly into the gate, accelerate hard, get
a tunnel transition, and arrive in the next sector. Not a map click.

**Seeds are pinned per sector, and the player's map remembers them.**

A sector's seed is what makes its contents reproducible, so the seed is
part of the sector's identity and is recorded in the player's map. Two
requirements follow:

    * POINTS OF INTEREST STAY PUT. A station you left is still there when
      you come back. Nothing in a sector may be regenerated differently on
      re-entry, so every seeded element must derive from the sector seed,
      never from arrival order or elapsed time.
    * LOOK-AND-FEEL DOES NOT CHANGE. The nebula palette, the skybox, the
      star field and the region layout of a sector must be identical every
      time you visit it.

This is a hard constraint on the generator design, and it is why §4's
"hierarchical deterministic seeds" and "coordinate-derived hashing" are not
optional polish — they are what makes revisit stability possible at all.

**Naming is a first-class hierarchy, not a decoration.**

Every level of the structure gets a stable, distinct, category-appropriate
name:

    Sector          e.g. "The Vexing Reach"
    Region          e.g. "Shattered Belt"
    Station         e.g. "Tannin Station"
    Outpost         e.g. "Waypost 7"
    Mining station  e.g. "Shaft 12"
    Planet          already implemented (genName)
    Asteroid field  e.g. "The Cinder Drift"
    Jumpgate        e.g. "Gate of Karr"
    Moon            already implemented (planet name + roman numeral)

The generator already exists (System.lua's genName — a consonant/vowel
syllable generator) and planets, stations and moons already use it. What
is missing is (a) category awareness, so a station name and a sector name
are distinguishable in the HUD, and (b) a per-scope uniqueness registry,
so two stations in one sector never share a name.

29b. Open questions
---------------------

These are the decisions still open. Each one changes the shape of the
generator, so they are answered before the SpaceField is built.

    * HOW FAR DOES A SECTOR REACH, AND HOW BIG IS A REGION? -- ANSWERED IN
      CODE, NEVER WRITTEN DOWN. The sector radius is 60,000 units (a sector
      is 120 km across) and a sector holds 1, 5 or 6 regions (a design
      parameter, decided by the sector's seed -- see 29d). The regions are
      arranged on a RING around the sector's centre, each with its own
      bearing, and their boundaries are exact Apollonius spheres (29c).
      This is the answer to write down, and it is the answer the scale
      question was asking for: at 120 km across with 5-6 regions, each
      region is ~40-50 km across, which is a REGION-SIZED place, not a
      patch. The remaining half of the question -- how big is a PLACE --
      is answered below, and the answer is "not built yet" (see 29h).

    * DO REGIONS HAVE RULES, OR ONLY A LOOK? -- STILL OPEN, AND THE ANSWER
      IS CURRENTLY "NOT EVEN A LOOK".

      The archetypes in `Game/Region.lua` (Silent Deep, Violet Veil,
      Shattered Belt, Solar Graveyard, Dust Expanse, Deep Field) each
      carry a `density`, a `storm` and a `light` -- and **NOTHING READS
      THEM.** The only consumer is the HUD's archetype NAME label. So
      "Violet Veil" is currently a word on a panel, not a place: crossing
      into it changes the text and nothing else. This is the gap between
      29a's "APPEARANCE is continuous" and the code, and it is the whole
      of 13f below.

      It is also the answer to the rails' purpose problem (29h): a region
      that has no appearance and no place IN it is not somewhere worth
      travelling to.

    * IS THE SECTOR GRAPH FULLY CONNECTED, OR DISTANCE-WEIGHTED? -- ANSWERED
      BY THE OLD SOURCE (29f): neither. It is the union of TWO MINIMUM
      SPANNING TREES over the siblings, with randomly perturbed edge
      weights, which is sparse, connected by construction, and has cycles
      for redundancy. Implemented, and `tools/validate_sectors.lua` checks
      that it is connected, spread, mutual, and identical with the JIT on
      and off.

    * DOES THE PLAYER GENERATE THE UNIVERSE, OR IS IT FIXED? -- ANSWERED IN
      PRACTICE, NEVER WRITTEN DOWN: the galaxy is generated from the WORLD
      seed, so it is player-generated, and `Config.gen.seedGlobal` pins it
      for reproducibility. The old game had a fixed universe with known
      coordinates; this one does not. If a fixed universe is wanted later,
      this is the decision to revisit -- and the sector seeds are already
      recorded per sector, which is half of it.

    * WHAT IS THE SAVE FORMAT? -- STILL OPEN, AND BIGGER THAN IT LOOKS.
      There is NO save system at all in the tree: no `saveGame`, no
      `loadGame`, nothing. The map holds the sector seeds in memory, and
      that is the whole of "the sector remembers itself". A save format is
      therefore not a tuning question but a missing feature, and it is
      not on anybody's list. It also blocks the "points of interest stay
      put" requirement in 29a for anything that is not derived from the
      sector seed.

29c. Phase C — the map knows where you are
------------------------------------------

The first two phases made a region a PLACE you can read (the panel, upper
left) and navigate by (the bearing arrow). Phase C puts it on the MAP,
because a name the player has to remember and a boundary they have to
guess are both worse than a picture.

**What the map shows**

    * The BOUNDARY of the region you are in, drawn as a circle.

      The boundary is a sphere in space (see the Apollonius derivation in
      Game/Region.lua), and the map is a top-down projection onto X/Z, so
      the sphere crosses the player's plane in a circle. That circle is the
      line you cross to be somewhere else. It is drawn UNDER the nodes,
      because it is the ground they sit on.

    * A MARKER and a NAME for every region, drawn OVER the nodes.

      Over, because the node field is dense — an asteroid field is two
      thousand dots — and a place name buried under them is a name nobody
      reads. The markers are clamped into the view (a place whose centre is
      off-screen still reads) and a clamped marker gets a leader line, so
      its name does not appear to belong to somewhere else.

      The marker is an OPAQUE chip carrying a cross and the name, not a
      translucent label. Two reasons, both learned from looking at it:
      everything in DrawEx blends ADDITIVELY, which is right for lines over
      a dark sky and useless over a bright one; and even 20% of a
      near-white node label showing through a translucent plate is brighter
      than the plate's own ink.

    * The SECTOR AND REGION in the map's header, top right.

      A map that does not say which place it is a map of is a field of dots
      with no context. The same state the HUD's panel reads — computed
      ONCE, by the app, and shared — so the panel and the map can never
      disagree about which region you are in.

**The map's own clutter, fixed**

Labelling every minor body turned the map into an unreadable pile of
"Body #123" over the asteroid field. The legend already says what a rock
is: a DOT. So minors are dots, and a minor's label appears only when it is
selected.

The reason they were labelled at all was a classification bug: a body was
a "place" if its SCALE was >= 50. That was written when a rock was 2..5
units across. The streamed asteroid field now makes rocks 40..540, so the
rule promoted every rock to a place — hundreds of labelled rings, and the
F7 "places" filter showing nothing but rocks.

Size is not what makes a body a place. A place is something you can go to
and do things with:

    * it has economy capability (a factory, a trader, a market), or
    * it is a planet, or
    * it has children of its own and no sockets (a station with modules).

A ship is a body with SOCKETS — that is what separates it from a station,
since both have actions and both have children.

**Still open after Phase C**

    * The map still fits to the node field, not to the sector. The regions
      are visible, but the sector's full extent is not what the opening
      view shows.
    * Region markers are drawn in AMBER, deliberately: the nodes are blue
      and the theme accent is crimson, so a third hue is what makes a
      place read as a place rather than as another kind of body.

29d. Phase D — the sector map, and the crash it hid
---------------------------------------------------

**THE MAP OPENS ON THE SECTOR, NOT ON THE SHIP'S FEET**

The map's fit used to frame the node field -- the asteroid field, a few
thousand rocks within ~30k of the ship. That is not a sector map; it is a
dot cloud at your own feet, and it says nothing about where you are in the
sector. The map now opens framed on the sector itself (60k across, centred
on the sector origin), so the named places are all on screen at once.

**REGIONS ARE CLICKABLE, AND DRILL IN**

A region is a place, not a body: it has no entity, so it lives beside the
node table rather than inside it, and it is hit-tested on its own against
the marker rectangle the draw code uses.

  * a single click selects the region and centres the view on it
  * a double click drills in: the map becomes "the things in this place"

The members of a region are the bodies whose DOMINANT region it is -- the
same rule the HUD uses to decide which region you are in, so the map and
the panel cannot disagree about what is where. (The provider's unit
records now carry the body's world Y as well as its X/Z: the map is a
top-down projection, but "is this body in that region" is a 3D question.)

The drilled region is drawn in GREEN, so it cannot be confused with the
region the ship is in (amber) or with a region that is merely nearby (dim
amber). Drilling out (right-click, or backtick) restores the sector view
exactly as it was.

**THE REGION COUNT NOW MATCHS THE DECISION**

§29a says a sector has "one vast region, or five or six smaller ones".
The code was doing a uniform 1..6, which produced two and three -- the
half-measure the design does not describe -- and made one-region sectors
as common as any other shape.

A one-region sector has nowhere to travel TO: the region IS the sector, so
flying out of it is flying out of the sector, and there is nothing beyond
that yet (no jumpgates). It is a legitimate shape -- a vast, uniform place
-- but it is a minority shape, so it is now 20%.

The salt moved from 91 to 90 because 91 happened to put the PROJECT'S OWN
DEFAULT SEED in the one-region case, so the demo world had a single name
for the whole sector and the region system was invisible in it. The salt
is a free design parameter with no contract on it.

**THE SECTOR EDGE POINTS BACK**

Past the sector edge there is nothing yet, so a marker pointing further
out is pointing at nothing. The sector-edge bearing now always points AT
the edge: straight out when inside, straight back IN when outside. The
panel says "outside the sector" in that case.

**THE CRASH F10 CAUSED**

F10 is bound to BOTH the profiler toggle and the map toggle, so opening the
map switched the profiler on as well. And the profiler had a latent bug
that had been running silently since frame one:

    Font_GetSize returns early on an EMPTY string without popping its
    profiler scope.

An empty string is what every UI label measures before it has any text --
and the sector panel has two labels that are ALWAYS empty (the archetype
line and the boundary line have no title prefix). So two scopes leaked
every frame.

Because Profiler_End pops whatever is on TOP of the scope stack, a missing
End does not just lose a scope: it makes every later End() pop the WRONG
scope. The stack grew by two entries per frame until Profiler_Begin hit
MAX_STACK_DEPTH and called Fatal -- about sixty frames, or two to four
seconds, after the player pressed F10.

The fixes:

  * Font_GetSize ends its scope before the early return.
  * Application:profiled catches, ends the scope, and re-raises, so a
    Lua error can never leave the scope stack unbalanced.
  * FRAME_END now passes the function name, and the profiler CHECKS that
    it is popping the scope it is supposed to pop. A mismatch is reported
    immediately, with a backtrace, instead of surfacing sixty frames later
    as a fatal overflow.
  * PHX_PROFILER=1 turns the profiler on at boot, so the imbalance is
    reproducible without pressing F10.

29e. Phase E — the jumpgates, ported from the old game
-------------------------------------------------------

The old Limit Theory's source was recovered (a `Warping/` folder: Wormhole.cpp,
WarpNode.cpp, WarpRail.cpp, wormhole.jsl, warprail.jsl, and the whole
`warpnode/` sound set), and it settles a question the design had left open:
**the old game had TWO different "warp" systems, and they map exactly onto
the two tiers the design has.**

    * The WORMHOLE is the jumpgate. A PAIR of linked endpoints, one in each
      of two sectors, and the travel is a DOCK:

          void Object_Wormholes(ObjectT* o1, ObjectT* o2) {
            a->GetNavigable()->nodes.push(NavigableNode(b, 0));
            b->GetNavigable()->nodes.push(NavigableNode(a, 0));
            a->SetName(o2->GetName() + " Wormhole");
            b->SetName(o1->GetName() + " Wormhole");
          }

          void Wormhole::Dock(Object const& docker) override {
            Object const& dest = Navigable.nodes[0].dest;
            dest->GetContainer()->AddInterior(docker);
            docker->SetPos(dest->GetPos() - 1500 * Normalize(dest->GetPos()));
          }

      That is the "jumpgates are sector-to-sector only" decision, already
      made and working in the old game.

    * The WARP NODE and WARP RAIL are something else entirely: a physical
      RAIL TRANSIT network inside a system. A ship flies into a node, is
      captured by a slot in the node's cross-section (a quadtree over
      angle x radius, split so each arriving ship gets room), and is then
      PUSHED along a bezier rail to the next node by forces. That is the
      old game's INTRA-system warp drive, and it maps onto the "FTL
      warp-drive planned later for that" decision rather than onto the
      jumpgates. It is a self-contained system and a good later project.

**THE JUMPGATES, PORTED**

    * script/Game/SectorGraph.lua -- the universe. Eight sectors on a
      golden-angle spiral through the galaxy, derived from the world seed,
      so the same galaxy always has the same sectors in the same places with
      the same names. The graph is a FULLY-CONNECTED MESH: every sector has
      a gate to every other one, and the gates sit on the sector's rim,
      spread evenly so they read as a set of places rather than a pile.

    * script/Game/Entities/Wormhole.lua -- the gate. A dockable entity that
      knows its partner; docking with it moves the ship to the partner's
      position and tells the app the sector changed. The old engine put the
      traveller into the destination CONTAINER; this engine's container is
      the parent tree and the world is one System, so the arrival is a
      position and a sector index, and the sector's regions and gates are
      regenerated from the DESTINATION sector's seed.

    * res/shader/fragment/effect/wormhole.glsl -- the old wormhole's
      fractal glow, ported. The old version started the march at the
      normalised LOCAL vertex position but marched along a WORLD direction,
      which is only right for an unrotated object; here the eye is brought
      into object space properly. The eye is passed in as a uniform rather
      than derived from the world matrix, because the transform needed is
      the INVERSE of the world matrix and the shader only has the
      inverse-TRANSPOSE.

    * res/sound/warpnode/ -- the old warp node's whole sound set (drone1/2/3,
      droneverb, dronewarp, crackle, lashing, static, frame, group, exit),
      brought over as MP3: the engine has no master volume and miniaudio's
      Vorbis decoder has been known to reject some valid streams. The gate
      hums a drone (a variant per gate) and plays `exit` when you come
      through.

**WHAT IS STILL MISSING**

The old game's UNIVERSE GENERATOR -- the thing that created the universe by
linking sectors -- was not in the folder. What is here is a minimal
replacement: a deterministic spiral of eight sectors, which gives the gates
something to connect. The real generator is the next thing to port, and it
is the piece that decides how many sectors exist, how they are placed, and
which gates exist between them.

29f. Phase F — the universe generator, and the bug it exposed
----------------------------------------------------------

The old game's universe generator was recovered (a `UniverseGen/` folder:
Universe.cpp, Region.cpp, Interior.cpp, universe.lts, System.lts), and it
settled the other open question.

**THE GATE GRAPH IS NOT A FULLY-CONNECTED MESH**

§29b recorded "fully-connected mesh" as the decision. The old source says
otherwise. From Region.cpp:

    const size_t kConnectivity = 2;
    for (size_t i = 0; i < kConnectivity; ++i) {
      ... a complete graph with edge weight Length(p1 - p2) * (1 + 0.5 * Exp)
      AutoPtr<Graph<ObjectT*>> mst = graph->ComputeMST();
      for each mst edge: Connect(src, dst);   // -> Object_Wormholes
    }

So the gate graph is the union of TWO MINIMUM SPANNING TREES over the
sibling regions, with randomly perturbed edge weights. That shape is right:

  * a spanning tree is connected by construction -- every region is
    reachable, so the player is never stranded;
  * it is SPARSE -- N-1 edges per tree, not N*(N-1)/2. At the old game's
    512 nodes a fully-connected mesh would put 511 gates on every rim;
  * the second tree adds REDUNDANCY -- the union has cycles, so a gate is
    not the only way between two places;
  * the random weight perturbation means the tree is not simply the
    minimum-distance one, so the galaxy does not degenerate into a path.

The layout is the old game's too: the children of a region are scattered
through a DISC around it, at random positions, each smaller than the
parent and smaller the further out it is, and never overlapping a sibling
-- the same principle as the regions inside a sector.

**THE BUG THIS EXPOSED: THE UNIVERSE WAS NOT DETERMINISTIC**

The sector layout came out DIFFERENT with LuaJIT's JIT on and with it off.
That is not a rounding curiosity: the galaxy's topology comes out of
COMPARISONS on the sector coordinates (which edge is cheapest, which sector
overlaps which), so a one-bit difference flips a comparison and the whole
galaxy changes shape.

And the difference is not one bit. `SpaceField.hash32` mixes its arguments
by MULTIPLICATION in floating point, and its terms overflow the 32-bit
range -- so the final conversion of the sum to an integer is on a value
OUTSIDE the range the conversion is defined for, and LuaJIT's compiled
code and its interpreter do that conversion differently. The same call can
return a different hash depending on whether the function was hot.

So the offline validator and the game were describing two DIFFERENT
universes, and the validator's idea of the galaxy was not the galaxy the
player flies through.

The fix is that the layout now uses EXACT 32-bit integer arithmetic
throughout:

  * a precomputed cosine/sine table, indexed by an INTEGER angle, because
    LuaJIT's compiled code replaces math.cos with a fast polynomial that
    does not agree with libm to the last bit;
  * a xor-and-shift mixer for the randomness, instead of hash32's
    float-based mixing;
  * an INTEGER weight for the spanning tree's edges, because a minimum
    spanning tree is decided by comparisons and a comparison between two
    floats can flip;
  * and the sibling-overlap rule SHRINKS a sector rather than REJECTING
    one, so nothing in the layout can change WHICH sectors exist.

tools/validate_sectors.lua checks all of it: the graph is connected, the
gates are spread and mutual, the galaxy is deterministic, and -- the one
that caught this -- **the layout does not depend on whether the JIT is
running**.

**WHAT IS STILL MISSING**

The old game's hierarchy is a TREE of regions: a Universe contains a
Region, a Region contains sub-regions, and the leaves are Systems. The
wormholes connect SIBLINGS, at each level.

What is implemented here is the FLAT version of that: one level of
sectors, connected by the old gate-graph algorithm. The nested version --
regions containing regions, and the hierarchy the player navigates -- is
the natural next step, and it needs the "regions" concept raised from a
field value to an object, which is a bigger change than it sounds (the
region's identity, its membership and its boundary are currently derived
from a seed and a position).

29g. Phase G — two maps, and how you actually travel
---------------------------------------------------

**THE MAP IS ONE NODE GRAPH, WITH THE GALAXY AS ITS OUTERMOST LEVEL**

This was wrong at first: there were two maps with two cameras. The old
Limit Theory's screenshots settled it -- it was ONE graph, and the galaxy
was simply its outermost level. Its object types were "Universe",
"Region", "System" and "Wormhole" SIDE BY SIDE: a Universe's children were
Regions, a Region's children were Systems, and the wormholes were the
LINKS between the siblings.

So:

    * The SECTOR level (F10) shows what is IN the sector: the bodies, the
      named regions, and the gates on its rim.
    * The GALAXY level (V) shows the SECTORS as nodes and the gates as
      links.

Same camera, same fit, same drill machinery -- the V key swaps the LEVEL.

**AND THE GATE'S FAR END IS A NODE, LIKE THE OLD GAME'S WORMHOLES**

The old game put the two wormhole endpoints at fixed world positions --
400000 units either side of the line between the two systems -- so the map
at the system level could draw the wormhole AND its link out to the other
end. You could see which way the exit lay.

Here the far end is in another sector, but its position is known just as
well, so the same trick works: a ghost node standing for the other side of
the pair, with a DOTTED link to it. (Dotted, because a solid line reads as
a physical strut, and a gate is not a strut -- it is a way through, and it
goes somewhere the map is not showing.)

**TWO KINDS OF GATE, AND HOW THE PLAYER TELLS THEM APART**

The old game had two, and they are not the same size of journey:

    * a SECTOR gate -- a JUMPGATE. It leaves the sector entirely: another
      part of the galaxy, with its own name, its own regions, its own
      look. (The old game's wormholes.)
    * a REGION gate -- an intra-sector link: another place in THIS sector.
      (The old game's warp-node rail network -- the orbital rails around a
      planet.)

So the kind is on the entity (`kind = 'sector' | 'region'`) and the map
draws them differently: a jumpgate is CYAN, an intra-sector gate is
AMBER (the same family as the regions, because it leads to one), and the
symbol key shows both.

**AND THE PLAYER IS NEVER LEFT TO WORK IT OUT**

Three places say what a gate does, so the map never has to be the only
source of the answer:

    * the PANEL carries it always --
      "Nearest jumpgate to The Totohi Reach  55 km". The player does not
      have to open the map and hunt for a gate, and does not have to
      guess where a gate leads.
    * the DOCK PROMPT names the destination when they are close enough to
      dock: "Press F to Dock -- The Katapa Void".
    * the MAP names every gate after its far end ("The Totohi Reach
      Wormhole") and links it, dotted, to a ghost node standing for the
      other side of the pair -- so you can see which way the exit lies.

**A NEW SECTOR HAS TO LOOK NEW**

Warping changed the NAME and nothing else: the same planet, the same sky,
the same rocks. Which is worse than not having the feature at all -- the
player is told they have travelled, and the world says otherwise. (This was
the exact complaint: "the sector I am brought to looks the same as the
last".)

So arriving in a sector REGENERATES that sector's contents from the
sector's seed:

    * the PLANET -- a new one, of a new type, at a new size and a new
      distance. It is the thing you look at. (System:spawnPlanet now takes
      an optional rng and an optional origin, so a planet can be a pure
      function of a sector rather than of the world's shared rng stream --
      which cannot be re-rolled, because that stream is shared with the
      rest of generation and reordering its draws reshuffles every
      existing world.)
    * the SKY -- a new nebula and a new starfield. The nebula is most of
      the screen, so this is most of the difference. It costs a hitch (the
      skybox is generated on the CPU and the irradiance map is convolved),
      which is the right place for one: a jump should feel like a jump.
    * the ROCKS -- already different, and not because of this: the asteroid
      field is a pure function of (world seed, chunk coordinate), and the
      sectors are hundreds of thousands of units apart, so a new sector is
      new chunks.

Measured across a warp: the planet went from an ICE body of radius 10867
to a TERRESTRIAL one of radius 5541, and the sky went from a teal
nebula to a green-and-violet one.

**HOW YOU TRAVEL: FLY IN AND DOCK**

    1. Fly to a gate. It is a big glowing sphere on the sector's rim, and
       the map says which sector it leads to.
    2. The dock prompt appears as you enter the portal's glow -- NOT when
       you are dead centre inside it. The player should not have to aim
       at the middle of a thing they can see the edge of.
    3. Press F (or the gamepad Y). The ship warps on the spot.

The warp is INSTANT, deliberately. The generic dock action flies the ship
at a point a radius-and-a-quarter BELOW the dockable, which is right for a
station you pull up to and wrong for a portal you fly into -- diving at
the floor of a portal looks like a bug. So a gate warps on the spot, the
way the old game did (`Wormhole::Dock` moved the docker into the
destination container directly).

The prompt names the key and the destination: "Press F to Dock -- The
Katapa Void".

**WHAT IS STILL MISSING**

The old game's hierarchy is a TREE of regions: a Universe contains a
Region, a Region contains sub-regions, and the leaves are Systems. The
wormholes connect SIBLINGS, at each level.

What is implemented here is the FLAT version of that: one level of
sectors, connected by the old gate-graph algorithm. The nested version --
regions containing regions, and the hierarchy the player navigates -- is
the natural next step, and it needs the "regions" concept raised from a
field value to an object, which is a bigger change than it sounds (the
region's identity, its membership and its boundary are currently derived
from a seed and a position).

29g. Phase G -- the warp lanes, rebuilt from the old code
--------------------------------------------------------

Josh's own words, from the May 2013 development video:

    "if you want to get from point A to point B within a system, you use
     these lanes, warp lanes, to get around quickly -- assuming you can hit
     them."

So a lane is a ROAD, not a door: you fly into it, it CAPTURES you, and it
carries you to the other end.

**WHAT THE OLD CODE ACTUALLY BUILT** (Warping/WarpNode.cpp, WarpRail.cpp)

    * The WARP NODE was a sphere of ICE:

          model = Model_Create()->Add(
            Mesh_BoxSphere(16, true)->SetU(1),
            Material_Ice());

      A CHAIN of these along the lane is what you see from a distance --
      the reference frames show a line of small blue structures, and those
      are the nodes, not the rail.

    * The WARP RAIL was a TUBE:

          model = Model_Create()->Add(Mesh_Cylinder(50)
            ->Scale(V3(1, 0.5f, 1))
            ->Translate(V3(0, 0.5f, 0))
            ->Rotate(V3(0, kPi2, 0)), shader);

      with the shader ADDITIVE, CULLING DISABLED and NO DEPTH WRITE. The
      culling is the important one: the camera is INSIDE the tube, so the
      surface you see is the far wall -- that is the wall effect, and it is
      the graphics rather than the geometry.

      (In that snapshot the rail's own drawable was commented out, so only
      the nodes were visible. The tube is what the code describes, and it
      is what the reference footage shows from inside one.)

The first attempt at this was a rectangular lattice -- a "window frame" --
which was wrong twice over: it was not what the old code built, and it was
a window rather than a road.

**THE THREE FORCES** (the old WarpNode controller)

    1. a RAIL FORCE toward the next node, scaled by the ship's mass;
    2. a LANE-LOCKING force, pulling the ship back onto the rail's line;
    3. the ARRIVAL -- at the far end the rail lets go.

The speed along the rail is CAPPED (1500), because the old game's drag
capped it and this engine's ship has no friction.

**THE LANES BRING YOU TO THE OTHER REGION**

A rail runs from one region's centre to the other's, so the membership flips
as you travel, and the region you arrive in is the other one. That is the
"at a minimum, these lanes bring you to the different regions".

**FINDING THEM** is the hard part -- they run between region centres tens
of thousands of units apart, and nothing about them announces itself from
a distance. So the panel carries the nearest one, the way it carries the
nearest jumpgate: "Nearest lane to Sanusege  13 km", measured to the
nearest warp NODE (the thing you fly into), not to the middle of the rail.

29h. Phase H -- what the warp lane actually LOOKS like
---------------------------------------------------------

From the reference frames, a lane frame is:

  * TWO large rectangular PANELS, one on each side of the lane, each
    carrying a bright blue LATTICE;
  * a GAP between them -- and THE GAP IS THE LANE. The ship flies through
    the gap, and the grid on the panels is what accelerates it;
  * the panels TILTED in OPPOSITE directions, so the pair reads as a funnel
    rather than two flat sheets;
  * a chunky pale BRACKET on each panel's inner edge -- the edges that
    bound the gap.

Three attempts got here, and each was wrong in an instructive way:

  1. A continuous TUBE with SPHERES on it. The old code has no tube: the
     old WarpRail's drawable was COMMENTED OUT, so what you saw was the
     warp NODES. And a tube reads as one blown-out white streak from a
     distance, which is nothing like a highway.
  2. A rectangular lattice -- which is the right IDEA, but it rendered
     black, twice, for two different reasons:
       - the grid term was NEGATIVE between the lines (it is 1 on a line
         and falls off past it), and a negative grid multiplied into the
         colour drove the whole field to black. It needs a clamp.
       - mWorldIT was left unset, so the vertex shader normalised a ZERO
         vector and the whole fragment went NaN -- which under additive
         blending is a black field, not a missing one.
  3. The panels, tilted, with the brackets on their inner edges.

Two GLSL traps worth remembering, both of which cost real time:

  * `line` is a RESERVED KEYWORD in GLSL 4.x. `float line = ...` does not
    compile.
  * A mangled comment -- `//` turned into `--` -- is not a comment at all
    in GLSL. `--` is a decrement operator, and the result is a syntax
    error a hundred lines away from the cause.

29i. WHERE THE PROGRAMME ACTUALLY STANDS (2026-10-21)
-----------------------------------------------------

A status read of the #13 items, because the list above was written as a
proposal and most of it has since been built.

| # | item | state |
|---|------|-------|
| 13a | Continuous SpaceField | **PARTLY.** `Game/SpaceField.lua` exists and is the exact 32-bit hash the universe layout needs, but it is NOT the environmental field 2 describes: the nebula, the asteroid field, the dust and the lightning still own private hash schemes, so the correlation failure 29a names -- "a beautiful clear void next to a rock field purely by chance", "rocks invisible inside the gas" -- is still exactly as likely. **This is the biggest open item in the whole document.** |
| 13b | Volumetric dust / nebula | **DONE.** The participating medium, the anchor volumes, the two-pass composite, the star occlusion and the god rays are all in and signed off. |
| 13c | Procedural asteroid fields | **DONE.** The endless chunk-streamed field, with the boundary hidden by a fragment discard rather than by scaling a body (which reallocates collision shapes and locks the game up). |
| 13d | Environmental motion | **PARTLY.** The nebula's drift and the cloud deck's wind are in; the asteroid field's rocks do not move. |
| 13e | Environmental events | **PARTLY.** Lightning is in and fires; radiation events, debris events and the rarity tiers are not. |
| 13f | Region transitions | **DONE (first cut) -- see 29k.** The regions now have a FIELD: the archetype's density, storm, light and rock count, blended across the boundary by the Apollonius membership, and read by the rocks, the gas and the lightning. The archetypes' numbers are no longer dead. |
| 13g | Streaming / LOD | **PARTLY.** Chunk streaming is in for the asteroid field; the near/mid/far representation tiers and the crossfade are not. |
| 13h | Ship / environment interaction | **PARTLY.** The hull is lit by the nebula's irradiance; the cockpit, the camera-motion response and the dust streaking are not. |
| 13i | Sectors, regions and places | **DONE for sectors and regions; PLACES ARE THE HOLE.** The named hierarchy, the pinned seeds, the map and the drill-in are all in. A "place" -- something you can go to and do things with -- is not: a sector has one planet, one station and one asteroid field, and its regions are areas of space. |
| 13j | Inter-sector travel | **DONE.** The jumpgates are the old game's wormholes, ported: a pair of linked endpoints, a dock, a warp, and a sector that regenerates itself from its own seed. The "FTL warp drive for long intra-sector travel" half is the warp lane, and that is where the next section is. |

29j. The warp lanes, and the question they have not answered
-----------------------------------------------------------

The lanes are BUILT and they LOOK right: a chain of frames, each a pair of
tilted grid panels with a ribbed bracket between them, the gap between the
panels being the lane the ship flies through. The physics is the old game's
three forces -- a rail force down the lane, a lane-locking force back onto
the line, and the arrival at the far end -- with the capture fixed to the
lane's CORRIDOR rather than to a single frame (the first version dropped the
ship off the rail between gates), the ship made non-collidable while it is
carried (it used to stop dead against a rock, two seconds into every ride),
and a braking exit (it used to be released at full speed into an asteroid
field).

The topology was rebuilt twice, and both times because the old source
settled it:

* the first version linked each region to its two NEAREST neighbours, which
  with six regions made EIGHT lanes that all met in the middle of the sector
  -- the sky above the ship was a knot of rails;
* the old game's own shape is a STAR from a hub (`UniverseGen/System.lts`
  links every point of interest to the first one), so that is what it is now:
  one spoke per region, each in its own direction, 41-58 km long.

**And they still have no purpose, and the reason is not a rendering problem.**

A lane that ends in empty space is a lane nobody would use, and that is
exactly what a lane does here: the sector's regions are AREAS, and nothing
is IN them. The player's own summary of it was the right one -- "if the warp
rail goes to nothing (empty space) why have it? We should not be going to
empty space."

So the missing thing is not the lane. It is the DESTINATION:

1. **A region needs a place in it.** The old game's POIs were a planet, a
   field, a station, a colony -- real objects with a market and a factory,
   and the rails ran between THOSE. Our regions are named volumes with a
   boundary and an archetype, and no contents.
2. **A region needs an appearance**, so that going somewhere is a change you
   can SEE (13f). The archetypes already describe six places with a
   character; nothing reads their density, storm or light.
3. **The ship needs to be able to get there without a rail.** The ship's
   top speed is a hardcoded 100 u/s (`Ship:getTopSpeed`, with its own TODO
   admitting it) in a sector 120 km across -- so crossing a sector takes
   TWENTY MINUTES of flight. That is why the rails were wanted in the first
   place, and it is why "just make the thrusters faster" is the right
   instinct: the scale of the sector and the scale of the ship disagree by
   two orders of magnitude, and no amount of lane plumbing fixes that.

**Where that leaves the lanes.** They are switched OFF in the debug window
("Universe > Warp Rails"), because the alternative is a permanently visible
road network that goes nowhere. The switch is live, so they can be looked at
at any time. The work that would make them worth having is content work --
places in the regions, a region personality, and a ship that can cross a
sector -- and that is a bigger thing than this document's remaining items.

29k. 13f -- the region's field, and the first consumers of it
------------------------------------------------------------

**THE PROBLEM, PRECISELY.** A region had IDENTITY and no APPEARANCE. It had
a name, an exact Apollonius boundary, a HUD readout and a map pin -- and
its archetype carried a `density`, a `storm` and a `light` that **NOTHING
READ**. The only consumer of the whole table was the archetype's NAME on
the panel. So "Violet Veil" was a word on a panel: flying into it changed
the text and nothing else, which is the exact opposite of what 6 asks for
("the player should feel that they have entered a different environment,
not simply crossed an invisible gameplay boundary").

**THE FIELD.** `Region.field(regions, x, y, z)` returns the blended
environmental parameters at a position: the gas density, the storminess,
the light level, the rock density, and the palette hue. The blend is
weighted by the Apollonius membership the HUD and the map already use --
so the field is a convex combination of continuous functions, and it is
CONTINUOUS by construction. There is no threshold anywhere in it and
there must never be one: a threshold here is a visible seam in the sky,
which is the thing 7 exists to prevent.

Two details that are easy to get wrong, and were:

* **A region with no archetype contributes the NEUTRAL value, not zero.**
  The obvious choice -- zero -- is wrong in a way that is invisible in the
  code and obvious in the world: an un-archetyped region would drag the
  whole field down toward zero, and the size of that drag would depend on
  how many of the sector's regions happen to lack a preset. Two sectors
  with the same kind of place in them would read differently because of a
  roll of the dice. The neutral value is the MEAN of the archetypes: a
  plain place is an average place.
* **The hue blends as a VECTOR, not as a number.** A hue is a position on
  a wheel, so 0.95 and 0.05 are near each other, and averaging them as
  numbers gives 0.5 -- a different colour, on the far side of the wheel
  from both.

**A CHANNEL THE TABLE WAS MISSING.** "Shattered Belt -- rock, debris, low
gas" describes a place full of ROCKS, but there was no rock density to
say so: `density` is the GAS density (Violet Veil is dense gas), so the
belt was the LEAST dense place in the table and the most rock-like one,
which is exactly backwards. The two are separate channels now.

**THE CONSUMERS.** The point of one field is that several things read it,
so they cannot disagree about what kind of place they are in -- which is
the correlation failure 29a names, where a rock field lands in a clear
void purely by chance.

* **The rocks** (`AsteroidField`): a chunk's rock count is scaled by the
  field's rock density at the chunk's centre, so a belt is about three
  times rockier than a deep field. The scale is baked in when the chunk
  is generated, which is safe because the regions do not change within a
  sector.
* **The gas** (`NebulaVolumes.build`): each anchor's density is scaled by
  the field's gas density at the ANCHOR's own position. Per anchor, not
  per build -- an anchor's density is then a pure function of where that
  anchor is, so rebuilding the list (which happens when the camera
  crosses a cell) gives every anchor the SAME density it had before.
  Sampling it once per build instead would make the whole visible sky
  change character in one step as the camera crossed a cell boundary: a
  pop, in the one place the player is guaranteed to be looking.
* **The lightning** (`LightningStorm`): the strike rate is scaled by the
  field's storminess at the camera, so a stormy kind of place storms.

**THE PANEL** names the transition, because the archetype's name on its
own is the DOMINANT region's -- which is a lie exactly where it matters.
Halfway between a "Solar Graveyard" and a "Silent Deep" the field is a
blend of the two, and the player can see that they are in between:
"Deep Field -> Solar Graveyard" appears once the blend has actually
reached the second one.

**MEASURED.** The field at a "Solar Graveyard" region's centre reads storm
0.798 and light 0.699; at a "Deep Field" region's centre, storm 0.125 and
light 0.277. The largest step between neighbouring samples along every
line that crosses a boundary is 0.014 -- a gradient, not a jump (a
switching field would step by the whole difference, tens of hundredths).
`tools/validate_regions.lua` checks all of that offline: that every
archetype carries every channel, that the field is continuous across
every boundary, that the regions are measurably different from each
other, and that a plain region does not drag the field to zero.

**WHAT IS STILL MISSING.** The `light` channel has no consumer yet, and
the region's HUE only reaches the map pin. Making the gas and the stars
take the region's palette is the next step, and it is the step that makes
the region archetype's name mean what it says.

29l. The places, the kinds, and the ship's speed
----------------------------------------------------

**THE QUESTION THIS ANSWERS.** A warp lane is only worth riding if it goes
somewhere. The lanes had been right -- built, correct, and pointed at
AREAS -- and a lane that ends in an area of nothing is a lane nobody would
use. So the answer is not more lane engineering. It is that the regions
need PLACES, and the old game's answer is the one to copy: its rails ran
between its POINTS OF INTEREST.

**EVERY REGION GETS A PLACE.** A station, scaled down to an outpost, at the
region's centre, named after the region and for what it is:

    a belt  ->  a mining RIG
    a yard  ->  a YARD (with a factory on it)
    a veil  ->  a RELAY (a beacon in the gas)

Every one of them has a market, so the ore has somewhere to go. And the
LANES now run to the places, because the lane's end is the region's
centre, which is where the place is -- "Nearest lane to Hogatuge Rig 17 km"
is a place; "Nearest lane to Hogatuge" was a direction.

**THE KINDS, AND WHY THEY ARE NOT THE ARCHETYPES.** The archetype is the
region's ATMOSPHERE (how much gas, how stormy, how bright, the palette).
The KIND is its CONTENT -- what is physically here. They compose: a belt
inside a dense veil is still a belt.

    belt   rock and ore, a swarm of it
    yard   open ground, a market and a factory
    veil   gas you cannot see far through

The content channels (the rock density and the ORE) live on the KIND, not
on the archetype, for a reason that only shows up in play: a PLAIN belt --
a belt with no archetype, which the design explicitly allows -- would have
lost its ore for having no atmosphere to be atmospheric about.

**A SECTOR IS GUARANTEED A MIX.** The first region is always a BELT and
the second always a YARD; the rest are drawn. Drawn alone, a quarter of
the sectors came out with no belt at all -- nothing to mine, and no lane
worth riding to anywhere. A sector with a belt and a yard has an economy:
mine there, sell here, and the lanes are the road between them.

**THE ORE.** A rock in a belt is ore nine times in ten; a rock in a deep
field is one time in ten. It comes from the same field as the density, so
the ore is IN the belts and the lanes lead to the belts.

(There was no ore before this, in any usable sense: the old static field
marked its rocks with `rng:choose(Item.T1)` -- and there is no `Item.T1`,
so every one of those rocks had been given a yield of NIL, which is a
mining action that hands the player nothing. The item the game had been
reaching for did not exist. It does now: `Item.Ore`.)

**THE SHIP'S SPEED.** The sector is 120 km across and the ship's top speed
was 203 u/s (MEASURED -- the hardcoded 100 in `Ship:getTopSpeed` had
never matched the physics, and the jobs' travel times were based on the
fiction). At 203 u/s crossing the sector took ten minutes and the nearest
region four, which is not a place you can play in, it is a map you can
look at. The thrust now buys **500 u/s** and the boost **1000**, so a
region is a minute away and the sector is two.

Three things had to move with it:

* **The ramming damage**, which was tuned against a 100 u/s ship. At 500
  u/s a rock would have been 166 damage against 100 HP -- instant death,
  and "routine flight" in a sector with a rock field would be lethal. The
  thresholds are now relative to the top speed.
* **The chase camera**, which was given a "lead" to cancel a translation
  lag that does not exist -- the camera's world position is `posOffset +
  posT` and `posT` is recomputed from the ship every frame, so it follows
  the ship exactly. The lead was v*0.1s, which is 50 units FORWARD at
  500 u/s, while the camera only sits 27 units behind the ship: it
  ended up 23 units in FRONT of the ship, inside its own radius, and the
  framing fell apart. The old Limit Theory's camera (liblt/Game/Camera.cpp)
  has the same property and solves it the honest way -- it advances its
  world position by the target's velocity every frame, and smooths only
  the RELATIVE offset.
* **The torques**, which go up by the same 2.46x as the thrust. The
  turning circle is v/omega, so scaling the speed and the turn
  acceleration together keeps the circle the same size in ship-lengths:
  a 500 u/s ship that turns like the old 203 u/s one.

**AND THE ECONOMY'S LAST MILE, WHICH IS NOW WALKED.**

The player could mine the ore and carry it, and there was nowhere to turn
it into anything. The market component existed -- with buy and sell
orders, a matching loop, and a TODO where the escrow should have been --
and its matching moved ORDER COUNTS rather than items and credits, so a
trade changed the books and nothing else. There was no interface for it
and no action.

So:

* **The transaction.** `Market:sell` and `Market:buy` move the goods and
  the credits between the two parties, against the market's best bid (the
  highest) and best ask (the lowest). A place has to be able to PAY, so
  the places have working capital.
* **The market panel**, at the dock. It is the economy's front door: the
  station's name, the player's credits and hold, the price the market will
  pay and the price it will ask, and the two keys that move things (R
  sells everything, T buys one).
* **The prices**, in Content.lua with the items -- a station buys the raw
  commodities at 14 and 9 and sells what its reactor makes for 26, and
  the spread is the reason the loop is worth running.

The loop, end to end: mine the isotopes in a belt, carry them to a rig or
a yard, sell them, and buy the energy cells the reactors make. Measured in
the running game: three isotopes sold for 42 credits, and an energy cell
bought for 26.

**WHAT IS STILL MISSING.** The credits buy energy cells, and the energy
cells have no use yet -- the ship's capacitor is not wired to them, and
there is nothing to upgrade. The economy runs; it does not yet lead
anywhere. And the market's NPC-to-NPC matching is still cosmetic: the
traders move order counts, not goods.


30. Visual "Wow Factor" Stack

The desired experience should build in layers.
Level 1 — Base Space

beautiful stars
deep blacks
subtle dust
good color grading

Level 2 — Medium

dust banks
nebula wisps
anisotropic sunlight
star occlusion

Level 3 — Scale

giant distant nebulae
asteroid belts
deep voids
huge structures
long transitions

Level 4 — Motion

drifting gas
moving dust
asteroid motion
turbulence

Level 5 — Events

lightning
storms
radiation bursts
debris events

Level 6 — Response

ship lighting
exposure
bloom
cockpit response
audio
particle interaction

Level 7 — Rare Moments

massive storm
enormous nebula wall
lightning illuminating an entire cloud
ship silhouetted against a nebula
then...

                    silence

                    ✦  ✦  ✦

The final contrast is intentional.
31. The Most Important Visual Principle

    The wow factor is contrast, not density.

Do not attempt to make every frame spectacular.

Instead, create a visual rhythm:

dark
  ↓
subtle dust
  ↓
faint glow
  ↓
dense cloud
  ↓
massive structure
  ↓
storm
  ↓
lightning
  ↓
flash
  ↓
afterglow
  ↓
silence
  ↓
clear stars

This gives the player moments worth remembering.

If everything is spectacular, nothing is spectacular.
32. Final Design Goal

The ultimate goal is for the player to stop thinking:

    "The game spawned a nebula."

and instead think:

    "I'm flying through space."

The environment should feel:

    endless
    deterministic
    alive
    enormous
    coherent
    slowly changing
    occasionally dangerous
    occasionally breathtaking

The procedural system should generate the environmental possibility, while the renderer turns that possibility into convincing visual presence.

The player should never be able to tell exactly where the procedural generation begins or ends.

This would be a good companion to the existing fog-nebula plan: that document describes how to render the medium; this one describes how to make the universe continuously generate the things the medium represents.

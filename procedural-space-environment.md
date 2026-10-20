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

    * HOW FAR DOES A SECTOR REACH, AND HOW BIG IS A REGION?

      Sector extent and region size set the scale of every field channel.
      If a sector is 10^6 units across and a region 10^5, then the macro
      field has room for real variation. If a sector is 10^4 and a region
      10^3, the region count per sector is small and the "field"
      degenerates into per-region constants.

    * DO REGIONS HAVE RULES, OR ONLY A LOOK?

      §6's archetypes imply contested space and trade hubs are
      gameplay-distinct, not just visually distinct. If regions carry
      rules (hostility, tariffs, which faction owns what), a region needs
      an identity that survives a save — a handle, not just a seed.

    * IS THE SECTOR GRAPH FULLY CONNECTED, OR DISTANCE-WEIGHTED?

      A fully-connected mesh is simple and always solvable. A
      distance-weighted graph ("only connect to sectors within N hops")
      is more interesting — it makes some sectors remote — but it means
      the graph is a global constraint and cannot be grown lazily.

    * DOES THE PLAYER GENERATE THE UNIVERSE, OR IS IT FIXED?

      A fixed universe (one galaxy seed, known to the player) makes
      "the same sector" mean the same thing to everyone. A player-
      generated universe is more personal and makes sharing harder.

    * WHAT IS THE SAVE FORMAT?

      The player's map holds sector seeds. That is a small, well-defined
      structure, but it needs to be decided before the map is built,
      because the map is where "the sector remembers itself" lives.

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

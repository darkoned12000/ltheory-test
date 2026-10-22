--[[ Game.Seed -- one source of truth for "which world is this?".

  Anything that used to seed itself from the clock (RNG_FromTime) seeds from
  here instead, so pinning `Config.gen.seedGlobal` reproduces the WHOLE boot --
  dust, particle bursts, ship/thruster meshes, NPC AI -- and not just the
  sector, nebula and planets. See docs/ltheory-planets.md 11.0 W2.

  Rules:
    * The app calls Seed.setWorld(seed) as the first thing it does, so anything
      created during generation derives from the printed boot-log "Seed:".
    * Before that (module load), Seed.get() falls back to Config.gen.seedGlobal
      -- Config is loaded before any app module (Main.lua:13-14 vs 39), so a
      pinned world is already known that early.
    * With no seed known at all (unpinned boot), Seed.rng falls back to
      RNG_FromTime() and everything behaves exactly as it did before. Nothing
      is promised to be reproducible in that mode.

  Tag streams are named, not positional, so adding a new generator never
  reshuffles the existing ones.
]]

local Seed = {}

local worldSeed = nil

function Seed.setWorld (seed)
  worldSeed = seed
end

function Seed.get ()
  return worldSeed or Config.gen.seedGlobal
end

-- Stable 64-bit mix of a stream name and an optional salt (an entity id, a
-- spawn ordinal, ...). Wrapping multiply+add only -- no bit ops, so this is
-- plain uint64 arithmetic on every LuaJIT build -- and deliberately not
-- string.hash (which is not stable enough to seed from across builds).
function Seed.tag (name, salt)
  local h = 0xCBF29CE484222325ULL
  for i = 1, #name do
    h = h * 0x100000001B3ULL + name:byte(i)
  end
  if salt then
    h = h * 0x100000001B3ULL + (math.floor(salt) % 0xFFFFFFFF)
  end
  return h
end

-- An RNG for a named stream. Pass `salt` to give each instance its own
-- independent stream (entity id, spawn index) instead of sharing one.
function Seed.rng (name, salt)
  local seed = Seed.get()
  if not seed then
    return RNG.FromTime()
  end
  return RNG.Create(seed + Seed.tag(name, salt))
end

return Seed

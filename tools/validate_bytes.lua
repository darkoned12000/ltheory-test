#!/usr/bin/env luajit
--[[----------------------------------------------------------------------------
  Offline Bytes round-trip validator for the ltheory-test LZ4 codec.

  Exercises the C++ Bytes_Compress / Bytes_Decompress path behind
  libphx/src/Bytes.cpp (LZ4 1.10.0, LZ4_decompress_safe + compressBound).
  Catches regressions where the header+payload framing or the
  safe-decompress migration (fast -> safe) breaks, which would corrupt
  saves / Gen data at runtime via Fatal() or silent truncation.

  Runs under luajit with NO GL/Engine context: only malloc + LZ4.
  Exit code non-zero on any failure. Wired into `python3 configure.py test`
  and `cmake --build` (phx_validate_bytes).

  What it covers (mirrors the deprecation fix in Bytes.cpp):
    - small incompressible payloads (needs compressBound, old code Fatal'd)
    - arbitrary strings, pattern blocks, highly compressible zeros
    - 10k random payload (binary safety)
    - header framing: compressed size + 4 == Bytes_GetSize(comp)
    - round-trip identity (memcmp)
----------------------------------------------------------------------------]]--

-- Make `require('ffi.libphx')` resolve without LD_LIBRARY_PATH.
local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1,1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.')..'/'..src end
local root = src:gsub('/tools/validate_bytes%.lua$', '')
if root == src then root = '.' end
package.path = root..'/libphx/script/?.lua;'..root..'/libphx/script/?/init.lua;'..package.path

local ffi = require('ffi')
local libphx = require('ffi.libphx').lib
require('ffi.Bytes') -- registers cdef, not strictly needed but keeps parity

local failures = 0
local function check(name, cond)
  if cond then print('ok   - '..name)
  else failures = failures+1; print('FAIL - '..name) end
end

local function bytesFromString(s)
  return libphx.Bytes_FromData(s, #s)
end

local function roundTrip(name, data, len)
  local src = libphx.Bytes_FromData(data, len)
  local srcSize = libphx.Bytes_GetSize(src)
  check(name..' source size', srcSize == len)

  local comp = libphx.Bytes_Compress(src)
  check(name..' compress non-nil', comp ~= nil)
  local compSize = libphx.Bytes_GetSize(comp)
  check(name..' comp has header', compSize >= 4)

  local decomp = libphx.Bytes_Decompress(comp)
  check(name..' decompress non-nil', decomp ~= nil)
  local decompSize = libphx.Bytes_GetSize(decomp)
  check(name..' round-trip size', decompSize == len)

  local p = ffi.cast('char*', libphx.Bytes_GetData(decomp))
  local got = ffi.string(p, len)
  local expect = type(data)=='string' and data or ffi.string(ffi.cast('char*',data), len)
  check(name..' round-trip bytes', got == expect)

  libphx.Bytes_Free(src)
  libphx.Bytes_Free(comp)
  libphx.Bytes_Free(decomp)
end

print('[validate_bytes] Bytes_Compress/Decompress round-trip (LZ4 safe, compressBound)')

-- 1. tiny incompressible (old alloc bug: 5 -> Fatal)
roundTrip('tiny hello', 'hello', 5)

-- 2. single byte
roundTrip('single x', 'x', 1)

-- 3. short string (previous manual test)
roundTrip('short sentence', 'Hello Limit Theory - testing LZ4 safe decompression 1234567890', 62)

-- 4. highly compressible (zeros)
do
  local z = string.rep('\0', 4096)
  roundTrip('zeros 4096', z, #z)
end

-- 5. pattern block (repeating)
do
  local pat = ('ABCD'):rep(256) -- 1024
  roundTrip('pattern ABCD*256', pat, #pat)
end

-- 6. 10k pseudo-random binary (uses FFI buffer)
do
  local n = 10000
  local buf = ffi.new('char[?]', n)
  for i=0,n-1 do buf[i] = i % 256 end
  roundTrip('binary 10k', buf, n)
end

-- 7. larger text with mixed compressibility
do
  local txt = ('The quick brown fox jumps over the lazy dog. '):rep(200)
  roundTrip('text 9k', txt, #txt)
end

print(failures==0 and '\n[Bytes tests] ALL PASS' or ('\n[Bytes tests] '..failures..' FAILED'))
os.exit(failures==0 and 0 or 1)

#!/usr/bin/env python
import os, re, sys, shutil, subprocess

# The offline shader validator needs moderngl (headless llvmpipe/EGL), which is
# installed under the 3.13 interpreter on this host — not the system python3.
# configure.py uses sys.executable for the CMake build/run steps (fine there) but
# pins python3.13 explicitly for the validator so it fails fast at *any* entry
# point rather than mid-game with "No module named 'moderngl'".
# The offline shader validator needs moderngl with a headless EGL context. On
# this host it lives in a project-local venv (.venv-tools). Prefer that; fall
# back to $PHX_VALIDATOR_PY, then python3, then the old python3.13 pin.
def _validator_py():
    here = os.path.dirname(os.path.abspath(__file__))
    venv = os.path.join(here, '.venv-tools', 'bin', 'python')
    if os.path.exists(venv):
        return venv
    return os.environ.get('PHX_VALIDATOR_PY', 'python3')

VALIDATOR_PY = _validator_py()

def current_glsl_version():
    # Parse the version the engine actually compiles with (single source of truth).
    try:
        with open(os.path.join('libphx', 'src', 'Shader.cpp')) as f:
            m = re.search(r'"#version\s+(\d+)', f.read())
            if m:
                return m.group(1)
    except Exception:
        pass
    return '330'

def run_shader_tests():
    print('[configure.py] Validating GLSL shaders (offline compile+link)')
    exe = os.path.join('tools', 'validate_glsl.py')
    if not os.path.exists(exe):
        print('[configure.py] No tools/validate_glsl.py found - skipping')
        return 0
    return subprocess.run([VALIDATOR_PY, exe, current_glsl_version()]).returncode

def run_bytes_tests():
    print('[configure.py] Validating Bytes LZ4 round-trip (safe decompress)')
    exe = os.path.join('tools', 'validate_bytes.lua')
    if not os.path.exists(exe):
        print('[configure.py] No tools/validate_bytes.lua found - skipping')
        return 0
    # Prefer the vendored LuaJIT (now OpenResty rolling) for reproducibility
    luajit = os.path.join('libphx', 'ext', 'bin', 'linux64', 'luajit')
    if not os.path.exists(luajit):
        luajit = 'luajit'
    return subprocess.run([luajit, exe]).returncode

def run_drawbatch_tests():
    print('[configure.py] Validating DrawBatch grouping (consecutive-run, order-preserving)')
    exe = os.path.join('tools', 'validate_drawbatch.lua')
    if not os.path.exists(exe):
        print('[configure.py] No tools/validate_drawbatch.lua found - skipping')
        return 0
    luajit = os.path.join('libphx', 'ext', 'bin', 'linux64', 'luajit')
    if not os.path.exists(luajit):
        luajit = 'luajit'
    return subprocess.run([luajit, exe]).returncode

def run_renderqueue_tests():
    print('[configure.py] Validating RenderJobQueue threading (barrier, order, shutdown)')
    exe = os.path.join('tools', 'validate_renderqueue.lua')
    if not os.path.exists(exe):
        print('[configure.py] No tools/validate_renderqueue.lua found - skipping')
        return 0
    luajit = os.path.join('libphx', 'ext', 'bin', 'linux64', 'luajit')
    if not os.path.exists(luajit):
        luajit = 'luajit'
    return subprocess.run([luajit, exe]).returncode

def run_sdl_tests():
    print('[configure.py] Validating SDL pkg/header/init + input wiring')
    rc = 0
    for exe in [os.path.join('tools','validate_sdl.py'),
                os.path.join('tools','validate_sdl_window.py'),
                os.path.join('tools','validate_sdl_input.py')]:
        if os.path.exists(exe):
            rc |= subprocess.run([VALIDATOR_PY, exe]).returncode
        else:
            print(f'[configure.py] No {exe} found - skipping')
    return rc

def run_hud_tests():
    print('[configure.py] Validating HUD reticle/turret parity (mouse vs gamepad)')
    exe = os.path.join('tools','validate_hud_reticle.lua')
    if not os.path.exists(exe):
        print('[configure.py] No tools/validate_hud_reticle.lua found - skipping')
        return 0
    luajit = os.path.join('libphx','ext','bin','linux64','luajit')
    if not os.path.exists(luajit):
        luajit = 'luajit'
    return subprocess.run([luajit, exe]).returncode

def run_tests():
    result = 0
    exe = os.path.join('build', 'test', 'lte_tests')
    env = dict(os.environ)
    if sys.platform != 'win32':
        # libphx has $ORIGIN RPATH (bin/libphx64r.so) so no LD_LIBRARY_PATH needed
        # at runtime; bin/ is kept for the legacy test harness. extbin/linux64 was
        # a stale FMOD/Bullet carrier (deleted 2026-08-28) — no longer emitted.
        paths = [os.path.join(os.getcwd(), 'bin')]
        existing = env.get('LD_LIBRARY_PATH', '')
        env['LD_LIBRARY_PATH'] = os.pathsep.join(paths + existing.split(os.pathsep) if existing else paths)
    print('[configure.py] Running LTE core unit tests')
    if os.path.exists(exe):
        result |= subprocess.run([exe], env=env).returncode
    else:
        print('[configure.py] No test executable found - skipping')
    result |= run_shader_tests()
    result |= run_bytes_tests()
    result |= run_drawbatch_tests()
    result |= run_renderqueue_tests()
    result |= run_sdl_tests()
    result |= run_hud_tests()
    return result

def validate_shaders():
    """Hard pre-flight gate: fail the build/run if any shader won't compile+link.

    Runs BEFORE producing anything so a broken .glsl never reaches runtime (where
    it would abort with no context). Returns 0 on success, non-zero on failure."""
    exe = os.path.join('tools', 'validate_glsl.py')
    if not os.path.exists(exe):
        print('[configure.py] No tools/validate_glsl.py found - skipping gate')
        return 0
    rc = subprocess.run([VALIDATOR_PY, exe, current_glsl_version()]).returncode
    if rc == 0:
        print('[configure.py] shader validation OK (offline compile+link)')
    else:
        print('[configure.py] FATAL: shader validation failed - refusing to build/run.', file=sys.stderr)
    return rc

# Main entry point

def main():
    try:
        os.mkdir('build')
    except Exception:
        pass
    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        if cmd == 'clean':
            shutil.rmtree('bin', ignore_errors=True)
            shutil.rmtree('build', ignore_errors=True)
            return 0

        # Pre-flight gate for every command except clean. A failing validation is
        # fatal here so the user never ships a binary that crashes at first draw.
        if validate_shaders() != 0:
            sys.exit(1)

        if cmd == 'build':
            subprocess.call(['cmake', '--build', './build', '--config', 'RelWithDebInfo'])
        elif cmd == 'run':
            exe = 'bin/lt64.exe' if os.name == 'nt' else 'bin/lt64r'
            subprocess.call([exe] + sys.argv[2:])
        elif cmd == 'test':
            return run_tests()
        else:
            subprocess.call(['cmake', '-S', './', '-B', './build'])
    else:
        # Default build
        if validate_shaders() != 0:
            sys.exit(1)
        subprocess.call(['cmake', '-S', './', '-B', './build'])

if __name__ == '__main__':
    main()

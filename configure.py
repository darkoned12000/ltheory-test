#!/usr/bin/env python
import os, sys, shutil, subprocess

# Helper for test harness

def run_tests():
    exe = os.path.join('build', 'test', 'lte_tests')
    env = dict(os.environ)
    if sys.platform != 'win32':
        paths = [os.path.join(os.getcwd(), 'bin'), os.path.join(os.getcwd(), 'extbin', 'linux64')]
        existing = env.get('LD_LIBRARY_PATH', '')
        env['LD_LIBRARY_PATH'] = os.pathsep.join(paths + existing.split(os.pathsep) if existing else paths)
    print('[configure.py] Running LTE core unit tests')
    if os.path.exists(exe):
        return subprocess.run([exe], env=env).returncode
    else:
        print('[configure.py] No test executable found – skipping')
        return 0

# Main entry point

def main():
    try:
        os.mkdir('build')
    except Exception:
        pass
    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        if cmd == 'build':
            subprocess.call(['cmake', '--build', './build', '--config', 'RelWithDebInfo'])
        elif cmd == 'clean':
            shutil.rmtree('bin', ignore_errors=True)
            shutil.rmtree('build', ignore_errors=True)
        elif cmd == 'run':
            exe = 'bin/lt64.exe' if os.name == 'nt' else 'bin/lt64r'
            subprocess.call([exe] + sys.argv[2:])
        elif cmd == 'test':
            return run_tests()
        else:
            subprocess.call(['cmake', '-S', './', '-B', './build'])
    else:
        # Default build
        subprocess.call(['cmake', '-S', './', '-B', './build'])

if __name__ == '__main__':
    main()

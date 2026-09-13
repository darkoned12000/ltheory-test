#include <clocale>
#include <cstdio>
#include <cstdlib>

#if defined(__linux__)
  #include <unistd.h>
  #include <signal.h>
  #include <execinfo.h>
  #include <libgen.h>
  #include <limits.h>
#endif

#ifndef DEBUG
  #define DEBUG 0
#endif

#ifndef CHECK_LEVEL
  #define CHECK_LEVEL 0
#endif

#include "Directory.h"
#include "Engine.h"
#include "File.h"
#include "Lua.h"

#if WINDOWS
extern "C" {
  __declspec(dllexport) unsigned long NvOptimusEnablement = 0x00000001;
  __declspec(dllexport) int AmdPowerXpressRequestHighPerformance = 1;
}
#endif

#if defined(__linux__)
// Catch hardware/memory crashes on Linux and output a stack trace
static void LinuxSignalHandler(int sig) {
  void* array[32];
  size_t size = backtrace(array, 32);
  fprintf(stderr, "\n=== FATAL: Signal %d received ===\n", sig);
  backtrace_symbols_fd(array, size, STDERR_FILENO);
  exit(1);
}

static void RegisterLinuxSignalHandlers() {
  struct sigaction sa;
  sa.sa_handler = LinuxSignalHandler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESETHAND;
  sigaction(SIGSEGV, &sa, nullptr);
  sigaction(SIGABRT, &sa, nullptr);
  sigaction(SIGFPE, &sa, nullptr);
}

// Force current working directory to the binary folder on Linux
static void FixLinuxWorkingDirectory() {
  char result[PATH_MAX];
  ssize_t count = readlink("/proc/self/exe", result, PATH_MAX);
  if (count != -1) {
    result[count] = '\0';
    char* dir = dirname(result);
    chdir(dir);
  }
}
#endif

int main (int argc, char* argv[]) {
  // Ensure consistent dot-decimal float parsing regardless of system locale
  setlocale(LC_ALL, "C");

#if defined(__linux__)
  RegisterLinuxSignalHandlers();
  FixLinuxWorkingDirectory();
#endif

  Engine_Init(4, 6);
  Lua* lua = Lua_Create();
  char const* entryPoint = "./script/Main.lua";

  if (!File_Exists(entryPoint))
  {
    Directory_Change("../");
    if (!File_Exists(entryPoint))
      Fatal("can't find script entrypoint <%s>", entryPoint);
  }

  // Inject system configuration flags using the standard Lua.h wrapper API
  Lua_SetBool(lua, "__debug__", DEBUG > 0);
  Lua_SetBool(lua, "__embedded__", true);
  Lua_SetNumber(lua, "__checklevel__", CHECK_LEVEL);
  if (argc >= 2)
    Lua_SetStr(lua, "__app__", argv[1]);

  Lua_DoFile(lua, entryPoint);

  Lua_Free(lua);
  Engine_Free();
  return 0;
}

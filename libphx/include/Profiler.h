#ifndef PHX_Profiler
#define PHX_Profiler

#include "Common.h"

#define ENABLE_PROFILER 1

PHX_API void  Profiler_Enable      ();
PHX_API void  Profiler_Disable     ();

PHX_API void  Profiler_Begin       (cstr);
PHX_API void  Profiler_End         ();
PHX_API void  Profiler_EndNamed    (cstr);
PHX_API void  Profiler_SetValue    (cstr, int);

PHX_API void  Profiler_LoopMarker  ();

PHX_API void  Profiler_Backtrace   ();

// The current scope-stack depth. -1 means the profiler is off.
//
// Exposed because a Begin/End imbalance is INVISIBLE from the scopes
// themselves: Profiler_End pops whatever is on top, so an unbalanced pair
// does not just lose a scope, it makes every later End() pop the WRONG one.
// The symptom is a scope stack that grows a couple of entries per frame
// until Profiler_Begin hits MAX_STACK_DEPTH and aborts the process -- with a
// backtrace full of repeated 'Frame' scopes and no hint where the leak
// started. Being able to read the depth makes that diagnosable.
PHX_API int   Profiler_GetStackDepth ();

#if ENABLE_PROFILER
  #define FRAME_BEGIN Profiler_Begin(__func__)
  // FRAME_END passes the function name so the profiler can CHECK that it is
// popping the scope it is supposed to pop.
//
// Profiler_End pops whatever is on TOP of the scope stack, so an unbalanced
// Begin/End pair does not merely lose a scope -- it makes every later End()
// pop the WRONG scope, and the stack grows a couple of entries per frame
// until Profiler_Begin hits MAX_STACK_DEPTH and aborts the process. The
// failure then looks like a random crash a minute into the session, with a
// backtrace full of repeated 'Frame' scopes and nothing pointing at the
// actual leak.
//
// Checking the name turns that into an immediate, precise message. It cost
// one strcmp per scope, and the profiler is a diagnostic tool that is off by
// default.
#define FRAME_END Profiler_EndNamed(__func__)
#else
  #define FRAME_BEGIN
  #define FRAME_END
#endif

#endif

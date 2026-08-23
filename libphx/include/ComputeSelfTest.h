#ifndef PHX_ComputeSelfTest
#define PHX_ComputeSelfTest

/* End-to-end compute pipeline check (.comp load -> SSBO upload/bind ->
 * dispatch -> barrier -> readback verify). Not compiled into the normal
 * boot path; callers gate it behind PHX_SELFTEST_COMPUTE=1 (Window_Create
 * invokes it right after OpenGL_Init once a context exists). */
void ComputeSelfTest_Run ();

#endif

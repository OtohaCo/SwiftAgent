#include "JournalProcessPrimitives.h"
#include <unistd.h>
#include <errno.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

/* Test-only raw child: no Swift/Foundation or allocations after fork. */
pid_t swiftagent_test_fork_exec(int gate_read, int gate_write, int witness_read, int witness_write) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    errno = ENOTSUP;
    return -1; /* Controlled fork integration is only macOS/Linux, not iOS. */
#else
    char *args[] = {"/bin/sleep", "60", NULL};
    pid_t child = fork();
    if (child == 0) {
        close(gate_write);
        close(witness_read);
        unsigned char byte;
        if (read(gate_read, &byte, 1) != 1) _exit(110);
        execv(args[0], args);
        _exit(111);
    }
    return child;
#endif
}

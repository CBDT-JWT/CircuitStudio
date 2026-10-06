#ifndef CIRCUITSTUDIO_NGSPICE_IOS_COMPAT_H
#define CIRCUITSTUDIO_NGSPICE_IOS_COMPAT_H
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <stdlib.h>
#include <errno.h>
// The simulator core is unchanged. CLI plot/shell helpers cannot launch tools on iOS.
static inline int circuitstudio_unavailable_shell(const char *command) {
    (void)command;
    errno = ENOTSUP;
    return -1;
}
#define system(command) circuitstudio_unavailable_shell(command)
#endif
#endif

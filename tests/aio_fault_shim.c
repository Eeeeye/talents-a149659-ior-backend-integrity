#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libaio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef int (*io_submit_fn)(io_context_t, long, struct iocb **);
typedef int (*io_getevents_fn)(io_context_t, long, long, struct io_event *,
                              struct timespec *);

static io_submit_fn real_submit;
static io_getevents_fn real_getevents;
static int submit_eintr_injected;
static int submit_short_injected;
static int getevents_eintr_injected;
static int completion_fault_injected;

static void record_fault(const char *kind)
{
    const char *path = getenv("IOR_AIO_FAULT_RECORD");
    int descriptor;

    if (path == NULL || path[0] == '\0')
        return;

    descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (descriptor < 0)
        return;

    (void)write(descriptor, kind, strlen(kind));
    (void)write(descriptor, "\n", 1);
    (void)close(descriptor);
}

static int mode_is(const char *expected)
{
    const char *mode = getenv("IOR_AIO_FAULT_MODE");
    return mode != NULL && strcmp(mode, expected) == 0;
}

static io_submit_fn load_submit(void)
{
    if (real_submit == NULL) {
        union {
            void *object;
            io_submit_fn function;
        } symbol;
        symbol.object = dlsym(RTLD_NEXT, "io_submit");
        if (symbol.object == NULL)
            return NULL;
        real_submit = symbol.function;
    }
    return real_submit;
}

static io_getevents_fn load_getevents(void)
{
    if (real_getevents == NULL) {
        union {
            void *object;
            io_getevents_fn function;
        } symbol;
        symbol.object = dlsym(RTLD_NEXT, "io_getevents");
        if (symbol.object == NULL)
            return NULL;
        real_getevents = symbol.function;
    }
    return real_getevents;
}

int io_submit(io_context_t context, long count, struct iocb **requests)
{
    io_submit_fn next = load_submit();
    if (next == NULL)
        return -ENOSYS;

    if (mode_is("transient-boundaries") && !submit_eintr_injected) {
        submit_eintr_injected = 1;
        return -EINTR;
    }

    if (mode_is("transient-boundaries") && !submit_short_injected
        && count > 1) {
        long accepted = count / 2;
        int result;
        if (accepted < 1)
            accepted = 1;
        result = next(context, accepted, requests);
        if (result > 0)
            submit_short_injected = 1;
        return result;
    }

    return next(context, count, requests);
}

int io_getevents(io_context_t context, long minimum, long maximum,
                 struct io_event *events, struct timespec *timeout)
{
    io_getevents_fn next = load_getevents();
    int result;
    if (next == NULL)
        return -ENOSYS;

    if (mode_is("transient-boundaries") && !getevents_eintr_injected) {
        getevents_eintr_injected = 1;
        return -EINTR;
    }

    result = next(context, minimum, maximum, events, timeout);
    if (result <= 0 || completion_fault_injected)
        return result;

    if (mode_is("short-completion")) {
        for (int index = 0; index < result; index++) {
            if ((long)events[index].res > 0) {
                events[index].res--;
                completion_fault_injected = 1;
                record_fault("short-completion");
                break;
            }
        }
    } else if (mode_is("negative-completion")) {
        events[0].res = -EIO;
        completion_fault_injected = 1;
        record_fault("negative-completion");
    } else if (mode_is("secondary-error")) {
        events[0].res2 = EIO;
        completion_fault_injected = 1;
        record_fault("secondary-error");
    }

    return result;
}

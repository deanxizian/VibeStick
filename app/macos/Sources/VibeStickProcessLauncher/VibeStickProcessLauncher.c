#include "VibeStickProcessLauncher.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <sys/wait.h>
#include <unistd.h>

static int32_t set_close_on_exec(int descriptor) {
    int flags = fcntl(descriptor, F_GETFD);
    if (flags == -1) {
        return errno;
    }
    if (fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == -1) {
        return errno;
    }
    return 0;
}

static int32_t move_above_standard_descriptors(int *descriptor) {
    if (*descriptor > STDERR_FILENO) {
        return 0;
    }
    int replacement = fcntl(*descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
    if (replacement == -1) {
        return errno;
    }
    close(*descriptor);
    *descriptor = replacement;
    return 0;
}

int32_t vibestick_spawn_process_group(
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    pid_t *process_id,
    int *output_fd
) {
    if (executable == NULL || argv == NULL || envp == NULL ||
        working_directory == NULL || process_id == NULL || output_fd == NULL) {
        return EINVAL;
    }

    int descriptors[2];
    if (pipe(descriptors) == -1) {
        return errno;
    }

    int32_t error = move_above_standard_descriptors(&descriptors[0]);
    if (error == 0) {
        error = move_above_standard_descriptors(&descriptors[1]);
    }
    if (error == 0) {
        error = set_close_on_exec(descriptors[0]);
    }
    if (error == 0) {
        error = set_close_on_exec(descriptors[1]);
    }
    if (error != 0) {
        close(descriptors[0]);
        close(descriptors[1]);
        return error;
    }

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int actions_initialized = 0;
    int attributes_initialized = 0;

    error = posix_spawn_file_actions_init(&actions);
    if (error == 0) {
        actions_initialized = 1;
        error = posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO);
    }
    if (error == 0) {
        error = posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO);
    }
    if (error == 0) {
        error = posix_spawn_file_actions_addclose(&actions, descriptors[0]);
    }
    if (error == 0) {
        error = posix_spawn_file_actions_addclose(&actions, descriptors[1]);
    }
    if (error == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // The non-_np spelling is only available on macOS 26. The project
        // supports macOS 14, where this remains the native atomic chdir action.
        error = posix_spawn_file_actions_addchdir_np(&actions, working_directory);
#pragma clang diagnostic pop
    }
    if (error == 0) {
        error = posix_spawnattr_init(&attributes);
        if (error == 0) {
            attributes_initialized = 1;
        }
    }
    if (error == 0) {
        error = posix_spawnattr_setpgroup(&attributes, 0);
    }
    if (error == 0) {
        // A GUI/test host can ignore or block termination signals. Explicitly
        // restore the normal command-line defaults so TERM gets a real grace
        // period before the process-group KILL fallback.
        sigset_t default_signals;
        sigemptyset(&default_signals);
        sigaddset(&default_signals, SIGHUP);
        sigaddset(&default_signals, SIGINT);
        sigaddset(&default_signals, SIGQUIT);
        sigaddset(&default_signals, SIGPIPE);
        sigaddset(&default_signals, SIGTERM);
        error = posix_spawnattr_setsigdefault(&attributes, &default_signals);
    }
    if (error == 0) {
        sigset_t signal_mask;
        sigemptyset(&signal_mask);
        error = posix_spawnattr_setsigmask(&attributes, &signal_mask);
    }
    if (error == 0) {
        short flags = POSIX_SPAWN_SETPGROUP |
            POSIX_SPAWN_CLOEXEC_DEFAULT |
            POSIX_SPAWN_SETSIGDEF |
            POSIX_SPAWN_SETSIGMASK;
        error = posix_spawnattr_setflags(&attributes, flags);
    }

    pid_t child = 0;
    if (error == 0) {
        error = posix_spawn(&child, executable, &actions, &attributes, argv, envp);
    }

    if (attributes_initialized) {
        posix_spawnattr_destroy(&attributes);
    }
    if (actions_initialized) {
        posix_spawn_file_actions_destroy(&actions);
    }
    close(descriptors[1]);

    if (error != 0) {
        close(descriptors[0]);
        return error;
    }

    *process_id = child;
    *output_fd = descriptors[0];
    return 0;
}

int32_t vibestick_wait_process(
    pid_t process_id,
    int32_t *exit_code,
    int32_t *termination_signal
) {
    if (process_id <= 0 || exit_code == NULL || termination_signal == NULL) {
        return EINVAL;
    }

    int status = 0;
    pid_t result;
    do {
        result = waitpid(process_id, &status, 0);
    } while (result == -1 && errno == EINTR);

    if (result == -1) {
        return errno;
    }

    if (WIFEXITED(status)) {
        *exit_code = WEXITSTATUS(status);
        *termination_signal = 0;
        return 0;
    }
    if (WIFSIGNALED(status)) {
        *termination_signal = WTERMSIG(status);
        *exit_code = *termination_signal;
        return 0;
    }
    return ECHILD;
}

int32_t vibestick_signal_process_group(pid_t process_group_id, int signal_number) {
    if (process_group_id <= 0) {
        return EINVAL;
    }
    if (kill(-process_group_id, signal_number) == 0 || errno == ESRCH) {
        return 0;
    }
    return errno;
}

int32_t vibestick_process_group_exists(pid_t process_group_id) {
    if (process_group_id <= 0) {
        return -EINVAL;
    }
    if (kill(-process_group_id, 0) == 0 || errno == EPERM) {
        return 1;
    }
    if (errno == ESRCH) {
        return 0;
    }
    return -errno;
}

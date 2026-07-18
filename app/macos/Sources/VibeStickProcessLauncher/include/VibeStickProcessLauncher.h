#ifndef VIBESTICK_PROCESS_LAUNCHER_H
#define VIBESTICK_PROCESS_LAUNCHER_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Starts `executable` as the leader of a new process group. stdout and stderr
/// are merged into a close-on-exec pipe returned through `output_fd`.
///
/// Returns zero on success or a POSIX error number on failure.
int32_t vibestick_spawn_process_group(
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    pid_t *process_id,
    int *output_fd
);

/// Reaps a process launched by `vibestick_spawn_process_group`.
/// `exit_code` matches Foundation.Process: normal exit status, or signal number.
/// Returns zero on success or a POSIX error number on failure.
int32_t vibestick_wait_process(
    pid_t process_id,
    int32_t *exit_code,
    int32_t *termination_signal
);

/// Sends a signal to every process in the group led by `process_group_id`.
/// ESRCH is treated as success because the group has already exited.
int32_t vibestick_signal_process_group(pid_t process_group_id, int signal_number);

/// Returns 1 while the group exists, 0 once it has exited, or -errno on error.
int32_t vibestick_process_group_exists(pid_t process_group_id);

#ifdef __cplusplus
}
#endif

#endif

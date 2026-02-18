#!/usr/bin/env python3
import sys
import fcntl
import shutil
import os
import errno

# Constants for Linux pipe operations
F_SETPIPE_SZ = 1031
F_GETPIPE_SZ = 1032
TARGET_PIPE_SIZE = 4096  # 4KB (approx 20ms of audio at 48kHz/16bit/stereo)


def get_pipe_size(fd):
    try:
        return fcntl.fcntl(fd, F_GETPIPE_SZ)
    except OSError as e:
        sys.stderr.write(f"Shim: Failed to get pipe size for fd {fd}: {e}\n")
        return -1


def set_pipe_size(fd, size):
    try:
        ret = fcntl.fcntl(fd, F_SETPIPE_SZ, size)
        return ret
    except OSError as e:
        sys.stderr.write(f"Shim: Failed to set pipe size for fd {fd} to {size}: {e}\n")
        return -1


def main():
    sys.stderr.write("Shim: Audio pipeline wrapper starting...\n")

    # Check and adjust Stdin (Input Pipe)
    stdin_fd = sys.stdin.fileno()
    initial_in_size = get_pipe_size(stdin_fd)
    if initial_in_size > TARGET_PIPE_SIZE:
        sys.stderr.write(
            f"Shim: Reducing STDIN pipe from {initial_in_size} to {TARGET_PIPE_SIZE}...\n"
        )
        new_size = set_pipe_size(stdin_fd, TARGET_PIPE_SIZE)
        sys.stderr.write(f"Shim: STDIN pipe size is now {new_size}\n")
    else:
        sys.stderr.write(f"Shim: STDIN pipe size already {initial_in_size}\n")

    # Check and adjust Stdout (Output Pipe)
    stdout_fd = sys.stdout.fileno()
    initial_out_size = get_pipe_size(stdout_fd)
    if initial_out_size > TARGET_PIPE_SIZE:
        sys.stderr.write(
            f"Shim: Reducing STDOUT pipe from {initial_out_size} to {TARGET_PIPE_SIZE}...\n"
        )
        new_size = set_pipe_size(stdout_fd, TARGET_PIPE_SIZE)
        sys.stderr.write(f"Shim: STDOUT pipe size is now {new_size}\n")
    else:
        sys.stderr.write(f"Shim: STDOUT pipe size already {initial_out_size}\n")

    sys.stderr.write("Shim: Starting stream copy...\n")
    sys.stderr.flush()

    try:
        sys.stderr.write("Shim: Waiting for first data...\n")
        first_chunk = True

        # Unbuffered copy loop
        while True:
            # Read up to 4KB (pipe size) at a time to minimize latency
            # We use os.read directly on file descriptors to bypass Python's internal buffering
            chunk = os.read(stdin_fd, TARGET_PIPE_SIZE)
            if not chunk:
                break

            if first_chunk:
                sys.stderr.write(f"Shim: First data received ({len(chunk)} bytes)!\n")
                first_chunk = False

            os.write(stdout_fd, chunk)

    except KeyboardInterrupt:
        pass
    except BrokenPipeError:
        # Downstream (aplay) closed
        pass
    except Exception as e:
        sys.stderr.write(f"Shim: Stream error: {e}\n")


if __name__ == "__main__":
    main()

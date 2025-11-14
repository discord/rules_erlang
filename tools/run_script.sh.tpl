#!/bin/bash
# Auto-generated Erlang release runner for %{release_name}%
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Release information
RELEASE_NAME="%{release_name}%"
RELEASE_VERSION="%{release_version}%"
APP_NAME="%{app_name}%"

# Erlang runtime discovery
# Priority order:
# 1. ERLANG_HOME environment variable
# 2. ERL_HOME environment variable (alternative name)
# 3. Build-time Erlang path (if embedded)
# 4. System PATH

find_erl() {
    # Check ERLANG_HOME first
    if [ -n "${ERLANG_HOME:-}" ] && [ -x "${ERLANG_HOME}/bin/erl" ]; then
        echo "${ERLANG_HOME}/bin/erl"
        return 0
    fi

    # Check ERL_HOME as alternative
    if [ -n "${ERL_HOME:-}" ] && [ -x "${ERL_HOME}/bin/erl" ]; then
        echo "${ERL_HOME}/bin/erl"
        return 0
    fi

    # Check if build-time path was embedded (optional - could be added later)
    # BUILD_TIME_ERL="%{erlang_home}%/bin/erl"
    # if [ -x "$BUILD_TIME_ERL" ]; then
    #     echo "$BUILD_TIME_ERL"
    #     return 0
    # fi

    # Fall back to PATH
    if command -v erl >/dev/null 2>&1; then
        echo "erl"
        return 0
    fi

    # No Erlang found
    echo >&2 "ERROR: Could not find Erlang/OTP runtime!"
    echo >&2 "Please ensure Erlang is installed and either:"
    echo >&2 "  - Set ERLANG_HOME to your Erlang installation directory"
    echo >&2 "  - Add erl to your PATH"
    exit 1
}

# Find the Erlang executable
ERL_CMD=$(find_erl)

# Optionally show which Erlang is being used (useful for debugging)
if [ "${DEBUG_ERLANG_PATH:-}" = "true" ]; then
    echo "Using Erlang at: $ERL_CMD"
    $ERL_CMD -eval 'io:format("Erlang/OTP ~s~n", [erlang:system_info(otp_release)]), halt().' -noshell
fi

# Default configuration
DEFAULT_NODE_NAME="${NODE_NAME:-$RELEASE_NAME}"
LOG_DIR="${LOG_DIR:-$RELEASE_ROOT/log}"
PIPE_DIR="${PIPE_DIR:-/tmp/erl_pipes/$RELEASE_NAME}"

# Paths
BOOT_FILE="$RELEASE_ROOT/releases/$RELEASE_VERSION/start"
LIB_DIR="$RELEASE_ROOT/lib"

# Create necessary directories
mkdir -p "$LOG_DIR" 2>/dev/null || true
mkdir -p "$PIPE_DIR" 2>/dev/null || true

# Build code paths for all applications in lib/
build_code_paths() {
    local paths=""
    for app_dir in "$LIB_DIR"/*/ebin; do
        if [ -d "$app_dir" ]; then
            paths="$paths -pa $app_dir"
        fi
    done
    echo "$paths"
}

# Get code paths
CODE_PATHS=$(build_code_paths)

# Common VM arguments
VM_ARGS="+Bd"
VM_ARGS="$VM_ARGS +K ${KERNEL_POLL:-true}"
VM_ARGS="$VM_ARGS +A ${ASYNC_THREADS:-10}"

# Add user-provided VM args
if [ -n "${EXTRA_VM_ARGS:-}" ]; then
    VM_ARGS="$VM_ARGS $EXTRA_VM_ARGS"
fi

# Distribution settings
DIST_ARGS=""
if [ -n "$DEFAULT_NODE_NAME" ]; then
    if [[ "$DEFAULT_NODE_NAME" == *"."* ]]; then
        DIST_ARGS="-name $DEFAULT_NODE_NAME"
    else
        DIST_ARGS="-sname $DEFAULT_NODE_NAME"
    fi
fi

if [ -n "${COOKIE:-}" ]; then
    DIST_ARGS="$DIST_ARGS -setcookie $COOKIE"
fi

# Config file handling
CONFIG_ARGS=""
if [ -f "$RELEASE_ROOT/sys.config" ]; then
    CONFIG_ARGS="-config $RELEASE_ROOT/sys"
elif [ -f "$RELEASE_ROOT/releases/$RELEASE_VERSION/sys.config" ]; then
    CONFIG_ARGS="-config $RELEASE_ROOT/releases/$RELEASE_VERSION/sys"
fi

case "${1:-foreground}" in
    start)
        echo "Starting $RELEASE_NAME..."
        cd "$RELEASE_ROOT"

        if [ "${START_MODE:-daemon}" = "daemon" ]; then
            $ERL_CMD $VM_ARGS \
                $DIST_ARGS \
                $CODE_PATHS \
                $CONFIG_ARGS \
                -boot "$BOOT_FILE" \
                -detached \
                -noinput
            echo "Started in background"
        else
            exec $ERL_CMD $VM_ARGS \
                $DIST_ARGS \
                $CODE_PATHS \
                $CONFIG_ARGS \
                -boot "$BOOT_FILE" \
                -noshell \
                -noinput
        fi
        ;;

    console)
        echo "Starting $RELEASE_NAME with console..."
        cd "$RELEASE_ROOT"
        exec $ERL_CMD $VM_ARGS \
            $DIST_ARGS \
            $CODE_PATHS \
            $CONFIG_ARGS \
            -boot "$BOOT_FILE"
        ;;

    foreground)
        echo "Starting $RELEASE_NAME in foreground..."
        cd "$RELEASE_ROOT"
        exec $ERL_CMD $VM_ARGS \
            $DIST_ARGS \
            $CODE_PATHS \
            $CONFIG_ARGS \
            -boot "$BOOT_FILE" \
            -noshell \
            -noinput
        ;;

    eval)
        shift
        cd "$RELEASE_ROOT"
        $ERL_CMD $VM_ARGS \
            $CODE_PATHS \
            $CONFIG_ARGS \
            -boot "$BOOT_FILE" \
            -noshell \
            -noinput \
            -eval "$*" \
            -s init stop
        ;;

    version)
        echo "$RELEASE_NAME $RELEASE_VERSION"
        ;;

    remote)
        if [ -z "$DEFAULT_NODE_NAME" ]; then
            echo "Error: NODE_NAME must be set for remote console"
            exit 1
        fi
        echo "Connecting to $DEFAULT_NODE_NAME..."
        exec $ERL_CMD \
            -sname "remsh_$$" \
            ${COOKIE:+-setcookie $COOKIE} \
            -remsh "$DEFAULT_NODE_NAME"
        ;;

    *)
        cat << EOF
Usage: $0 {start|console|foreground|eval|version|remote} [OPTIONS]

Commands:
  start      Start in background (daemon mode)
  console    Start with interactive Erlang console
  foreground Start in foreground (no console)
  eval CODE  Evaluate Erlang code and exit
  version    Show release version
  remote     Connect remote console to running node

Environment Variables:
  ERLANG_HOME     Path to Erlang installation (optional, auto-detected)
  NODE_NAME       Erlang node name (default: $RELEASE_NAME)
  COOKIE          Erlang distribution cookie
  START_MODE      For 'start': daemon|foreground (default: daemon)
  LOG_DIR         Log directory (default: \$RELEASE_ROOT/log)
  KERNEL_POLL     Enable kernel poll: true|false (default: true)
  ASYNC_THREADS   Async thread pool size (default: 10)
  EXTRA_VM_ARGS   Additional VM arguments
  DEBUG_ERLANG_PATH Show which Erlang is being used (set to 'true')

Examples:
  # Start in daemon mode
  $0 start

  # Start with console
  $0 console

  # Start with node name
  NODE_NAME=myapp@localhost $0 start

  # Connect remote console
  NODE_NAME=myapp@localhost $0 remote

  # Evaluate code
  $0 eval "application:which_applications()."

EOF
        exit 1
        ;;
esac

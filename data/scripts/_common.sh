# Shared helpers for rubox shell scripts.
# Source this at the top: source "$(dirname "$0")/_common.sh"

# Resolve DATA_DIR and PROJECT_DIR.
# In gem layout, RUBOX_DATA_DIR is set by the Ruby CLI.
# In standalone layout, DATA_DIR is one level up from scripts/.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${RUBOX_DATA_DIR:-}" ]]; then
    DATA_DIR="$RUBOX_DATA_DIR"
    PROJECT_DIR="$(pwd)"
else
    DATA_DIR="$(cd "$_SCRIPT_DIR/.." && pwd)"
    PROJECT_DIR="$DATA_DIR"
fi

# Number of parallel jobs for compilation.
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

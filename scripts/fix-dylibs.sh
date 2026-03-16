#!/usr/bin/env bash
#
# fix-dylibs.sh - Bundle non-system dylibs and rewrite load paths.
#
# Scans all .bundle and .dylib files in a directory for non-system
# dynamic dependencies, copies them into a lib/ directory, and
# rewrites references using install_name_tool.
#
# Usage: ./scripts/fix-dylibs.sh <staging_dir>
#
set -euo pipefail

STAGING_DIR="$1"
LIB_DIR="${STAGING_DIR}/lib/dylibs"
mkdir -p "$LIB_DIR"

is_system_lib() {
    local path="$1"
    case "$path" in
        /usr/lib/*|/System/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Collect all .bundle and .dylib files
mapfile -t TARGETS < <(find "$STAGING_DIR" -type f \( -name "*.bundle" -o -name "*.dylib" \) ! -path "*/DWARF/*")

FIXED=0
ITERATIONS=0
MAX_ITERATIONS=10

# Iterate until no new dylibs are discovered (handles transitive deps)
while [[ $ITERATIONS -lt $MAX_ITERATIONS ]]; do
    ITERATIONS=$((ITERATIONS + 1))
    NEW_DEPS=0

    for target in "${TARGETS[@]}"; do
        # Get non-system dependencies
        while IFS= read -r dep; do
            dep=$(echo "$dep" | sed 's/^[[:space:]]*//' | cut -d' ' -f1)
            [[ -z "$dep" ]] && continue

            if is_system_lib "$dep"; then
                continue
            fi

            dep_basename=$(basename "$dep")
            bundled_path="${LIB_DIR}/${dep_basename}"

            # Copy the dylib if not already bundled
            if [[ ! -f "$bundled_path" ]]; then
                if [[ -f "$dep" ]]; then
                    echo "    Bundling: ${dep} -> lib/dylibs/${dep_basename}"
                    cp "$dep" "$bundled_path"
                    chmod 644 "$bundled_path"
                    # Add to targets for transitive dep scanning
                    TARGETS+=("$bundled_path")
                    NEW_DEPS=$((NEW_DEPS + 1))
                else
                    echo "    WARNING: dependency not found: ${dep} (needed by $(basename "$target"))"
                    continue
                fi
            fi

            # Compute relative path from target to lib/dylibs/
            target_dir=$(dirname "$target")
            rel_path=$(python3 -c "
import os.path
print(os.path.relpath('${LIB_DIR}', '${target_dir}'))
")
            new_ref="@loader_path/${rel_path}/${dep_basename}"

            # Rewrite the reference
            install_name_tool -change "$dep" "$new_ref" "$target" 2>/dev/null || true
            FIXED=$((FIXED + 1))
        done < <(otool -L "$target" 2>/dev/null | tail -n +2)
    done

    if [[ $NEW_DEPS -eq 0 ]]; then
        break
    fi
done

# Re-sign all modified binaries (required on Apple Silicon)
if [[ $FIXED -gt 0 ]]; then
    echo "    Re-signing modified binaries..."
    for target in "${TARGETS[@]}"; do
        codesign -f -s - "$target" 2>/dev/null || true
    done
    # Sign bundled dylibs too
    for dylib in "$LIB_DIR"/*.dylib; do
        [[ -f "$dylib" ]] && codesign -f -s - "$dylib" 2>/dev/null || true
    done
fi

echo "    Fixed ${FIXED} dylib references across ${#TARGETS[@]} files"

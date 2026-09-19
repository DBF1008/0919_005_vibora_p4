#!/usr/bin/env bash
#
# Builds the Cython extensions and runs the full unit-test suite,
# including the new input-source routing (query / path) and File-field
# upload tests.
#
# Usage (run manually):
#   ./test.sh            # (re)build native extensions + run all unit tests
#   ./test.sh --build    # only (re)build the native extensions
#   ./test.sh --quick    # run only the schema tests (assumes already built)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${PYTHON:-python3}"

log() {
    printf '\033[1;34m[test.sh]\033[0m %s\n' "$1"
}

fail() {
    printf '\033[1;31m[test.sh] ERROR:\033[0m %s\n' "$1" >&2
    exit 1
}

ensure_cython() {
    if ! "$PYTHON_BIN" -c "import Cython" >/dev/null 2>&1; then
        fail "Cython is not installed for $PYTHON_BIN.
Install the build requirements first, for example:
    $PYTHON_BIN -m pip install -r requirements.txt
(requirement pins Cython==0.28.3; a newer 0.2x/0.29 release also works.)"
    fi
}

build_extensions() {
    ensure_cython
    log "Compiling .pyx sources (this may take a minute)..."
    "$PYTHON_BIN" build.py
}

ensure_built() {
    if ! "$PYTHON_BIN" -c "import vibora.schemas.extensions.fields" >/dev/null 2>&1; then
        log "Native extensions are not built yet."
        build_extensions
    fi
}

run_schema_tests() {
    log "Running schema unit tests..."
    "$PYTHON_BIN" -m unittest -v \
        tests.schemas.schemas \
        tests.schemas.sources
}

run_all_tests() {
    log "Running full unit-test suite..."
    "$PYTHON_BIN" test.py
}

case "${1:-all}" in
    --build)
        build_extensions
        log "Build completed successfully."
        ;;
    --quick)
        ensure_built
        run_schema_tests
        log "Schema tests finished."
        ;;
    all|"")
        build_extensions
        run_all_tests
        log "All tests passed."
        ;;
    *)
        fail "Unknown option: $1 (supported: --build, --quick, or no argument)"
        ;;
esac

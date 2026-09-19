#!/usr/bin/env bash
#
# test.sh - Build (if needed) and run every Vibora unit-test module.
#
# Usage:
#   ./test.sh                 # run all test modules
#   ./test.sh schemas forms   # run only these (substring-matched) modules
#
# Environment overrides:
#   PYTHON=/path/to/python  Python interpreter to use (default: python3)
#   SKIP_BUILD=1            Do not try to (re)build the Cython extensions
#
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${PYTHON:-python3}"
FILTER=("$@")

echo "==> Using interpreter: $PYTHON_BIN ($($PYTHON_BIN --version 2>&1))"

# ---------------------------------------------------------------------------
# 1. Build the native Cython extensions when they are missing or stale.
# ---------------------------------------------------------------------------
if [ "${SKIP_BUILD:-0}" != "1" ]; then
    NEED_BUILD=0
    for pyx in $(find vibora -name '*.pyx'); do
        so="${pyx%.pyx}"
        if ! compgen -G "${so}*.so" > /dev/null; then
            NEED_BUILD=1
            break
        fi
    done
    if [ "$NEED_BUILD" = "1" ]; then
        echo "==> Native extensions missing, building with build.py ..."
        "$PYTHON_BIN" build.py || {
            echo "!! Build failed. Install Cython (requirements.txt pins cython) or set SKIP_BUILD=1." >&2
            exit 1
        }
    fi
fi

# ---------------------------------------------------------------------------
# 2. Run the unit tests through a small runner. The runner is written to a
#    temporary file so this script stays a single self-contained entry point.
# ---------------------------------------------------------------------------
RUNNER="$(mktemp "${TMPDIR:-/tmp}/vibora_tests.XXXXXX.py")"
trap 'rm -f "$RUNNER"' EXIT

cat > "$RUNNER" << 'PYEOF'
import asyncio
import collections
import collections.abc
import importlib
import os
import sys
import traceback
import unittest

ROOT = os.getcwd()
sys.path.insert(0, ROOT)
FILTER = sys.argv[1:]

# --- Compatibility shims so the legacy code base also imports/runs on modern
#     Python interpreters (collections aliases, default event loop). ---------
for _name in ('Callable', 'Iterable', 'Mapping', 'MutableMapping', 'Sequence',
              'MutableSequence', 'Set', 'Hashable', 'Awaitable', 'Coroutine'):
    if not hasattr(collections, _name):
        setattr(collections, _name, getattr(collections.abc, _name))

if not hasattr(asyncio, 'coroutine'):
    def _coroutine(func):
        return func
    asyncio.coroutine = _coroutine


def _ensure_event_loop():
    try:
        loop = asyncio.get_event_loop()
        if loop.is_closed():
            raise RuntimeError('closed loop')
    except RuntimeError:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)


_ensure_event_loop()

TESTS_DIR = os.path.join(ROOT, 'tests')
loader = unittest.TestLoader()

modules = []
for base, _dirs, files in os.walk(TESTS_DIR):
    for filename in files:
        if not filename.endswith('.py') or filename == '__init__.py':
            continue
        rel = os.path.relpath(os.path.join(base, filename), TESTS_DIR)
        dotted = 'tests.' + rel[:-3].replace(os.sep, '.')
        if FILTER and not any(token in dotted for token in FILTER):
            continue
        modules.append(dotted)

modules.sort()

passed_modules = []
failed_modules = []
total_tests = 0
total_failures = 0
total_errors = 0

for dotted in modules:
    print('\n' + '=' * 72)
    print('RUN', dotted)
    print('=' * 72)
    try:
        suite = loader.loadTestsFromName(dotted)
    except Exception:
        print('!! Failed to import', dotted)
        traceback.print_exc()
        failed_modules.append((dotted, 'import error'))
        continue

    result = unittest.TextTestRunner(verbosity=2).run(suite)
    count = result.testsRun
    bad = len(result.failures) + len(result.errors)
    total_tests += count
    total_failures += len(result.failures)
    total_errors += len(result.errors)

    if bad:
        failed_modules.append((dotted, '%d failure(s)/error(s)' % bad))
        print('RESULT %s: FAIL (%d of %d)' % (dotted, bad, count))
    else:
        passed_modules.append(dotted)
        print('RESULT %s: OK (%d test(s))' % (dotted, count))

print('\n' + '#' * 72)
print('SUMMARY')
print('#' * 72)
print('Modules passed : %d' % len(passed_modules))
print('Modules failed : %d' % len(failed_modules))
print('Tests run      : %d' % total_tests)
print('Failures       : %d' % total_failures)
print('Errors         : %d' % total_errors)

if failed_modules:
    print('\nFailed modules:')
    for name, reason in failed_modules:
        print('  - %s (%s)' % (name, reason))
    sys.exit(1)

print('\nAll unit-test modules passed.')
PYEOF

"$PYTHON_BIN" "$RUNNER" ${FILTER[@]+"${FILTER[@]}"}

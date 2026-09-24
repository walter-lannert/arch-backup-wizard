#!/usr/bin/env bash
# ==============================================================================
# Arch Backup Wizard — Hermetic Bash Test & Mock Harness
# Zero-dependency, isolated environment for testing wizard libraries
# ==============================================================================
set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_RED="\033[1;31m"
CLR_GREEN="\033[1;32m"
CLR_YELLOW="\033[1;33m"
CLR_BLUE="\033[1;34m"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TEST_NAMES=()

# Global test sandbox
TEST_TEMP_DIR=""
MOCK_DIR=""
ORIG_PATH="$PATH"

setup_test_env() {
    TEST_TEMP_DIR=$(mktemp -d "/tmp/abw_test.XXXXXX")
    MOCK_DIR="$TEST_TEMP_DIR/mocks"
    mkdir -p "$MOCK_DIR"
    export PATH="$MOCK_DIR:$ORIG_PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export UI_SILENT="true"
    mkdir -p "$HOME"
}

teardown_test_env() {
    export PATH="$ORIG_PATH"
    if [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Create a mocked executable in the mock directory
# Usage: mock_cmd <command_name> <shell_script_body>
mock_cmd() {
    local cmd="$1"
    local body="${2:-true}"
    local target="$MOCK_DIR/$cmd"
    cat <<EOF > "$target"
#!/usr/bin/env bash
$body
EOF
    chmod +x "$target"
}

# Assertions
assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-Assertion failed}"
    if [[ "$expected" != "$actual" ]]; then
        echo -e "${CLR_RED}  [ASSERT FAILED] $msg${CLR_RESET}" >&2
        echo "    Expected: '$expected'" >&2
        echo "    Actual:   '$actual'" >&2
        return 1
    fi
    return 0
}

assert_ne() {
    local unexpected="$1"
    local actual="$2"
    local msg="${3:-Assertion failed}"
    if [[ "$unexpected" == "$actual" ]]; then
        echo -e "${CLR_RED}  [ASSERT FAILED] $msg${CLR_RESET}" >&2
        echo "    Value was unexpectedly: '$actual'" >&2
        return 1
    fi
    return 0
}

assert_match() {
    local pattern="$1"
    local string="$2"
    local msg="${3:-Assertion failed}"
    if [[ ! "$string" =~ $pattern ]]; then
        echo -e "${CLR_RED}  [ASSERT FAILED] $msg${CLR_RESET}" >&2
        echo "    Pattern: '$pattern'" >&2
        echo "    String:  '$string'" >&2
        return 1
    fi
    return 0
}

assert_file_exists() {
    local file="$1"
    local msg="${2:-File does not exist: $file}"
    if [[ ! -e "$file" ]]; then
        echo -e "${CLR_RED}  [ASSERT FAILED] $msg${CLR_RESET}" >&2
        return 1
    fi
    return 0
}

assert_dir_exists() {
    local dir="$1"
    local msg="${2:-Directory does not exist: $dir}"
    if [[ ! -d "$dir" ]]; then
        echo -e "${CLR_RED}  [ASSERT FAILED] $msg${CLR_RESET}" >&2
        return 1
    fi
    return 0
}

assert_success() {
    local cmd="$1"
    local msg="${2:-Command failed unexpectedly: $cmd}"
    if ! eval "$cmd"; then
        echo -e "${CLR_RED}  [ASSERT FAILED] $msg${CLR_RESET}" >&2
        return 1
    fi
    return 0
}

assert_failure() {
    local cmd="$1"
    local msg="${2:-Command succeeded unexpectedly: $cmd}"
    if eval "$cmd"; then
        echo -e "${CLR_RED}  [ASSERT FAILED] $msg${CLR_RESET}" >&2
        return 1
    fi
    return 0
}

# Run a test function
run_test() {
    local test_fn="$1"
    local test_desc="${2:-$test_fn}"
    (( TESTS_RUN++ )) || true

    setup_test_env
    local status=0
    set +e
    (
        set -euo pipefail
        "$test_fn"
    )
    status=$?
    set -e
    teardown_test_env

    if (( status == 0 )); then
        (( TESTS_PASSED++ )) || true
        echo -e "${CLR_GREEN}✓ PASS:${CLR_RESET} $test_desc"
    else
        (( TESTS_FAILED++ )) || true
        FAILED_TEST_NAMES+=("$test_desc")
        echo -e "${CLR_RED}✗ FAIL:${CLR_RESET} $test_desc (exit: $status)"
    fi
}

test_summary() {
    echo "--------------------------------------------------------------------------------"
    if (( TESTS_RUN == 0 )); then
        echo -e "${CLR_RED}NO TESTS RUN: Test suite discovered 0 tests${CLR_RESET}"
        return 1
    fi
    if (( TESTS_FAILED == 0 )); then
        echo -e "${CLR_GREEN}ALL TESTS PASSED: $TESTS_PASSED / $TESTS_RUN${CLR_RESET}"
        return 0
    else
        echo -e "${CLR_RED}TEST FAILURES: $TESTS_FAILED / $TESTS_RUN failed${CLR_RESET}"
        for f in "${FAILED_TEST_NAMES[@]}"; do
            echo -e "  - ${CLR_RED}$f${CLR_RESET}"
        done
        return 1
    fi
}

# Discover and run all test_* functions, then print a summary.
run_tests() {
    local test_funcs
    test_funcs="$(compgen -A function | grep '^test_' | grep -v '^test_summary$' | sort)" || true

    for func in ${test_funcs}; do
        run_test "${func}"
    done

    test_summary
}

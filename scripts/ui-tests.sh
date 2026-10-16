#!/bin/bash
# Run the UI tests: they use the app as a person does. They're slow, so
# they run here, before a release, not in CI.
#
#   scripts/ui-tests.sh                 # the Mac UI tests (a few minutes)
#   scripts/ui-tests.sh PivotScenario   # just the tests matching a filter
#   scripts/ui-tests.sh --ipad          # the Mac tests, then the iPad XCUITests
#
# Each Mac test saves a trace of its steps, and a screenshot of each failed
# check, in .build/ui-test-artifacts/<test>/. SIMPLESPREAD_UI_SHOTS=1 also
# screenshots every step a test notes.
set -uo pipefail
cd "$(dirname "$0")/.."

ipad=0
filter=SpreadsheetAppUITests
for arg in "$@"; do
    case "$arg" in
        --ipad) ipad=1 ;;
        *) filter="$arg" ;;
    esac
done

log=.build/ui-test-artifacts/run.log
mkdir -p .build/ui-test-artifacts
# One at a time: each test's window must be the key window.
SIMPLESPREAD_UI_TESTS=1 swift test --no-parallel --filter "$filter" 2>&1 | tee "$log" \
    | grep --line-buffered -E '^(◇ Test .* started|✔ Test|✘|↳ )' | grep -v '↳ Testing Library\|↳ Target Platform\|Test case passing'
status=${PIPESTATUS[0]}

# AppKit can end the test host without a word (and a zero status): a run
# that never reports its result failed, wherever it stopped.
if ! grep -q '^[✔✘] Test run with' "$log"; then
    echo "The UI tests stopped without finishing. The last steps of the last test to start:"
    last=$(grep '^◇ Test .* started' "$log" | tail -1 | sed -E 's/^◇ Test ([^(]*).*/\1/')
    [ -n "$last" ] && tail -5 ".build/ui-test-artifacts/$last/trace.log" 2>/dev/null
    status=1
fi
[ "$status" -eq 0 ] || exit "$status"

if [ "$ipad" -eq 1 ]; then
    command -v xcodegen >/dev/null || { echo "The iPad tests need XcodeGen: brew install xcodegen"; exit 1; }
    (cd iOS && xcodegen -q && xcodebuild test -project SimpleSpread.xcodeproj -scheme SimpleSpread \
        -destination "platform=iOS Simulator,name=${SIMPLESPREAD_IPAD:-iPad Pro 13-inch (M5)}" \
        -only-testing:SimpleSpreadUITests \
        -skip-testing:SimpleSpreadUITests/ReviewTests \
        -skip-testing:SimpleSpreadUITests/SimpleSpreadUITests/testScreenshots \
        -retry-tests-on-failure -test-iterations 3 -quiet) || exit 1
fi

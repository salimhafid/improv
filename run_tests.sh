#!/bin/bash
# Run the whole offline test suite: Python (scrapers + aggregators) and the
# Swift logic harness (models, date utils, section building — compiled straight
# against the app sources, no Xcode test target). Fails on the first suite that
# fails.
set -euo pipefail
cd "$(dirname "$0")"

echo "── Python tests ──────────────────────────────────────"
.venv/bin/python -m unittest discover -s tests

echo "── Swift logic tests ─────────────────────────────────"
BIN="$(mktemp -d)/improv_logic_tests"
xcrun swiftc -parse-as-library -o "$BIN" \
  ios/UCBShows/Support/DateUtils.swift \
  ios/UCBShows/Models/Show.swift \
  ios/UCBShows/Models/Class.swift \
  ios/UCBShows/Models/Source.swift \
  ios/UCBShows/Models/Filters.swift \
  ios/UCBShows/Models/Talent.swift \
  ios/UCBShows/Support/AppSupport.swift \
  ios/UCBShows/Support/SearchText.swift \
  ios/UCBShows/Services/FeedService.swift \
  ios/UCBShows/Services/ReminderPlan.swift \
  ios/UCBShows/Services/ShowsStore.swift \
  ios/UCBShows/Services/ClassesStore.swift \
  tests/ios/LogicTests.swift
"$BIN"

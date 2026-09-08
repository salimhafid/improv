#!/bin/bash
# Run the whole offline test suite: Python (scrapers + aggregators) and the
# Swift logic harness (models, date utils, section building — compiled straight
# against the app sources, no Xcode test target). Fails on the first suite that
# fails.
set -euo pipefail
cd "$(dirname "$0")"

echo "── Python tests ──────────────────────────────────────"
# REFRESH_DETAILS is the scraper's opt-in re-scrape switch; exported in a
# shell it would flip three aggregator tests. PYTHON overrides the venv.
env -u REFRESH_DETAILS "${PYTHON:-.venv/bin/python}" -m unittest discover -s tests

echo "── Swift logic tests ─────────────────────────────────"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
BIN="$BUILD_DIR/improv_logic_tests"
# Only files free of UIKit/SwiftUI/UserNotifications imports can be here —
# the harness links as a macOS command-line binary.
xcrun swiftc -parse-as-library -o "$BIN" \
  ios/UCBShows/Support/DateUtils.swift \
  ios/UCBShows/Models/Show.swift \
  ios/UCBShows/Models/Ticket.swift \
  ios/UCBShows/Models/Venue.swift \
  ios/UCBShows/Models/Class.swift \
  ios/UCBShows/Models/ClassCurriculum.swift \
  ios/UCBShows/Services/ClassAlertPreferences.swift \
  ios/UCBShows/Models/Source.swift \
  ios/UCBShows/Models/Filters.swift \
  ios/UCBShows/Models/Talent.swift \
  ios/UCBShows/Support/AppSupport.swift \
  ios/UCBShows/Support/SearchText.swift \
  ios/UCBShows/Services/FeedService.swift \
  ios/UCBShows/Services/ReminderPlan.swift \
  ios/UCBShows/Services/ShowsStore.swift \
  ios/UCBShows/Services/ClassesStore.swift \
  ios/UCBShows/Services/TalentStore.swift \
  tests/ios/ClassAlertPreferenceTests.swift \
  tests/ios/LogicTests.swift
"$BIN"

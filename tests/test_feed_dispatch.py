"""Exercise the class watcher's real dispatch decisions with a recording gh."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / ".github/scripts/dispatch-feeds.sh"


class FeedDispatchTests(unittest.TestCase):
    def test_hourly_and_detection_dispatches(self):
        with tempfile.TemporaryDirectory() as temp:
            subprocess.run(["bash", "-eu", "-c", """
                source "$SCRIPT"
                gh() {
                    echo "$*" >> calls
                    [[ "$available" == true ]]
                }
                available=true
                MODE=chain
                next_full_publish=0
                dispatch_feeds 10 true
                dispatch_feeds 130 true
                echo ucb_ny > "$WATCH_NEW_CLASSES_FILE"
                dispatch_feeds 250 false
                test -s "$WATCH_NEW_CLASSES_FILE"
                dispatch_feeds 370 true
                test ! -s "$WATCH_NEW_CLASSES_FILE"
                dispatch_feeds 3609 true
                available=false
                echo ucb_la > "$WATCH_NEW_CLASSES_FILE"
                if dispatch_feeds 3610 true; then exit 1; fi
                test -s "$WATCH_NEW_CLASSES_FILE"
                available=true
                dispatch_feeds 3730 false
                test -s "$WATCH_NEW_CLASSES_FILE"
                dispatch_feeds 3850 true
                echo ucb_ny > "$WATCH_NEW_CLASSES_FILE"
                dispatch_feeds 7330 true
                test ! -s "$WATCH_NEW_CLASSES_FILE"
                MODE=ucb
                dispatch_feeds 20000 true
                echo ucb_ny > "$WATCH_NEW_CLASSES_FILE"
                dispatch_feeds 20001 true
            """], env={**os.environ, "SCRIPT": str(SCRIPT),
                       "WATCH_NEW_CLASSES_FILE": str(Path(temp) / "new-classes")},
                           cwd=temp, check=True, stdout=subprocess.PIPE)
            full = "workflow run scrape.yml --ref main"
            classes = full + " -f classes_only=true"
            self.assertEqual((Path(temp) / "calls").read_text().splitlines(),
                             [full, classes, full, full, classes, full, classes])

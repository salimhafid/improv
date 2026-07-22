# TODO.md — open items, watchlist, and likely next steps

Companion to [CONTEXT.md](CONTEXT.md). Status as of 2026-07-22.

## Blocking release (user actions in App Store Connect)

- [ ] **Ship v1.2**: create version 1.2 on the app's page, add What's New
      (Second City*, Logan Square Improv, The Playground, six months of
      Annoyance + Second City shows, Second City & Logan Square classes,
      collapsible UCB Core Curriculum section, rich share previews,
      Apple/Google calendar choice, 1-hour reminders — *trim to whatever
      the approved 1.1 build lacked), select build **1.2 (16)** (build 15
      predates the Core Curriculum UI), Submit for Review.
- [ ] Confirm ASC Support URL = `https://github.com/salimhafid/improv` and
      Privacy Policy URL = `.../blob/main/PRIVACY.md` (changed after 1.1 was
      prepared; may still show old salimhafid.com values).

## Watchlist (check occasionally; all fail-soft)

- [x] ~~`wgis_ny` 0 upcoming shows~~ — RESOLVED 2026-07-22: verified correct.
      All WGIS Crowdwork shows are Pacific-timezone; WGIS NY runs classes
      only. 0 is the right answer, not a breakage.
- [ ] Annoyance meta enrichment (descriptions/images) is partial whenever
      ThunderTix 429s mid-run; self-heals daily. If chronically bad, add
      per-URL carry-over like the UCB detail cache. (The 180-day horizon
      raised productions-per-run from ~49 to ~80 — watch 429 frequency.)
- [ ] UCB shows pagination (`?_page=N`, 88 cards/page) assumes WPGB keeps
      server-rendering history pages; if UCB's feed count ever snaps back to
      exactly 88/city, the walk broke — check `_PAGE_SIZE` still matches.
- [ ] Second City classes ride `/_next/data/<buildId>/find-a-class/chicago.json`;
      a Next.js build mid-scrape 404s once (fail-soft, carries). Chronic
      failure likely means the route or payload shape changed.
- [ ] UCB detail-enrichment budget is 400 fetches/run vs ~413 first-time
      targets after pagination (281 UCB shows + 132 Magnet) — new-show
      backlogs converge on the second run via `detail_done`; fine unless
      the budget is lowered.
- [ ] Playground depends on a hardcoded Google Calendar id (in
      sources/playground.py). If the theater regenerates it, the source
      raises and carries; re-extract the id from their show-calendar page
      (`calendar.google.com/calendar/embed?src=…` in the Canva HTML).
- [ ] Second City stage names are a slug heuristic (Mainstage / e.t.c. /
      Skybox); shows that don't match get an empty venue.
- [ ] GitHub Actions crons on public repos can lag minutes-to-an-hour at
      peak; the bot's own commits keep the workflow from being auto-disabled
      at 60 days of repo inactivity.
- [ ] ASC screenshots were captured before Second City / Logan Square /
      Playground / onboarding shipped. Fine for review, but a refresh would
      show the fuller Chicago lineup (recipe in CONTEXT.md).

## Nice-to-haves (discussed, not committed)

- [x] ~~Classes for the newer Chicago sources~~ — DONE 2026-07-22: Second City
      (Next.js find-a-class data route, ~109 sections) and Logan Square
      (Crowdwork `lsi`) shipped. Playground verified to have NO classes
      program (sitemap + rendered site) — nothing to add.
- [ ] **UCB online classes** (Arlo tag LOC_Online, ~15 offerings incl. core
      levels): bookable from anywhere but the app's model is city-scoped —
      needs a product decision (attach to both cities? an "Online" scope?).
      Same question for WGIS `/onlineclasses` (~7 open workshops).
- [ ] Arlo satellite locations (Austin 12, Pittsburgh 10, Edinburgh 7
      classes) if the app ever expands beyond NY/LA/Chicago.
- [ ] Second City stage/venue: 84% of show items have blank venue (slug
      heuristic only matches Mainstage/e.t.c./Skybox) — the patronticket
      blob or page data may carry the real stage; needs field spelunking.
- [ ] Brooklyn CC polish: map Squarespace categories (Eris Mainstage / Deep
      Space / Pig Pen + two street addresses) into venue instead of
      comedy_types; parse class start dates out of product titles.
- [ ] WGIS class enrichment (0% descriptions/images — needs per-workshop
      detail-page fetches) and show prices (cost.formatted is in the API;
      shows have no price field in the feed model today).
- [ ] iO Fest passes appear as "shows" (they're ticket bundles); Annoyance
      "CLASS:"-titled ThunderTix entries duplicate Crowdwork classes —
      both could use tagging/dedupe.
- [ ] Cast/talent for non-UCB theaters (no structured data found so far;
      Second City's patronticket blob has no lineup info).
- [ ] Hosted OG interstitial pages so *pasted* links get custom previews —
      **explicitly skipped by user** (needs a GitHub org for generic Pages);
      revisit only if asked.
- [ ] Tonight home-screen widget — built once (build ~1), removed by user
      request when cutting bandwidth. Code is in git history
      (`git log --all -- 'ios/UCBWidget/*'`) if ever wanted again.
- [ ] Talent directory: DCM-only performers who are on none of the four
      scraped pages can't exist by construction now (DCM page is fully
      scraped), but UCB could add rosters (e.g. touring companies) — the
      PAGES list in sources/ucb_talent.py is the extension point.

## Docs debt

- [ ] Root README.md still describes the Cloud Run era in places (deploy.sh,
      Flask serving). The Flask app still works for local dev, and deploy.sh
      is legacy-but-functional; a rewrite reflecting the Actions+raw
      architecture would help outside readers. (ios/README.md and
      CONTEXT.md are current.)
- [ ] ios/README.md line ~5 still says feeds come from "the Cloud Run
      backend" in its intro sentence — cosmetic, one line.
- [ ] UCBapp.md (the future-apps playbook) predates the raw-CDN move, the
      LPLinkMetadata share pattern, and several scraping protocols
      (patronticket blobs, WPGB ajax, ThunderTix reports/calendar, Crowdwork
      API, Google-Calendar-behind-Canva). Worth a refresh pass if it gets
      used for a new app.

## Session hygiene reminders (for the next Claude)

- Re-ask the user for the GitHub PAT when pushing (never stored on disk).
- Always `git pull --rebase` before pushing (the scrape bot commits often);
  keep the newer docs/*.json on conflicts.
- Rate-limit empathy: ThunderTix ≤3 concurrent; don't loop full-scrape tests
  back-to-back against it.
- After any app-code change that ships: bump CURRENT_PROJECT_VERSION (both
  configs), archive, upload, commit — the full runbook is in CONTEXT.md.

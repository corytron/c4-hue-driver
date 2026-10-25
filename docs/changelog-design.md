# Changelog (issue #255)

The contract for one changelog that every release publishes on GitHub and
every driver package carries at the bottom of its Documentation tab.
Branch `feature/changelog-255`. Owner, 2026-10-25: "We need to publish a
changelog on gh for every release (non-dev) as well as a running list of
change-logs for every version ever released at the bottom of the documents
tab for each driver we release."

## 1. The source: `CHANGELOG.md`

One file at the repository root, written by hand, newest first. Only
releases are listed: a release is a GitHub release cut by the Release
workflow (or, before that workflow existed, a published release build).
Development builds and VM builds installed for tests are never listed.

```markdown
# Changelog

<free text: one paragraph saying what is listed and how versions and
build numbers relate; no headings>

## Unreleased

### Fixed
- One line per change, written for the people who install and use the
  drivers. Issue numbers in brackets at the end: (#232).

## 1.0 "Cassian", build 349 (2026-10-25)

### Added
- ...
### Changed
- ...
### Fixed
- ...
### Security
- ...
### Known limits
- ...
```

Rules the checker enforces:

- The first `##` heading is exactly `## Unreleased`; it may be empty (no
  `###` sections and no bullets).
- Every other `##` heading matches
  `^## (\d+)\.(\d+) "([^"]+)", build (\d+) \((\d{4}-\d{2}-\d{2})\)$`:
  version, codename, build number, date.
- Released entries are ordered by build number, strictly decreasing; dates
  never increase going down; a version's codename is the same for every
  entry of that major version.
- Inside an entry only `###` headings from this list, in this order, each
  at most once: `Added`, `Changed`, `Fixed`, `Security`, `Known limits`.
- Under a `###` heading only bullet lines (`- `) and their continuation
  lines (indented by two spaces). No nested lists, no tables, no HTML.
- Inline markup allowed in bullets: `` `code` ``, `**bold**`, and issue or
  PR references `#123`. Links `[text](url)` render as their text.
- Every released entry has at least one bullet.

## 2. The tool: `tools/changelog.py` (Python 3.12, standard library only)

```
changelog.py check  [--file CHANGELOG.md]
changelog.py html   [--file F] [--release VERSION --build N --date YYYY-MM-DD]
                    [--dev-build N] [--codename NAME]
changelog.py notes  [--file F] --version VERSION --build N --date YYYY-MM-DD
                    [--codename NAME] [--template .github/release-notes.md]
changelog.py stamp  [--file F] --version VERSION --build N --date YYYY-MM-DD
                    [--codename NAME]
```

- `check`: validates §1; prints `CHANGELOG.md: ok (N releases)` or every
  problem with its line number and exits 1.
- `html`: prints an HTML fragment (no `<html>`/`<body>`) for a
  Documentation tab:
  `<h2 id="changelog">Changelog</h2>`, one sentence of introduction, then
  per entry an `<h3>` with the heading text and per category a `<p><b>Fixed</b></p>`
  and a `<ul>` of `<li>`. Text is HTML-escaped; `` `code` `` becomes
  `<code>`, `**x**` becomes `<b>`, links become their text, `#123` stays
  text.
  - With `--release`: the `Unreleased` entry, if it has bullets, is
    rendered as that release (`1.0 "Cassian", build N (date)`). The
    codename is taken from the newest released entry of the same major
    version; for the first release of a new major version `--codename` is
    required (`html`, `notes` and `stamp` all accept it). If `Unreleased` is
    empty, it is left out.
  - With `--dev-build N`: a non-empty `Unreleased` renders as
    `Unreleased (development build N)`.
  - With neither: a non-empty `Unreleased` renders as `Unreleased`.
  - An empty `Unreleased` is never rendered.
- `notes`: prints the Markdown that the Release workflow publishes as the
  release's notes, from `.github/release-notes.md` (§4) with its
  placeholders filled: `{version}`, `{codename}`, `{build}`, `{date}`,
  `{this_build}` (the `Unreleased` entry's sections as Markdown, under no
  heading of its own) and `{history}` (every released entry of the same
  version, newest first, each as a `###` heading and its sections as
  bold category lines and bullets). It refuses (exit 1) when `Unreleased`
  has no bullets: a release must say what it changes.
- `stamp`: rewrites the file: the `Unreleased` heading becomes the
  released heading for `--version`, `--build` and `--date` (codename from
  the file, or `--codename` for the first entry of a new major version),
  and a new empty `## Unreleased` is inserted above it. Refuses when
  `Unreleased` is empty or when the build already has an entry. Writes the
  file only after the result passes `check`.

Exit codes: 0 done, 1 refused or invalid, 2 usage.

## 3. Where it shows

- **Composer:** each driver's `www/documentation.html` carries one marker
  line `<!-- CHANGELOG -->` as the last section before the footer caption
  (the license and trademark line). `tools/build.sh` replaces that marker
  in the **staged** copy with `changelog.py html`'s output: with `--release
  <version> --build <build> --date <today>` when HEAD has a `v*` tag (the
  Release workflow's build, and `tools/build.sh` on a tagged commit), with
  `--dev-build <build>` in a `--dev` build, and with neither otherwise. The
  file in `src/` keeps the marker. A build whose documentation lacks the
  marker, or whose changelog fails `check`, fails.
- **GitHub, per release:** the Release workflow's build job runs
  `changelog.py notes` and hands `release-notes.md` to the publish job with
  the packages; the publish job sets it as the release's notes on every
  run (`gh release create --notes-file`, or `gh release edit --notes-file`
  when the release exists). The notes are no longer edited by hand; the
  title stays `<version> "<codename>"`. A release run with an empty
  `Unreleased` fails in the build job.
- **GitHub, the running list:** `CHANGELOG.md` itself, linked from the
  README, from each release's notes and from the Discussions announcement.

## 4. `.github/release-notes.md`

The fixed part of every release's notes (what you get, requirements,
install, verify, licence), taken from today's v1.0 notes and kept in the
repository, with the placeholders of §2. `{this_build}` comes under a
heading "New in build {build}" and `{history}` under "Earlier builds of
{version}", followed by a link to `CHANGELOG.md`.

## 5. Process (CLAUDE.md, release checklist)

- A PR that changes what the drivers do, or what their documentation says,
  adds a line under `## Unreleased` (the PR template asks).
- After a release, the desired-state PR (`deploy/house.yaml`) also runs
  `changelog.py stamp` with the release's version, build and date, so
  `CHANGELOG.md` names the build that was published.
- `tools/check.sh` gains the check `changelog` (`changelog.py check`),
  run by CI's tooling job.

## 6. Who owns which file

| Owner | Files |
|---|---|
| tool agent | `tools/changelog.py`, `tools/tests/test_changelog.py` |
| history agent | `CHANGELOG.md` |
| coordinator | this file, `.github/release-notes.md`, `tools/build.sh`, `tools/check.sh`, `.github/workflows/release.yml`, `.github/workflows/ci.yml`, `src/*/www/documentation.html` (the marker), `.github/PULL_REQUEST_TEMPLATE.md`, `README.md`, `CLAUDE.md`, `docs/release-checklist.md`, `docs/cicd-gitops-design.md` |

## 7. Done means

`tools/check.sh` passes, including `changelog`; `tools/build.sh` and
`tools/build.sh --dev` put the rendered changelog at the bottom of all
three Documentation tabs (checked by unzipping); a dry run of
`changelog.py notes` for the next build reads right; the next release
publishes its notes from the changelog and its packages carry it.

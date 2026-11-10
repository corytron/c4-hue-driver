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
  never increase going down; every entry carries the codename that
  `.github/codenames.json` gives its version X.Y (below).
- Inside an entry only `###` headings from this list, in this order, each
  at most once: `Added`, `Changed`, `Fixed`, `Security`, `Known limits`.
- Under a `###` heading only bullet lines (`- `) and their continuation
  lines (indented by two spaces). No nested lists, no tables, no HTML.
- Inline markup allowed in bullets: `` `code` ``, `**bold**`, and issue or
  PR references `#123`. Links `[text](url)` render as their text.
- Every released entry has at least one bullet.

### Codenames: `.github/codenames.json` (#304)

Owner, 2026-10-26: each X.Y release has its own codename, kept by all its
builds and betas. How the names are chosen is the owner's and stays out of
public text (#416). One file names them, and the tool takes every
codename from it:

```json
{
  "1.0": "Cassian",
  "1.1": "Brasso"
}
```

- One JSON object. Each key is a version X.Y without leading zeros, once. A
  prerelease X.Y-beta.N has no key of its own: every build of X.Y, its
  betas included, takes the name of X.Y.
- Each name is plain, ASCII letters and digits joined by single spaces or
  hyphens (`Mon Mothma`, `K-2SO`), and no two versions share one, whatever
  the letter case.
- `check` reports what breaks these rules, each as
  `.github/codenames.json: message`, and every released entry whose X.Y
  the file does not name or whose codename is not the file's, at the
  entry's line.
- A version the file does not name cannot be built as a release or a
  prerelease: `html`, `notes` and `stamp` refuse it (§2), and the Release
  workflow's build fails before any package is packed. Renaming an X.Y that
  has published builds also means correcting those releases' titles and
  notes and their Discussions announcements, as #304 did for the 1.1 betas.

### Codename notes: `.github/codename-notes.json` (#464)

Owner, 2026-11-10: the notes of every release, past and future, open with a
blurb as their first sentence: what the release's codename means in the
show and, where it fits, how that ties to what the release changed. One
file holds the blurbs, and `notes` takes each from it:

```json
{
  "1.0": "Cassian Andor, ..., names the first release: the bridge, lights, scenes and zone lights ...",
  "1.1": "Brasso, ..., names the release that brings Hue motion sensors ..."
}
```

- One JSON object keyed like `.github/codenames.json`: each key a version
  X.Y without leading zeros, once, and exactly the versions that file
  names. Every X.Y with a codename has a blurb, and an X.Y without one has
  none. A prerelease X.Y-beta.N has no key of its own: every build of X.Y,
  its betas included, opens with the blurb of X.Y.
- Each blurb is one line of text that is not blank: no line break, since
  the notes open with it as one paragraph. It shows in the release's notes
  on GitHub only, never in a Documentation tab.
- A blurb says what the name means; how the names are chosen stays out of
  it, as out of all public text (#416).
- `check` reports what breaks these rules, each as
  `.github/codename-notes.json: message`, so CI's `changelog` check and
  every build fail on a version that has a codename but no blurb.
- `notes` refuses a version whose X.Y has no blurb or an empty one, before
  it prints any notes, so the Release workflow's build job fails before any
  release is created or changed (§2). `html` and `stamp` do not read the
  file.

## 2. The tool: `tools/changelog.py` (Python 3.12, standard library only)

```
changelog.py check  [--file CHANGELOG.md] [--codenames .github/codenames.json]
                    [--codename-notes .github/codename-notes.json]
changelog.py html   [--file F] [--codenames C]
                    [--release VERSION --build N --date YYYY-MM-DD]
                    [--dev-build N] [--codename NAME]
changelog.py notes  [--file F] [--codenames C] [--codename-notes B]
                    --version VERSION --build N --date YYYY-MM-DD
                    [--codename NAME] [--template .github/release-notes.md]
changelog.py stamp  [--file F] [--codenames C]
                    --version VERSION --build N --date YYYY-MM-DD
                    [--codename NAME]
```

`--codenames` names another codenames file than `.github/codenames.json`,
and `--codename-notes` (`check` and `notes` only) another codename notes
file than `.github/codename-notes.json` (the tests use their own). The
Release workflow passes neither: it reads the files of the commit it
builds.

- `check`: validates §1, the codenames and codename notes files included;
  prints `CHANGELOG.md: ok (N releases)` or every problem (in
  `CHANGELOG.md` with its line number) and the number of each file's
  problems, and exits 1.
- `html`: prints an HTML fragment (no `<html>`/`<body>`) for a
  Documentation tab:
  `<h2 id="changelog">Changelog</h2>`, one sentence of introduction, then
  per entry an `<h3>` with the heading text and per category a `<p><b>Fixed</b></p>`
  and a `<ul>` of `<li>`. Text is HTML-escaped; `` `code` `` becomes
  `<code>`, `**x**` becomes `<b>`, links become their text, `#123` stays
  text.
  - With `--release`: the `Unreleased` entry, if it has bullets, is
    rendered as that release (`1.0 "Cassian", build N (date)`). The
    codename is the one `.github/codenames.json` gives the version's X.Y
    (§1), and a version the file does not name is refused. `--codename`
    (`html`, `notes` and `stamp` all accept it) only confirms that name:
    any other is refused, and it never names a version the file does not.
    If `Unreleased` is empty, it is left out.
  - With `--dev-build N`: a non-empty `Unreleased` renders as
    `Unreleased (development build N)`.
  - With neither: a non-empty `Unreleased` renders as `Unreleased`.
  - An empty `Unreleased` is never rendered.
- `notes`: prints the Markdown that the Release workflow publishes as the
  release's notes, from `.github/release-notes.md` (§4) with its
  placeholders filled: `{version}`, `{codename}`, `{codename_note}` (the
  blurb `.github/codename-notes.json` gives the version's X.Y, §1),
  `{build}`, `{date}`, `{this_build}` (the `Unreleased` entry's sections as
  Markdown, under no heading of its own) and `{history}` (every released
  entry of the same version, newest first, each as a `###` heading and its
  sections as bold category lines and bullets). Every placeholder is filled
  in one pass, so a value that holds `{build}` keeps it as written. It
  refuses (exit 1, nothing printed on stdout) when `Unreleased` has no
  bullets (a release must say what it changes), when the version's X.Y has
  no blurb or an empty one, when the codename notes file fails `check`,
  and when the template lacks `{this_build}` or `{codename_note}`. The
  refusals for a blurb read:

  ```
  error: 1.6 has no blurb in .github/codename-notes.json: each X.Y gets one there before its first build, saying what its codename means; the notes open with it
  error: the blurb of 1.6 in .github/codename-notes.json is empty: it says what the codename "Name" means, and the notes open with it
  ```
- `stamp`: rewrites the file: the `Unreleased` heading becomes the
  released heading for `--version`, `--build` and `--date` (codename from
  `.github/codenames.json`), and a new empty `## Unreleased` is inserted
  above it. Refuses when `Unreleased` is empty or when the build already
  has an entry. Writes the file only after the result passes `check`.

Prereleases (#269, `docs/prerelease-design.md`): `--version` and `html
--release` also take `X.Y-beta.N`, which is never an entry of `CHANGELOG.md`.
`html` shows a non-empty `Unreleased` entry as `1.1 beta 1 "Brasso"
(prerelease), build N (date)`, with the codename of 1.1, never as the
release. `notes` fills `.github/prerelease-notes.md` (its default for a
prerelease) with `{version}`
(`1.1-beta.1`), `{release}` (`1.1`), `{beta}`, `{codename}`,
`{codename_note}` (the blurb of `1.1`), `{build}`, `{date}`,
`{this_build}`, `{stable}` and `{stable_version}` (the newest released
entry, which the prerelease follows), and with no `{history}`.
`stamp` refuses a prerelease, and `html` and `notes` refuse a prerelease of a
version the file lists already: a prerelease comes before its release.

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
  `Unreleased`, or for an X.Y without a blurb, fails in the build job.
- **GitHub, the running list:** `CHANGELOG.md` itself, linked from the
  README, from each release's notes and from the Discussions announcement.

## 4. `.github/release-notes.md`

The fixed part of every release's notes (what you get, requirements,
install, verify, licence), taken from today's v1.0 notes and kept in the
repository, with the placeholders of §2. `{codename_note}` is the first
paragraph, on its own line right after the `##` heading and before
"Released {date}." (#464); `.github/prerelease-notes.md` has it in the same
place, before its bold first line. `{this_build}` comes under a heading
"New in build {build}" and `{history}` under "Earlier builds of
{version}", followed by a link to `CHANGELOG.md`.

## 5. Process (CLAUDE.md, release checklist)

- A PR that changes what the drivers do, or what their documentation says,
  adds a line under `## Unreleased` (the PR template asks).
- After a release, the desired-state PR (`deploy/house.yaml`) also runs
  `changelog.py stamp` with the release's version, build and date, so
  `CHANGELOG.md` names the build that was published.
- `tools/check.sh` gains the check `changelog` (`changelog.py check`),
  run by CI's tooling job.
- Before the first build of a new X.Y, its first prerelease included, the
  coordinator picks its codename and reports it, without waiting for
  approval (#396); a pull request then adds it to
  `.github/codenames.json` (#304) and its blurb to
  `.github/codename-notes.json` (#464).

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

# Prereleases for testers

Status: contract, 2026-10-26 (#269). Written before the code. The motion
sensor feature (#268) ships to a tester as a GitHub prerelease. It is the first one, and the
Release workflow, the changelog tool and the deploy tool cannot cut or
install one today.

## 1. Versions and tags

| Kind | Version | Tag | Tag moves? | On GitHub |
| --- | --- | --- | --- | --- |
| Stable | `X.Y` | `vX.Y` | yes, every build of X.Y moves it (as today) | a release, "Latest" |
| Prerelease | `X.Y-beta.N`, N = 1, 2, ... | `vX.Y-beta.N` | **never**: each beta gets a new tag | a prerelease, never "Latest" |

- One pattern everywhere: `^[0-9]+\.[0-9]+(-beta\.[1-9][0-9]*)?$` for versions, and the same with a leading `v` for tags. This covers the workflow, `tools/deploy.py`, `tools/changelog.py`, `deploy/house.yaml` and the drift issue's title.
- A prerelease takes the codename of its major version (1.1-beta.1 is "Cassian").
- Prereleases are built from `main`, by the same two-job Release workflow, with the same checks, attestations and assets as a stable release. `main` is the only source.
- GitHub's `releases/latest` and the README's Download links skip prereleases, so they keep serving the stable release.
- A dispatch whose prerelease tag already exists fails before building anything.

## 2. The packages: one list

The packages are named in one place: the directories `src/<name>/` that hold a `driver.xml`, sorted by name. Today they are `hue_bridge`, `hue_light` and `hue_scene`; #268 adds a fourth.
- `tools/build.sh` builds exactly those (coordinator).
- `build/manifest.json` lists them.
- The Release workflow's checks (the file listing, `SHA256SUMS.txt`, the provenance subjects, the upload) take the list from the manifest, never a literal list. The manifest is itself checked against the `src/*/driver.xml` directories of the commit.
- CI's build job does the same.
- `deploy/house.yaml`'s `drivers:` must equal the release manifest's packages; `tools/deploy.py start` refuses otherwise.

## 3. Notes

- **Stable releases:** unchanged (docs/changelog-design.md). Notes come from `## Unreleased`, and the desired-state PR stamps the entry afterwards.
- **Prereleases:**
  - `tools/changelog.py notes --version X.Y-beta.N ...` fills a separate template, `.github/prerelease-notes.md`, from the same `## Unreleased` entry. That entry is everything since the last stable release, which is what a tester should read.
  - The template says, in this order:
    - that this is a prerelease for testing;
    - which stable release it follows;
    - how to install it: all packages at once through Driver ▸ "Add or Update Driver or Agent…", updating in place, never deleting and re-adding the bridge;
    - how to go back: install the latest stable release's files the same way;
    - how to report: the "Beta feedback" issue form, or the person who sent the link;
    - the verify-a-download block;
    - the license lines.
  - There is no `{history}` (betas are not in `CHANGELOG.md`).
  - An empty `## Unreleased` fails the run, as for a stable release.
- `tools/changelog.py stamp` refuses a prerelease version: `CHANGELOG.md` lists stable releases only, and the stable 1.1 entry later carries everything.
- The release title is `X.Y beta N "Codename" (build B)`.
- `gh release create --prerelease --latest=false`.

## 4. The house

- `deploy/house.yaml` may name a prerelease tag. `tools/deploy.py` accepts it (validate, start, done, record, status).
- The drift issue's title becomes `Deploy vX.Y-beta.N (build B) to the house`. The title matcher (#244) accepts both forms and nothing else.
- The brief says "prerelease" and lists every package of the manifest.
- Going back to stable is an ordinary desired-state PR.

## 5. Feedback

- A new issue form, `.github/ISSUE_TEMPLATE/beta-feedback.yml`, "Beta feedback". It asks for:
  - the prerelease version;
  - the Control4 OS and Composer Pro versions;
  - the bridge model and software;
  - the devices involved, for example sensor models;
  - what was done and what was seen;
  - the relevant Lua output, with addresses and ids replaced.
- A label `beta-feedback` in `.github/labels.json`.
- The owner may also paste feedback that came by other channels.

## 6. Who writes what

| Files | Owner |
| --- | --- |
| `.github/workflows/release.yml`, `.github/workflows/ci.yml` (the build job's package checks only), `.github/workflows/drift.yml`, `tools/deploy.py` and its tests, `tools/changelog.py` and its tests, `.github/prerelease-notes.md`, `.github/ISSUE_TEMPLATE/beta-feedback.yml`, `.github/labels.json`, `docs/release-checklist.md` (a "Prerelease" section), `docs/cicd-gitops-design.md` (section 5), `docs/changelog-design.md` (one paragraph) | agent **prerelease** |
| `tools/build.sh` (derive the package list), `README.md`, `CLAUDE.md`, `docs/README.md`, `CHANGELOG.md`, this file | coordinator |

## 7. Done

- `tools/check.sh` passes.
- The tests cover:
  - the version and tag pattern, both accepted and refused;
  - prerelease notes;
  - a stamp refused for a prerelease;
  - `house.yaml` with a prerelease tag;
  - the drift title matcher;
  - the package list read from a manifest with four packages.
- `actionlint` and `zizmor` are clean.
- Nothing is released by this PR. The first real run is `1.1-beta.1` after #268 merges.

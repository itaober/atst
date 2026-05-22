---
name: atst-release
description: Cut a new GitHub release of the atst macOS app — bumps the version, builds the DMG, tags, pushes, and publishes the release. Use this skill whenever the user asks to "release", "ship", "cut a version", "tag a version", "publish a release", "make a release", "发版", "发布新版本", or asks how the release process works for atst. Covers the full workflow including version-bump conventions, bilingual CHANGELOG editing, the release.sh script's pre-flight checks, and what to do when the script refuses to run.
---

# Releasing atst

This project has a one-shot release script. Your job is to **prepare the inputs** (CHANGELOG entries) and **run the script** — almost everything else is automated.

## The workflow at a glance

```
1. Verify clean state
2. Pick the next version (semver bump)
3. Add a `## vX.Y.Z` section to BOTH CHANGELOG files
4. Commit the CHANGELOG update + push
5. bash Scripts/release.sh vX.Y.Z
6. (Optional) verify the release page renders correctly
```

## Step 1 — Verify clean state

Before doing anything, confirm:

- Working tree is clean (`git status` shows nothing to commit)
- You're on `main`
- `main` is up to date with `origin/main`

The release script will refuse to run on a dirty tree, but catching it now means you don't waste a build cycle.

## Step 2 — Pick the version

Check the latest tag and bump per semver:

```bash
git describe --tags --abbrev=0
```

| Change type | Bump |
|---|---|
| Bug fix / docs / refactor | patch (`v0.1.2` → `v0.1.3`) |
| New feature, backwards-compatible | minor (`v0.1.2` → `v0.2.0`) |
| Breaking change in config / API / UX | major (`v0.1.2` → `v1.0.0`) |

atst is pre-1.0, so users generally tolerate minor-version UX shifts. Don't bump major just because the UI changed.

## Step 3 — Edit CHANGELOG (both files)

Open both files and convert the existing `## Unreleased` heading into a new versioned section, then add a new empty `## Unreleased` at the top.

**Files**:
- `CHANGELOG.md` (English)
- `CHANGELOG.zh-CN.md` (Chinese)

**Rules** (the previous releases set the tone — match them):
- Each bullet describes a **change**, not an install instruction or feature description (install lives in README, not release notes)
- Bullets should be parallel across the two files (same number of bullets, same order, same meaning)
- Keep bullets to one line where possible
- Don't put a date in the header — the GitHub release page already shows it
- Don't put a description / tagline after the version — the section header is exactly `## vX.Y.Z`

**Example pattern** (mirror what's in the existing CHANGELOG):

`CHANGELOG.md`:
```markdown
## Unreleased

(no changes yet)

## v0.1.3

- Specific change one, what it does for users
- Specific change two

## v0.1.2
...
```

`CHANGELOG.zh-CN.md`:
```markdown
## Unreleased

（暂无变更）

## v0.1.3

- 具体变更一，对用户的实际影响
- 具体变更二

## v0.1.2
...
```

The release script reads bullets verbatim out of the `## vX.Y.Z` section in each file — whatever you write here is what appears in the GitHub release notes.

## Step 4 — Commit the CHANGELOG update

Commit and push the CHANGELOG diff on its own (don't mix with feature commits). Suggested message form:

```
chore: changelog for vX.Y.Z
```

Then `git push origin main`.

The reason the CHANGELOG commit happens **before** tagging: the tag will point at this commit, so anyone browsing the tag in GitHub sees the changelog entry as the latest change.

## Step 5 — Run the release script

```bash
bash Scripts/release.sh vX.Y.Z
```

What it does, in order:
1. Validates the version arg (semver shape)
2. Refuses if working tree is dirty, tag exists locally, or either CHANGELOG section is missing/empty
3. Builds the DMG (`Scripts/build-dmg.sh` → `.build/atst.dmg`, ~2 MB)
4. Computes the DMG's SHA-256
5. Creates an annotated git tag `vX.Y.Z` and pushes it to `origin`
6. Creates a GitHub release titled exactly `vX.Y.Z` (no descriptive subtitle), body stitched from both CHANGELOG sections in this structure:
   ```
   ## English
   <bullets from CHANGELOG.md>

   ## 简体中文
   <bullets from CHANGELOG.zh-CN.md>

   ---

   shasum -a 256 atst.dmg
   <hash>  atst.dmg
   ```
7. Attaches `atst.dmg` to the release

On success it prints the release URL.

## Step 6 — (Optional) Verify

Open `https://github.com/itaober/atst/releases/tag/vX.Y.Z` and confirm:
- Title is exactly `vX.Y.Z`
- Both English and Chinese sections render with all bullets
- DMG is attached
- SHA-256 block at the bottom

## When things go wrong

### `Scripts/release.sh` refuses to run

The script prints a clear `✗ ...` message for each failure mode:

| Error | Fix |
|---|---|
| `Working tree is dirty` | `git status`, commit or stash |
| `Tag vX.Y.Z already exists locally` | Either you ran it twice, or you skipped a version. Bump higher: `vX.Y.(Z+1)` |
| `No '## vX.Y.Z' section found in CHANGELOG.md` | Step 3 not done. Add the section, commit it, retry |
| `Version must look like 'v1.2.3'` | You passed something else — must be `v` + 3 numbers |

### You released with the wrong notes

You can edit the release body after the fact without rebuilding the DMG:

```bash
# Edit one of the CHANGELOG files, then:
gh release edit vX.Y.Z --repo itaober/atst --notes-file <(cat <<'EOF'
## English

<corrected bullets>

## 简体中文

<corrected bullets>
EOF
)
```

You can also pass `--title "vX.Y.Z"` if the title got corrupted.

### You need to delete a release entirely

```bash
gh release delete vX.Y.Z --repo itaober/atst --yes
git tag -d vX.Y.Z
git push --delete origin vX.Y.Z
```

Then re-run `Scripts/release.sh` with a clean state. **Don't** reuse the same version number for a "v2" — bump to a fresh patch (`vX.Y.(Z+1)`); reusing tags confuses anyone who already downloaded.

## What NOT to do

- **Don't** put install instructions in release notes — they live in README and would just go stale
- **Don't** add a descriptive subtitle to the release title (e.g. "v0.1.3 — better UX"); the title is version-only by convention. Descriptions belong in CHANGELOG bullets
- **Don't** skip the Chinese CHANGELOG. Both releases so far are bilingual; an English-only release breaks the pattern for Chinese-locale users
- **Don't** tag manually with `git tag` and `gh release create` separately — the script's pre-flight checks exist for good reasons (catching missing CHANGELOG, dirty tree, etc.) and you'll lose that safety net
- **Don't** edit the CHANGELOG inside `Scripts/release.sh` — that script is automation; the source of truth for what gets released is the CHANGELOG files

## Why these conventions

A few of the rules above might feel arbitrary; the reasoning:

- **Version-only titles** keep the release list dense and scannable on GitHub. Subtitle text was tried once (v0.1.0 originally said "— initial release") and immediately felt noisy next to v0.1.1, v0.1.2.
- **Bilingual notes** matter because the user base is ~50/50 CN/EN. Single-language notes alienate half of them.
- **CHANGELOG as source of truth** lets future you (or anyone reviewing a tag) read the same changelog that's on the release page — they're identical by construction, not by manual sync.
- **Ad-hoc codesigning** (in `build-app.sh`) means each release's signature is different. macOS may reset Accessibility permission on user upgrade. Mention this in release notes only if it's a particularly large jump; otherwise it's noise. (Proper Apple Developer ID notarization is on the roadmap.)

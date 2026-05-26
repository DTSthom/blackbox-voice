# Blackbox tag vocabulary

Tags are space- or comma-separated context labels attached to a recording session via the `tags.txt` sidecar (written by `bbsync` at upload time). They land in each transcript's YAML frontmatter and are queryable via `bb tag <pattern>`.

## Structure

The convention is 4-dimensional: every tag should fit one of these prefix buckets. The prefix makes downstream filtering trivial (e.g. `bb tag person:` lists everything mentioning any person).

| Prefix | Count per session | Meaning | Example |
|---|---|---|---|
| `project:` | 0..N | Project slug (your own naming scheme) | `project:apollo`, `project:roof-rebuild` |
| `person:` | 0..N | Kebab-case name | `person:alice-smith`, `person:bob-jones` |
| `activity:` | 0..1 typical | What you were doing | `activity:standup`, `activity:site-walk`, `activity:phone-call`, `activity:lunch` |
| `context:` | 0..1 typical | Day-shape bucket | `context:office`, `context:field`, `context:personal`, `context:travel` |

## Worked examples

| Scenario | Tag string |
|---|---|
| Standup with Alice | `project:apollo, person:alice-smith, activity:standup` |
| Lunch with a friend (personal lean) | `person:bob-jones, activity:lunch, context:personal` |
| Site walk with two people on a specific project | `project:roof-rebuild, person:alice-smith, person:bob-jones, activity:site-walk, context:field` |
| Solo deep-work session | `project:apollo, activity:deep-work, context:office` |
| Drive between sites — recorder running ambient | `context:travel` |

## Rules of thumb

- **Use kebab-case** for multi-word values (`alice-smith`, not `Alice Smith`).
- **Don't repeat the operator** as a `person:` tag — your voice is the assumed default.
- **Context is for filtering, not narrative.** If you want narrative, put it in the daily summary; tags are for `bb tag` queries.
- **Tags are operator-enforced** — no code validation. If you typo a tag, it'll show up under the typo.

## Extending

If a new prefix becomes natural (e.g. `location:` for travel-heavy field work), edit this file and re-pull on each node. The pipeline doesn't enforce the prefix list — it's just a convention to keep `bb tag` queries useful.

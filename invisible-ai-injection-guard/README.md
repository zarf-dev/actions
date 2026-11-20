# invisible-ai-injection-guard

A GitHub Action that detects content in issue and pull request titles, descriptions and comments that is **hidden
from people reading them on GitHub but fully visible to automated tools**, then labels the issue or pull request,
reports the findings and hides offending comments.

The action only flags content. It never closes issues or pull requests: deciding what to do with a flagged item is a
separate responsibility, which you can give to another job or workflow (see
[Close flagged items in a separate job](#close-flagged-items-in-a-separate-job)).

## Why

AI coding agents and assistants read the raw Markdown of issues and pull requests. GitHub's rendered view does not
show HTML comments, invisible Unicode characters, and several other constructs, so an attacker can put
instructions there that maintainers never see but an agent will follow ("prompt injection"). This has been used to
make agents running in CI leak secrets or take unwanted actions.

This action flags that hidden content before an agent (or a person) acts on it.

## What it detects

| Rule                        | Default severity             | What it means                                                                                                                                                                                                                |
| --------------------------- | ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `unicode-tag`               | high                         | Unicode "tag" characters (U+E0000–E007F), which encode invisible ASCII text ("ASCII smuggling"). The decoded text is shown. Emoji subdivision flags are allowed.                                                             |
| `bidi-control`              | high (overrides) / medium    | Bidirectional controls (U+202A–202E, U+2066–2069) that reorder how text is displayed ("Trojan Source").                                                                                                                      |
| `variation-selector`        | high / medium                | Variation selectors that do not modify the preceding character, or runs of them that encode hidden bytes (decoded when possible). A single selector after an emoji or Han character is allowed.                              |
| `invisible-character`       | medium (high for runs of 8+) | Zero-width spaces/joiners, word joiners, Hangul and Braille blank fillers, and other format characters. Emoji ZWJ sequences, joiners inside Arabic/Persian/Indic words, and a leading BOM are allowed. Soft hyphens are low. |
| `html-comment`              | low / medium / high          | `<!-- … -->` comments. Long comments are medium; comments containing text aimed at AI tools are high. Comments that appear in the repository's templates are ignored.                                                        |
| `unterminated-html-comment` | high                         | A line starting with `<!--` that is never closed hides everything after it.                                                                                                                                                  |
| `markdown-comment`          | low / medium / high          | Link-reference "comments" such as `[//]: # (text)` that never render.                                                                                                                                                        |
| `hidden-html`               | medium / high                | Content inside elements GitHub removes (`<script>`, `<style>`, `<template>`, …), or elements with `hidden`, `aria-hidden`, or invisible inline styles.                                                                       |
| `hidden-attribute-text`     | high                         | `alt`, `title`, `aria-label`, `data-*` and Markdown image alt / link titles that contain text aimed at AI tools.                                                                                                             |
| `blank-line-padding`        | medium / high                | Long runs of visually empty lines (`&nbsp;`, `<br>`, fillers) that push content out of view.                                                                                                                                 |
| `directional-mark`          | low                          | LRM/RLM/ALM marks. Common in right-to-left text, so reported as low only.                                                                                                                                                    |

"Text aimed at AI tools" covers phrases such as instruction overrides ("ignore previous instructions"), role
assignment ("you are an AI assistant"), references to system prompts, named AI tools, command execution, secret
exfiltration, concealment ("don't tell the user"), approval requests and chat-template tokens.

Markup inside fenced code blocks and inline code is rendered literally (it is visible), so it is not reported.
Invisible Unicode is reported everywhere.

## Usage

```yaml
on:
  issues:
    types: [opened, edited, reopened]
  pull_request_target:
    types: [opened, edited, reopened]
  issue_comment: # comments on issues and pull requests
    types: [created, edited]
  pull_request_review_comment: # inline review comments
    types: [created, edited]
  pull_request_review: # review bodies
    types: [submitted, edited]

permissions: {}

jobs:
  scan:
    runs-on: ubuntu-latest
    permissions:
      contents: read # read issue/PR templates
      issues: write # labels, comments, hiding issue comments
      pull-requests: write # labels, comments, hiding review comments
    steps:
      - uses: zarf-dev/actions/invisible-ai-injection-guard@<commit-sha>
```

By default this adds the `suspicious-hidden-content` label and posts a comment listing the findings. The comment
is updated in place when the description is edited, and when a later edit is clean the label is removed and the
comment is marked as resolved.

Drop any events you do not want to scan.

### Comments

When a comment (issue comment, pull request conversation comment, inline review comment or review body) contains
hidden content, the action:

- **hides the comment** (minimizes it as spam; set `hide-comment: false` to disable, or `hide-comment-reason` to
  pick another reason). Review bodies cannot be hidden through the API, so they are only reported.
- **adds the label** to the issue or pull request the comment belongs to (`add-label`).
- **posts a report** that links to the comment, without mentioning its author (`comment`).

If the comment is later edited to remove the hidden content, its report is marked as resolved. The label stays
(the item may have been labeled for other reasons) and the comment stays hidden until a maintainer unhides it.

### Label only, with a custom label

```yaml
- uses: zarf-dev/actions/invisible-ai-injection-guard@<commit-sha>
  with:
    label: prompt-injection
    comment: false
```

### Trusted bots

Some bots write hidden markers into their own text, for example Dependabot's
`[//]: # (dependabot-automerge-start)`. In the release notes it copies, Dependabot also puts a zero-width space
after `@` (`@\u{200B}user`) so the upstream authors are not notified, and replaces raw HTML it strips with
`<!-- raw HTML omitted -->`. List these bots in `trusted-bots` to allow all of these:

```yaml
- uses: zarf-dev/actions/invisible-ai-injection-guard@<commit-sha>
  with:
    trusted-bots: |
      - dependabot[bot]
```

GitHub only passes strings to actions, so a YAML list (`trusted-bots: [a, b]`) is rejected by the workflow parser.
Write the list as a block string instead, one item per line, with or without a leading `- `. The same format
works for `exempt-users`.

A trusted bot is **not** exempt from scanning:

- Only that bot's known markers are allowed, matched by narrow patterns. A mention break is allowed only as a single
  zero-width space between `@` and a letter or digit. Anything else hidden in its text is still
  reported. This matters because Dependabot copies release notes and changelogs from the dependency into the pull
  request, so a malicious or compromised package can hide instructions there.
- The author must be a GitHub App account (`Bot` type with a login ending in `[bot]`). User names cannot contain
  brackets, so nobody can register `dependabot[bot]`, and the login comes from GitHub, not from the text.
- The bot must also be the account that triggered the event. If someone else edits the bot's text, the markers are
  reported like any other hidden content.

Supported bots: `dependabot[bot]`.

### Close flagged items in a separate job

Closing is not part of this action. To close flagged items automatically, add a second job that runs
[close-on-labels](../close-on-labels/README.md) after the scan, so the decision to close lives in
your workflow, where you can see and change it:

```yaml
jobs:
  scan:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      issues: write
      pull-requests: write
    outputs:
      detected: ${{ steps.guard.outputs.detected }}
    steps:
      - id: guard
        uses: zarf-dev/actions/invisible-ai-injection-guard@<commit-sha>

  close:
    needs: scan
    # Close only when the description is flagged, not when a comment is: otherwise anyone who can comment could
    # close any open item.
    if: needs.scan.outputs.detected == 'true' && (github.event_name == 'issues' || github.event_name == 'pull_request_target')
    runs-on: ubuntu-latest
    permissions:
      contents: read
      issues: write
      pull-requests: write
    steps:
      - uses: zarf-dev/actions/close-on-labels@<commit-sha>
        with:
          or: suspicious-hidden-content
          number: ${{ github.event.issue.number || github.event.pull_request.number }}
          comment: 'Closing because this was labeled {{matched}}.'
```

close-on-labels reads the labels from the API when it runs, so it closes the item only if the label was actually
applied.

GitHub has no token permission that allows labeling but not closing: `issues: write` and `pull-requests: write`
cover both. Removing closing from the action means it has no code path that closes anything, but the token you give
it could still be used to close items, so keep granting only the permissions listed above.

A workflow triggered by the `labeled` event does not work with the default token: GitHub does not start new
workflow runs for events caused by `GITHUB_TOKEN`. Use the job above, or have this action label with a GitHub App
token if you prefer a separate label-driven workflow.

### Gate an AI agent on the result

```yaml
jobs:
  scan:
    runs-on: ubuntu-latest
    outputs:
      detected: ${{ steps.guard.outputs.detected }}
    steps:
      - id: guard
        uses: zarf-dev/actions/invisible-ai-injection-guard@<commit-sha>

  agent:
    needs: scan
    permissions: {}
    if: needs.scan.outputs.detected == 'false'
    runs-on: ubuntu-latest
    steps:
      - run: echo "Safe to hand the description to an AI agent"
```

## Inputs

| Name                         | Default                                      | Description                                                                                                       |
| ---------------------------- | -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `token`                      | `${{ github.token }}`                        | Token used to read templates, label items, and post or hide comments.                                             |
| `add-label`                  | `true`                                       | Add a label when hidden content is detected.                                                                      |
| `label`                      | `suspicious-hidden-content`                  | Label name. Created if it does not exist.                                                                         |
| `label-color`                | `b60205`                                     | Hex color used when creating the label.                                                                           |
| `label-description`          | `Contains content hidden from human readers` | Description used when creating the label.                                                                         |
| `hide-comment`               | `true`                                       | Hide (minimize) comments that contain hidden content.                                                             |
| `hide-comment-reason`        | `spam`                                       | Reason shown on hidden comments: `spam`, `abuse`, `off-topic`, `outdated`, `duplicate` or `resolved`.             |
| `comment`                    | `true`                                       | Post (and keep updated) a comment that lists the findings.                                                        |
| `show-evidence`              | `true`                                       | Include short, escaped excerpts of the hidden content in the comment.                                             |
| `remove-label-when-clean`    | `true`                                       | Remove the label after a clean edit.                                                                              |
| `min-severity`               | `medium`                                     | Lowest severity that triggers actions: `low`, `medium` or `high`.                                                 |
| `ignore-template-comments`   | `true`                                       | Ignore comments that also appear in the repository's (or the owner's `.github` repository's) issue/PR templates.  |
| `max-blank-lines`            | `30`                                         | Visually empty lines allowed before following content is reported as padding.                                     |
| `max-comment-length`         | `200`                                        | HTML comments longer than this are medium instead of low severity.                                                |
| `trusted-bots`               | _(empty)_                                    | Bots whose own markers are allowed, one per line; their text is still scanned. See [Trusted bots](#trusted-bots). |
| `exempt-users`               | _(empty)_                                    | Logins that are not scanned, one per line. Edits by anyone else are still scanned.                                |
| `exempt-author-associations` | _(empty)_                                    | Author associations that are not scanned, for example `OWNER,MEMBER`. Edits by anyone else are still scanned.     |
| `fail-on-detection`          | `false`                                      | Fail the step when hidden content is detected.                                                                    |

## Outputs

| Name           | Description                                                                                   |
| -------------- | --------------------------------------------------------------------------------------------- |
| `detected`     | `true` if at least one finding meets `min-severity`, otherwise `false`.                       |
| `count`        | Number of findings at or above `min-severity`.                                                |
| `max-severity` | `low`, `medium`, `high`, or `none`.                                                           |
| `findings`     | JSON array of findings: `rule`, `severity`, `message`, `field`, `line`, `column`, `evidence`. |

Findings are also written as workflow annotations and to the job summary.

## Security notes

- **Use `pull_request_target` for pull requests.** Under `pull_request`, pull requests from forks receive a
  read-only token, so labeling and commenting fail. This action never checks out or runs code from the
  pull request, so it is safe to run under `pull_request_target`. Do not add a step that checks out the pull
  request's head in the same job.
- **Evidence is never echoed verbatim.** The report comment describes findings by rule, code point and location.
  Excerpts are escaped (invisible characters are shown as `\u{…}`) and truncated, so the comment cannot itself
  smuggle the payload. Set `show-evidence: false` to omit excerpts entirely.
- **Exemptions are opt-in.** Nothing is exempt by default, because trusted accounts can be compromised and
  descriptions can be pasted from untrusted sources. An exemption only applies when the author triggered the event,
  so text edited by someone else is always scanned. Prefer `trusted-bots` over `exempt-users` for bots.
- **Detection is not prevention.** Treat issue and pull request text as untrusted input in any workflow that gives
  an AI agent access to secrets or write permissions, whether or not this action reports anything.

## Failure modes

The step fails, so the problem is visible in the checks, when:

- the workflow runs on an event the action does not support (see [Usage](#usage) for the list), or the event payload
  has no issue, pull request or comment;
- a GitHub API call that applies the result fails (labeling, posting the report, hiding a comment). The error says
  which call failed and which permissions to grant. Outputs are still set, so later jobs can use them;
- an input is invalid;
- `fail-on-detection` is `true` and hidden content is found.

Event actions that do not add or change text (for example `labeled` or `deleted`) are skipped without failing. If the
repository's templates cannot be read, the run continues and reports comments that come from the templates too.

## Limitations

- Titles, descriptions, comments, review comments and review bodies are scanned. Commit messages, file contents and
  discussions are not.
- Pull request reviews and review comments on pull requests **from forks** run with a read-only token (GitHub has
  no `_target` variant for these events), so the action reports findings in the log, summary and outputs but cannot
  label, comment on or hide them. Comments in the pull request conversation (`issue_comment`) are not affected.
- Heuristics for "text aimed at AI tools" are English-only and can be evaded by a determined attacker. Content that
  is hidden is still reported at its base severity regardless of wording.
- Visible text is not analyzed; a prompt injection written in plain sight is out of scope.
- GitHub limits a step to 10 warning annotations; all findings are still in the comment, summary and outputs.

## Testing

The action is written in TypeScript and bundled into `dist/index.js` with esbuild. From this directory:

```bash
npm ci
npm run all       # format check, lint, typecheck, unit tests with coverage, build, end-to-end tests
npm test          # unit tests only
npm run test:e2e  # build, then run dist/index.js against every example in e2e/cases/
```

The tests need Node.js 24 and no network access or credentials.

### End-to-end examples

[`e2e/cases/`](e2e/cases) holds one Markdown file per scenario: front matter that describes the event, inputs and
expected outputs, followed by the issue, pull request or comment body. The end-to-end suite builds the action and
runs the bundled `dist/index.js` as a separate Node.js process for each file, with a fake GitHub event and no
network access, then checks the exit code, outputs and annotations.

```markdown
---
event: issue_comment # issues, pull_request(_target), issue_comment, pull_request_review(_comment)
title: Optional title
input-min-severity: low # any action input, as input-<name>
expect-detected: true
expect-max-severity: high
expect-rules: html-comment, unicode-tag
expect-no-rules: bidi-control
---

Body text with <!-- a hidden comment --> and {TAG:smuggled text}.
```

Invisible characters are written with an escape notation so that example files stay readable and reviewable:
`{U+200B}` (or `{U+200B*20}` to repeat), `{TAG:text}` for Unicode tag smuggling, `{VS:text}` for variation-selector
smuggling, and `{NL*40}` for repeated newlines. See the [`e2e/run.ts`](e2e/run.ts) header for the full list of keys.

`dist/index.js` is the bundled action and must be committed. Run `npm run build` after changing `src/` or the
dependencies; CI fails if `dist/` is out of date.

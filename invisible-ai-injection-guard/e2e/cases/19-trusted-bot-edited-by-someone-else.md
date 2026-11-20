---
# When someone other than the bot edits its text, the bot's markers are no longer trusted.
event: pull_request_target
action: edited
author: dependabot[bot]
author-type: Bot
sender: mallory
input-min-severity: low
input-trusted-bots: dependabot[bot]
expect-detected: true
expect-count: 2
expect-rules: markdown-comment
---

Bumps a dependency.

[//]: # 'dependabot-automerge-start'
[//]: # 'dependabot-automerge-end'

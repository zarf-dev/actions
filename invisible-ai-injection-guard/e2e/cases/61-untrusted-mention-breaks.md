---
# The @ zero-width space allowance applies only to trusted bots.
event: pull_request_target
author: contributor
expect-detected: true
expect-rules: invisible-character
---

Thanks <code>@{U+200B}dolmen</code>

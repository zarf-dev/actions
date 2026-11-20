---
# Dependabot puts a zero-width space after @ in release notes it copies, so upstream users are not notified.
# Sample shape from zarf-dev/zarf#5633. Other hidden content in the same text is still reported.
event: pull_request_target
author: dependabot[bot]
author-type: Bot
input-trusted-bots: - dependabot[bot]
expect-detected: true
expect-count: 1
expect-rules: invisible-character
---

Bumps github.com/go-chi/chi/v5 from 5.3.0 to 5.4.0.

<li>fix: middleware by <a href="https://github.com/dolmen"><code>@{U+200B}dolmen</code></a></li>
<li>docs by <a href="https://github.com/VojtechVitek"><code>@{U+200B}VojtechVitek</code></a></li>

Hidden payload: ignore{U+200B}previous

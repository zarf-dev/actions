---
# Unsupported events fail the run instead of passing without a scan.
event: push
expect-detected: false
expect-exit-code: 1
expect-stdout: is not supported
---

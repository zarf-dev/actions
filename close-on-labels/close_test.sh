#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026-Present The Zarf Authors
#
# Tests close.sh against canned GitHub API responses by placing a fake `gh` first on PATH.
# Requires bash, jq and yq (mikefarah v4). Run: close-on-labels/close_test.sh

# Expected messages contain literal backticks, so single quotes are intended.
# shellcheck disable=SC2016

set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The fake gh records every call. `gh api repos/<repo>/issues/<n>` prints $FAKE_GH_ITEM, a contents request prints
# $FAKE_GH_CONTENT (or fails with 404 when it is unset), and any call whose arguments contain $FAKE_GH_FAIL_ON fails.
mkdir "$work/bin" "$work/ws"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_CALLS"
if [ -n "${FAKE_GH_FAIL_ON:-}" ] && [[ "$*" == *"$FAKE_GH_FAIL_ON"* ]]; then
  echo "HTTP 500: fake failure" >&2
  exit 1
fi
case "$*" in
  *"/contents/"*)
    if [ -n "${FAKE_GH_CONTENT:-}" ]; then cat "$FAKE_GH_CONTENT"; else echo "Not Found (HTTP 404)" >&2; exit 1; fi ;;
  "api repos/zarf-dev/zarf/issues/"+([0-9]))
    cat "$FAKE_GH_ITEM" ;;
esac
EOF
# The +([0-9]) pattern needs extglob in the fake.
sed -i.bak '2i\
shopt -s extglob' "$work/bin/gh" && rm "$work/bin/gh.bak"
chmod +x "$work/bin/gh"

# item <state> <issue|pr> [label...] writes the item the fake gh returns.
item() {
  local state=$1 kind=$2
  shift 2
  jq -n --arg state "$state" --arg kind "$kind" '{
    state: $state,
    labels: [$ARGS.positional[] | {name: .}]
  } + (if $kind == "pr" then {pull_request: {url: "x"}} else {} end)' --args "$@" > "$work/item.json"
}

# rules <yaml> writes the rules file into the fake workspace.
rules() {
  printf '%s\n' "$1" > "$work/ws/rules.yaml"
}

# rule <keys> writes a single rule with ID close from YAML flow-mapping entries.
rule() {
  rules "rules: [{id: close, $1}]"
}

failures=0
passed=0
failed=0
test_name=""
test_failures=0

# report prints one line for the test that just finished.
report() {
  [ -n "$test_name" ] || return 0
  if [ "$test_failures" -eq 0 ]; then
    echo "[PASS] $test_name"
    passed=$((passed + 1))
  else
    echo "[FAIL] $test_name"
    failed=$((failed + 1))
  fi
}

# begin <name> finishes the previous test and starts a new one.
begin() {
  report
  test_name=$1
  test_failures=0
}
output=""
status=0

# run_close [VAR=value...] runs close.sh with defaults that the overrides can replace.
run_close() {
  : > "$work/calls"
  : > "$work/out"
  output=$(env \
    PATH="$work/bin:$PATH" \
    FAKE_GH_ITEM="$work/item.json" \
    FAKE_GH_CALLS="$work/calls" \
    GH_TOKEN=test-token \
    REPO=zarf-dev/zarf \
    SHA=0123456789abcdef \
    WORKSPACE="$work/ws" \
    EVENT_NAME=issues \
    EVENT_NUMBER=7 \
    GITHUB_OUTPUT="$work/out" \
    INPUT_RULES_FILE=rules.yaml \
    INPUT_TARGET=all \
    INPUT_COMMENT= \
    INPUT_CLOSE_REASON=not_planned \
    INPUT_LOCK=false \
    INPUT_DRY_RUN=false \
    INPUT_NUMBER= \
    "$@" \
    "$script_dir/close.sh" 2>&1)
  status=$?
}

fail() {
  failures=$((failures + 1))
  test_failures=$((test_failures + 1))
  echo "FAIL: $test_name: $1"
  printf '    %s\n' "${output//$'\n'/$'\n    '}"
}

expect_status() {
  [ "$status" -eq "$1" ] || fail "expected exit $1, got $status"
}

expect_output() {
  [[ "$output" == *"$1"* ]] || fail "expected output to contain: $1"
}

expect_no_output() {
  [[ "$output" != *"$1"* ]] || fail "expected output not to contain: $1"
}

# output_value <name> reads a value written in the GITHUB_OUTPUT heredoc format.
output_value() {
  awk -v name="$1" '
    $0 ~ "^" name "<<" { delim = substr($0, length(name) + 3); reading = 1; next }
    reading && $0 == delim { exit }
    reading { print }
  ' "$work/out"
}

expect_out() {
  local actual
  actual=$(output_value "$1")
  [ "$actual" = "$2" ] || fail "expected output $1 to be '$2', got '$actual'"
}

# expect_result <result> <closed> <matched-rule> <matched-labels>
expect_result() {
  expect_out result "$1"
  expect_out closed "$2"
  expect_out matched-rule "$3"
  expect_out matched-labels "$4"
  expect_out number "${5:-7}"
}

expect_call() {
  grep -qF -- "$1" "$work/calls" || fail "expected a gh call containing: $1"
}

expect_no_call() {
  ! grep -qF -- "$1" "$work/calls" || fail "expected no gh call containing: $1"
}

# Write calls are the ones that change state: comment, close, lock.
write_calls() {
  grep -cE -- '/comments|-X PATCH|-X PUT' "$work/calls" || true
}

expect_no_writes() {
  [ "$(write_calls)" -eq 0 ] \
    || fail "expected no write calls, got: $(grep -E -- '/comments|-X PATCH|-X PUT' "$work/calls")"
}

expect_gh_calls() {
  local calls
  calls=$(wc -l < "$work/calls" | tr -d ' ')
  [ "$calls" -eq "$1" ] || fail "expected $1 gh calls, got $calls"
}

# --- label matching ---------------------------------------------------------------------------------------------

begin "any-labels: one label present closes the issue"
rule 'any-labels: "wontfix, invalid"'
item open issue bug wontfix
run_close
expect_status 0
expect_result closed true close wontfix
expect_call "-X PATCH repos/zarf-dev/zarf/issues/7 -f state=closed -f state_reason=not_planned"
expect_no_call "/comments"
expect_no_call "/lock"

begin "any-labels: no label present leaves the issue open"
rule 'any-labels: "wontfix, invalid"'
item open issue bug
run_close
expect_status 0
expect_result none false "" ""
expect_no_writes
expect_output 'does not apply, none of "wontfix", "invalid" is present.'
expect_output "No rule applies. Issue #7 stays open."

begin "all-labels: one label missing leaves the issue open"
rule 'all-labels: "duplicate\nhas-replacement"'
item open issue duplicate
run_close
expect_status 0
expect_result none false "" ""
expect_no_writes
expect_output 'missing "has-replacement"'

begin "all-labels: all labels present closes the issue"
rule 'all-labels: "duplicate\nhas-replacement"'
item open issue has-replacement duplicate
run_close INPUT_CLOSE_REASON=Completed
expect_status 0
expect_result closed true close has-replacement,duplicate
expect_call "state_reason=completed"

begin "any-labels + all-labels: both must hold"
rule 'any-labels: [a, b], all-labels: [c, d]'
item open issue a c
run_close
expect_result none false "" ""
item open issue b c d
run_close
expect_result closed true close b,c,d

begin "not-labels inside a close rule blocks that rule"
rule 'any-labels: [wontfix], not-labels: [keep-open]'
item open issue wontfix keep-open
run_close
expect_status 0
expect_result none false "" ""
expect_no_writes
expect_output 'does not apply, has "keep-open".'

begin "not-labels inside a close rule does not block when absent"
rule 'any-labels: [wontfix], not-labels: [keep-open]'
item open issue wontfix
run_close
expect_result closed true close wontfix

begin "labels match case-insensitively and keep the item's casing"
rule 'any-labels: [wontfix]'
item open issue "WontFix"
run_close
expect_result closed true close WontFix

begin "labels with spaces and punctuation"
rule 'all-labels: ["good first issue", "kind/bug", "priority: high", "a (b)"]'
item open issue "good first issue" "kind/bug" "priority: high" "a (b)"
run_close
expect_result closed true close "good first issue,kind/bug,priority: high,a (b)"

# --- order ------------------------------------------------------------------------------------------------------

rules '
rules: # checked in order, the first rule that applies decides
  - id: keep
    not-labels: [keep-open]
  - id: close if one
    any-labels: [wontfix, invalid, duplicate]
  - id: close if all
    all-labels: [duplicate, has-replacement]'

begin "order: wontfix is closed by the first close rule"
item open issue wontfix
run_close INPUT_RULES_FILE=rules.yaml
expect_status 0
expect_result closed true "close if one" wontfix
expect_output 'Rule "keep" (index: 1): does not apply, none of "keep-open" is present.'
expect_output 'Rule "close if one" (index: 2): applies ("wontfix").'
expect_output "The 1 rule(s) after it were not checked."
expect_no_output 'Rule "close if all"'

begin "order: keep rule first keeps the item open and stops"
item open issue wontfix keep-open
run_close INPUT_RULES_FILE=rules.yaml
expect_status 0
expect_result kept false keep keep-open
expect_no_writes
expect_output 'Rule "keep" (index: 1): applies (has "keep-open"), keeping the item open.'
expect_output "The 2 rule(s) after it were not checked."
expect_no_output 'Rule "close if one"'

begin "order: the earlier of two matching close rules wins"
item open issue duplicate has-replacement
run_close INPUT_RULES_FILE=rules.yaml
expect_result closed true "close if one" duplicate

begin "order: nothing applies"
item open issue has-replacement
run_close INPUT_RULES_FILE=rules.yaml
expect_result none false "" ""
expect_no_writes
expect_output 'Rule "close if all" (index: 3): does not apply, missing "duplicate".'

begin "order: the same rules with keep last close the item and warn"
rules '
rules:
  - id: close if one
    any-labels: [wontfix, invalid, duplicate]
  - id: close if all
    all-labels: [duplicate, has-replacement]
  - id: keep
    not-labels: [keep-open]'
item open issue wontfix keep-open
run_close INPUT_RULES_FILE=rules.yaml
expect_status 0
expect_result closed true "close if one" wontfix
expect_output '::warning title=close-on-labels::Rule "keep" (index: 3) only has `not-labels` and comes after every rule that can close'

begin "removed inline inputs cannot add a close rule before file rules"
rule 'any-labels: [other]'
item open issue wontfix
run_close INPUT_RULES_FILE=rules.yaml INPUT_OR=wontfix
expect_status 0
expect_result none false "" ""
expect_no_writes

begin "removed inline not input cannot override a file rule"
rule 'any-labels: [wontfix]'
item open issue wontfix keep-open
run_close INPUT_RULES_FILE=rules.yaml INPUT_NOT=keep-open
expect_status 0
expect_result closed true close wontfix

# --- target -----------------------------------------------------------------------------------------------------

begin "target: a close rule for prs skips an issue"
rule 'any-labels: [wontfix]'
item open issue wontfix
run_close INPUT_TARGET=prs
expect_result none false "" ""
expect_output 'Rule "close" (index: 1): skipped, it only applies to pull requests.'

begin "target: a close rule for issues skips a pull request"
rule 'any-labels: [wontfix]'
item open pr wontfix
run_close INPUT_TARGET=issues
expect_result none false "" ""

begin "target: a keep rule for prs does not protect an issue"
rules '
rules:
  - id: keep prs
    not-labels: [keep-open]
    target: prs
  - id: close
    any-labels: [wontfix]'
item open issue wontfix keep-open
run_close INPUT_RULES_FILE=rules.yaml
expect_result closed true close wontfix

begin "target: the same keep rule protects a pull request"
item open pr wontfix keep-open
run_close INPUT_RULES_FILE=rules.yaml
expect_result kept false "keep prs" keep-open

# --- pull requests, comment, lock -------------------------------------------------------------------------------

begin "pull request is closed without a state reason"
rule 'any-labels: [wontfix]'
item open pr wontfix
run_close
expect_result closed true close wontfix
expect_call "-X PATCH repos/zarf-dev/zarf/issues/7 -f state=closed"
expect_no_call "state_reason"
expect_output "Closed pull request #7."

begin "comment, close and lock happen in that order"
rule 'any-labels: [wontfix, invalid]'
item open issue invalid wontfix
run_close INPUT_LOCK=TRUE \
  INPUT_COMMENT='Closed by {{rule}}: {{matched}}. ({{rule}})'
expect_status 0
expect_result closed true close invalid,wontfix
order=$(grep -oE '/comments|-X PATCH|-X PUT' "$work/calls" | tr '\n' ' ')
[ "$order" = "/comments -X PATCH -X PUT " ] || fail "expected comment, close, lock; got: $order"
expect_call 'body=Closed by close: `invalid`, `wontfix`. (close)'
expect_call "-X PUT repos/zarf-dev/zarf/issues/7/lock"

begin "placeholders are replaced once, not inside label or rule IDs"
rules '
rules:
  - id: "{{matched}}"
    any-labels: ["{{rule}}"]
    comment: "{{rule}} / {{matched}}"'
item open issue "{{rule}}"
run_close INPUT_RULES_FILE=rules.yaml
expect_call 'body={{matched}} / `{{rule}}`'

begin "file rules take input defaults and can override them"
rules '
rules:
  - id: defaults
    any-labels: [a]
  - id: overrides
    any-labels: [b]
    reason: completed
    comment: ""
    lock: false'
item open issue a
run_close INPUT_RULES_FILE=rules.yaml INPUT_COMMENT="default {{rule}}" INPUT_LOCK=true
expect_call "body=default defaults"
expect_call "state_reason=not_planned"
expect_call "/lock"
item open issue b
run_close INPUT_RULES_FILE=rules.yaml INPUT_COMMENT="default {{rule}}" INPUT_LOCK=true
expect_result closed true overrides b
expect_no_call "/comments"
expect_no_call "/lock"
expect_call "state_reason=completed"

begin "rule lists may be comma separated strings"
rules '
rules:
  - id: csv
    any-labels: "wontfix, invalid"
    not-labels: keep-open'
item open issue invalid
run_close INPUT_RULES_FILE=rules.yaml
expect_result closed true csv invalid

# --- dry run, closed items, numbers -----------------------------------------------------------------------------

begin "dry-run reports the match without changing anything"
rule 'any-labels: [wontfix]'
item open issue wontfix
run_close INPUT_DRY_RUN=true INPUT_COMMENT=bye INPUT_LOCK=true
expect_status 0
expect_result would-close false close wontfix
expect_no_writes
expect_output "Dry run: Issue #7 would be closed. Nothing was changed."

begin "dry-run with a keep rule reports kept"
rules '
rules:
  - id: keep
    not-labels: [keep-open]
  - id: close
    any-labels: [wontfix]'
item open issue keep-open wontfix
run_close INPUT_RULES_FILE=rules.yaml INPUT_DRY_RUN=true
expect_result kept false keep keep-open

begin "an item that is already closed is skipped"
rule 'any-labels: [wontfix]'
item closed issue wontfix
run_close
expect_status 0
expect_result none false "" ""
expect_no_writes
expect_output "Issue #7 is closed. Nothing to do."

begin "number input overrides the event"
rule 'any-labels: [wontfix]'
item open issue wontfix
run_close INPUT_NUMBER=" 42 "
expect_result closed true close wontfix 42
expect_call "api repos/zarf-dev/zarf/issues/42"

# --- rules file location ----------------------------------------------------------------------------------------

begin "rules file is read from the workspace with a ./ prefix"
rules '
rules:
  - id: local
    any-labels: [wontfix]'
item open issue wontfix
run_close INPUT_RULES_FILE=./rules.yaml
expect_result closed true local wontfix
expect_no_call "/contents/"

begin "rules file missing from the workspace is fetched from the repository"
printf 'rules:\n  - id: remote\n    any-labels: [wontfix]\n' > "$work/remote.yaml"
item open issue wontfix
run_close INPUT_RULES_FILE=.github/close-rules.yaml FAKE_GH_CONTENT="$work/remote.yaml"
expect_status 0
expect_result closed true remote wontfix
expect_call "repos/zarf-dev/zarf/contents/.github/close-rules.yaml?ref=0123456789abcdef"

begin "rules file missing everywhere fails"
run_close INPUT_RULES_FILE=.github/missing.yaml
expect_status 1
expect_output "Could not read rules-file '.github/missing.yaml'. It is not in the workspace"
expect_output "Not Found (HTTP 404)"
expect_no_writes

# --- validation (no item is read and nothing changes) -----------------------------------------------------------

# invalid_rules <name> <yaml> <expected error>
invalid_rules() {
  begin "invalid rules: $1"
  rules "$2"
  item open issue wontfix
  run_close INPUT_RULES_FILE=rules.yaml
  expect_status 1
  expect_output "$3"
  expect_output "The rules are invalid. Fix the errors above."
  expect_gh_calls 0
}

invalid_rules "missing rules list" 'other: 1' 'rules.yaml: expected a non-empty `rules` list.'
invalid_rules "empty rules list" 'rules: []' 'rules.yaml: expected a non-empty `rules` list.'
invalid_rules "empty file" '' 'rules.yaml: expected a non-empty `rules` list.'
invalid_rules "rule is not a mapping" $'rules:\n  - wontfix' \
  'rules.yaml: Rule (index: 1) must be a mapping'
invalid_rules "unknown key" $'rules:\n  - id: x\n    any-labels: [a]\n    labels: [b]' \
  'rules.yaml: Rule "x" (index: 1) has unknown key(s): labels.'
invalid_rules "legacy name key" $'rules:\n  - id: x\n    name: old\n    any-labels: [a]' \
  'rules.yaml: Rule "x" (index: 1) has unknown key(s): name.'
for legacy_key in or and not or-labels and-labels; do
  invalid_rules "legacy label key $legacy_key" "rules: [{id: legacy, $legacy_key: [wontfix]}]" \
    "rules.yaml: Rule \"legacy\" (index: 1) has unknown key(s): $legacy_key."
  expect_output 'Allowed: id, any-labels, all-labels, not-labels, target, reason, comment, lock.'

  invalid_rules "mixed legacy label key $legacy_key" \
    "rules: [{id: legacy, any-labels: [wontfix], $legacy_key: [keep-open]}]" \
    "rules.yaml: Rule \"legacy\" (index: 1) has unknown key(s): $legacy_key."
  expect_output 'Allowed: id, any-labels, all-labels, not-labels, target, reason, comment, lock.'
done
invalid_rules "no label conditions" $'rules:\n  - id: x' \
  'rules.yaml: Rule "x" (index: 1) needs `any-labels`, `all-labels` or `not-labels`.'
invalid_rules "empty list" $'rules:\n  - id: x\n    any-labels: []' 'rules.yaml: Rule "x" (index: 1): `any-labels` is empty.'
invalid_rules "list of mappings" $'rules:\n  - id: x\n    any-labels: [{a: 1}]' \
  'rules.yaml: Rule "x" (index: 1): `any-labels` must be a list of labels.'
invalid_rules "missing ID" $'rules:\n  - any-labels: [a]' \
  'rules.yaml: Rule (index: 1): `id` is required. Add a unique, non-empty string ID.'
invalid_rules "missing ID after a matching rule" $'rules:\n  - {id: first, any-labels: [wontfix]}\n  - any-labels: [b]' \
  'rules.yaml: Rule (index: 2): `id` is required.'
invalid_rules "empty ID" $'rules:\n  - id: ""\n    any-labels: [a]' 'rules.yaml: Rule (index: 1): `id` is empty.'
invalid_rules "whitespace ID" $'rules:\n  - id: " "\n    any-labels: [a]' 'rules.yaml: Rule (index: 1): `id` is empty.'
for invalid_id in null 123 true '[a]' '{a: 1}'; do
  invalid_rules "ID is $invalid_id" "rules: [{id: $invalid_id, any-labels: [a]}]" \
    'rules.yaml: Rule (index: 1): `id` must be a non-empty string.'
done
invalid_rules "duplicate IDs" $'rules:\n  - {id: x, any-labels: [a]}\n  - {id: x, any-labels: [b]}' \
  'Duplicate rule ID "x" at rules.yaml (index: 1), rules.yaml (index: 2). Rule IDs must be unique.'
invalid_rules "duplicate IDs after trimming" $'rules:\n  - {id: " x ", any-labels: [a]}\n  - {id: x, any-labels: [b]}' \
  'Duplicate rule ID "x" at rules.yaml (index: 1), rules.yaml (index: 2).'
invalid_rules "bad target" $'rules:\n  - id: x\n    any-labels: [a]\n    target: both' \
  'rules.yaml: Rule "x" (index: 1): `target` must be one of issues, prs, all (got "both").'
invalid_rules "bad reason" $'rules:\n  - id: x\n    any-labels: [a]\n    reason: spam' \
  'rules.yaml: Rule "x" (index: 1): `reason` must be one of completed, not_planned (got "spam").'
invalid_rules "comment not a string" $'rules:\n  - id: x\n    any-labels: [a]\n    comment: [x]' \
  'rules.yaml: Rule "x" (index: 1): `comment` must be a string.'
invalid_rules "lock not a boolean" $'rules:\n  - id: x\n    any-labels: [a]\n    lock: "yes"' \
  'rules.yaml: Rule "x" (index: 1): `lock` must be true or false (got "yes").'
invalid_rules "comment on a keep rule" $'rules:\n  - id: keep\n    not-labels: [a]\n    comment: x\n  - id: close\n    any-labels: [b]' \
  'rules.yaml: Rule "keep" (index: 1): `comment` only applies to rules with `any-labels` or `all-labels`.'
invalid_rules "only keep rules" $'rules:\n  - id: keep\n    not-labels: [keep-open]' 'No rule can close anything.'

begin "the former inline ID is available to file rules"
rules 'rules: [{id: inline, any-labels: [wontfix]}]'
item open issue wontfix
run_close INPUT_RULES_FILE=rules.yaml
expect_status 0
expect_result closed true inline wontfix
expect_output 'Rule "inline" (index: 1): applies'

begin "rule IDs are trimmed for logs, outputs and comments"
rules 'rules: [{id: " rejected ", any-labels: [wontfix], comment: "Closed by {{rule}}"}]'
run_close INPUT_RULES_FILE=rules.yaml
expect_status 0
expect_result closed true rejected wontfix
expect_output 'Rule "rejected" (index: 1): applies'
expect_call 'body=Closed by rejected'

begin "invalid rules: invalid YAML"
rules 'rules: ['
run_close INPUT_RULES_FILE=rules.yaml
expect_status 1
expect_output "rules.yaml: invalid YAML:"
[[ "$output" == *"line 2"* || "$output" == *"L2.C1"* ]] || fail "expected YAML error to identify line 2"
expect_no_output "$work"
expect_gh_calls 0

for path in "" " " ./; do
  begin "invalid inputs: rules-file '$path' has no path"
  run_close INPUT_RULES_FILE="$path"
  expect_status 1
  expect_output "rules-file is required. Set it to the path of a YAML file with a non-empty rules list."
  expect_gh_calls 0
done

for legacy_input in INPUT_OR=wontfix INPUT_AND=wontfix INPUT_NOT=keep-open; do
  begin "removed inline input cannot replace required rules-file: $legacy_input"
  item open issue wontfix
  run_close INPUT_RULES_FILE= "$legacy_input"
  expect_status 1
  expect_output "rules-file is required."
  expect_gh_calls 0
done

# invalid_input <VAR=value> <expected error>
invalid_input() {
  begin "invalid input: $1"
  item open issue wontfix
  run_close "$1"
  expect_status 1
  expect_output "$2"
  expect_gh_calls 0
}

invalid_input INPUT_TARGET=both "target must be one of: issues prs all. Got 'both'."
invalid_input INPUT_CLOSE_REASON=spam "close-reason must be one of: completed not_planned. Got 'spam'."
invalid_input INPUT_LOCK=yes "lock must be one of: true false. Got 'yes'."
invalid_input INPUT_DRY_RUN=1 "dry-run must be one of: true false. Got '1'."
invalid_input INPUT_NUMBER=abc "number must be a positive whole number. Got 'abc'."
invalid_input INPUT_NUMBER=0 "number must be a positive whole number. Got '0'."

begin "no number in the event and no number input"
run_close EVENT_NUMBER= EVENT_NAME=schedule
expect_status 1
expect_output "The 'schedule' event has no issue or pull request. Set the number input."
expect_gh_calls 0

# --- API failures -----------------------------------------------------------------------------------------------

begin "failure reading the item"
rule 'any-labels: [wontfix]'
item open issue wontfix
run_close FAKE_GH_FAIL_ON="issues/7"
expect_status 1
expect_output "Could not read #7 in zarf-dev/zarf: HTTP 500: fake failure"
expect_no_writes

begin "failure posting the comment does not close"
run_close INPUT_COMMENT=bye FAKE_GH_FAIL_ON="/comments"
expect_status 1
expect_output "Could not comment on #7, so it was not closed"
expect_output '::error title=close-on-labels::Rule "close" (index: 1): Could not comment'
expect_no_call "-X PATCH"

begin "failure closing after the comment says the item is still open"
run_close INPUT_COMMENT=bye FAKE_GH_FAIL_ON="-X PATCH"
expect_status 1
expect_output "Posted the comment but could not close #7, so it is still open"
expect_output '::error title=close-on-labels::Rule "close" (index: 1): Posted the comment but could not close'

begin "failure closing without a comment identifies the rule"
run_close FAKE_GH_FAIL_ON="-X PATCH"
expect_status 1
expect_output '::error title=close-on-labels::Rule "close" (index: 1): Could not close #7'

begin "failure locking"
run_close INPUT_LOCK=true FAKE_GH_FAIL_ON="-X PUT"
expect_status 1
expect_output "Closed #7 but could not lock it"
expect_output '::error title=close-on-labels::Rule "close" (index: 1): Closed #7 but could not lock it'

rules '
rules:
  - id: unmatched
    any-labels: [other]
  - id: rejected
    any-labels: [wontfix]'
for operation in comment close lock; do
  begin "failure in file rule: $operation identifies the ID and file index"
  case "$operation" in
    comment) fail_on=/comments ;;
    close) fail_on="-X PATCH" ;;
    lock) fail_on="-X PUT" ;;
  esac
  run_close INPUT_RULES_FILE=rules.yaml INPUT_COMMENT=bye INPUT_LOCK=true \
    FAKE_GH_FAIL_ON="$fail_on"
  expect_status 1
  expect_output '::error title=close-on-labels::Rule "rejected" (index: 2):'
done

# --- escaping ---------------------------------------------------------------------------------------------------

begin "workflow command values are escaped"
rules '
rules:
  - id: close
    any-labels: [a]
  - id: "100% kept"
    not-labels: [b]'
item open issue x
run_close INPUT_RULES_FILE=rules.yaml
expect_output 'Rule "100%25 kept" (index: 2) only has `not-labels`'

begin "rule IDs cannot inject workflow commands into logs or errors"
rules '
rules:
  - id: "100%\n::error::forged"
    any-labels: [wontfix]'
item open issue wontfix
run_close INPUT_RULES_FILE=rules.yaml FAKE_GH_FAIL_ON="-X PATCH"
expect_status 1
expect_output 'Rule "100%\n::error::forged" (index: 1): applies'
expect_output '::error title=close-on-labels::Rule "100%25\n::error::forged" (index: 1): Could not close'
expect_no_output $'\n::error::forged'

# --- README example ---------------------------------------------------------------------------------------------

rules "$(awk '
  $0 == "# .github/close-rules.yaml" { reading = 1; next }
  reading && $0 == "```" { exit }
  reading { print }
' "$script_dir/README.md")"

for kind in issue pr; do
  begin "README example: $kind with wontfix closes by rejected"
  item open "$kind" wontfix
  run_close INPUT_RULES_FILE=rules.yaml
  expect_status 0
  expect_result closed true rejected wontfix

  begin "README example: $kind with keep-open is protected"
  item open "$kind" wontfix keep-open
  run_close INPUT_RULES_FILE=rules.yaml
  expect_status 0
  expect_result kept false keep keep-open
  expect_no_writes

  begin "README example: $kind with duplicate uses the earlier close rule"
  item open "$kind" duplicate has-replacement
  run_close INPUT_RULES_FILE=rules.yaml
  expect_status 0
  expect_result closed true rejected duplicate

  begin "README example: $kind without a matching rule stays open"
  item open "$kind" has-replacement
  run_close INPUT_RULES_FILE=rules.yaml
  expect_status 0
  expect_result none false "" ""
  expect_no_writes
done

# --- this repository's own rules ---------------------------------------------------------------------------------

repo_rules="$script_dir/../.github/close-rules.yaml"
mkdir -p "$work/ws/.github"
cp "$repo_rules" "$work/ws/.github/close-rules.yaml"

begin "repository rules: wontfix closes with a comment"
item open issue wontfix
run_close INPUT_RULES_FILE=.github/close-rules.yaml
expect_status 0
expect_result closed true rejected wontfix
expect_call 'body=Closing because this was labeled `wontfix`.'
expect_no_output "::warning"

begin "repository rules: keep-open keeps the item open"
item open pr duplicate keep-open
run_close INPUT_RULES_FILE=.github/close-rules.yaml
expect_result kept false keep keep-open
expect_no_writes

begin "repository rules: other labels are left alone"
item open issue bug enhancement
run_close INPUT_RULES_FILE=.github/close-rules.yaml
expect_result none false "" ""
expect_no_writes

# --- action.yaml ------------------------------------------------------------------------------------------------

begin "action.yaml passed all checks"
output=""
manifest="$script_dir/action.yaml"
[ "$(yq '.inputs.rules-file.required' "$manifest")" = true ] || fail "rules-file must be required"
for input in or and not; do
  [ "$(yq ".inputs | has(\"$input\")" "$manifest")" = false ] || fail "inline input $input must be removed"
done
for input in $(yq '.inputs | keys | .[]' "$manifest"); do
  [ "$input" = token ] && continue
  var="INPUT_$(tr 'a-z-' 'A-Z_' <<< "$input")"
  [ "$(yq ".runs.steps[0].env.$var" "$manifest")" = "\${{ inputs.$input }}" ] \
    || fail "input $input is not passed as $var"
  grep -q "\$$var\|{$var" "$script_dir/close.sh" || fail "close.sh does not read $var"
done
for out in $(yq '.outputs | keys | .[]' "$manifest"); do
  [ "$(yq ".outputs.\"$out\".value" "$manifest")" = "\${{ steps.close.outputs.$out }}" ] \
    || fail "output $out is not mapped to steps.close.outputs.$out"
  grep -q "set_output $out " "$script_dir/close.sh" || fail "close.sh never sets output $out"
done

report
echo
if [ "$failures" -gt 0 ]; then
  echo "$passed passed, $failed failed ($failures assertion(s))"
  exit 1
fi
echo "All $passed close-on-labels tests passed"

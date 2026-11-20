#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026-Present The Zarf Authors
#
# Closes an issue or pull request when its labels match an ordered list of rules.
#
# Required environment: GH_TOKEN, REPO, SHA, WORKSPACE, EVENT_NAME, EVENT_NUMBER, GITHUB_OUTPUT, and the
# INPUT_* variables set in action.yaml.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Workflow command values must escape %, CR and LF (S2).
escape() {
  local value=$1
  value=${value//'%'/'%25'}
  value=${value//$'\r'/'%0D'}
  value=${value//$'\n'/'%0A'}
  printf '%s' "$value"
}

fail() {
  echo "::error title=close-on-labels::$(escape "$1")"
  exit 1
}

warn() {
  echo "::warning title=close-on-labels::$(escape "$1")"
}

# Plain log lines always start with fixed text, and line breaks are removed, so values cannot form workflow commands.
log() {
  local line=$1
  line=${line//$'\r'/ }
  printf '%s\n' "${line//$'\n'/ }"
}

set_output() {
  local delimiter
  delimiter="EOF_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s<<%s\n%s\n%s\n' "$1" "$delimiter" "$2" "$delimiter" >> "$GITHUB_OUTPUT"
}

for tool in gh jq yq; do
  command -v "$tool" > /dev/null \
    || fail "$tool is required but was not found. GitHub-hosted Ubuntu runners include it;\
 install it on self-hosted runners."
done
yq --version 2>&1 | grep -q mikefarah \
  || fail "yq must be mikefarah/yq v4 (https://github.com/mikefarah/yq). Found: $(yq --version 2>&1 | head -n 1)."

trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  printf '%s' "${value%"${value##*[![:space:]]}"}"
}

# check_choice <input> <value> <allowed...>
check_choice() {
  local name=$1 value=$2
  shift 2
  local allowed
  for allowed in "$@"; do
    [ "$value" = "$allowed" ] && return 0
  done
  fail "$name must be one of: $*. Got '$value'."
}

target=$(trim "${INPUT_TARGET,,}")
reason=$(trim "${INPUT_CLOSE_REASON,,}")
lock=$(trim "${INPUT_LOCK,,}")
dry_run=$(trim "${INPUT_DRY_RUN,,}")
check_choice target "$target" issues prs all
check_choice close-reason "$reason" completed not_planned
check_choice lock "$lock" true false
check_choice dry-run "$dry_run" true false

number=$(trim "$INPUT_NUMBER")
if [ -n "$number" ]; then
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || fail "number must be a positive whole number. Got '$number'."
else
  number=${EVENT_NUMBER:-}
  [ -n "$number" ] || fail "The '$EVENT_NAME' event has no issue or pull request. Set the number input."
fi

rules_file=$(trim "$INPUT_RULES_FILE")
rules_file=${rules_file#./}
[ -n "$rules_file" ] || fail "rules-file is required. Set it to the path of a YAML file with a non-empty rules list."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [[ "$rules_file" == /* ]]; then local_path=$rules_file; else local_path="$WORKSPACE/$rules_file"; fi
if [ -f "$local_path" ]; then
  cp "$local_path" "$work/rules.yaml"
else
  if ! api_error=$(gh api -H "Accept: application/vnd.github.raw+json" \
    "repos/$REPO/contents/$rules_file?ref=$SHA" 2>&1 > "$work/rules.yaml"); then
    fail "Could not read rules-file '$rules_file'. It is not in the workspace, and fetching it from $REPO\
 at $SHA failed: $api_error. Check the path, and that the token has contents read access."
  fi
fi
if ! yaml_error=$(yq -o=json '.' < "$work/rules.yaml" 2>&1 > "$work/file.json"); then
  fail "$rules_file: invalid YAML: $yaml_error"
fi
[ -s "$work/file.json" ] || echo null > "$work/file.json"

jq -n \
  --slurpfile file "$work/file.json" \
  --arg path "$rules_file" \
  --arg target "$target" \
  --arg reason "$reason" \
  --arg comment "$INPUT_COMMENT" \
  --argjson lock "$lock" \
  '{file: $file[0], path: $path,
    defaults: {target: $target, reason: $reason, comment: $comment, lock: $lock}}' \
  | jq -f "$script_dir/rules.jq" > "$work/rules.json"

if [ "$(jq '.errors | length' "$work/rules.json")" -gt 0 ]; then
  while IFS= read -r message; do
    echo "::error title=close-on-labels::$(escape "$message")"
  done < <(jq -r '.errors[]' "$work/rules.json")
  fail "The rules are invalid. Fix the errors above."
fi
while IFS= read -r message; do
  warn "$message"
done < <(jq -r '.warnings[]' "$work/rules.json")

if ! api_error=$(gh api "repos/$REPO/issues/$number" 2>&1 > "$work/item.json"); then
  fail "Could not read #$number in $REPO: $api_error"
fi

state=$(jq -r '.state' "$work/item.json")
kind=$(jq -r 'if .pull_request then "prs" else "issues" end' "$work/item.json")
noun=$([ "$kind" = prs ] && echo "Pull request" || echo "Issue")

result=none closed=false matched_rule="" matched_labels=""

if [ "$state" != open ]; then
  log "$noun #$number is $state. Nothing to do."
else
  labels=$(jq -r '[.labels[].name] | if length == 0 then "(none)" else join(", ") end' "$work/item.json")
  log "$noun #$number has labels: $labels"

  jq --slurpfile item "$work/item.json" --arg kind "$kind" \
    '{rules: .rules, labels: [$item[0].labels[].name], kind: $kind}' "$work/rules.json" \
    | jq -f "$script_dir/match.jq" > "$work/match.json"

  while IFS= read -r line; do
    log "$line"
  done < <(jq -r '.log[]' "$work/match.json")

  unchecked=$(jq -r '.unchecked' "$work/match.json")
  [ "$unchecked" -eq 0 ] || log "The $unchecked rule(s) after it were not checked."

  if [ "$(jq -r '.rule == null' "$work/match.json")" = true ]; then
    log "No rule applies. $noun #$number stays open."
  else
    matched_rule=$(jq -r '.rule.id' "$work/match.json")
    matched_labels=$(jq -r '.matched | join(",")' "$work/match.json")
    rule_context=$(jq -r '.rule | "Rule \(.id | tojson) (index: \(.index))"' "$work/match.json")

    if [ "$(jq -r '.rule.kind' "$work/match.json")" = keep ]; then
      result=kept
      log "$noun #$number stays open."
    elif [ "$dry_run" = true ]; then
      result=would-close
      log "Dry run: $noun #$number would be closed. Nothing was changed."
    else
      # One pass, so a placeholder inside a label or rule ID is not replaced again.
      comment=$(jq -r '
        (.matched | map("`\(.)`") | join(", ")) as $m
        | .rule.id as $id
        | .rule.comment | split("{{matched}}") | map(split("{{rule}}") | join($id)) | join($m)' "$work/match.json")

      if [ -n "$comment" ]; then
        if ! api_error=$(gh api "repos/$REPO/issues/$number/comments" -f body="$comment" 2>&1 > /dev/null); then
          fail "$rule_context: Could not comment on #$number, so it was not closed: $api_error"
        fi
      fi

      close_args=(-X PATCH "repos/$REPO/issues/$number" -f state=closed)
      [ "$kind" = prs ] || close_args+=(-f state_reason="$(jq -r '.rule.reason' "$work/match.json")")
      if ! api_error=$(gh api "${close_args[@]}" 2>&1 > /dev/null); then
        if [ -n "$comment" ]; then
          fail "$rule_context: Posted the comment but could not close #$number, so it is still open: $api_error"
        fi
        fail "$rule_context: Could not close #$number: $api_error"
      fi
      result=closed closed=true
      log "Closed ${noun,} #$number."

      if [ "$(jq -r '.rule.lock' "$work/match.json")" = true ]; then
        if ! api_error=$(gh api -X PUT "repos/$REPO/issues/$number/lock" 2>&1 > /dev/null); then
          fail "$rule_context: Closed #$number but could not lock it: $api_error"
        fi
        log "Locked ${noun,} #$number."
      fi
    fi
  fi
fi

set_output closed "$closed"
set_output result "$result"
set_output matched-rule "$matched_rule"
set_output matched-labels "$matched_labels"
set_output number "$number"

# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026-Present The Zarf Authors
#
# Finds the first rule that applies to an issue or pull request.
#
# Input:  {"rules": [normalized rule], "labels": [label name], "kind": "issues"|"prs"}
# Output: {"log": [string], "rule": <rule or null>, "matched": [label name], "unchecked": <number>}
#
# Rules are checked in order and the first one that applies decides. A rule with `any-labels` or `all-labels`
# (kind "close") applies when every list it sets is satisfied. A rule with only `not-labels` (kind "keep") applies
# when the item has one of its labels, and keeps the item open.

def norm: ascii_downcase | gsub("^\\s+|\\s+$"; "");
def present($have): norm as $x | any($have[]; . == $x);
def quoted: map("\"\(.)\"") | join(", ");
def target_name: if . == "prs" then "pull requests" else "issues" end;

# Labels on the item, with the item's casing, that appear in $wanted.
def on_item($labels; $wanted): ($wanted | map(norm)) as $w | [$labels[] | select(norm as $x | $w | index([$x]))];

def evaluate($have; $kind):
  if .target != "all" and .target != $kind then
    {status: "skipped", why: "it only applies to \(.target | target_name)"}
  elif .kind == "keep" then
    if any(.["not-labels"][]; present($have)) then {status: "applies"}
    else {status: "no", why: "none of \(.["not-labels"] | quoted) is present"} end
  else
    [.["all-labels"][] | select(present($have) | not)] as $missing
    | [.["not-labels"][] | select(present($have))] as $blocked
    | ((.["any-labels"] | length) == 0 or any(.["any-labels"][]; present($have))) as $any_ok
    | if $any_ok and ($missing | length) == 0 and ($blocked | length) == 0 then {status: "applies"}
      else {status: "no", why: ([
        (if $any_ok then empty else "none of \(.["any-labels"] | quoted) is present" end),
        (if ($missing | length) > 0 then "missing \($missing | quoted)" else empty end),
        (if ($blocked | length) > 0 then "has \($blocked | quoted)" else empty end)
      ] | join("; "))}
      end
  end;

. as $in
| ($in.labels | map(norm)) as $have
| [$in.rules[] | . as $r | evaluate($have; $in.kind) + {rule: $r}] as $results
| ([$results | to_entries[] | select(.value.status == "applies") | .key] | first) as $hit
| (if $hit == null then null else $results[$hit].rule end) as $rule
| (if $rule == null then []
   elif $rule.kind == "keep" then on_item($in.labels; $rule["not-labels"])
   else on_item($in.labels; $rule["any-labels"] + $rule["all-labels"]) end) as $matched
| {
    log: [$results | to_entries[] | select($hit == null or .key <= $hit) | .value
      | "Rule \(.rule.id | tojson) (index: \(.rule.index)): " + (
          if .status == "skipped" then "skipped, \(.why)."
          elif .status == "no" then "does not apply, \(.why)."
          elif .rule.kind == "keep" then "applies (has \($matched | quoted)), keeping the item open."
          else "applies (\($matched | quoted))." end)],
    rule: $rule,
    matched: $matched,
    unchecked: (if $hit == null then 0 else ($results | length) - $hit - 1 end)
  }

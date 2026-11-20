# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026-Present The Zarf Authors
#
# Validates and normalizes close-on-labels rules.
#
# Input:  {"file": <parsed rules file>, "path": <rules-file path>,
#          "defaults": {"target", "reason", "comment", "lock"}}
# Output: {"errors": [string], "warnings": [string], "rules": [normalized rule]}
#
# A normalized rule has an id, file index (1-based), kind ("close"|"keep"),
# label lists and action settings.
# Keys containing hyphens are read with quoted subscripts, for example .["any-labels"].

def trim_ws: gsub("^\\s+|\\s+$"; "");

def allowed_keys: ["id", "any-labels", "all-labels", "not-labels", "target", "reason", "comment", "lock"];

# A list of labels, given as a YAML list or as a comma or newline separated string. null when malformed.
def label_list:
  (if type == "array" then . elif type == "string" then [splits("[,\n]")] else [.] end)
  | if all(.[]; type == "string" or type == "number")
    then map(tostring | trim_ws) | map(select(length > 0))
    else null
    end;

# The lowercased value when it is a string in $allowed, otherwise null.
def one_of($allowed):
  if type == "string" then ascii_downcase as $v | if $allowed | index([$v]) then $v else null end else null end;

# check($at; $index; $defaults): validates one rule. Returns {"errors": [...], "rule": {...}}.
def check($at; $index; $defaults):
  . as $r
  | " (index: \($index))" as $position
  | if ($r | type) != "object" then
      {errors: ["\($at): Rule\($position) must be a mapping with `id` and `any-labels`, `all-labels` or `not-labels`."],
       rule: null}
    else
      ($r.id | if type == "string" then trim_ws else null end) as $id
      | ("\($at): Rule" + (if $id == null or $id == "" then "" else " \($id | tojson)" end)
          + $position) as $where
      | [$r | keys[] | select(. as $k | allowed_keys | index([$k]) | not)] as $unknown
      | (reduce ("any-labels", "all-labels", "not-labels") as $k ({};
          if $r | has($k) then . + {($k): ($r[$k] | label_list)} else . end)) as $lists
      | (if ($lists | has("any-labels")) or ($lists | has("all-labels")) then "close" else "keep" end) as $kind
      | ($r.target | one_of(["issues", "prs", "all"])) as $target
      | ($r.reason | one_of(["completed", "not_planned"])) as $reason
      | {
          errors: (
            (if ($unknown | length) > 0 then
               ["\($where) has unknown key(s): \($unknown | join(", ")). Allowed: \(allowed_keys | join(", "))."]
             else [] end)
            + (if ($r | has("id") | not) then
                 ["\($where): `id` is required. Add a unique, non-empty string ID."]
               elif $id == null then ["\($where): `id` must be a non-empty string."]
               elif $id == "" then ["\($where): `id` is empty. Set a unique, non-empty string ID."]
               else [] end)
            + (if ($lists | length) == 0 then ["\($where) needs `any-labels`, `all-labels` or `not-labels`."] else [] end)
            + [$lists | to_entries[]
                | if .value == null then "\($where): `\(.key)` must be a list of labels."
                  elif (.value | length) == 0 then "\($where): `\(.key)` is empty."
                  else empty end]
            + (if ($r | has("target")) and $target == null then
                 ["\($where): `target` must be one of issues, prs, all (got \($r.target | tojson))."]
               else [] end)
            + (if $kind == "keep" then
                 [("reason", "comment", "lock") as $k | select($r | has($k))
                  | "\($where): `\($k)` only applies to rules with `any-labels` or `all-labels`."
                    + " A rule with only `not-labels` keeps items open."]
               else
                 (if ($r | has("reason")) and $reason == null then
                    ["\($where): `reason` must be one of completed, not_planned (got \($r.reason | tojson))."]
                  else [] end)
                 + (if ($r | has("comment")) and ($r.comment | type) != "string" then
                      ["\($where): `comment` must be a string."]
                    else [] end)
                 + (if ($r | has("lock")) and ($r.lock | type) != "boolean" then
                      ["\($where): `lock` must be true or false (got \($r.lock | tojson))."]
                    else [] end)
               end)
          ),
          rule: {
            id: $id,
            index: $index,
            kind: $kind,
            "any-labels": ($lists["any-labels"] // []),
            "all-labels": ($lists["all-labels"] // []),
            "not-labels": ($lists["not-labels"] // []),
            target: ($target // $defaults.target),
            reason: ($reason // $defaults.reason),
            comment: (if $r | has("comment") then $r.comment else $defaults.comment end),
            lock: (if $r | has("lock") then $r.lock else $defaults.lock end)
          }
        }
    end;

. as $in
| (if ($in.file | type) != "object" or ($in.file.rules | type) != "array" or ($in.file.rules | length) == 0 then
     {errors: ["\($in.path): expected a non-empty `rules` list."], checked: []}
   else
     {errors: [], checked: [$in.file.rules | to_entries[]
       | .key as $i | .value | check($in.path; $i + 1; $in.defaults)]}
   end) as $file
| $file.checked as $checked
| [$checked[].rule | select(. != null)] as $rules
| ($rules | map(select(.id != null and .id != "")) | group_by(.id) | map(select(length > 1))) as $dupes
| ($file.errors + ($checked | map(.errors) | add // [])) as $rule_errors
| {
    errors: (
      $rule_errors
      + [$dupes[] | "Duplicate rule ID \(.[0].id | tojson) at "
          + (map("\($in.path) (index: \(.index))") | join(", "))
          + ". Rule IDs must be unique."]
      + (if ($rule_errors | length) == 0 and ([$rules[] | select(.kind == "close")] | length) == 0 then
           ["No rule can close anything. Add a rule with `any-labels` or `all-labels`;"
             + " a rule with only `not-labels` only keeps items open."]
         else [] end)
    ),
    warnings: (
      ([$rules | to_entries[] | select(.value.kind == "close") | .key] | max) as $last_close
      | [$rules | to_entries[]
         | select(.value.kind == "keep" and $last_close != null and .key > $last_close)
         | "Rule \(.value.id | tojson) (index: \(.value.index))"
           + " only has `not-labels` and comes after every rule that can close,"
           + " so it never has an effect. Move it above the rules it should protect."]
    ),
    rules: $rules
  }

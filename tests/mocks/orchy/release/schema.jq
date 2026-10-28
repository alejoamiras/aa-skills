# orchy.release/1's shape, for the derivation's tests and its live check: jq -e --arg repo <o/r> --arg rc <exit> -f schema.jq
def s: type == "string";
def ss: type == "array" and all(.[]; type == "string");
def nb: . == null or type == "boolean";
def method: IN("merge", "squash", "rebase");
def branch: type == "object" and (.name | s) and (.methods == null or (.methods | ss and all(.[]; method)))
  and ([.linear, .signed, .strict, .queue] | all(.[]; nb)) and (.checks == null or (.checks | ss))
  and (.reviews == null or (.reviews | type == "number")) and (.deploys == null or (.deploys | ss));
(keys == ["at", "branch", "environments", "external", "freeze", "repo", "schema", "shape", "skill", "sync", "tags", "tool", "trunk",
  "unknown", "workflows"])
and .schema == "orchy.release/1" and .repo == $repo and (.at | s and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
and (.shape | IN("promote", "single", "none", "unknown")) and (.trunk | branch) and (.branch == null or (.branch | branch))
and (.tool | type == "object" and (.kind | IN("release-please", "tag", "dispatch", "none", "unknown"))
  and ([.branch, .bot, .head] | all(.[]; . == null or type == "string")))
and (.sync == null or (.sync | type == "object" and (.from | s) and (.to | s) and (.method == null or (.method | method))
  and (.head | s) and (.blocked_by == null or (.blocked_by | s))))
and (if .shape == "promote" then .branch != null and .sync != null elif .shape == "unknown" then true else .branch == null and .sync == null end)
and (.tags == null or (.tags | type == "array" and all(.[]; (.pattern | s) and (.creation | IN("restricted", "open")))))
and (.environments == null or (.environments | type == "array"
  and all(.[]; (.name | s) and (.reviewers | type == "number") and (.self_review_blocked | type == "boolean"))))
and (.workflows == null or (.workflows | type == "array" and all(.[]; (.path | s) and (.dispatch == null or (.dispatch | ss))
  and (.push_branches | ss) and (.push_tags | ss) and (.environments | ss) and (.signals | ss))))
and (.skill == null or (.skill | type == "object" and (.path | s) and (.block | type == "boolean")))
and (.freeze | nb) and (.external == null or (.external | ss)) and (.unknown | ss)
and ((.unknown | length > 0) == ($rc == "3"))

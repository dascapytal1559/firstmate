#!/usr/bin/env bash
# fm-size.sh - size a Claude ship or scout against each account's quota before
# it starts, pick the account it fits on, and record how the estimate held up.
#
# Usage:
#   fm-size.sh pick --task <id> --kind <ship|scout> --model <model> --effort <effort> --backend <backend> [--account <id>]
#   fm-size.sh finish --task <id>
#   fm-size.sh due
#   fm-size.sh report [--since <YYYY-MM-DD[THH:MMZ]>]
#   fm-size.sh refit [--min <n>] [--write]
#
# docs/configuration.md "Worker sizing" owns config/worker-sizing.json and the
# operator contract; this header owns the mechanics. Opt-in: without that file
# `pick` prints nothing and exits 0 having read nothing, so bin/fm-spawn.sh
# behaves exactly as before.
#
# pick (bin/fm-spawn.sh runs it for a fresh Claude ship or scout, before
# anything is leased or launched):
#   1. Each account in the file is one Claude login: on backend t3code a T3
#      provider instance, whose login folder comes from fm_claude_login_t3_root;
#      on any other backend a config/claude-accounts entry (`ordinary` or a
#      Claude config directory). All accounts are read at once with
#      fm_claude_login_read at the file's max_age_seconds, so a read within
#      that age reuses quota-axi's cache instead of asking the vendor again.
#   2. The new job is sized at its class's p90 (class = kind, model family,
#      effort; else the same model family and effort; else the file's
#      fallback class), in the class's weight unit (list-price dollars of
#      everything but cache reads), and converted to each limit's percent with
#      the account plan's rate. The 5-hour size is scaled by the minutes left
#      to that window's reset over the class's busy_p90, capped at 1.
#   3. What is already running on the account is held back: every live Claude
#      ship or scout of this home (a task record whose latest status is not
#      done or failed) at its class's p75 minus what its transcripts show it
#      has spent since it started, never below zero; every no-mistakes run
#      executing for one of them, on pipeline_account, at the pipeline class's
#      p75; and every start this script picked within pending_minutes whose
#      task record is not written yet. A task's account is its t3_instance=
#      (or account=) record, moved by a later usage-limit move, else the
#      account its start record names, else the account whose login folder
#      holds its newest transcript, else the standing mapping.
#   4. It fits when, on every limit the account reports, left - held - reserve
#      >= size: the 5-hour window (reserve.five_hour), the week
#      (reserve.weekly), and for a Fable job the Fable allowance
#      (reserve.weekly, at the plan's fable_weekly rate, else its weekly rate).
#      A plan without a 5-hour rate leaves that window unsized.
#   5. The pick is the account that fits with the soonest weekly reset; else an
#      account that could not be measured (with a warning); else the start is
#      queued: exit 76, naming the soonest time an account's 5-hour (or weekly)
#      reset would let it fit, a state/worker-sizing/queue/<task> entry, and
#      state/worker-sizing-retry.check.sh so the watcher wakes firstmate then.
#      A wait over queue_notice_minutes says to tell the captain.
#   --account <id> is firstmate's explicit choice: that account is sized and
#   started on whether or not it fits, and the record says so.
#   stderr: one line per account and one decision line, each `sizing: ...`.
#   stdout: the picked account id, nothing else.
#   Exit 0 start, 76 queued, 2 a usage error or malformed file (reported,
#   never sized around). A missing jq prints one warning and exits 0 empty.
#
# Records: every pick appends one JSON line to data/worker-sizing/records.jsonl
# (event start or queue: task, kind, model, effort, the class used, account,
# why, the estimate, every account's reading and held amount, the running work
# counted, and the sizing step's own time and printed lines). finish, which
# bin/fm-teardown.sh runs at cleanup for a task this script sized, appends the
# actual: duration, the transcripts' tokens, weight and busy minutes, the
# account's reading then, and whether a usage limit cut the task off
# (state/<id>.usage-limit). due prints one `check:` line per queued start
# whose time has come and retires its entry. report summarises estimate
# against actual per class, cut-offs, queued starts and their waits, and the
# sizing step's cost. refit recomputes each class's p75, p90 and busy_p90 from
# finished records (classes with fewer than --min, default 5, keep theirs),
# prints the changes, and with --write saves them, keeping a backup.
#
# Transcripts are <login>/projects/<worktree path, each non-alphanumeric
# character as ->/**/*.jsonl, assistant records de-duplicated by request id;
# cache writes weigh 1.25x (5-minute) and 2x (1-hour) input, as the sizing
# report measured. Nothing here launches Claude, reads message text, or
# changes any account or home file other than its own records.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG_FILE="$CONFIG/worker-sizing.json"
RECORDS="$DATA/worker-sizing/records.jsonl"
QUEUE_DIR="$STATE/worker-sizing/queue"
LOCK="$STATE/worker-sizing/lock"
CHECK_SCRIPT="$STATE/worker-sizing-retry.check.sh"
QUEUED_EXIT=76

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-claude-login-lib.sh
. "$SCRIPT_DIR/fm-claude-login-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}
now() { printf '%s' "${FM_SIZE_NOW:-$(date +%s)}"; }
# Milliseconds since the epoch where bash offers it, else whole seconds.
now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local s=${EPOCHREALTIME%[.,]*} f=${EPOCHREALTIME#*[.,]}000
    printf '%s' "$((s * 1000 + 10#${f:0:3}))"
  else
    printf '%s' "$(( $(date +%s) * 1000 ))"
  fi
}
meta_get() {  # <file> <key>: the last <key>= value, or nothing
  [ -f "$1" ] || return 0
  awk -v k="$2=" 'index($0, k) == 1 { v = substr($0, length(k) + 1) } END { printf "%s", v }' "$1"
}

# Shared jq definitions: ISO time to epoch, model family.
# shellcheck disable=SC2016  # jq program text: its $names are jq variables.
JQ_DEFS='
  def ep: if . == null then null else
    (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?)(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") // null) as $m |
    if $m == null then null else
      ($m.d | if length == 16 then . + ":00" else . end | . + "Z" | fromdateiso8601) as $t |
      ($m.z // "Z") as $z |
      if $z == "Z" then $t else
        ($z | gsub(":"; "")) as $o |
        (($o[1:3] | tonumber) * 3600 + ($o[3:5] | tonumber) * 60) as $s |
        if $o[0:1] == "+" then $t - $s else $t + $s end
      end
    end end;
  def fam: ascii_downcase | if test("fable") then "fable" elif test("opus") then "opus"
    elif test("sonnet") then "sonnet" elif test("haiku") then "haiku" else "other" end;
  def r1: (. * 10 | round) / 10;
  def pct($q): sort as $v | if ($v | length) == 0 then null else
    ((($v | length) - 1) * $q) as $k | ($k | floor) as $i |
    $v[$i] + ($v[[$i + 1, ($v | length) - 1] | min] - $v[$i]) * ($k - $i) end;
  def iso: todate | sub(":[0-9]{2}Z$"; "Z");
'

# The configuration with defaults filled in, or `error: <why>`.
# shellcheck disable=SC2016  # jq program text: its $names are jq variables.
JQ_CONFIG="$JQ_DEFS"'
  def num: type == "number";
  def rates_ok: type == "object" and (to_entries | all(.value | num and . > 0));
  . as $c |
  if type != "object" then "error: not a JSON object"
  elif ($c.accounts | type) != "array" or ($c.accounts | length) == 0 then "error: accounts must list at least one account"
  elif ($c.accounts | any(type != "object" or (.id | type) != "string" or .id == "" or (.plan | type) != "string")) then "error: each account needs a string id and plan"
  elif ([$c.accounts[].id] | unique | length) != ($c.accounts | length) then "error: an account id is listed twice"
  elif ($c.plans | type) != "object" then "error: plans must be an object"
  elif ($c.accounts | any(.plan as $p | $c.plans[$p] == null)) then "error: account \([$c.accounts[] | select(.plan as $p | $c.plans[$p] == null) | .id] | first) names an undefined plan"
  elif ($c.plans | to_entries | any((.value.weekly | rates_ok | not) or (.value.weekly.other | num | not))) then "error: every plan needs weekly rates (percent per weight unit) with at least an other rate"
  elif ($c.plans | to_entries | any((.value.five_hour // {} | rates_ok | not) or (.value.fable_weekly // {} | rates_ok | not))) then "error: five_hour and fable_weekly rates must be positive numbers"
  elif ($c.classes | type) != "array" or ($c.classes | length) == 0 then "error: classes must list at least one class"
  elif ($c.classes | any(type != "object" or (.kind | type) != "string" or (.model | type) != "string" or (.effort | type) != "string"
        or (.p75 | num | not) or (.p90 | num | not) or (.busy_p90 | num | not) or .p75 < 0 or .p90 < 0 or .busy_p90 < 0)) then "error: each class needs kind, model, effort, p75, p90 and busy_p90"
  elif ([$c.reserve.five_hour?, $c.reserve.weekly?, $c.max_age_seconds, $c.read_seconds, $c.queue_notice_minutes, $c.pending_minutes] | any(. != null and (num | not))) then "error: reserve, max_age_seconds, read_seconds, queue_notice_minutes and pending_minutes must be numbers"
  elif ($c.pipeline_account != null and ([$c.accounts[].id] | index($c.pipeline_account)) == null) then "error: pipeline_account is not one of the accounts"
  else
    ($c.fallback // {kind: "ship", model: "opus", effort: "high"}) as $fb |
    if ([$c.classes[] | select(.kind == $fb.kind and .model == $fb.model and .effort == $fb.effort)] | length) == 0
    then "error: no class matches the fallback \($fb.kind) \($fb.model) \($fb.effort)"
    else {
      accounts: $c.accounts, plans: $c.plans, classes: $c.classes, fallback: $fb,
      reserve: {five_hour: ($c.reserve.five_hour // 10), weekly: ($c.reserve.weekly // 2)},
      max_age_seconds: ($c.max_age_seconds // 120), read_seconds: ($c.read_seconds // 20),
      queue_notice_minutes: ($c.queue_notice_minutes // 60), pending_minutes: ($c.pending_minutes // 15),
      pipeline_account: ($c.pipeline_account // null), t3_home: ($c.t3_home // ""),
      default_model: ($c.default_model // "opus"), default_effort: ($c.default_effort // "high"),
      prices: ({fable: [8, 40], opus: [4, 20], sonnet: [2, 10]} + ($c.prices // {}))
    } end
  end'

# A quota-axi snapshot reduced to what sizing reads.
# shellcheck disable=SC2016  # jq program text: its $names are jq variables.
JQ_READING="$JQ_DEFS$FM_QUOTA_ROW_JQ"'
  def left($w):
    if ($w.percentRemaining | type) == "number" then $w.percentRemaining
    elif ($w.percentUsed | type) == "number" then 100 - $w.percentUsed
    else null end;
  def win($row; $id; $gone): ([$row.windows[]? | select(type == "object" and .id == $id)] | first) as $w |
    if $w == null or left($w) == null then null
    else {left: (if $gone then 0 else left($w) end), reset: ($w.resetsAt | ep)} end;
  quota_row(.; "claude"; "") as $row |
  if $row == null then {measured: false, why: "no claude quota row"}
  elif $row.quotaSemantics.status == "unknown" then
    {measured: false, why: "quota unknown\(if $row.state.status then " (\($row.state.status): \($row.state.error // "no reason given"))" else "" end)"}
  else
    [$row.quotaSemantics.effectiveAvailability[]? | select(.runway.status == "exhausted_now") | .scope] as $gone |
    {measured: true, five: win($row; "five_hour"; false),
     week: win($row; "seven_day"; ($gone | index("all_models")) != null),
     fable: win($row; "model:fable"; ($gone | index("model:fable")) != null)} |
    if .week == null then {measured: false, why: "no weekly window reported"} else . end
  end'

# Transcript records (one compact object per line) to a usage summary.
# shellcheck disable=SC2016  # jq program text: its $names are jq variables.
JQ_SCAN="$JQ_DEFS"'
  [inputs | select(.ts != null) | .t = (.ts | ep) | select(.t != null and .t >= $start and ($end == null or .t <= $end))]
  | unique_by(.rid) | sort_by(.t)
  | map(. as $r | ($r.m | fam) as $f | ($prices[$f] // $prices.opus) as $p | ($r.u // {}) as $u |
      ($u.cache_creation.ephemeral_1h_input_tokens // 0) as $c1 |
      ([($u.cache_creation.ephemeral_5m_input_tokens // (($u.cache_creation_input_tokens // 0) - $c1)), 0] | max) as $c5 |
      {t: $r.t, f: $f, in: ($u.input_tokens // 0), out: ($u.output_tokens // 0), c5: $c5, c1: $c1, cr: ($u.cache_read_input_tokens // 0),
       w: (((($u.input_tokens // 0) + $c5 * 1.25 + $c1 * 2) * $p[0] + ($u.output_tokens // 0) * $p[1]) / 1000000)})
  | . as $c
  | {calls: ($c | length), weight: ([$c[].w] | add // 0),
     by_family: (reduce $c[] as $x ({}; .[$x.f] += $x.w)),
     tokens: {input: ([$c[].in] | add // 0), output: ([$c[].out] | add // 0), cache_write_5m: ([$c[].c5] | add // 0),
              cache_write_1h: ([$c[].c1] | add // 0), cache_read: ([$c[].cr] | add // 0)},
     busy_minutes: ([$c[].t] as $ts | [range(1; $ts | length) | ($ts[.] - $ts[. - 1]) | if . > 600 then 600 else . end] | add // 0 | . / 60),
     first: ($c[0].t // null), last: ($c[-1].t // null)}'

# Pick (or queue) a start from the gathered inputs.
# shellcheck disable=SC2016  # jq program text: its $names are jq variables.
JQ_DECIDE="$JQ_DEFS"'
  def cls($kind; $fam; $eff):
    ([$cfg.classes[] | select(.kind == $kind and .model == $fam and .effort == $eff) | . + {match: "exact"}] | first) //
    ([$cfg.classes[] | select(.model == $fam and .effort == $eff) | . + {match: "same model and effort"}] | first) //
    ([$cfg.classes[] | select(.kind == $cfg.fallback.kind and .model == $cfg.fallback.model and .effort == $cfg.fallback.effort) | . + {match: "fallback"}] | first);
  def rate($plan; $limit; $fam): ($cfg.plans[$plan][$limit]) as $r | if $r == null then null else ($r[$fam] // $r.other // null) end;
  def frate($plan): rate($plan; "fable_weekly"; "fable") // rate($plan; "weekly"; "fable");
  cls($req.kind; $req.family; $req.effort) as $c |
  # held: what running work on account $a still holds, by limit.
  def held($a):
    [$run[] | select(.account == $a.id) | . as $it | cls($it.kind; $it.family; $it.effort) as $ic |
      {task: $it.task, kind: $it.kind, family: $it.family, source: $it.source, assumed: ($it.assumed // false),
       rem: ([$ic.p75 - ($it.spent // 0), 0] | max)}];
  def check($a; $r; $t):
    held($a) as $h |
    (if $r.five != null and rate($a.plan; "five_hour"; $req.family) != null then
       ((if $r.five.reset == null then 300 else ($r.five.reset - $t) / 60 end) as $mins |
        (if $c.busy_p90 <= 0 then 1 else ([$mins / $c.busy_p90, 1] | min) end) as $scale |
        ($c.p90 * rate($a.plan; "five_hour"; $req.family) * ([$scale, 0] | max)) as $need |
        ([$h[] | .rem * (rate($a.plan; "five_hour"; .family) // 0)] | add // 0) as $held |
        {limit: "5h", left: $r.five.left, held: $held, reserve: $cfg.reserve.five_hour, need: $need,
         ok: ($r.five.left - $held - $cfg.reserve.five_hour >= $need)})
     elif $r.five != null then {limit: "5h", unsized: true, left: $r.five.left, ok: true}
     else empty end),
    (($c.p90 * rate($a.plan; "weekly"; $req.family)) as $need |
     ([$h[] | .rem * rate($a.plan; "weekly"; .family)] | add // 0) as $held |
     {limit: "week", left: $r.week.left, held: $held, reserve: $cfg.reserve.weekly, need: $need,
      ok: ($r.week.left - $held - $cfg.reserve.weekly >= $need)}),
    (if $req.family == "fable" and $r.fable != null then
       (($c.p90 * frate($a.plan)) as $need |
        ([$h[] | select(.family == "fable") | .rem * frate($a.plan)] | add // 0) as $held |
        {limit: "fable", left: $r.fable.left, held: $held, reserve: $cfg.reserve.weekly, need: $need,
         rate: (if rate($a.plan; "fable_weekly"; "fable") == null then "weekly" else "fable_weekly" end),
         ok: ($r.fable.left - $held - $cfg.reserve.weekly >= $need)})
     else empty end);
  def evaluate($a):
    if ($a.reading.measured | not) then $a + {measured: false, fits: null, running: (held($a) | length)}
    else [check($a; $a.reading; $now)] as $ch |
      $a + {measured: true, checks: $ch, fits: ($ch | all(.ok)), running: (held($a) | length), held_work: held($a)} end;
  # The reading a reset at $t would leave.
  def after($r; $t):
    $r | (if .five != null and .five.reset != null and .five.reset <= $t then .five = {left: 100, reset: ($t + 18000)} else . end)
       | (if .week.reset != null and .week.reset <= $t then .week = {left: 100, reset: ($t + 604800)} else . end)
       | (if .fable != null and .fable.reset != null and .fable.reset <= $t then .fable = {left: 100, reset: ($t + 604800)} else . end);
  def fits_at($a; $t): [check($a; after($a.reading; $t); $t)] | all(.ok);
  def line($e):
    "sizing: \($e.id) (\($e.plan))" +
    (if $e.measured | not then " | not measured: \($e.reading.why)"
     else ([$e.checks[] |
        if .unsized then " | \(.limit) \(.left | r1)% left, unsized"
        else " | \(.limit) \(.left | r1)-\(.held | r1) held-\(.reserve) reserve, needs \(.need | r1)\(if .rate == "weekly" then " (weekly rate)" else "" end): \(if .ok then "ok" else "short" end)" end] | join("")) +
       " | \($e.running) running" end);
  [$acc[] | evaluate(.)] as $ev |
  ($ev | map(select(.measured)) | sort_by(.reading.week.reset // 9999999999)) as $measured |
  ($ev | map(select(.measured | not))) as $unmeasured |
  ($measured + $unmeasured) as $ordered |
  (if $explicit != "" then
     (([$ordered[] | select(.id == $explicit)] | first) // null) as $e |
     {decision: "explicit", account: $explicit,
      why: (if $e == null then "chosen by firstmate; not one of the sized accounts"
            elif $e.fits == true then "chosen by firstmate; fits"
            elif $e.fits == false then "chosen by firstmate; does not fit, starting anyway as chosen"
            else "chosen by firstmate; not measured" end)}
   elif ([$measured[] | select(.fits)] | length) > 0 then
     {decision: "start", account: ([$measured[] | select(.fits)] | first | .id), why: "fits; soonest weekly reset of the accounts that fit"}
   elif ($unmeasured | length) > 0 then
     {decision: "start", account: $unmeasured[0].id, why: "no measured account fits; \($unmeasured[0].id) could not be measured, starting there with a warning", warning: true}
   else
     ([$measured[] | . as $a |
        ([$a.reading.five.reset, $a.reading.week.reset, $a.reading.fable.reset] | map(select(. != null and . > $now)) | unique) as $ts |
        ([$ts[] | select(fits_at($a; .))] | first) as $t | select($t != null) | {id: $a.id, at: $t}] | sort_by(.at) | first) as $soon |
     if $soon != null then
       {decision: "queue", account: $soon.id, at: $soon.at, why: "no account fits now; soonest fit after a reset"}
     else
       (([$measured[] | .reading.five.reset // empty | select(. > $now)] | min) // ($now + 1800)) as $t |
       {decision: "queue", account: null, at: $t, why: "no account fits now or after its next reset; retry then (it may still not fit)"}
     end
   end) as $d |
  ($ev | map(select(.id == $d.account)) | first) as $chosen |
  {class: $c, decision: $d,
   estimate: (if $chosen.measured then [$chosen.checks[] | {key: .limit, value: (.need // null)}] | from_entries else null end),
   lines: ([$ordered[] | line(.)] +
     [if $d.decision == "queue" then
        "sizing: queued - \($d.why); \(if $d.account then "\($d.account) " else "" end)at \($d.at | iso) (in \((($d.at - $now) / 60) | ceil) min); the start is retried then"
      else "sizing: \(if $d.decision == "explicit" then "explicit" else "start" end) \($d.account) - \($d.why) (\($req.kind) \($req.family) \($req.effort) sized as \($c.kind) \($c.model) \($c.effort), \($c.match))" end] +
     [if $d.decision == "queue" and (($d.at - $now) / 60) > $cfg.queue_notice_minutes then
        "sizing: the wait passes \($cfg.queue_notice_minutes) minutes - tell the captain" else empty end]),
   accounts: [$ev[] | {id, plan, measured, fits, running, reading, checks: (.checks // null)}],
   running: $run}'

# --- shared helpers -------------------------------------------------------------

load_config() {
  [ -f "$CONFIG_FILE" ] || return 1
  CFG_JSON=$(jq -c "$JQ_CONFIG" "$CONFIG_FILE" 2>/dev/null) ||
    die "$CONFIG_FILE is not valid JSON (docs/configuration.md \"Worker sizing\")"
  case "$CFG_JSON" in
    '"error: '*) die "$CONFIG_FILE: $(printf '%s' "$CFG_JSON" | jq -r '.' | sed 's/^error: //') (docs/configuration.md \"Worker sizing\")" ;;
  esac
  return 0
}
cfg() { printf '%s' "$CFG_JSON" | jq -r "$1"; }

# The login folder of account <id> on <backend>, in ACCT_ROOT, or ACCT_WHY.
account_root() {  # <backend> <id>
  ACCT_ROOT=
  ACCT_WHY=
  if [ "$1" = t3code ]; then
    if fm_claude_login_t3_root "$CONFIG" "$(fm_claude_login_default_t3_home "$(cfg '.t3_home // ""')" "$CONFIG")" "$2"; then
      ACCT_ROOT=$FM_CLAUDE_LOGIN_ROOT
    else
      ACCT_WHY=$FM_CLAUDE_LOGIN_WHY
      return 1
    fi
  elif [ "$2" = ordinary ]; then
    ACCT_ROOT=
  else
    ACCT_ROOT=$(fm_claude_login_normalize "$(fm_claude_login_expand_home "$2")")
  fi
  return 0
}

# Usage of the Claude transcripts for <worktree> under <root> between
# <start> and <end|null>, as JSON.
scan_usage() {  # <root> <worktree> <start> <end|null>
  local root=${1:-$HOME/.claude} wt=$2 start=$3 end=$4 dir mins
  dir="$root/projects/$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')"
  if [ -z "$wt" ] || [ ! -d "$dir" ]; then
    printf '{"found":false,"calls":0,"weight":0,"busy_minutes":0}'
    return 0
  fi
  mins=$(( ($(now) - start) / 60 + 2 ))
  [ "$mins" -gt 0 ] || mins=2
  find "$dir" -name '*.jsonl' -type f -mmin "-$mins" -print 2>/dev/null |
    while IFS= read -r f; do grep -F '"usage"' "$f" 2>/dev/null; done |
    jq -R -c 'fromjson? // empty | select(.type == "assistant" and (.message.usage | type) == "object")
      | {rid: (.requestId // .message.id // .uuid), ts: .timestamp, m: (.message.model // ""), u: .message.usage}' 2>/dev/null |
    jq -n -c --argjson start "$start" --argjson end "$end" --argjson prices "$(cfg '.prices | tojson')" "$JQ_SCAN" 2>/dev/null |
    jq -c '. + {found: true}' 2>/dev/null || printf '{"found":false,"calls":0,"weight":0,"busy_minutes":0}'
}

# The last start record for <task>, or nothing.
last_start() {  # <task>
  [ -f "$RECORDS" ] || return 0
  jq -c --arg t "$1" 'select(.event == "start" and .task == $t)' "$RECORDS" 2>/dev/null | tail -1
}

family_of() {  # <model>
  local m
  m=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$m" in
    ''|default) cfg '.default_model' ;;
    *fable*) printf fable ;;
    *opus*) printf opus ;;
    *sonnet*) printf sonnet ;;
    *haiku*) printf haiku ;;
    *) printf other ;;
  esac
}
effort_of() {  # <effort>
  case "$1" in ''|default) cfg '.default_effort' ;; *) printf '%s' "$1" ;; esac
}

append_record() {  # <json>
  mkdir -p "$(dirname "$RECORDS")" || return 1
  printf '%s\n' "$1" >> "$RECORDS"
}

# --- pick -----------------------------------------------------------------------

# The account a live task runs on, and whether that was assumed.
task_account() {  # <backend> <id> <meta> <accounts-json>
  local acct moved
  moved=$(meta_get "$STATE/$2.usage-limit" moved_to)
  if [ "$1" = t3code ]; then
    acct=${moved:-$(meta_get "$3" t3_instance)}
  else
    acct=$(meta_get "$3" account)
  fi
  if [ -z "$acct" ]; then
    acct=$(last_start "$2" | jq -r '.account // empty' 2>/dev/null)
  fi
  # A task recorded before any of that: the account whose login folder holds
  # its most recently written transcript.
  [ -n "$acct" ] || acct=$(transcript_account "$(meta_get "$3" worktree)" "$4")
  if [ -n "$acct" ]; then
    printf '%s\tfalse' "$acct"
  elif [ "$1" = t3code ]; then
    printf '%s\ttrue' "$(fm_claude_login_standing_instance "$CONFIG" "$SCRIPT_DIR/fm-t3-mcp.mjs")"
  else
    printf 'ordinary\ttrue'
  fi
}

# The account whose login folder has the newest transcript for <worktree>.
transcript_account() {  # <worktree> <accounts-json>
  local wt=$1 enc id root newest best='' best_t=0
  [ -n "$wt" ] || return 0
  enc=$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')
  while IFS=$'\t' read -r id root; do
    [ -n "$id" ] || continue
    root=${root:-$HOME/.claude}
    [ -d "$root/projects/$enc" ] || continue
    newest=$(find "$root/projects/$enc" -name '*.jsonl' -type f -print0 2>/dev/null |
      xargs -0 stat -f %m 2>/dev/null | sort -n | tail -1)
    [ -n "$newest" ] || newest=$(find "$root/projects/$enc" -name '*.jsonl' -type f -print0 2>/dev/null |
      xargs -0 stat -c %Y 2>/dev/null | sort -n | tail -1)
    case "$newest" in ''|*[!0-9]*) continue ;; esac
    [ "$newest" -gt "$best_t" ] || continue
    best=$id
    best_t=$newest
  done <<EOF
$(printf '%s' "$2" | jq -r '.[] | [.id, .root] | @tsv' 2>/dev/null)
EOF
  printf '%s' "$best"
}

# True when the no-mistakes run for <branch> in <worktree> is executing.
pipeline_executing() {  # <worktree> <branch>
  local out status
  command -v no-mistakes >/dev/null 2>&1 || return 1
  [ -d "$1" ] || return 1
  out=$( cd "$1" 2>/dev/null && fm_run_timed 5 no-mistakes axi status 2>/dev/null </dev/null ) || return 1
  status=$(printf '%s\n' "$out" | awk -F, -v b="$2" '$2 == b { gsub(/"/, "", $3); print $3; exit }')
  case "$status" in pending|running|fixing|ci) return 0 ;; esac
  return 1
}

gather_running() {  # <backend> <task> <accounts-json> -> JSON array on stdout
  local backend=$1 task=$2 accounts=$3 meta id kind harness last state acct assumed start root wt spent fam eff mode
  local pipeline_acct items='[]'
  pipeline_acct=$(cfg '.pipeline_account // empty')
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$id" != "$task" ] || continue
    kind=$(meta_get "$meta" kind)
    case "$kind" in ship|scout) ;; *) continue ;; esac
    harness=$(meta_get "$meta" harness)
    [ "$harness" = claude ] || continue
    [ -z "$(meta_get "$meta" remote_host)" ] || continue
    last=$(awk 'NF { l = $0 } END { print l }' "$STATE/$id.status" 2>/dev/null)
    state=${last%%[ :]*}
    case "$state" in done|failed) continue ;; esac
    IFS=$'\t' read -r acct assumed <<EOF
$(task_account "$backend" "$id" "$meta" "$accounts")
EOF
    root=$(printf '%s' "$accounts" | jq -r --arg a "$acct" '.[] | select(.id == $a) | .root' 2>/dev/null)
    start=$(meta_get "$meta" spawn_gen)
    start=${start#s}
    start=${start%%.*}
    case "$start" in ''|*[!0-9]*) start=$(stat -f %m "$meta" 2>/dev/null || stat -c %Y "$meta" 2>/dev/null || now) ;; esac
    wt=$(meta_get "$meta" worktree)
    fam=$(family_of "$(meta_get "$meta" model)")
    eff=$(effort_of "$(meta_get "$meta" effort)")
    spent=0
    if printf '%s' "$accounts" | jq -e --arg a "$acct" 'any(.[]; .id == $a)' >/dev/null 2>&1; then
      spent=$(scan_usage "$root" "$wt" "$start" null | jq '.weight // 0' 2>/dev/null) || spent=0
    fi
    items=$(printf '%s' "$items" | jq -c --arg t "$id" --arg a "$acct" --arg k "$kind" --arg f "$fam" --arg e "$eff" \
      --argjson s "${spent:-0}" --argjson as "$assumed" --argjson st "$start" \
      '. + [{task: $t, account: $a, kind: $k, family: $f, effort: $e, spent: $s, assumed: $as, started: $st, source: "worker"}]')
    mode=$(meta_get "$meta" mode)
    if [ -n "$pipeline_acct" ] && [ "$mode" = no-mistakes ] && pipeline_executing "$wt" "$(meta_get "$meta" branch)"; then
      items=$(printf '%s' "$items" | jq -c --arg t "$id" --arg a "$pipeline_acct" \
        '. + [{task: ($t + " pipeline"), account: $a, kind: "pipeline", family: "opus", effort: "high", spent: 0, source: "pipeline"}]')
    fi
  done
  # Starts picked moments ago whose task record is not written yet; once the
  # record exists the task is counted from it above.
  if [ -f "$RECORDS" ]; then
    local row tid
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      tid=$(printf '%s' "$row" | jq -r '.task')
      [ ! -f "$STATE/$tid.meta" ] || continue
      items=$(printf '%s' "$items" | jq -c --argjson r "$row" 'if any(.[]; .task == $r.task) then . else . + [$r] end')
    done <<EOF
$(tail -n 400 "$RECORDS" | jq -c --arg t "$task" --argjson since "$(( $(now) - $(cfg '.pending_minutes') * 60 ))" \
  'select(.event == "start" and .ts >= $since and .task != $t) | {task, account, kind, family, effort, spent: 0, source: "pending"}' 2>/dev/null)
EOF
  fi
  printf '%s' "$items"
}

ensure_check_script() {
  [ -f "$CHECK_SCRIPT" ] && return 0
  mkdir -p "$STATE" || return 1
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Written by bin/fm-size.sh: wakes firstmate when a queued worker start is due.\n'
    printf 'FM_HOME=%q FM_STATE_OVERRIDE=%q FM_DATA_OVERRIDE=%q FM_CONFIG_OVERRIDE=%q exec %q due\n' \
      "$FM_HOME" "$STATE" "$DATA" "$CONFIG" "$SCRIPT_DIR/fm-size.sh"
  } > "$CHECK_SCRIPT.tmp.$$" && chmod +x "$CHECK_SCRIPT.tmp.$$" && mv "$CHECK_SCRIPT.tmp.$$" "$CHECK_SCRIPT"
}

cmd_pick() {
  local task='' kind='' model='' effort='' backend='' explicit=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task|--kind|--model|--effort|--backend|--account)
        [ "$#" -ge 2 ] || die "$1 needs a value"
        case "$1" in
          --task) task=$2 ;; --kind) kind=$2 ;; --model) model=$2 ;;
          --effort) effort=$2 ;; --backend) backend=$2 ;; --account) explicit=$2 ;;
        esac
        shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -n "$task" ] && [ -n "$backend" ] || die "pick needs --task and --backend"
  case "$kind" in ship|scout) ;; *) die "--kind must be ship or scout" ;; esac
  [ -f "$CONFIG_FILE" ] || return 0
  command -v jq >/dev/null 2>&1 || { echo "warning: worker sizing skipped: jq is not installed" >&2; return 0; }
  local t0 started family eff work accounts n i id plan root reading ts out decision account lines rc=0
  t0=$(now_ms)
  started=$(now)
  load_config
  family=$(family_of "$model")
  eff=$(effort_of "$effort")
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-size.XXXXXX") || { echo "warning: worker sizing skipped: no scratch directory" >&2; return 0; }
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT
  mkdir -p "$(dirname "$LOCK")"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait_max "$LOCK" 120 || { echo "warning: worker sizing skipped: another start held the sizing lock for 120 s" >&2; return 0; }

  # Resolve every account's login, then read them all at once.
  n=$(cfg '.accounts | length')
  i=0
  : > "$work/accounts.jsonl"
  while [ "$i" -lt "$n" ]; do
    id=$(cfg ".accounts[$i].id")
    plan=$(cfg ".accounts[$i].plan")
    if account_root "$backend" "$id"; then
      printf '%s\n' "$ACCT_ROOT" > "$work/root.$i"
      fm_claude_login_read "$ACCT_ROOT" "$(cfg '.max_age_seconds')s" "$(cfg '.read_seconds')" "$work/q.$i.json" &
    else
      printf '%s\n' "$ACCT_WHY" > "$work/why.$i"
    fi
    i=$((i + 1))
  done
  wait
  i=0
  while [ "$i" -lt "$n" ]; do
    id=$(cfg ".accounts[$i].id")
    plan=$(cfg ".accounts[$i].plan")
    root=''
    if [ -f "$work/why.$i" ]; then
      reading=$(jq -c -n --arg w "$(cat "$work/why.$i")" '{measured: false, why: $w}')
    else
      root=$(cat "$work/root.$i")
      if [ -s "$work/q.$i.json" ] && fm_quota_json_valid < "$work/q.$i.json" 2>/dev/null; then
        reading=$(jq -c "$JQ_READING" "$work/q.$i.json" 2>/dev/null) ||
          reading='{"measured":false,"why":"cannot read the quota-axi snapshot"}'
      elif command -v quota-axi >/dev/null 2>&1; then
        reading='{"measured":false,"why":"quota-axi could not measure it"}'
      else
        reading='{"measured":false,"why":"quota-axi is not installed"}'
      fi
    fi
    jq -c -n --arg id "$id" --arg plan "$plan" --arg root "$root" --argjson r "$reading" \
      '{id: $id, plan: $plan, root: $root, reading: $r}' >> "$work/accounts.jsonl"
    i=$((i + 1))
  done
  accounts=$(jq -c -s '.' "$work/accounts.jsonl")
  gather_running "$backend" "$task" "$accounts" > "$work/running.json"

  out=$(jq -c -n --argjson cfg "$CFG_JSON" --argjson acc "$accounts" --argjson run "$(cat "$work/running.json")" \
    --argjson now "$started" --arg explicit "$explicit" \
    --argjson req "$(jq -c -n --arg k "$kind" --arg f "$family" --arg e "$eff" --arg m "$model" '{kind: $k, family: $f, effort: $e, model: $m}')" \
    "$JQ_DECIDE" 2>&1) || {
    fm_lock_release "$LOCK"
    echo "warning: worker sizing skipped: the sizing step failed: $(printf '%s' "$out" | head -1)" >&2
    return 0
  }
  lines=$(printf '%s' "$out" | jq -r '.lines[]')
  printf '%s\n' "$lines" >&2
  decision=$(printf '%s' "$out" | jq -r '.decision.decision')
  account=$(printf '%s' "$out" | jq -r '.decision.account // empty')
  ts=$(now)
  local event=start at=''
  if [ "$decision" = queue ]; then
    event=queue
    at=$(printf '%s' "$out" | jq -r '.decision.at')
  fi
  append_record "$(printf '%s' "$out" | jq -c --arg event "$event" --argjson ts "$ts" --arg task "$task" --arg kind "$kind" \
    --arg model "$model" --arg family "$family" --arg effort "$eff" --arg backend "$backend" \
    --argjson ms "$(( $(now_ms) - t0 ))" --argjson nlines "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" '
    {event: $event, ts: $ts, task: $task, kind: $kind, model: $model, family: $family, effort: $effort, backend: $backend,
     class: (.class | {kind, model, effort, match, p75, p90, busy_p90}),
     decision: .decision.decision, account: .decision.account, why: .decision.why, warning: (.decision.warning // false),
     at: (.decision.at // null), estimate: .estimate,
     accounts: [.accounts[] | {id, plan, measured, fits, running, reading, checks}],
     running: [.running[] | {task, account, kind, family, effort, spent, source, assumed}],
     sizing_ms: $ms, lines: $nlines}')" ||
    echo "warning: could not append the worker sizing record to $RECORDS" >&2
  if [ "$decision" = queue ]; then
    mkdir -p "$QUEUE_DIR"
    printf 'at=%s\naccount=%s\nqueued=%s\nkind=%s\nmodel=%s\neffort=%s\n' "$at" "$account" "$ts" "$kind" "$model" "$eff" > "$QUEUE_DIR/$task"
    ensure_check_script || echo "warning: could not write $CHECK_SCRIPT; retry the start by hand" >&2
    rc=$QUEUED_EXIT
  else
    rm -f "$QUEUE_DIR/$task"
    printf '%s\n' "$account"
  fi
  fm_lock_release "$LOCK"
  return "$rc"
}

# --- finish -----------------------------------------------------------------------

cmd_finish() {
  local task=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -ge 2 ] || die "--task needs a value"; task=$2; shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -n "$task" ] || die "finish needs --task"
  command -v jq >/dev/null 2>&1 || return 0
  local start_rec
  start_rec=$(last_start "$task")
  [ -n "$start_rec" ] || return 0
  [ -f "$CONFIG_FILE" ] && load_config || CFG_JSON='{"prices":{"fable":[8,40],"opus":[4,20],"sonnet":[2,10]},"max_age_seconds":120,"t3_home":""}'
  local meta="$STATE/$task.meta" started backend account root wt usage reading limited window ended work
  started=$(printf '%s' "$start_rec" | jq -r '.ts')
  backend=$(printf '%s' "$start_rec" | jq -r '.backend')
  account=$(printf '%s' "$start_rec" | jq -r '.account // empty')
  wt=$(meta_get "$meta" worktree)
  ended=$(now)
  root=
  reading='{"measured":false,"why":"account not known"}'
  if [ -n "$account" ] && account_root "$backend" "$account"; then
    root=$ACCT_ROOT
    work=$(mktemp -d "${TMPDIR:-/tmp}/fm-size.XXXXXX") || work=
    if [ -n "$work" ]; then
      if fm_claude_login_read "$root" "$(cfg '.max_age_seconds // 120')s" 15 "$work/q.json"; then
        reading=$(jq -c "$JQ_READING" "$work/q.json" 2>/dev/null) || reading='{"measured":false,"why":"cannot read the snapshot"}'
      else
        reading='{"measured":false,"why":"quota-axi could not measure it"}'
      fi
      rm -rf "$work"
    fi
  fi
  usage=$(scan_usage "$root" "$wt" "$started" "$ended")
  limited=false
  window=
  if [ -f "$STATE/$task.usage-limit" ]; then
    limited=true
    window=$(meta_get "$STATE/$task.usage-limit" window)
  fi
  append_record "$(jq -c -n --argjson ts "$ended" --arg task "$task" --arg account "$account" --argjson started "$started" \
    --argjson usage "$usage" --argjson reading "$reading" --argjson limited "$limited" --arg window "$window" \
    --arg moved "$(meta_get "$STATE/$task.usage-limit" moved_to)" '
    {event: "finish", ts: $ts, task: $task, account: $account, duration_minutes: ((($ts - $started) / 60) | floor),
     usage: $usage, reading: $reading, cut_off: $limited,
     cut_off_window: (if $window == "" or $window == "-" then null else $window end),
     moved_to: (if $moved == "" then null else $moved end)}')" 2>/dev/null || true
  return 0
}

# --- due ----------------------------------------------------------------------------

cmd_due() {
  [ -d "$QUEUE_DIR" ] || return 0
  local f task at queued account t
  t=$(now)
  for f in "$QUEUE_DIR"/*; do
    [ -f "$f" ] || continue
    task=$(basename "$f")
    at=$(meta_get "$f" at)
    case "$at" in ''|*[!0-9]*) continue ;; esac
    [ "$at" -le "$t" ] || continue
    queued=$(meta_get "$f" queued)
    account=$(meta_get "$f" account)
    rm -f "$f"
    echo "check: worker sizing: queued start of $task is due${account:+ (expected to fit on $account)} after $(( (t - ${queued:-$t}) / 60 )) min; dispatch it again"
  done
  return 0
}

# --- report -------------------------------------------------------------------------

cmd_report() {
  local since=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --since)
        [ "$#" -ge 2 ] || die "--since needs a value"
        since=$(jq -n -r --arg s "$2" "$JQ_DEFS"'$s | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . + "T00:00Z" else . end | ep // empty')
        [ -n "$since" ] || die "--since must be YYYY-MM-DD or YYYY-MM-DDTHH:MMZ"
        shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -f "$RECORDS" ] || { echo "worker sizing: no records yet ($RECORDS)"; return 0; }
  [ -f "$CONFIG_FILE" ] && load_config || CFG_JSON='{"plans":{}}'
  jq -r -n --argjson since "$since" --argjson cfg "$CFG_JSON" "$JQ_DEFS"'
    [inputs | select(.ts >= $since)] as $r |
    ($r | map(select(.event == "start"))) as $starts |
    ($r | map(select(.event == "queue"))) as $queues |
    ($r | map(select(.event == "finish")) | map({key: .task, value: .}) | from_entries) as $fin |
    ($starts | map(select($fin[.task] != null) | . as $s | $fin[$s.task] as $f |
      {cls: "\($s.kind) \($s.family) \($s.effort)", est: $s.class.p90, p75: $s.class.p75, act: ($f.usage.weight // 0),
       found: ($f.usage.found // false), cut: $f.cut_off, minutes: $f.duration_minutes})) as $pairs |
    "worker sizing since \(if $since == 0 then "the first record" else ($since | iso) end):",
    "  starts \($starts | length) (\($starts | map(select(.decision == "explicit")) | length) explicit, \($starts | map(select(.warning)) | length) on an unmeasured account), queued \($queues | length), finished \($fin | length)",
    ($r | map(select(.sizing_ms != null))) as $sized |
    "  sizing step: median \(($sized | map(.sizing_ms) | pct(0.5) // 0) | round) ms, max \($sized | map(.sizing_ms) | max // 0) ms, median \(($sized | map(.lines) | pct(0.5) // 0) | round) lines printed",
    "  cut off by a usage limit: \($pairs | map(select(.cut)) | length) of \($pairs | length) finished\(if ($pairs | map(select(.cut)) | length) > 0 then " (" + ($pairs | map(select(.cut)) | map(.cls) | join(", ")) + ")" else "" end)",
    "  per class: n, estimate p90 / p75 weight, actual median / max weight, finished above the p90",
    ($pairs | group_by(.cls)[] | . as $g |
      "    \($g[0].cls): \($g | length), \($g[0].est | r1) / \($g[0].p75 | r1), \($g | map(.act) | pct(0.5) | r1) / \($g | map(.act) | max | r1), \($g | map(select(.act > .est)) | length) above\(if ($g | map(select(.found | not)) | length) > 0 then " (\($g | map(select(.found | not)) | length) without transcripts)" else "" end)"),
    ($queues | map(. as $q | ($starts | map(select(.task == $q.task and .ts >= $q.ts)) | first) as $s |
       {task, wait: (if $s then (($s.ts - $q.ts) / 60 | round) else null end), planned: ((($q.at - $q.ts) / 60) | round)}) as $w |
     "  queued starts: \($w | map(select(.wait != null)) | length) started later, waits median \($w | map(.wait // empty) | pct(0.5) // "-") min, max \($w | map(.wait // empty) | max // "-") min (planned median \($w | map(.planned) | pct(0.5) // "-") min); \($w | map(select(.wait == null)) | length) not started yet")
  ' "$RECORDS"
}

# --- refit --------------------------------------------------------------------------

cmd_refit() {
  local min=5 write=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --min) [ "$#" -ge 2 ] || die "--min needs a value"; min=$2; shift 2 ;;
      --write) write=1; shift ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  case "$min" in ''|*[!0-9]*) die "--min must be a whole number" ;; esac
  load_config || die "no $CONFIG_FILE to refit"
  [ -f "$RECORDS" ] || { echo "worker sizing refit: no records yet"; return 0; }
  local result
  result=$(jq -c -n --argjson min "$min" --slurpfile c "$CONFIG_FILE" "$JQ_DEFS"'
    [inputs] as $r |
    ($r | map(select(.event == "finish")) | map({key: .task, value: .}) | from_entries) as $fin |
    ($r | map(select(.event == "start" and $fin[.task] != null and ($fin[.task].usage.found // false))) | unique_by(.task)
      | map(. as $s | {kind: $s.kind, model: $s.family, effort: $s.effort, w: $fin[$s.task].usage.weight, busy: $fin[$s.task].usage.busy_minutes})
      | group_by([.kind, .model, .effort]) | map({kind: .[0].kind, model: .[0].model, effort: .[0].effort, n: length,
          p75: (map(.w) | pct(0.75) | . * 100 | round / 100), p90: (map(.w) | pct(0.9) | . * 100 | round / 100),
          busy_p90: (map(.busy) | pct(0.9) | round)})) as $fit |
    $c[0] as $cfg |
    ($cfg.classes | map(. as $old | ([$fit[] | select(.kind == $old.kind and .model == $old.model and .effort == $old.effort)] | first) as $f |
       if $f != null and $f.n >= $min then $old + {p75: $f.p75, p90: $f.p90, busy_p90: $f.busy_p90, n: $f.n, refit: true} else $old end)) as $kept |
    ($fit | map(select(.n >= $min) | . as $f | select(($cfg.classes | any(.kind == $f.kind and .model == $f.model and .effort == $f.effort)) | not) | $f + {refit: true})) as $new |
    {config: ($cfg + {classes: (($kept + $new) | map(del(.refit)))}),
     changes: ([$kept[] | select(.refit)] + $new | map("\(.kind) \(.model) \(.effort): n \(.n), p75 \(.p75), p90 \(.p90), busy_p90 \(.busy_p90)")),
     thin: ($fit | map(select(.n < $min) | "\(.kind) \(.model) \(.effort): \(.n) finished"))}' "$RECORDS") ||
    die "cannot refit from $RECORDS"
  printf '%s' "$result" | jq -r '
    if (.changes | length) == 0 then "worker sizing refit: no class has enough finished records yet"
    else "worker sizing refit:", (.changes[] | "  " + .) end,
    (if (.thin | length) > 0 then "  kept (too few records): " + (.thin | join("; ")) else empty end)'
  if [ "$write" = 1 ] && [ "$(printf '%s' "$result" | jq '.changes | length')" -gt 0 ]; then
    cp "$CONFIG_FILE" "$CONFIG_FILE.bak-$(now)" || die "cannot back up $CONFIG_FILE"
    printf '%s' "$result" | jq '.config' > "$CONFIG_FILE.tmp.$$" || die "cannot write $CONFIG_FILE"
    mv "$CONFIG_FILE.tmp.$$" "$CONFIG_FILE" || die "cannot write $CONFIG_FILE"
    echo "  written to $CONFIG_FILE (backup beside it)"
  fi
}

case "${1-}" in
  pick) shift; cmd_pick "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  due) shift; cmd_due "$@" ;;
  report) shift; cmd_report "$@" ;;
  refit) shift; cmd_refit "$@" ;;
  -h|--help|help) usage ;;
  *) die "usage: fm-size.sh pick|finish|due|report|refit (see --help)" ;;
esac

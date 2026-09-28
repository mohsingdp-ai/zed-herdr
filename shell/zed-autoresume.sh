# Run Claude Code from Zed terminals inside Herdr.
# Sourced from ~/.bashrc (interactive shells only).
#
# When a Herdr server is running, claude (or any agent Herdr supports) runs inside a Herdr pane (Herdr owns
# the PTY and agent status) and the Zed terminal just attaches to it. Closing
# the Zed thread closes the pane; quitting Zed keeps the agent running in
# Herdr, and the threads Zed restores reattach to those agents (_czr_restore).
# Renaming the Zed thread renames the Herdr pane. CZR_HERDR=0 disables this.

CZR_STATE=${XDG_STATE_HOME:-~/.local/state}/zed-herdr

_czr_in_zed() {
  # A Herdr pane can inherit Zed's env from whoever started the server.
  [[ -z ${HERDR_ENV:-} ]] || return 1
  [[ ${ZED_TERM:-} == true || ${TERM_PROGRAM:-} == zed || -n ${ZED_ENVIRONMENT:-} ]]
}

_czr_herdr() {
  command herdr ${CZR_HERDR_SESSION:+--session "$CZR_HERDR_SESSION"} "$@"
}

_czr_pty_guard() {
  # Wrap herdr attach in a pty guard that drops collapsed/dummy resize events
  # (e.g. cols=2 from inactive or hidden Zed sidebar threads), preventing them
  # from squishing the Herdr pane when viewed in full screen.
  local bin=$CZR_STATE/bin/czr-pty-guard
  local src=${BASH_SOURCE[0]%/*}/czr-pty-guard.c
  if [[ -f $src && ( ! -x $bin || $src -nt $bin ) ]] && command -v gcc >/dev/null; then
    mkdir -p "${bin%/*}"
    gcc -O2 "$src" -o "$bin" 2>/dev/null
  fi
  if [[ -x $bin ]]; then
    "$bin" herdr ${CZR_HERDR_SESSION:+--session "$CZR_HERDR_SESSION"} "$@"
  else
    _czr_herdr "$@"
  fi
}

herdr() {
  # A plain `herdr` (the TUI, outside Zed and Herdr) runs inside czr-pty-guard,
  # which sees its terminal's focus-in and resize events and then gives every
  # agent also shown in Zed herdr's pane size (czr-herdr-focus). Event driven
  # and works in any terminal with focus reporting. Everything else is as usual.
  if [[ $# -eq 0 && -z ${HERDR_ENV:-} ]] && ! _czr_in_zed; then
    CZR_FOCUS_HOOK=${BASH_SOURCE[0]%/*}/czr-herdr-focus _czr_pty_guard
  else
    command herdr "$@"
  fi
}

_czr_project() {
  # Zed project root this shell belongs to: the longest Zed project folder that
  # is $PWD or a parent of it. Falls back to $PWD.
  local db=${CZR_ZED_DB:-~/.local/share/zed/db/0-stable/db.sqlite} p best=""
  while IFS= read -r p; do
    [[ -n $p && ( $PWD == "$p" || $PWD == "$p"/* ) && ${#p} -gt ${#best} ]] && best=$p
  done < <(sqlite3 -readonly "$db" "select paths from workspaces where remote_connection_id is null" 2>/dev/null)
  echo "${best:-$PWD}"
}

_czr_herdr_start() {
  # agent args... -> prints the id of a new Herdr pane (in $PWD) running agent.
  # One Herdr workspace per Zed project, tagged zd_project=<root> (same tag the
  # zed-herdr sync script uses); each agent gets its own tab in it.
  [[ ${CZR_HERDR:-1} != 0 ]] && command -v herdr >/dev/null && command -v jq >/dev/null || return 1
  local root ws out pane cmd
  root=$(_czr_project)
  ws=$(_czr_herdr workspace list 2>/dev/null | jq -r --arg r "$root" --arg n "${root##*/}" '.result.workspaces as $w |
    first(($w[] | select(.tokens.zd_project == $r)), ($w[] | select(.tokens.zd_project == null and .label == $n)))
    | .workspace_id // empty') || return 1
  if [[ -n $ws ]]; then
    pane=$(_czr_herdr tab create --no-focus --workspace "$ws" --cwd "$PWD" --label "$1" | jq -r .result.root_pane.pane_id)
  else
    out=$(_czr_herdr workspace create --no-focus --cwd "$PWD" --label "${root##*/}") || return 1
    ws=$(jq -r .result.workspace.workspace_id <<<"$out")
    pane=$(jq -r .result.root_pane.pane_id <<<"$out")
  fi
  # Tag (or re-tag an adopted same-name workspace) so later lookups are exact.
  _czr_herdr workspace report-metadata "$ws" --source zed-herdr --token "zd_project=$root" >/dev/null 2>&1
  [[ -n $pane && $pane != null ]] || return 1
  # exec: the pane closes when the agent exits, which ends the Zed-side attach.
  printf -v cmd '%q ' "$@"
  # Start the agent at Zed's size, not herdr's: attach then changes nothing, so
  # the agent doesn't jump/redraw right after opening. Tiny sizes are skipped
  # (czr-pty-guard ignores them too).
  local rows cols
  read -r rows cols < <(stty size </dev/tty 2>/dev/null)
  (( ${cols:-0} >= 40 && ${rows:-0} >= 10 )) && cmd="stty rows $rows cols $cols; exec $cmd" || cmd="exec $cmd"
  _czr_herdr pane run "$pane" "$cmd" >/dev/null || return 1
  echo "$pane"
}

_czr_sync_name() {
  # pane - called each _czr_herdr_watch tick. Finds this thread's Zed row (the one whose
  # title matches what _czr_herdr_watch wrote, ignoring the animated first glyph),
  # copies a rename done in
  # Zed (custom_title) onto the Herdr pane, and names the Herdr tab what Zed
  # shows: that rename, else the agent's task title. Herdr notifications name
  # the tab, so they then match the Zed thread. Uses _czr_herdr_watch's db/tid/named/tab/tabbed.
  local t ct want
  t=$(cat "$CZR_STATE/title.${1//:/_}" 2>/dev/null)
  if [[ -z $tid && -n $t ]]; then
    # Compare after the first space: the leading "glyph " is an animation frame
    # (or Herdr's red dot) and Zed may still show the previous one. Everything
    # after it is stable. instr()/substr() are char-wise, so the emoji is safe.
    local suffix=${t#* }
    tid=$(sqlite3 -readonly "$db" "select terminal_id from sidebar_terminal_threads where substr(title, instr(title, ' ') + 1) = '${suffix//\'/\'\'}'")
    [[ $tid == *$'\n'* ]] && tid=""  # two threads show the same line; wait for a unique one
  fi
  if [[ -n $tid ]] && ct=$(sqlite3 -readonly "$db" "select coalesce(custom_title, '') from sidebar_terminal_threads where terminal_id = '$tid'") && [[ $ct != "$named" ]]; then
    # Empty only after a Zed name existed: Zed's name was cleared, clear Herdr's too.
    if [[ -n $ct ]]; then _czr_herdr pane rename "$1" "$ct"; else _czr_herdr pane rename "$1" --clear; fi >/dev/null
    named=$ct
  fi
  if [[ -n $named ]]; then
    want=$named
  else
    # t is "<frame> <task>" (working) or "<glyph> <status> · <task>".
    want=${t#* }
    case $want in
      blocked\ ·\ *|done\ ·\ *|idle\ ·\ *|unknown\ ·\ *) want=${want#* · } ;;
    esac
  fi
  [[ -n $want && $want != "$tabbed" ]] || return
  [[ -n $tab ]] || tab=$(_czr_herdr pane get "$1" | jq -r '.result.pane.tab_id // empty')
  [[ -n $tab ]] && _czr_herdr tab rename "$tab" "$want" >/dev/null && tabbed=$want
}

_czr_herdr_watch() {
  # pane tty shell-pid shell-start zed-pid zed-start
  # One background helper per attached agent (was two: title + reaper). Runs in
  # its own session, so it survives the hangup that kills the shell.
  #
  # Title: mirror Herdr's agent status into the tty's title, which is what Zed's
  # sidebar shows as the thread name. Herdr's attach doesn't forward titles, so
  # this listens to the server's own push stream (events.subscribe on the session
  # socket, same events Herdr's clients render from). While the agent works the
  # title is a spinning braille spinner + the task title; other states show
  # "<glyph> <status> · <task>". USR1 (sent when attach ends) stops the title.
  # ponytail: writes the tty alongside attach; a write can land mid-frame
  # (one-frame glitch). Upgrade: Herdr forwarding titles to attach clients.
  #
  # Close: clicking x on a Zed thread deletes its row from Zed's sidebar DB and
  # kills its shell together (measured: same 50ms tick): close the Herdr pane at
  # once. Zed quit/restart kills shells but keeps the rows, so the agent keeps
  # running in Herdr. Anything unclear keeps the agent.
  # ponytail: "a row vanished as our shell died" = our thread; a different thread
  # closed in that same instant would be taken as ours. Upgrade: Zed exposing its
  # terminal id to the shell.
  trap '' HUP
  exec >/dev/null 2>&1 </dev/null
  local db=${CZR_ZED_DB:-~/.local/share/zed/db/0-stable/db.sqlite} prev="" now i gone=0 tid="" named="" tab="" tabbed=""
  local q="select terminal_id from sidebar_terminal_threads" tick=0 t
  local sock status="" title="" agent="" line ev g cur rc shown="" fi=0
  local sfile=$CZR_STATE/size.${1//:/_}
  SUB_PID=""  # set by coproc; not local, coproc assigns it globally
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)  # braille spinner while working
  local tfile=$CZR_STATE/title.${1//:/_}
  _czr_rows_vanished() { now=$(sqlite3 -readonly "$db" "$q") && [[ -n $prev ]] && grep -qvxF -f <(printf '%s\n' "$now") <<<"$prev"; }
  _czr_title_stop() { [[ -n $SUB_PID ]] && kill "$SUB_PID"; SUB_PID=""; rm -f "$tfile"; }
  trap _czr_title_stop USR1
  trap '_czr_title_stop; exit' TERM
  if [[ -n $2 ]] && command -v socat >/dev/null; then
    sock=$(herdr session list --json | jq -r --arg s "${CZR_HERDR_SESSION:-}" \
      'first(.sessions[] | select(if $s == "" then .default else .name == $s end)) | .socket_path')
    if [[ -S $sock ]]; then
      coproc SUB { exec socat - "UNIX-CONNECT:$sock"; }
      jq -nc --arg p "$1" '{id: "zed-title", method: "events.subscribe", params: {subscriptions: [
        {type: "pane.agent_status_changed", pane_id: $p}, {type: "pane.updated"}, {type: "pane.closed"}]}}' >&"${SUB[1]}"
      # Subscribe first, then read current state, so no change falls in between.
      IFS=$'\t' read -r status agent title < <(_czr_herdr agent get "$1" |
        jq -r '.result.agent | [.agent_status, .agent // "agent", .terminal_title_stripped // ""] | @tsv')
    fi
  fi
  # Watch for our shell dying; note when any thread row vanishes (Zed may delete
  # the row a moment before or after it kills the shell).
  while :; do
    if [[ -n $SUB_PID ]]; then
      case $status in
        working) g=${frames[fi]} ;;
        blocked) g=✘ ;;  # heavy ballot X: the ✗ cross, bold
        done) g=✓ ;;
        idle) g=◯ ;;  # large circle: the ○, bigger
        *) g=· ;;
      esac
      if [[ $status == working ]]; then
        cur="$g ${title:-$agent}"  # spinner instead of the word "working"
      else
        cur="$g ${status:-unknown} · ${title:-$agent}"
      fi
      if [[ $cur != "$shown" ]]; then
        printf '\e]0;%s\a' "$cur" >"$2"
        # _czr_sync_name finds this thread's Zed row by it (Zed stores it as the title).
        printf '%s' "$cur" >"$tfile"
        shown=$cur
      fi
      IFS= read -t 0.2 -r line <&"${SUB[0]}"; rc=$?
      if (( rc > 128 )); then
        [[ $status == working ]] && fi=$(( (fi + 1) % ${#frames[@]} ))
      elif (( rc == 0 )); then
        ev=$(jq -r --arg p "$1" '
          if .error then "x"
          elif .data.pane.pane_id == $p then "t\t\(.data.pane.terminal_title_stripped // "")"
          elif .data.pane_id == $p and .data.agent_status then "s\t\(.data.agent_status)"
          elif .data.pane_id == $p and (.event | test("closed")) then "x"
          else "-" end' <<<"$line")
        case $ev in
          t$'\t'*) title=${ev#t$'\t'} ;;
          s$'\t'*) status=${ev#s$'\t'}; fi=0 ;;
          x) _czr_title_stop ;;
        esac
      else
        _czr_title_stop  # stream ended
      fi
    else
      sleep 0.2
    fi
    # Close/rename checks every 0.2s, however busy the event stream is.
    t=${EPOCHREALTIME/./}
    (( t - tick >= 200000 )) || continue
    tick=$t
    _czr_alive "$3" "$4" || break
    _czr_rows_vanished && gone=$t
    _czr_sync_name "$1"
    [[ -n ${now+x} ]] && prev=$now
  done
  _czr_title_stop
  rm -f "$sfile"
  [[ -n $5 ]] || return
  (( ${EPOCHREALTIME/./} - gone < 3000000 )) && { _czr_herdr pane close "$1"; return; }
  for i in {1..40}; do
    _czr_alive "$5" "$6" || return
    _czr_rows_vanished && { _czr_herdr pane close "$1"; return; }
    sleep 0.05
  done
}

_czr_claim() {
  # pane - mark the pane as shown by this shell, so no other restored thread
  # attaches it too. mkdir is atomic; a claim whose shell died is taken over.
  # The claim appears with its owner already inside (rename is atomic).
  local d=$CZR_STATE/claims/${1//:/_} tmp
  mkdir -p "$CZR_STATE/claims"
  tmp=$(mktemp -d "$CZR_STATE/claims/.new.XXXXXX") || return 1
  echo "$$ $(_czr_starttime $$)" >"$tmp/owner"
  mv -T "$tmp" "$d" 2>/dev/null && return
  if ! _czr_alive $(cat "$d/owner" 2>/dev/null); then
    rm -rf "$d"
    mv -T "$tmp" "$d" 2>/dev/null && return
  fi
  rm -rf "$tmp"
  return 1
}

_czr_restore() {
  # After a Zed restart, Zed reopens its threads as plain shells. Each Zed row
  # still titled with our status line (braille spinner, ✘, ✓, ◯ or ·;
  # ○/✗/❌/×, ◐◓◑◒ and ✢/●/🔴 are older ones) was
  # showing a Herdr agent, so while this project has more such rows than live
  # claims, attach this shell
  # to one of the project's Herdr agents that no thread shows.
  # ponytail: which restored thread gets which agent is first come; the title
  # then follows the agent, so names come out right. Exact match needs Zed
  # telling the shell its thread id.
  [[ ${CZR_HERDR:-1} != 0 ]] && command -v herdr >/dev/null && command -v jq >/dev/null || return
  local db=${CZR_ZED_DB:-~/.local/share/zed/db/0-stable/db.sqlite} root rows ws live=0 d pane
  root=$(_czr_project)
  rows=$(sqlite3 -readonly "$db" "select count(*) from sidebar_terminal_threads
    where folder_paths = '${root//\'/\'\'}' and substr(title, 1, 2) in
    ('⠋ ', '⠙ ', '⠹ ', '⠸ ', '⠼ ', '⠴ ', '⠦ ', '⠧ ', '⠇ ', '⠏ ',
     '✘ ', '✗ ', '❌ ', '◯ ', '○ ', '◐ ', '◓ ', '◑ ', '◒ ', '× ', '✓ ', '· ',
     '✢ ', '✳ ', '✶ ', '✻ ', '✽ ', '❌ ', '● ', '🔴 ')" 2>/dev/null)
  (( ${rows:-0} > 0 )) || return
  ws=$(_czr_herdr workspace list 2>/dev/null | jq -r --arg r "$root" \
    'first(.result.workspaces[] | select(.tokens.zd_project == $r)) | .workspace_id // empty')
  [[ -n $ws ]] || return
  for d in "$CZR_STATE/claims/${ws}_"*; do
    [[ -d $d ]] && _czr_alive $(cat "$d/owner" 2>/dev/null) && live=$((live + 1))
  done
  (( rows > live )) || return
  for pane in $(_czr_herdr agent list 2>/dev/null | jq -r --arg w "$ws" '.result.agents[] | select(.workspace_id == $w) | .pane_id'); do
    _czr_claim "$pane" && { _czr_herdr_attach "$pane"; return; }
  done
}

_czr_herdr_attach() {
  # Wait for Herdr to detect the agent, then show its live terminal here.
  local i rc t zpid wp
  mkdir -p "$CZR_STATE"
  _czr_claim "$1"
  for i in {1..40}; do
    _czr_herdr agent get "$1" >/dev/null 2>&1 && break
    sleep 0.25
  done
  t=$(tty 2>/dev/null)
  zpid=$(_czr_find_zed)
  # Own session: survives the hangup that kills this shell when the thread closes.
  wp=$( ( setsid bash -c 'source "$0"; _czr_herdr_watch "$@"' "${BASH_SOURCE[0]}" \
    "$1" "$t" $$ "$(_czr_starttime $$)" "$zpid" "${zpid:+$(_czr_starttime "$zpid")}" \
    </dev/null >/dev/null 2>&1 & echo $! ) )
  CZR_SIZE_FILE=$CZR_STATE/size.${1//:/_} _czr_pty_guard agent attach "$1"
  rc=$?
  # Keep the close watch if the pane still exists: attach can exit a moment before
  # the shell when the thread is being closed. The title stops either way.
  if _czr_herdr pane get "$1" >/dev/null 2>&1; then kill -USR1 "$wp"; else kill "$wp"; fi 2>/dev/null
  rm -rf "$CZR_STATE/claims/${1//:/_}"
  return "$rc"
}

_czr_ppid() {
  local s
  s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  s=${s##*) }
  set -- $s
  echo "$2"
}

_czr_starttime() {
  local s
  s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  s=${s##*) }
  set -- $s
  echo "${20}"
}

_czr_alive() {
  # pid [starttime] - starttime guards against pid reuse
  [[ -n ${1:-} ]] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  [[ -z ${2:-} ]] || [[ "$(_czr_starttime "$1")" == "$2" ]]
}

_czr_find_zed() {
  if [[ -n ${CZR_TEST_ZED_PID:-} ]]; then
    echo "$CZR_TEST_ZED_PID"
    return 0
  fi
  local p=$$ comm
  while [[ -n $p && $p -gt 1 ]]; do
    comm=$(cat "/proc/$p/comm" 2>/dev/null) || return 1
    case "$comm" in
      zed-editor|zed) echo "$p"; return 0 ;;
    esac
    p=$(_czr_ppid "$p")
  done
  return 1
}

claude() {
  # Upgrade Claude Code first when a newer release is out (defined in ~/.bashrc).
  declare -F _claude_update >/dev/null && _claude_update
  if ! _czr_in_zed || [[ -n ${CLAUDECODE:-} ]]; then
    command claude "$@"
    return
  fi
  # Pass through anything that isn't a plain interactive launch:
  # print mode, explicit session management, or CLI subcommands.
  local a
  for a in "$@"; do
    case "$a" in
      -p|--print|-c|--continue|-r|--resume|--resume=*|--session-id|--session-id=*|--fork-session|--from-pr|--from-pr=*|-v|--version|-h|--help|mcp|plugin|config|doctor|update|install|migrate-installer|setup-token)
        command claude "$@"
        return
        ;;
    esac
  done
  local pane
  pane=$(_czr_herdr_start claude "$@") || { command claude "$@"; return; }
  _czr_herdr_attach "$pane"
}

opencode() {
  if ! _czr_in_zed; then
    command opencode "$@"
    return
  fi
  # Only the TUI (optionally with a project path or flags) goes to Herdr;
  # subcommands like run/serve/auth and help/version run here as usual.
  local a
  for a in "$@"; do
    case "$a" in
      -h|--help|-v|--version|completion|acp|mcp|attach|run|debug|providers|auth|agent|upgrade|uninstall|serve|web|models|stats|export|import|github|pr|session|plugin|plug|db)
        command opencode "$@"
        return
        ;;
    esac
  done
  local pane
  pane=$(_czr_herdr_start opencode "$@") || { command opencode "$@"; return; }
  _czr_herdr_attach "$pane"
}

_czr_agent() {
  # kind args... - any other agent Herdr supports (kilo, codex, gemini, ...), like
  # opencode() above. Only a plain interactive launch goes to Herdr: help/version/
  # print flags, or a first word that isn't a directory (subcommand or prompt),
  # run here as usual.
  local kind=$1 a pane
  shift
  _czr_in_zed || { command "$kind" "$@"; return; }
  for a in "$@"; do
    case $a in -h|--help|-v|-V|--version|-p|--print) command "$kind" "$@"; return ;; esac
  done
  [[ -z ${1:-} || $1 == -* || -d $1 ]] || { command "$kind" "$@"; return; }
  pane=$(_czr_herdr_start "$kind" "$@") || { command "$kind" "$@"; return; }
  _czr_herdr_attach "$pane"
}

# One wrapper per agent kind Herdr supports (kind = executable name), read from
# Herdr itself so new kinds work without editing this file.
for _czr_k in $(herdr agent start --help 2>/dev/null | sed -n 's/.*\[possible values: \(.*\)\].*/\1/p' | tr -d ,); do
  declare -F "$_czr_k" >/dev/null || eval "function $_czr_k { _czr_agent $_czr_k \"\$@\"; }"
done
unset _czr_k

# A new interactive Zed shell may be a thread Zed restored after a restart.
# Checked once, at the first prompt, so the rest of ~/.bashrc has loaded.
_czr_restore_once() {
  local c keep=()
  for c in "${PROMPT_COMMAND[@]}"; do [[ $c == _czr_restore_once ]] || keep+=("$c"); done
  PROMPT_COMMAND=("${keep[@]}")
  _czr_restore
}
[[ $- == *i* ]] && _czr_in_zed && [[ -z ${CLAUDECODE:-} ]] && PROMPT_COMMAND=(_czr_restore_once "${PROMPT_COMMAND[@]}")

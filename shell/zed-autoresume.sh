# Run Claude Code from Zed terminals inside Herdr.
# Sourced from ~/.bashrc (interactive shells only).
#
# When a Herdr server is running, claude (or any agent Herdr supports) runs inside a Herdr pane (Herdr owns
# the PTY and agent status) and the Zed terminal just attaches to it. Closing
# the Zed thread closes the pane; quitting Zed keeps the agent running in
# Herdr, and the threads Zed restores reattach to those agents (_czr_restore).
# A thread shows its pane's name, and renaming the Zed thread renames the Herdr
# tab and pane. CZR_HERDR=0 disables this.

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
    # Build beside it and swap in: running guards keep the old file open.
    gcc -O2 "$src" -o "$bin.$$" 2>/dev/null && mv -f "$bin.$$" "$bin"
  fi
  if [[ -x $bin ]]; then
    "$bin" herdr ${CZR_HERDR_SESSION:+--session "$CZR_HERDR_SESSION"} "$@"
  else
    _czr_herdr "$@"
  fi
}

_czr_status_font() {
  # Installs czr-status.ttf (status icons in Herdr's colors, built by
  # czr-status-font.py) for Zed; succeeds once it's installed. Zed loads fonts
  # when it starts, so it needs one restart to show them.
  local src=${BASH_SOURCE[0]%/*}/czr-status.ttf dst=${XDG_DATA_HOME:-~/.local/share}/fonts/czr-status.ttf
  if [[ -f $src && ( ! -f $dst || $src -nt $dst ) ]]; then
    mkdir -p "${dst%/*}" && cp "$src" "$dst" && fc-cache -f "${dst%/*}" >/dev/null 2>&1
  fi
  [[ -f $dst ]]
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
  # shows: that rename, else the pane name (the agent's task title when the pane
  # has no name). Herdr notifications name
  # the tab, so they then match the Zed thread. Uses _czr_herdr_watch's db/tid/named/pname/tab/tabbed.
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
    named=$ct pname=$ct
  fi
  if [[ -n $named ]]; then
    want=$named
  else
    # t is "<glyph> <task>" (unknown status: "<glyph> unknown · <task>").
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
  # title is a spinning braille spinner + the pane name, other states the icon + the pane name;
  # unknown shows "<glyph> unknown · <pane name>". The pane name is what the user named it in
  # Herdr (else the agent's name); a pane without a name falls back to the
  # agent's task title. USR1 (sent when attach ends) stops the title.
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
  local sock status="" title="" agent="" aname="" pname="" line ev g cur rc shown="" fi=0
  local sfile=$CZR_STATE/size.${1//:/_}
  SUB_PID=""  # set by coproc; not local, coproc assigns it globally
  # Status icons: gray text symbols, or with the czr-status font installed
  # its colored ones (green ring idle, yellow spinner working, red ✕ blocked,
  # teal ✓ done; code points as in czr-status-font.py).
  local frames=(⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷) i_idle=● i_blocked=✘ i_done=✓ i_unknown=·
  if _czr_status_font; then
    frames=($'\U00100010' $'\U00100011' $'\U00100012' $'\U00100013' $'\U00100014' $'\U00100015' $'\U00100016' $'\U00100017')
    i_idle=$'\U00100000' i_blocked=$'\U00100001' i_done=$'\U00100002' i_unknown=$'\U00100003'
  fi
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
      IFS=$'\t' read -r status agent title aname < <(_czr_herdr agent get "$1" |
        jq -r '.result.agent | [.agent_status, .agent // "agent", .terminal_title_stripped // "", .name // ""] | @tsv')
      # The pane name: what it was renamed to in Herdr, else the agent's name.
      # It names this thread, so a thread restored to a named pane comes back
      # as that pane.
      IFS= read -r pname < <(_czr_herdr pane get "$1" | jq -r '.result.pane.label // ""')
      [[ -n $pname ]] || pname=$aname
    fi
  fi
  # Watch for our shell dying; note when any thread row vanishes (Zed may delete
  # the row a moment before or after it kills the shell).
  while :; do
    if [[ -n $SUB_PID ]]; then
      case $status in
        working) g=${frames[fi]} ;;
        blocked) g=$i_blocked ;;
        done) g=$i_done ;;
        idle) g=$i_idle ;;
        *) g=$i_unknown ;;
      esac
      if [[ $status == working || $status == idle || $status == blocked || $status == done ]]; then
        cur="$g ${pname:-${title:-$agent}}"  # the icon alone says the status
      else
        cur="$g ${status:-unknown} · ${pname:-${title:-$agent}}"
      fi
      if [[ $cur != "$shown" ]]; then
        printf '\e]0;%s\a' "$cur" >"$2"
        # _czr_sync_name finds this thread's Zed row by it (Zed stores it as the title).
        printf '%s' "$cur" >"$tfile"
        # Kept after the thread closes: _czr_restore matches a restored row by it.
        # ponytail: one small file per pane ever shown, never cleaned up.
        printf '%s' "$cur" >"$CZR_STATE/last.${1//:/_}"
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

_czr_own_row() {
  # db - prints this shell's Zed sidebar row: sets a unique title and waits for
  # a row to take it. Zed also runs panel/editor terminals, identical from
  # inside; those get no row, so this fails for them.
  local probe="· czr-$$-$RANDOM" row i
  for i in {1..40}; do
    # To the terminal: stdout is the caller's $(...). Again each time,
    # alternating so it changes: at Zed's start a thread's shell can run
    # before Zed listens to its title, and one set early would be missed.
    printf '\e]0;%s\a' "$probe$(( i % 2 ? 1 : 2 ))" >/dev/tty
    row=$(sqlite3 -readonly "$1" "select terminal_id from sidebar_terminal_threads where title in ('${probe}1', '${probe}2')" 2>/dev/null)
    [[ -n $row ]] && { echo "$row"; return; }
    sleep 0.1
  done
  return 1
}

_czr_restore() {
  # After a Zed restart, Zed reopens its threads as plain shells. A sidebar
  # thread (_czr_own_row) in a project with a Herdr agent no Zed terminal shows
  # takes it: the one its old title names (last.<pane>, kept by
  # _czr_herdr_watch), else any. Not by title alone: Zed saves titles lazily,
  # so a thread made shortly before a restart comes back with its shell's.
  [[ ${CZR_HERDR:-1} != 0 ]] && command -v herdr >/dev/null && command -v jq >/dev/null || return
  local db=${CZR_ZED_DB:-~/.local/share/zed/db/0-stable/db.sqlite} root d pane panes=() f row old
  root=$(_czr_project)
  # Old titles, read before the probe title replaces ours.
  old=$(sqlite3 -readonly "$db" "select terminal_id, title from sidebar_terminal_threads where folder_paths = '${root//\'/\'\'}'" 2>/dev/null)
  # A thread herdr-to-zed just opened: show the agent it queued for this
  # project. Only a sidebar thread takes it: the panel terminal Zed restores
  # as it opens the project starts about then too. mv is atomic, so only one
  # shell takes each. $PWD: a worktree Zed just opened may not be a saved Zed
  # project yet.
  for f in "$CZR_STATE"/show/*; do
    [[ -f $f ]] && [[ $(<"$f") == "$root" || $(<"$f") == "$PWD" ]] || continue
    [[ -n $row ]] || row=$(_czr_own_row "$db") || return
    mv "$f" "$f.$$" 2>/dev/null || continue
    rm -f "$f.$$"
    pane=${f##*/} pane=${pane/_/:}
    _czr_claim "$pane" && { _czr_herdr_attach "$pane"; return; }
  done
  [[ -n $old ]] || return  # no threads here before this shell
  # The project's agents no Zed terminal shows: those running in its folder
  # (herdr cuts long workspace tokens, so not matched by zd_project).
  for pane in $(_czr_herdr agent list 2>/dev/null | jq -r --arg r "$root" \
      '.result.agents[] | select(.cwd == $r or (.cwd | startswith($r + "/"))) | .pane_id'); do
    d=$CZR_STATE/claims/${pane//:/_}
    [[ -d $d ]] && _czr_alive $(cat "$d/owner" 2>/dev/null) || panes+=("$pane")
  done
  (( ${#panes[@]} )) || return
  [[ -n $row ]] || row=$(_czr_own_row "$db") || return
  old=$(sed -n "s/^$row|//p" <<<"$old")
  [[ -n $old ]] || return  # our row isn't one Zed had: not a thread
  for pane in "${panes[@]}"; do
    [[ $(cat "$CZR_STATE/last.${pane//:/_}" 2>/dev/null) == "$old" ]] && _czr_claim "$pane" && { _czr_herdr_attach "$pane"; return; }
  done
  for pane in "${panes[@]}"; do
    _czr_claim "$pane" && { _czr_herdr_attach "$pane"; return; }
  done
}

_czr_show_root() {
  # dir - the Zed project to show dir's agent in. A linked git worktree (e.g. a
  # Herdr worktree) is its own project, which Zed groups under the main repo;
  # else the Zed project dir is in, which would wrongly be ~ for
  # ~/.herdr/worktrees/... when ~ is open in Zed.
  local g c
  cd "$1" 2>/dev/null || return 1
  { read -r g && read -r c; } < <(git rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null)
  if [[ -n $g && $g != "$c" ]]; then git rev-parse --show-toplevel; else _czr_project; fi
}

_czr_zeditor() {
  # A Zed that this starts (none running) inherits this env. Drop Herdr's and
  # Claude Code's, or every Zed shell takes itself for a Herdr pane or a Claude
  # child and skips all of this.
  env $(compgen -e | grep -E '^(HERDR_|CLAUDE)' | sed 's/^/-u /') zeditor "$@"
}

_czr_kids() {
  # pid - sets KIDS to its child pids, from the kernel's list: no pgrep (it
  # scans all of /proc) and no subshells, as herdr-to-zed asks often.
  local f k
  KIDS=()
  for f in /proc/"$1"/task/*/children; do
    k=()
    read -r -a k 2>/dev/null <"$f"  # fails at the missing final newline, still reads
    KIDS+=("${k[@]}")
  done
}

_czr_zed_shells() {
  # Sets SHELLS to the pids of the shells Zed runs (its terminals).
  local z p c
  SHELLS=()
  [[ -n ${ZED_PIDS:-} ]] || ZED_PIDS=$(pidof zed-editor)  # herdr-to-zed resets it per run
  for z in $ZED_PIDS; do
    _czr_kids "$z"
    for p in "${KIDS[@]}"; do
      read -r c 2>/dev/null <"/proc/$p/comm" && [[ $c == bash ]] && SHELLS+=("$p")
    done
  done
}

herdr-to-zed() {
  # [project-dir] - show every Herdr agent (of that project only, if given; "."
  # = this one) that no Zed terminal shows yet: open its project in Zed,
  # start a terminal thread there (Zed keymap: ctrl-alt-shift-t ->
  # agent::NewTerminalThread) and let that shell's _czr_restore attach it.
  # Then closes the idle shells left in those projects (empty threads).
  # With Zed not running, it first drops Zed's saved threads in those projects
  # (not renamed ones): Zed would restore them as empty shells that start only
  # once clicked, out of reach. Each agent gets a fresh thread instead.
  # ponytail: Hyprland only (hyprctl sends the key); one agent at a time.
  command -v hyprctl >/dev/null && command -v zeditor >/dev/null && command -v jq >/dev/null \
    || { echo "herdr-to-zed: needs hyprctl, zeditor and jq" >&2; return 1; }
  local db=${CZR_ZED_DB:-~/.local/share/zed/db/0-stable/db.sqlite} pane cwd root name f t win i want="" n=0 z p r c=0 k
  local -A roots rootof
  local -a todo failed pending KIDS SHELLS
  local ZED_PIDS=""  # Zed's pids, found once (_czr_zed_shells)
  local pass
  if [[ -n ${1:-} ]]; then
    want=$(_czr_show_root "$1") || { echo "herdr-to-zed: no such directory: $1" >&2; return 1; }
  fi
  mkdir -p "$CZR_STATE/show"
  while IFS=$'\t' read -r pane cwd; do
    # The project it was last shown in (_czr_herdr_attach), even if since
    # removed from Zed: else Zed's nearest known folder could be a parent.
    root=$(cat "$CZR_STATE/root.${pane//:/_}" 2>/dev/null)
    [[ -d $root ]] || root=$(_czr_show_root "$cwd") || continue
    [[ -z $want || $root == "$want" ]] || continue
    roots[$root]=1 rootof[$pane]=$root
  done < <(_czr_herdr agent list | jq -r '.result.agents[] | [.pane_id, .cwd] | @tsv')
  if (( ${#roots[@]} )) && ! pidof zed-editor >/dev/null; then
    t=""
    for r in "${!roots[@]}"; do t+="${t:+,}'${r//\'/\'\'}'"; done
    sqlite3 "$db" "delete from sidebar_terminal_threads where custom_title is null and folder_paths in ($t); select changes()" |
      { read -r c; (( c == 0 )) || echo "dropped $c saved Zed thread(s)"; }
  fi
  # Two passes: a project Zed has to load afresh (e.g. one just removed from
  # it) can take longer than the waits below; the second pass finds it ready.
  todo=("${!rootof[@]}")
  for pass in 1 2; do
  failed=() pending=()
  for pane in "${todo[@]}"; do
    root=${rootof[$pane]}
    f=$CZR_STATE/claims/${pane//:/_}
    [[ -d $f ]] && _czr_alive $(cat "$f/owner" 2>/dev/null) && continue
    name=${root##*/}
    # After a Zed restart, a thread's shell starts only once its project is
    # opened, and that shell reattaches. So if Zed still has this agent's
    # thread, open the project and wait for it instead of adding a thread.
    # Compares after the first space: the leading glyph may be another frame.
    t=$(cat "$CZR_STATE/last.${pane//:/_}" 2>/dev/null) t=${t#* }
    # A shell already running in the project: Zed has started its threads, so
    # none will reattach on opening it. Straight to a new thread.
    _czr_zed_shells
    for z in "${SHELLS[@]}"; do [[ $(readlink "/proc/$z/cwd") == "$root"* ]] && t=""; done
    if [[ -n $t ]] && (( $(sqlite3 -readonly "$db" "select count(*) from sidebar_terminal_threads
        where folder_paths = '${root//\'/\'\'}' and substr(title, instr(title, ' ') + 1) = '${t//\'/\'\'}'" 2>/dev/null || echo 0) > 0 )); then
      # Its shell starts as the project opens, if it isn't running already
      # (then it won't reattach). No new shell there soon: add a thread instead.
      _czr_zed_shells; p=" ${SHELLS[*]} "
      _czr_zeditor "$root" >/dev/null 2>&1
      f=$CZR_STATE/claims/${pane//:/_}
      for i in {1..80}; do
        [[ -d $f ]] && _czr_alive $(cat "$f/owner" 2>/dev/null) && break
        if (( i == 30 )); then  # 1.5s: did Zed start a shell in the project?
          z=""
          _czr_zed_shells
          for z in "${SHELLS[@]}"; do
            [[ $p != *" $z "* && $(readlink "/proc/$z/cwd") == "$root"* ]] && break
            z=""
          done
          [[ -n $z ]] || break
        fi
        sleep 0.05
      done
      if [[ -d $f ]] && _czr_alive $(cat "$f/owner" 2>/dev/null); then
        echo "$pane -> $name (its thread)"
        n=$((n + 1))
        continue
      fi
    fi
    f=$CZR_STATE/show/${pane//:/_}
    _czr_zeditor "$root" >/dev/null 2>&1
    # Zed's window title starts with the project name once it has focus.
    # Just switched to it: give Zed a moment to load the project, or the new
    # terminal can miss the sidebar.
    win=""
    for i in {1..50}; do
      win=$(hyprctl activewindow -j | jq -r --arg n "$name" \
        'select(.class == "dev.zed.Zed" and (.title | startswith($n))) | .address')
      [[ -n $win ]] && break
      sleep 0.1
    done
    (( i > 1 )) && sleep 1.5
    # Queue the agent now, as the key goes out (see _czr_restore).
    _czr_zed_shells; p=" ${SHELLS[*]} "
    printf '%s' "$root" >"$f"
    # Down and up in one Lua call (Hyprland 0.55+), so up follows at once:
    # Zed, busy opening the thread, would take a late up for a held key and
    # repeat it (a second, empty thread).
    [[ -n $win ]] && hyprctl eval 'for _, s in ipairs({ "down", "up" }) do
        hl.dispatch(hl.dsp.send_key_state({ mods = "CTRL ALT SHIFT", key = "T", state = s })) end' >/dev/null 2>&1
    # Wait only until Zed has started the thread's shell (or a shell took the
    # agent), then go on: the shells load ~/.bashrc and take their agents in
    # parallel, checked below.
    for i in {1..100}; do
      [[ -e $f ]] || break
      _czr_zed_shells
      for z in "${SHELLS[@]}"; do
        [[ $p != *" $z "* && $(readlink "/proc/$z/cwd") == "$root"* ]] && break 2
      done
      sleep 0.02
    done
    pending+=("$pane")
  done
  for i in {1..200}; do
    t=""
    for pane in "${pending[@]}"; do [[ -e $CZR_STATE/show/${pane//:/_} ]] && t=1; done
    [[ -n $t ]] || break
    sleep 0.05
  done
  for pane in "${pending[@]}"; do
    f=$CZR_STATE/show/${pane//:/_} name=${rootof[$pane]##*/}
    if [[ -e $f ]]; then
      rm -f "$f"
      failed+=("$pane")
      (( pass == 1 )) || echo "! $pane ($name): no Zed terminal picked it up" >&2
    else
      # Taken by the new thread, or by an old one of the project that Zed
      # started when the project opened.
      echo "$pane -> $name"
      n=$((n + 1))
    fi
  done
  (( ${#failed[@]} )) || break
  todo=("${failed[@]}")
  done
  echo "$n agent(s) now shown in Zed"
  # Idle = nothing running in it. Only shells that set the ALRM trap below
  # (listed in closable/): bash catches ALRM itself too, so any other shell
  # would die of it, not exit 0, and Zed keeps a thread that died.
  for f in "$CZR_STATE"/closable/*; do
    [[ -f $f ]] && ! _czr_alive "${f##*/}" "$(<"$f")" && rm -f "$f"
  done
  _czr_zed_shells
  for p in "${SHELLS[@]}"; do
    _czr_kids "$p"
    [[ $p != "$$" && ${#KIDS[@]} == 0 ]] || continue
    [[ -f $CZR_STATE/closable/$p && $(<"$CZR_STATE/closable/$p") == "$(_czr_starttime "$p")" ]] || continue
    r=$(_czr_show_root "$(readlink "/proc/$p/cwd")") && [[ -n $r && -n ${roots[$r]-} ]] || continue
    # In a linked worktree, Zed drops the whole project when its last thread
    # closes, killing every terminal in it: keep one showing an agent there.
    if [[ $(git -C "$r" rev-parse --git-dir 2>/dev/null) != "$(git -C "$r" rev-parse --git-common-dir 2>/dev/null)" ]]; then
      t=""
      for z in "${SHELLS[@]}"; do  # a thread attached to an agent (_czr_herdr_attach)
        [[ $(readlink "/proc/$z/cwd") == "$r" ]] || continue
        _czr_kids "$z"
        for k in "${KIDS[@]}"; do
          read -r k 2>/dev/null <"/proc/$k/comm" && [[ $k == czr-pty-guard || $k == herdr || $k == tmux* ]] && t=1
        done
      done
      [[ -n $t ]] || continue
    fi
    kill -ALRM "$p" 2>/dev/null && c=$((c + 1))
  done
  (( c == 0 )) || echo "$c empty shell(s) closed"
}

_czr_herdr_attach() {
  # Wait for Herdr to detect the agent, then show its live terminal here.
  local i rc t zpid wp
  mkdir -p "$CZR_STATE"
  _czr_project >"$CZR_STATE/root.${1//:/_}"  # where it's shown, for herdr-to-zed
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
  if _czr_sidebar_ok "$1"; then
    _czr_sidebar "$1"
  else
    CZR_SIZE_FILE=$CZR_STATE/size.${1//:/_} _czr_pty_guard agent attach "$1"
  fi
  rc=$?
  # Keep the close watch if the pane still exists: attach can exit a moment before
  # the shell when the thread is being closed. The title stops either way.
  if _czr_herdr pane get "$1" >/dev/null 2>&1; then kill -USR1 "$wp"; else kill "$wp"; fi 2>/dev/null
  rm -rf "$CZR_STATE/claims/${1//:/_}"
  return "$rc"
}

_czr_sidebar_ok() {
  # pane - Claude Code has no side panel; claude-sidebar (context, cost, limits,
  # like OpenCode's) can be shown next to it. Claude only, wide terminals only,
  # not inside tmux. CZR_SIDEBAR=0 disables it.
  local cols
  [[ ${CZR_SIDEBAR:-1} != 0 && -z ${TMUX:-} ]] && command -v tmux >/dev/null && command -v claude-sidebar >/dev/null || return 1
  read -r _ cols < <(stty size </dev/tty 2>/dev/null)
  (( ${cols:-0} >= 110 )) || return 1
  [[ $(_czr_herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent // empty') == claude ]]
}

_czr_sidebar() {
  # pane - the attach, with claude-sidebar in a 32-column strip on its right.
  # tmux does the split: own server (-L czr), no config, no prefix key or status
  # bar, so keys go straight through. A click goes to the pane under it (the
  # sidebar opens the clicked agent) but keyboard focus stays on the agent.
  # The session ends with the attach, and
  # with the Zed terminal (destroy-unattached), so no attach is left behind.
  # ponytail: tmux sits between Zed and herdr; drop it if herdr's attach gains a side pane.
  local name=czr-${1//:/_}
  tmux -L czr kill-session -t "$name" 2>/dev/null
  tmux -L czr -f /dev/null new-session -s "$name" \
    env CZR_SIZE_FILE="$CZR_STATE/size.${1//:/_}" CZR_HERDR_SESSION="${CZR_HERDR_SESSION:-}" \
    bash -c 'source "$0"; _czr_pty_guard agent attach "$1"; tmux -L czr kill-session -t "$2"' \
    "${BASH_SOURCE[0]}" "$1" "$name" \; \
    set destroy-unattached on \; set status off \; set prefix None \; set mouse on \; \
    set -g default-terminal tmux-256color \; set -g focus-events on \; \
    set -s escape-time 0 \; set -s extended-keys on \; set -s set-clipboard on \; \
    set -as terminal-features ',*:RGB:extkeys:clipboard:focus' \; \
    bind -n MouseDown1Pane send-keys -M \; \
    set-hook window-layout-changed 'resize-pane -t :.1 -x 32' \; \
    split-window -h -d -l 32 claude-sidebar "pane-$1"
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
  _czr_busy=1
  _czr_restore
  unset _czr_busy
}
if [[ $- == *i* ]] && _czr_in_zed && [[ -z ${CLAUDECODE:-} ]]; then
  PROMPT_COMMAND=(_czr_restore_once "${PROMPT_COMMAND[@]}")
  # herdr-to-zed closes idle shells with ALRM: exit 0 closes the Zed thread.
  # ALRM, as bash at an idle prompt runs its trap at once (USR1/USR2 wait for Enter).
  trap '[[ -n ${_czr_busy-} ]] || exit 0' ALRM
  mkdir -p "$CZR_STATE/closable" && _czr_starttime $$ >"$CZR_STATE/closable/$$"
fi

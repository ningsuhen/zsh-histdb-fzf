#!/usr/bin/env zsh
FZF_HISTDB_FILE="${(%):-%N}"

HISTDB_FZF_LOGFILE=~/fzfhistlog
autoload -U colors && colors
histdb-fzf-query(){
  _histdb_init
  local -a opts

  zparseopts -E -D -a opts \
             s d t

  local where=""
  local everywhere=0
  for opt ($opts); do
      case $opt in
          -s)
              where="${where:+$where and} session in (${HISTDB_SESSION})"
              ;;
          -d)
              where="${where:+$where and} (places.dir like '$(sql_escape $PWD)%')"
              ;;
          -t)
              everywhere=1
              ;;
      esac
  done
  if [[ $everywhere -eq 0 ]];then
    where="${where:+$where and} places.host=${HISTDB_HOST}"
  fi

  local cols="history.id as id, commands.argv as argv, max(start_time) as max_start, exit_status"

  local mst="datetime(max_start, 'unixepoch')"
  local dst="datetime('now', 'start of day')"
  local timecol="strftime(case when $mst > $dst then '%H:%M' else '%d/%m' end, max_start, 'unixepoch', 'localtime') as time"

  local query="
select
id,
${timecol},
CASE exit_status WHEN 0 THEN '' ELSE '${fg[red]}' END || argv as cmd,
CASE exit_status WHEN 0 THEN '' ELSE '${reset_color}' END
from
(select
  ${cols}
from
  history
  left join commands on history.command_id = commands.id
  left join places on history.place_id = places.id
${where:+where ${where}}
group by history.command_id, history.place_id
order by max_start desc)
order by max_start desc"

  _histdb_query -separator '  ' "$query"
}

histdb-detail(){
  HISTDB_FILE=$1
  local where="(history.id == '$(sed -e "s/'/''/g" <<< "$2" | tr -d '\000')')"

  local cols="
    history.id as id,
    commands.argv as argv,
    max(start_time) as max_start,
    exit_status,
    duration as secs,
    count() as runcount,
    history.session as session,
    places.host as host,
    places.dir as dir"

  local query="
    select
      strftime('%d/%m/%Y %H:%M', max_start, 'unixepoch', 'localtime') as time,
      exit_status,
      secs,
      host,
      dir,
      session,
      argv as cmd
    from
      (select ${cols}
      from
        history
        left join commands on history.command_id = commands.id
        left join places on history.place_id = places.id
      where ${where} limit 1)
  "

  array=("${(@s/\t/)$(sqlite3 -cmd ".timeout 1000" "${HISTDB_FILE}" -separator "\t" "$query" )}")

  if [[ ! ${array[2]} ]];then
    #Color exitcode red if not 0
    array[2]=$(echo "\033[31m${array[2]}\033[0m")
  fi
  if [[ ${array[3]} -gt 300 ]];then
    # Duration red if > 5 min
    array[3]=$(echo "\033[31m${array[3]}\033[0m")
  elif [[ ${array[3]} -gt 60 ]];then
    # Duration yellow if > 1 min
    array[3]=$(echo "\033[33m${array[3]}\033[0m")
  fi

  printf "\033[1mLast run\033[0m\n\nTime:      %s\nStatus:    %s\nDuration:  %s sec.\nHost:      %s\nDirectory: %s\nSessionid: %s\nCommand:\n\n\033[1m%s\n\033[0m" "${array[@]}"
}

histdb-fzf-log() {
  if [[ ! -z ${HISTDB_FZF_LOGFILE} ]]; then
    if [[ ! -f ${HISTDB_FZF_LOGFILE} ]]; then
      touch ${HISTDB_FZF_LOGFILE}
    fi
    echo $* >> ${HISTDB_FZF_LOGFILE}
  fi
}

histdb-fzf-widget() {
  local selected num mode exitkey typ cmd_opts
  ORIG_FZF_DEFAULT_OPTS=$FZF_DEFAULT_OPTS
  query=${(qqq)LBUFFER}
  origquery=${LBUFFER}
  histdb-fzf-log "original query $query"
  modes=('session' 'loc' 'global')
  if [[ -z ${HISTDB_SESSION} ]];then
    mode=2
  else
    mode=1
  fi

  if [[ "${HISTDB_FZF_DEFAULT_MODE}" =~ [123] ]];then
    mode=${HISTDB_FZF_DEFAULT_MODE}
  fi

  histdb-fzf-log "Start mode ${modes[$mode]} ($mode)"
  exitkey='ctrl-r'
  setopt localoptions noglobsubst noposixbuiltins pipefail 2> /dev/null
  while [[ "$exitkey" != "" && "$exitkey" != "esc" ]]; do
    histdb-fzf-log "Exitkey $exitkey"
    if [[ $exitkey =~ "f." ]]; then
      mode=${exitkey[$(($MBEGIN+1)),$MEND]}
      histdb-fzf-log "mode changed to ${modes[$mode]} ($mode)"
    fi
    case "$modes[$mode]" in
      'session')
        cmd_opts="-s"
        typ="Session local history ${fg[blue]}${HISTDB_SESSION}${reset_color}"
        ;;
      'loc')
        cmd_opts="-d"
        typ="Directory local history ${fg[blue]}$(pwd)${reset_color}"
        ;;
      'global')
        cmd_opts="${HISTDB_FZF_GLOBAL_OPTS}"
        typ='global history'
        ;;
    esac
    mode=$((($mode % $#modes) + 1))
    histdb-fzf-log "mode changed to ${modes[$mode]} ($mode)"
    result=( "${(f@)$( histdb-fzf-query ${cmd_opts} |
      FZF_DEFAULT_OPTS="--height ${FZF_TMUX_HEIGHT:-40%} $ORIG_FZF_DEFAULT_OPTS --ansi --header='$typ
${bold_color}F1: session F2: directory F3: global${reset_color}' -n2.. --with-nth=2.. --tiebreak=index --expect='esc,ctrl-r,f1,f2,f3' --print-query --preview='source ${FZF_HISTDB_FILE}; histdb-detail ${HISTDB_FILE} {1}' --preview-window=right:${HISTDB_FZF_PREVIEW_WIDTH:-50}%:wrap --ansi --no-hscroll --query=${query} +m" $(__fzfcmd))}" )
    histdb-fzf-log "result was $result"
    histdb-fzf-log "returncode was $?"
    query=$result[1]
    exitkey=${result[2]}
    fzf_selected="${(j: :)${(@z)result[3]}[@]:2}"
    histdb-fzf-log "fzf_selected_test = ${(@z)result[3]}"
    histdb-fzf-log "fzf_selected_test = ${(@)result[3]}"
    histdb-fzf-log "fzf_selected_test = ${(qqqq)result[3]}"
    histdb-fzf-log "fzf_selected_test = ${result[3]}"
    histdb-fzf-log "fzf_selected_test = ${fzf_selected_test}"
    histdb-fzf-log "Query was      $query"
    histdb-fzf-log "Exitkey was    $query"
    histdb-fzf-log "fzf_selected = $fzf_selected $#fzf_selected"
    selected="${fzf_selected}"
    histdb-fzf-log "selected = $selected"
  done
  if [[ "$exitkey" == "esc" ]]; then
    LBUFFER=$origquery
  else
    LBUFFER=$selected
  fi
  histdb-fzf-log "set lbuffer = $LBUFFER"
  zle redisplay
  typeset -f zle-line-init >/dev/null && zle zle-line-init

  return $ret
}
zle     -N   histdb-fzf-widget

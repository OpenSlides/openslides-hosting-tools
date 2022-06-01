_os4instancectl()
{
  local cur prev opts diropts
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  opts="help ls add rm start stop update erase lock unlock autoscale manage"
  opts+=" --help --force --color --project-dir --fast --patient --no-pid-file --no-add-account --verbose"
  opts+=" --compose-template --config-template"
  opts+=" --long --metadata --online --offline --error --version --locked --unlocked"
  opts+=" --clone-from --local-only"
  opts+=" --tag --management-tool"
  opts+=" --migrations-finalize --migrations-no-ask"
  opts+=" --accounts --dry-run"
  opts+=" --action"
  diropts="ls|rm|start|stop|update|erase|lock|unlock|autoscale|manage|--clone-from"

  if [[ ${prev} =~ ${diropts} ]]; then
    COMPREPLY=( $(cd /srv/openslides/os4-instances && compgen -d -- ${cur}) )
    return 0
  fi

  if [[ ${prev} == --*template ]]; then
    _filedir
    return 0
  fi

  if [[ ${prev} =~ --management-tool|-O ]]; then
    _filedir
    return 0
  fi

  if [[ ${cur} == * ]] ; then
    COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
    return 0
  fi
}

complete -F _os4instancectl os4instancectl

# Generated from scripts/hb.sh by scripts/generate-hb-assets.sh.
# shellcheck shell=bash disable=SC2207
_hb() {
  local cur prev cmd subcmd

  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  if [ "$COMP_CWORD" -gt 0 ]; then
    prev="${COMP_WORDS[COMP_CWORD - 1]}"
  else
    prev=""
  fi
  cmd="${COMP_WORDS[1]:-}"
  subcmd="${COMP_WORDS[2]:-}"

  case "$cmd" in
    "")
      COMPREPLY=($(compgen -W "builder socktainer doctor help --help -h --version -V" -- "$cur"))
      return 0
      ;;
    builder)
      if [ "$COMP_CWORD" -eq 2 ]; then
        COMPREPLY=($(compgen -W "status logs test repair reset gc inspect ssh help" -- "$cur"))
        return 0
      fi

      case "$subcmd" in
        logs)
          case "$prev" in
            -n | --lines)
              return 0
              ;;
          esac

          if [ "$COMP_CWORD" -eq 3 ] && [ "${cur#-}" = "$cur" ]; then
            COMPREPLY=($(compgen -W "idle readiness boot" -- "$cur"))
            return 0
          fi

          COMPREPLY=($(compgen -W "-f --follow -n --lines <LINES> -h --help" -- "$cur"))
          return 0
          ;;
        help)
          COMPREPLY=($(compgen -W "status logs test repair reset gc inspect ssh" -- "$cur"))
          return 0
          ;;
        ssh)
          return 0
          ;;
      esac

      return 0
      ;;
    socktainer)
      if [ "$COMP_CWORD" -eq 2 ]; then
        COMPREPLY=($(compgen -W "status logs help" -- "$cur"))
        return 0
      fi

      case "$subcmd" in
        logs)
          COMPREPLY=($(compgen -W "-f --follow -h --help" -- "$cur"))
          return 0
          ;;
        help)
          COMPREPLY=($(compgen -W "status logs" -- "$cur"))
          return 0
          ;;
      esac

      return 0
      ;;
    doctor)
      if [ "$COMP_CWORD" -eq 2 ]; then
        COMPREPLY=($(compgen -W "runtime dns host help" -- "$cur"))
        return 0
      fi

      if [ "$subcmd" = help ]; then
        COMPREPLY=($(compgen -W "runtime dns host" -- "$cur"))
        return 0
      fi

      return 0
      ;;
    help)
      COMPREPLY=($(compgen -W "builder socktainer doctor" -- "$cur"))
      return 0
      ;;
  esac
}

complete -F _hb -o nosort hb

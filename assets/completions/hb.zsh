#compdef hb
# Generated from scripts/hb.sh by scripts/generate-hb-assets.sh.

local -a top_commands builder_commands builder_help_commands builder_log_targets builder_log_options
local -a socktainer_commands socktainer_help_commands socktainer_log_options
local -a doctor_commands doctor_help_commands

top_commands=('builder' 'socktainer' 'doctor' 'help' '--help' '-h' '--version' '-V')
builder_commands=('status' 'logs' 'test' 'repair' 'reset' 'gc' 'inspect' 'ssh' 'help')
builder_help_commands=('status' 'logs' 'test' 'repair' 'reset' 'gc' 'inspect' 'ssh')
builder_log_targets=('idle' 'readiness' 'boot')
builder_log_options=('-f' '--follow' '-n' '--lines' '-h' '--help')
socktainer_commands=('status' 'logs' 'help')
socktainer_help_commands=('status' 'logs')
socktainer_log_options=('-f' '--follow' '-h' '--help')
doctor_commands=('runtime' 'dns' 'host' 'help')
doctor_help_commands=('runtime' 'dns' 'host')

if ((CURRENT == 2)); then
  _describe 'command' top_commands
  return
fi

case "$words[2]" in
  builder)
    if ((CURRENT == 3)); then
      _describe 'builder command' builder_commands
      return
    fi

    case "$words[3]" in
      logs)
        if ((CURRENT == 4)) && [[ "$words[CURRENT]" != -* ]]; then
          _describe 'log target' builder_log_targets
          return
        fi
        _describe 'option' builder_log_options
        ;;
      help)
        _describe 'builder command' builder_help_commands
        ;;
      ssh)
        return
        ;;
    esac
    ;;
  socktainer)
    if ((CURRENT == 3)); then
      _describe 'socktainer command' socktainer_commands
      return
    fi

    case "$words[3]" in
      logs)
        _describe 'option' socktainer_log_options
        ;;
      help)
        _describe 'socktainer command' socktainer_help_commands
        ;;
    esac
    ;;
  doctor)
    if ((CURRENT == 3)); then
      _describe 'doctor command' doctor_commands
      return
    fi

    if [[ "$words[3]" == help ]]; then
      _describe 'doctor command' doctor_help_commands
    fi
    ;;
  help)
    _describe 'command' doctor_commands
    ;;
esac

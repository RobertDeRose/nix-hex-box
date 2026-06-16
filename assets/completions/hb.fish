# Generated from scripts/hb.sh by scripts/generate-hb-assets.sh.

complete -c hb -f
complete -c hb -n "not __fish_seen_subcommand_from builder socktainer doctor help" -a builder
complete -c hb -n "not __fish_seen_subcommand_from builder socktainer doctor help" -a socktainer
complete -c hb -n "not __fish_seen_subcommand_from builder socktainer doctor help" -a doctor
complete -c hb -n "not __fish_seen_subcommand_from builder socktainer doctor help" -a help

complete -c hb -n "__fish_seen_subcommand_from builder; and not __fish_seen_subcommand_from status logs test repair reset gc inspect ssh help" -a status
complete -c hb -n "__fish_seen_subcommand_from builder; and not __fish_seen_subcommand_from status logs test repair reset gc inspect ssh help" -a logs
complete -c hb -n "__fish_seen_subcommand_from builder; and not __fish_seen_subcommand_from status logs test repair reset gc inspect ssh help" -a test
complete -c hb -n "__fish_seen_subcommand_from builder; and not __fish_seen_subcommand_from status logs test repair reset gc inspect ssh help" -a repair
complete -c hb -n "__fish_seen_subcommand_from builder; and not __fish_seen_subcommand_from status logs test repair reset gc inspect ssh help" -a reset
complete -c hb -n "__fish_seen_subcommand_from builder; and not __fish_seen_subcommand_from status logs test repair reset gc inspect ssh help" -a gc
complete -c hb -n "__fish_seen_subcommand_from builder; and not __fish_seen_subcommand_from status logs test repair reset gc inspect ssh help" -a inspect
complete -c hb -n "__fish_seen_subcommand_from builder; and not __fish_seen_subcommand_from status logs test repair reset gc inspect ssh help" -a ssh
complete -c hb -n "__fish_seen_subcommand_from builder; and not __fish_seen_subcommand_from status logs test repair reset gc inspect ssh help" -a help
complete -c hb -n "__fish_seen_subcommand_from builder logs" -a "idle readiness boot"
complete -c hb -n "__fish_seen_subcommand_from builder logs" -l follow -s f
complete -c hb -n "__fish_seen_subcommand_from builder logs" -l lines -s n

complete -c hb -n "__fish_seen_subcommand_from socktainer; and not __fish_seen_subcommand_from status logs help" -a status
complete -c hb -n "__fish_seen_subcommand_from socktainer; and not __fish_seen_subcommand_from status logs help" -a logs
complete -c hb -n "__fish_seen_subcommand_from socktainer; and not __fish_seen_subcommand_from status logs help" -a help
complete -c hb -n "__fish_seen_subcommand_from socktainer logs" -l follow -s f

complete -c hb -n "__fish_seen_subcommand_from doctor; and not __fish_seen_subcommand_from runtime dns host help" -a runtime
complete -c hb -n "__fish_seen_subcommand_from doctor; and not __fish_seen_subcommand_from runtime dns host help" -a dns
complete -c hb -n "__fish_seen_subcommand_from doctor; and not __fish_seen_subcommand_from runtime dns host help" -a host
complete -c hb -n "__fish_seen_subcommand_from doctor; and not __fish_seen_subcommand_from runtime dns host help" -a help

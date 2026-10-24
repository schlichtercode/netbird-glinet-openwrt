-- Argument validation for the "netbird" RPC object is done inside the
-- object itself (strict whitelists per field); the generic GL pattern would
-- reject legitimate values such as URLs with "=" or tokens with "_".
return {
    set_config = true,
    action = true,
    get_log = true,
    get_status = true,
    get_config = true,
    run_watchdog = true,
    get_exit_state = true,
    get_networks = true,
    select_network = true,
}

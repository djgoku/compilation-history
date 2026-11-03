# Doctor

`doctor` tells an agent whether the selected Emacs server can run builds: history tracking enabled, interface enabled, the wait socket, the database path and the server's `server_name`. It never opens the database. When the selected server is missing or lacks the module, it names the sibling servers that have it.

## Sub-features

- `doctor-healthy` reports both modes enabled, a socket path, the database and `server_name`.
- `doctor-history-off` reports `history_enabled: false` while the interface stays enabled with its socket.
- `doctor-disabled` reports `interface_enabled: false` and `socket: null` after the interface is turned off.
- `doctor-selector` reports the `--server` value, or `COMPILATION_HISTORY_AGENT_SERVER` when no `--server` is given, as `server_selector`.
- `doctor-loaded-servers` exits 1 with `server_unavailable` or `interface_unavailable` and lists the sockets beside the selected one whose Emacs has the module in `loaded_servers`.

## How to get to it (user POV)

- Run `compilation-history-agent doctor`, optionally with `--server SOCKET` or `COMPILATION_HISTORY_AGENT_SERVER`.

## Driving it with cli.sh

Preconditions:

- A launched server and `DOCTOR OK`.

- **Healthy.** Run `$S/capture.sh doctor-healthy $S/cli.sh doctor`. Exit 0; `.protocol_version == 1`, `.history_enabled` and `.interface_enabled` are true, `.socket` starts with `$VERIFY_ROOT`, `.database` is `$VERIFY_ROOT/history.db`, `.server_selector` ends in `emacs-server/agent-test`, `.server_name == "agent-test"`.
- **Environment selector.** Run `COMPILATION_HISTORY_AGENT_SERVER="$VERIFY_ROOT/emacs-server/agent-test" $S/capture.sh doctor-env bin/compilation-history-agent doctor`. Exit 0; `.server_selector` is that path.
- **Missing server.** Run `$S/capture.sh doctor-missing $S/cli.sh --server "$VERIFY_ROOT/emacs-server/nope" doctor`; the later `--server` wins. Exit 1; `.error == "server_unavailable"`, `.loaded_servers` is `["$VERIFY_ROOT/emacs-server/agent-test"]`, and `.message` ends with `retry with --server set to an entry of loaded_servers`.
- **Disabled.** Run `$S/observe.sh '(compilation-history-agent-mode -1)'`, then `$S/capture.sh doctor-disabled $S/cli.sh doctor`. Exit 0; `.interface_enabled == false` and `.socket == null`. Restore with `$S/observe.sh '(compilation-history-agent-mode 1)'`.
- **History off.** Run `$S/observe.sh '(compilation-history-mode -1)'`, then `$S/capture.sh doctor-history-off $S/cli.sh doctor`. Exit 0; `.history_enabled == false`, `.interface_enabled == true`, `.socket` not null. A `start` now exits 1 with `history_unavailable`. Restore with `$S/observe.sh '(compilation-history-mode 1)'`.

## Gotchas

- Turning the interface off is done through `observe.sh` because the CLI has no command for it; this is setup, not the behavior under test.
- `doctor` reports server configuration. It does not prove a build can start; follow it with `run-and-wait`.

# Eggdrop Bot — Workspace Rules

## Project Overview
This workspace contains an Eggdrop IRC bot configuration and Tcl scripts. The bot runs on the Undernet IRC network.

## Language & Runtime
- All bot scripts are written in **Tcl** and executed by the Eggdrop process.
- Configuration is in `eggdrop.conf` (Tcl syntax).
- Scripts live in the `scripts/` directory and are sourced via `source` directives in `eggdrop.conf`.

## Coding Conventions
- Follow existing Tcl style: single-space indentation, `proc` naming with namespace-like prefixes (e.g. `fz:pubcom`).
- Use Eggdrop's built-in commands (`puthelp`, `putquick`, `putserv`, `pushmode`, `bind`, etc.) rather than raw socket I/O.
- Preserve all existing comments and header blocks when editing scripts.
- When adding new scripts, include a header comment block with author, version, date, and description.

## Safety Rules
- **Never** delete or overwrite `eggdrop.conf` without explicit user confirmation.
- **Never** remove scripts from `scripts/` without explicit user confirmation.
- When modifying bind commands, double-check flag requirements (`m`, `o`, `n`, `p`, etc.) to avoid accidentally granting public access to privileged commands.
- Bot credentials, passwords, and hostmasks in config files are sensitive — do not log or echo them.

## Testing
- Tcl scripts cannot be unit-tested in isolation; verify syntax with `tclsh` if available.
- After modifying scripts, remind the user to `.rehash` or restart the bot to pick up changes.

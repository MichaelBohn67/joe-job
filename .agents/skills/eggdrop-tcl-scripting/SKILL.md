---
name: eggdrop-tcl-scripting
description: >
  Expert guidance for writing, modifying, and debugging Eggdrop IRC bot Tcl scripts.
  Use this skill when creating or editing .tcl scripts in the scripts/ directory,
  working with eggdrop.conf, or troubleshooting Eggdrop bot behavior. Covers bind
  types, Eggdrop Tcl commands, channel management, user flags, and script structure.
---

# Eggdrop Tcl Scripting Skill

## When to Use
Activate this skill when:
- Creating a new Eggdrop Tcl script
- Modifying an existing `.tcl` script in `scripts/`
- Editing `eggdrop.conf` to source scripts or change bot settings
- Debugging Eggdrop bind/proc issues
- Working with user flags, channel modes, or ban management

## Eggdrop Fundamentals

### Script Loading
Scripts are loaded via `source` in `eggdrop.conf`:
```tcl
source scripts/myscript.tcl
```
After changes, the bot must be rehashed (`.rehash` on the partyline) or restarted.

### Bind Types
Common bind types used in this project:

| Bind Type | Description | Callback Signature |
|-----------|-------------|-------------------|
| `pub`     | Public channel command | `proc name {nick uhost hand chan arg}` |
| `pubm`    | Public message match (wildcard) | `proc name {nick uhost hand chan arg}` |
| `msg`     | Private message command | `proc name {nick uhost hand arg}` |
| `join`    | User joins channel | `proc name {nick uhost hand chan}` |
| `part`    | User parts channel | `proc name {nick uhost hand chan arg}` |
| `sign`    | User quits IRC | `proc name {nick uhost hand chan arg}` |
| `kick`    | User is kicked | `proc name {nick uhost hand chan target reason}` |
| `nick`    | User changes nick | `proc name {nick uhost hand chan newnick}` |
| `mode`    | Channel mode change | `proc name {nick uhost hand chan mc {victim ""}}` |
| `dcc`     | DCC/partyline command | `proc name {hand idx arg}` |

### User Flags
| Flag | Meaning |
|------|---------|
| `n`  | Global owner |
| `m`  | Global master |
| `o`  | Global op |
| `p`  | Global partyline access |
| `Q`  | Authenticated (custom, used by auth scripts) |
| `\|n` | Channel owner |
| `\|m` | Channel master |
| `\|o` | Channel op |

### Key Eggdrop Commands
- `puthelp "RAW IRC"` — Queue message (lowest priority)
- `putserv "RAW IRC"` — Queue message (medium priority)
- `putquick "RAW IRC"` — Queue message (highest priority)
- `pushmode <chan> <+/- mode> [target]` — Queue a mode change
- `flushmode <chan>` — Flush queued mode changes
- `botisop <chan>` — Check if bot has ops
- `isop <nick> <chan>` — Check if nick has ops
- `onchan <nick> <chan>` — Check if nick is on channel
- `chanlist <chan>` — List all nicks on channel
- `matchattr <hand> <flags> [chan]` — Check user flags
- `nick2hand <nick>` — Get handle from nick
- `getchanhost <nick> <chan>` — Get user@host for nick
- `maskhost <uhost>` — Generate a ban mask from user@host
- `newchanban <chan> <mask> <creator> <reason> <time>` — Add internal channel ban
- `chattr <hand> <flags> [chan]` — Change user attributes

## Script Structure Template
```tcl
##############################
# Script Name v1.0
# Author: <name>
# Date: <date>
# Description: <what it does>
##############################

# Configuration
set myscript(setting) "value"

# Binds
bind pub m|m !mycommand myscript:cmd

# Procedures
proc myscript:cmd {nick uhost hand chan arg} {
 global myscript
 # implementation
}

putlog "myscript.tcl v1.0 loaded."
```

## Additional Bind Types

| Bind Type | Description | Callback Signature |
|-----------|-------------|-------------------|
| `raw`     | Raw IRC server numeric/keyword | `proc name {from keyword text}` |
| `notc`    | Notice from user | `proc name {nick uhost hand text dest}` |
| `evnt`    | Eggdrop event (e.g. `init-server`) | `proc name {type}` |
| `time`    | Timed event (cron-like) | `proc name {min hour day month year}` |
| `ctcp`    | CTCP request | `proc name {nick uhost hand dest keyword arg}` |

## Namespace Pattern
For complex scripts, use Tcl namespaces to avoid variable collisions:
```tcl
namespace eval ::myscript {
    variable config
    set config(setting) "value"

    bind pub - !cmd [namespace current]::handler

    proc handler {nick uhost hand chan arg} {
        variable config
        # use $config(setting)
    }
}
```
See `auth.tcl` and `guard.tcl` for real examples of this pattern.

## Global Array Pattern
For simpler scripts, use a global array named after the script:
```tcl
set myscript_enabled 1
set myscript_timeout 30

proc myscript_handler {nick uhost hand chan arg} {
    global myscript_enabled myscript_timeout
    if {!$myscript_enabled} { return 0 }
    # ...
}
```
See `czura_spamban.tcl` and `czura_joincheck.tcl` for this pattern.

## Logging Pattern
Scripts that need their own log file should use this pattern:
```tcl
proc myscript_write_log {type chan nick uhost message} {
    global myscript_log_file
    if {$myscript_log_file eq ""} { return }
    set timestamp [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]
    set log_entry "\[$timestamp\] \[$type\]"
    if {$chan ne ""} { append log_entry " \[$chan\]" }
    if {$nick ne ""} {
        if {$uhost ne ""} {
            append log_entry " <$nick!$uhost>"
        } else {
            append log_entry " <$nick>"
        }
    }
    append log_entry " $message"
    # Create directory if needed
    set log_dir [file dirname $myscript_log_file]
    if {$log_dir ne "" && $log_dir ne "." && ![file isdirectory $log_dir]} {
        catch {file mkdir $log_dir}
    }
    if {[catch {
        set fd [open $myscript_log_file a]
        fconfigure $fd -translation auto
        puts $fd $log_entry
        close $fd
    } err]} {
        putlog "\[MyScript-Error\] Failed to write log: $err"
    }
}
```
Log files go in the `logs/` directory. Always use `putlog` as a fallback for Eggdrop's built-in logging.

## Ban/Kick Pattern
When banning and kicking a user:
```tcl
if {[botisop $chan]} {
    set hostname [lindex [split $uhost @] 1]
    set banmask "*!*@$hostname"
    # Set internal ban (tracked by Eggdrop) with duration in minutes
    newchanban $chan $banmask "ScriptName" "Ban reason" $ban_minutes
    # Apply the ban on IRC
    putquick "MODE $chan +b $banmask"
    # Kick the user
    putquick "KICK $chan $nick :Kick reason"
}
```
Always check `botisop` before attempting mode changes. Use `putquick` for ban/kick to ensure fast execution.

## Project-Specific Notes

### Bot Identity & Network
- **Network**: Undernet (`net-type 2`)
- **Nick**: `Johannes35` (alt: `Johannes??`)
- **Botnet nick**: `Johannes35`
- **Owner**: `Mike1967GER`
- **Username**: `johannes`
- **Listen port**: 3578 (all)

### Authentication
- The bot authenticates with Undernet's **X** service on connect via `auth.tcl`
- Auth uses namespace `services:auth:00201` and sends `login` command to `X@channels.undernet.org`
- Custom `Q` flag is used by `fzcommands.tcl` and `cmd_auth.tcl` for user authentication
- The configurable trigger character is stored in `fzcom(trigger)` (default `!`)

### Channels
The bot is configured to join these channels:
- `#gaysons4dads`
- `#boychat.de`
- `#gayfriends`
- `#gaysubs`

### Loaded Modules
`blowfish`, `channels`, `server`, `ctcp`, `irc`, `transfer`, `share`, `compress`, `notes`, `console`, `seen`, `uptime`

### Active Scripts (loaded in eggdrop.conf)
| Script | Purpose |
|--------|---------|
| `alltools.tcl` | Utility functions |
| `action.fix.tcl` | Action fix |
| `dccwhois.tcl` | Enhanced `.whois` for all users |
| `botops.tcl` | Bot ops management |
| `englishbar.tcl` | English bar script |
| `IRCguard.tcl` | IRC guard protection |
| `GreetLeave.tcl` | Greet/leave messages |
| `atvoice.tcl` | Auto-voice |
| `keeptopic1.5.tcl` | Topic persistence |
| `rehash.tcl` | Rehash utility |
| `guard.tcl` | Channel protection (namespace `::protection`, trigger `$`) |
| `pubcommands.tcl` | Channel settings via public commands (prefix `.`) |
| `czura_spamban.tcl` | Czura spam detection & banning |
| `czura_joincheck.tcl` | Czura spambot nick detection on join |
| `auth.tcl` | Undernet X authentication |
| `topicengine.tcl` | Topic engine |
| `uncut.tcl` | Uncut script |

### Command Prefixes
Different scripts use different command prefixes:
- `pubcommands.tcl`: `.` prefix (e.g. `.seen on`, `.bitch off`)
- `guard.tcl`: `$` prefix (e.g. `$deopall`, `$recover`)
- `czura_spamban.tcl`: `!spamban` command
- `fzcommands.tcl`: configurable via `fzcom(trigger)`, default `!`

### Ban Mask Types (from config)
The `ban-type` setting (currently `3`) controls ban mask format:
- `0`: `*!user@host`
- `1`: `*!*user@host`
- `2`: `*!*@host`
- `3`: `*!*user@*.host` (current setting)
- `4`: `*!*@*.host`
- Types 5–9 include the nick; types 10–29 use wildcard variants

### Key Config Values for Scripts
```tcl
set default-flags "hp"          ;# New users get +h +p
set global-chanmode "nt"        ;# Default channel modes
set global-ban-time 120         ;# Ban duration in minutes
set global-exempt-time 60       ;# Exempt duration in minutes
set nick-len 32                 ;# Max nick length
set max-bans 30                 ;# Max bans per channel
set max-modes 30                ;# Max modes per command
set learn-users 0               ;# No self-registration via hello
set msg-rate 2                  ;# Seconds between queued messages
```

### Flood Protection Defaults
```tcl
set global-flood-chan 15:60     ;# 15 msgs in 60 sec
set global-flood-deop 3:10
set global-flood-kick 3:10
set global-flood-join 5:60
set global-flood-ctcp 3:60
set global-flood-nick 5:60
```

## Script Development Checklist
1. Create the `.tcl` file in `scripts/`
2. Add configuration variables at the top
3. Add `bind` statements for commands/events
4. Implement procs with correct callback signatures
5. Add `putlog "scriptname.tcl vX.X loaded."` at the end
6. Add `source scripts/scriptname.tcl` to `eggdrop.conf`
7. Rehash the bot (`.rehash`) or restart it

## References
- [Eggdrop Tcl Commands](https://docs.eggheads.org/mainDocs/tcl-commands.html)
- [Eggdrop Bind Types](https://docs.eggheads.org/mainDocs/tcl-commands.html#bind-types)
- [Eggdrop Settings](https://docs.eggheads.org/mainDocs/settings.html)

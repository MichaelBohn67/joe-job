#
# czura_spamban.tcl - Czura Spam Detector & Banner for Eggdrop
#
# Detects the known "Madeleine Czura" multi-line spam and automatically
# sets a host-mask ban + kick on the spammer.
#
# Commands (in channel, requires +o flag):
#   !spamban status   - Show current status (enabled/disabled)
#   !spamban on       - Enable the spam detector
#   !spamban off      - Disable the spam detector
#   !spamban test     - List the patterns being watched
#
# DCC/partyline commands:
#   .spamban status|on|off|test
#
# Load: source scripts/czura_spamban.tcl   (in your eggdrop.conf)
#

# ---------------------------------------------------------------------------
# Script metadata
# ---------------------------------------------------------------------------
set czura_name    "CzuraSpamBan"
set czura_version "1.1"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Set to 1 to enable, 0 to disable
set czura_enabled 1

# How many seconds a user's messages are tracked before expiring
set czura_buffer_window 30

# Minimum number of distinct pattern hits from the same nick to trigger a ban
set czura_trigger_threshold 2

# Ban duration in minutes (0 = permanent)
set czura_ban_minutes 1440

# Ban style:
#   "host"          - Ban the host: *!*@host (Default)
#   "nick"          - Ban the nick: nick!*@*
#   "nickhost"      - Ban nick and host: nick!*@host
#   "nickuserhost"  - Ban nick, user, and host: nick!*user@host
set czura_ban_style "host"

# ---------------------------------------------------------------------------
# Logging Configuration
# ---------------------------------------------------------------------------
# Set to 1 to enable file logging, 0 to disable
set czura_log_enabled 1

# Path to the log file. Path is relative to Eggdrop root directory.
# Parent directories will be automatically created if they don't exist.
set czura_log_file "logs/czura_spamban.log"

# Set to 1 to log individual pattern matches (hits)
set czura_log_matches 1

# ---------------------------------------------------------------------------
# Spam patterns (case-insensitive Tcl regexps)
# Each entry: {regex} {human label}
# ---------------------------------------------------------------------------
set czura_patterns [list \
    {(?i)madeleine[\s._-]*czura}                                                    {name: Madeleine Czura} \
    {(?i)madd?y[\s._-]*czura}                                                       {name variant: Maddy Czura} \
    {(?i)maddyczura@gmail\.com}                                                      {email: maddyczura@gmail.com} \
    {(?i)madeleine\.czura@arcadis\.com}                                              {email: madeleine.czura@arcadis.com} \
    {(?i)peter\.czura@ntlworld\.com}                                                 {email: peter.czura@ntlworld.com} \
    {(?i)peter\.czura@corrigenda\.co\.uk}                                             {email: peter.czura@corrigenda.co.uk} \
    {(?i)peter[\s._-]*czura}                                                        {name: Peter Czura} \
    {(?i)\+44[\s-]*7599[\s-]*248[\s-]*843}                                           {phone: +44-7599248843} \
    {(?i)linkedin\.com/in/maddy[_-]?czura}                                           {linkedin} \
    {(?i)instagram\.com/maddy[_-]?czura}                                             {instagram} \
    {(?i)164\s*Plashet\s*Road}                                                       {address: 164 Plashet Road} \
    {(?i)8\s*Southampton\s*Road.*Fareham}                                            {address: 8 Southampton Road, Fareham} \
    {(?i)corrigenda\.co\.uk}                                                          {domain: corrigenda.co.uk} \
    {(?i)just\s+thought\s+i.?d\s+leave\s+my\s+number\s+here\s+in\s+case\s+you.?re\s+lonely} {spam phrase} \
]

# ---------------------------------------------------------------------------
# State: per-channel, per-nick rolling hit tracker
# czura_hits(network,channel,nick) = list of {timestamp pattern_index}
# ---------------------------------------------------------------------------
if {![info exists czura_hits]} {
    array set czura_hits {}
}

# Track whether the recurring cleanup timer has been started
if {![info exists czura_cleanup_timer_started]} {
    set czura_cleanup_timer_started 0
}

# ---------------------------------------------------------------------------
# Log writer: writes formatted log entries to the file
# ---------------------------------------------------------------------------
proc czura_write_log {type chan nick uhost message} {
    global czura_log_enabled czura_log_file

    # Log to file if enabled
    if {$czura_log_enabled && $czura_log_file ne ""} {
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

        set log_dir [file dirname $czura_log_file]
        if {$log_dir ne "" && $log_dir ne "." && ![file isdirectory $log_dir]} {
            catch {file mkdir $log_dir}
        }
        
        if {[catch {
            set fd [open $czura_log_file a]
            fconfigure $fd -translation auto
            puts $fd $log_entry
            close $fd
        } err]} {
            putlog "\002\[SpamBan-Error\]\002 Failed to write to log file $czura_log_file: $err"
        }
    }
}

# ---------------------------------------------------------------------------
# Cleanup: remove expired entries
# ---------------------------------------------------------------------------
proc czura_cleanup {} {
    global czura_hits czura_buffer_window

    set now [clock seconds]
    set expired [list]

    foreach key [array names czura_hits] {
        set kept [list]
        foreach entry $czura_hits($key) {
            lassign $entry ts idx
            if {($now - $ts) < $czura_buffer_window} {
                lappend kept $entry
            }
        }
        if {[llength $kept] == 0} {
            lappend expired $key
        } else {
            set czura_hits($key) $kept
        }
    }

    foreach key $expired {
        unset czura_hits($key)
    }
}

# ---------------------------------------------------------------------------
# Cleanup timer: keep stale hit state from accumulating
# ---------------------------------------------------------------------------
proc czura_cleanup_tick {} {
    global czura_cleanup_timer_started

    czura_cleanup

    if {!$czura_cleanup_timer_started} {
        return 0
    }

    timer 1 [list czura_cleanup_tick]
    return 0
}

proc czura_start_cleanup_timer {} {
    global czura_cleanup_timer_started

    if {!$czura_cleanup_timer_started} {
        set czura_cleanup_timer_started 1
        timer 1 [list czura_cleanup_tick]
    }
}

# ---------------------------------------------------------------------------
# Check if the bot is opped in a channel
# ---------------------------------------------------------------------------
proc czura_is_opped {chan} {
    return [botisop $chan]
}

# ---------------------------------------------------------------------------
# Ban and kick the spammer
# ---------------------------------------------------------------------------
proc czura_build_banmask {nick uhost} {
    global czura_ban_style

    set username [lindex [split $uhost @] 0]
    set hostname [lindex [split $uhost @] 1]
    set clean_user [string trimleft $username "~"]

    switch -nocase -- $czura_ban_style {
        "nick" {
            return "$nick!*@*"
        }
        "nickhost" {
            return "$nick!*@$hostname"
        }
        "nickuserhost" {
            return "$nick!*$clean_user@$hostname"
        }
        "host" -
        default {
            if {$hostname eq "" || ![string match "*.*" $hostname]} {
                putlog "\002\[SpamBan\]\002 Host '$hostname' looks incomplete, using user-based ban."
                czura_write_log "INFO" "" $nick $uhost "Host '$hostname' looks incomplete, using user-based ban"
                return "*!*$username@*"
            }

            return "*!*@$hostname"
        }
    }
}

proc czura_ban_kick {chan nick uhost} {
    global czura_ban_minutes

    set banmask [czura_build_banmask $nick $uhost]

    # Set the ban
    if {$czura_ban_minutes > 0} {
        newchanban $chan $banmask "CzuraSpamBan" "Spam detected (Czura spam)" $czura_ban_minutes
    } else {
        newchanban $chan $banmask "CzuraSpamBan" "Spam detected (Czura spam)"
    }
    putquick "MODE $chan +b $banmask"
    putquick "KICK $chan $nick :Spam detected (Czura spam) - banned"

    putlog "\002\[SpamBan\]\002 Banned $nick ($banmask) in $chan"
    czura_write_log "BAN" $chan $nick $uhost "Banned $nick ($banmask) in $chan (Duration: $czura_ban_minutes min)"
}

# ---------------------------------------------------------------------------
# Main message handler — bound to public messages via pubm
# ---------------------------------------------------------------------------
proc czura_on_pubmsg {nick uhost hand chan text} {
    global czura_enabled czura_patterns czura_hits czura_trigger_threshold czura_log_matches

    if {!$czura_enabled} { return 0 }

    # Protect ops: skip users who are opped on the channel or have +o in the
    # bot's userlist so they are never banned by the spam detector.
    if {[isop $nick $chan] || ([matchattr $hand o] || [matchattr $hand o|o $chan])} {
        return 0
    }

    set key "$chan,$nick"
    set now [clock seconds]
    set matched_any 0
    set pat_count [expr {[llength $czura_patterns] / 2}]

    for {set i 0} {$i < $pat_count} {incr i} {
        set pattern [lindex $czura_patterns [expr {$i * 2}]]

        if {[regexp -- $pattern $text]} {
            set matched_any 1
            set label [lindex $czura_patterns [expr {$i * 2 + 1}]]

            # Initialise tracker if needed
            if {![info exists czura_hits($key)]} {
                set czura_hits($key) [list]
            }

            # Check for duplicate pattern index in the current burst
            set already 0
            foreach entry $czura_hits($key) {
                if {[lindex $entry 1] == $i} {
                    set already 1
                    break
                }
            }

            if {!$already} {
                lappend czura_hits($key) [list $now $i]
            }

            if {$czura_log_matches} {
                czura_write_log "MATCH" $chan $nick $uhost "Matched pattern \"$label\" in message: \"$text\""
            }
        }
    }

    if {!$matched_any} { return 0 }

    # Clean up old entries
    czura_cleanup

    # Count unique pattern hits for this nick
    if {[info exists czura_hits($key)]} {
        set unique_indices [list]
        foreach entry $czura_hits($key) {
            set idx [lindex $entry 1]
            if {$idx ni $unique_indices} {
                lappend unique_indices $idx
            }
        }

        set hit_count [llength $unique_indices]

        if {$hit_count >= $czura_trigger_threshold} {
            putlog "\002\[SpamBan\]\002 Spam detected from $nick ($hit_count pattern hits) in $chan"
            czura_write_log "TRIGGER" $chan $nick $uhost "Spam threshold reached ($hit_count pattern hits)"

            if {[czura_is_opped $chan]} {
                czura_ban_kick $chan $nick $uhost
            } else {
                # Not opped - try to do a WHOIS to learn their real host,
                # and log instructions for manual ban
                putlog "\002\[SpamBan\]\002 Not opped in $chan - cannot ban $nick automatically"
                putlog "\002\[SpamBan\]\002 Attempting WHOIS on $nick for host info..."
                czura_write_log "WARNING" $chan $nick $uhost "Not opped in $chan - cannot ban $nick automatically"
                czura_write_log "WHOIS" $chan $nick $uhost "Attempting WHOIS on $nick for host info..."
                putquick "WHOIS $nick"
            }

            # Send explanation to the channel
            puthelp "PRIVMSG $chan :You are seeing those messages because our channel is being targeted by an automated spam bot running what is known as a Joe-Job - a malicious spam campaign designed to look like it was sent by a specific person, but actually created by an attacker to harass or ruin that person's reputation."
            # puthelp "PRIVMSG $chan :The messages you are seeing typically look something like this:"
            # puthelp "PRIVMSG $chan :\u201cHi Guys! It's Madeleine Czura! Just thought I'd leave my number here in case you're lonely ;) ...\u201d followed by a UK phone number, personal and professional email addresses, and social media links."

            # Clear this nick's tracker so we don't re-trigger
            if {[info exists czura_hits($key)]} {
                unset czura_hits($key)
            }
        }
    }

    return 0
}

# ---------------------------------------------------------------------------
# Public command handler:  !spamban <on|off|status|test>
# ---------------------------------------------------------------------------
proc czura_pub_cmd {nick uhost hand chan text} {
    global czura_enabled czura_hits czura_trigger_threshold czura_buffer_window czura_patterns

    set subcmd [string tolower [string trim $text]]

    switch -- $subcmd {
        "on" {
            set czura_enabled 1
            puthelp "PRIVMSG $chan :\002\[SpamBan\]\002 Spam detection ENABLED"
            putlog "\[SpamBan\] Enabled by $nick"
            czura_write_log "CMD" $chan $nick $uhost "Spam detection ENABLED via public command"
        }
        "off" {
            set czura_enabled 0
            puthelp "PRIVMSG $chan :\002\[SpamBan\]\002 Spam detection DISABLED"
            putlog "\[SpamBan\] Disabled by $nick"
            czura_write_log "CMD" $chan $nick $uhost "Spam detection DISABLED via public command"
        }
        "status" {
            if {$czura_enabled} {
                set state "ENABLED"
            } else {
                set state "DISABLED"
            }
            set tracked [llength [array names czura_hits]]
            puthelp "PRIVMSG $chan :\002\[SpamBan\]\002 Status: $state"
            puthelp "PRIVMSG $chan :\002\[SpamBan\]\002 Tracking $tracked nick(s)"
            puthelp "PRIVMSG $chan :\002\[SpamBan\]\002 Trigger: $czura_trigger_threshold pattern hits within ${czura_buffer_window}s"
        }
        "test" {
            puthelp "PRIVMSG $chan :\002\[SpamBan\]\002 Watching for these patterns:"
            set pat_count [expr {[llength $czura_patterns] / 2}]
            for {set i 0} {$i < $pat_count} {incr i} {
                set label [lindex $czura_patterns [expr {$i * 2 + 1}]]
                set num [expr {$i + 1}]
                puthelp "PRIVMSG $chan :  $num: $label"
            }
        }
        default {
            puthelp "PRIVMSG $chan :\002\[SpamBan\]\002 Usage: !spamban <on|off|status|test>"
        }
    }

    return 0
}

# ---------------------------------------------------------------------------
# DCC/partyline command:  .spamban <on|off|status|test>
# ---------------------------------------------------------------------------
proc czura_dcc_cmd {hand idx text} {
    global czura_enabled czura_hits czura_trigger_threshold czura_buffer_window czura_patterns

    set subcmd [string tolower [string trim $text]]

    switch -- $subcmd {
        "on" {
            set czura_enabled 1
            putdcc $idx "\[SpamBan\] Spam detection ENABLED"
            czura_write_log "CMD" "" $hand "" "Spam detection ENABLED via DCC command"
        }
        "off" {
            set czura_enabled 0
            putdcc $idx "\[SpamBan\] Spam detection DISABLED"
            czura_write_log "CMD" "" $hand "" "Spam detection DISABLED via DCC command"
        }
        "status" {
            if {$czura_enabled} {
                set state "ENABLED"
            } else {
                set state "DISABLED"
            }
            set tracked [llength [array names czura_hits]]
            putdcc $idx "\[SpamBan\] Status: $state"
            putdcc $idx "\[SpamBan\] Tracking $tracked nick(s)"
            putdcc $idx "\[SpamBan\] Trigger: $czura_trigger_threshold pattern hits within ${czura_buffer_window}s"
        }
        "test" {
            putdcc $idx "\[SpamBan\] Watching for these patterns:"
            set pat_count [expr {[llength $czura_patterns] / 2}]
            for {set i 0} {$i < $pat_count} {incr i} {
                set label [lindex $czura_patterns [expr {$i * 2 + 1}]]
                set num [expr {$i + 1}]
                putdcc $idx "  $num: $label"
            }
        }
        default {
            putdcc $idx "\[SpamBan\] Usage: .spamban <on|off|status|test>"
        }
    }

    return 0
}

# ---------------------------------------------------------------------------
# Register bindings
# ---------------------------------------------------------------------------

# Catch all public messages for spam scanning (wildcard match)
bind pubm - * czura_on_pubmsg

# !spamban command — requires +o flag (channel op in bot userlist)
bind pub o !spamban czura_pub_cmd

# .spamban partyline command — requires +o flag
bind dcc o spamban czura_dcc_cmd

czura_start_cleanup_timer

putlog "\002\[SpamBan\]\002 $czura_name v$czura_version loaded - Czura spam detection active"

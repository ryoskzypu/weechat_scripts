# SPDX-FileCopyrightText: 2025 ryoskzypu <ryoskzypu@proton.me>
#
# SPDX-License-Identifier: MIT-0
#
# histsearch_readline.pl — simulate GNU's Readline history search commands
#
# Description:
#   Simulate GNU's Readline history-search-backward and history-search-forward commands.
#   See:
#     https://wiki.archlinux.org/title/Readline#History
#     https://man.archlinux.org/man/readline.3#history~3
#
#   Commands:
#     /hslist
#       List keyboard keys that are currently bound to the /hist_search_backward
#       and /hist_search_forward commands.
#
# Bugs:
#   https://github.com/ryoskzypu/weechat_scripts
#
# History:
#   2025-05-25, ryoskzypu <ryoskzypu@proton.me>:
#     version 1.0: initial release (Idea by skejg, thanks)

use v5.26.0;

use strict;
use warnings;
use builtin qw< trim >;

# Debug data structures.
#use Data::Dumper qw< Dumper >;
#$Data::Dumper::Terse = 1;
#$Data::Dumper::Useqq = 1;

# Global variables

my %SCRIPT = (
    prog    => 'histsearch_readline',
    version => '1.0',
    author  => 'ryoskzypu <ryoskzypu@proton.me>',
    licence => 'MIT-0',
    desc    => "Simulate GNU's Readline history search commands",
);
my $PROG = $SCRIPT{'prog'};

# Config
my %conf;
my $conf_file;

# Return codes
my $OK  = weechat::WEECHAT_RC_OK;
my $ERR = weechat::WEECHAT_RC_ERROR;

# Command history
my %cmd_hist;
my @bwd_hist;

# Callback flags
my $backward   = 0;
my $forward    = 0;
my $input_pos  = 0;
my $search_pos = 0;
my $bwd_len    = 0;
my $first      = 0;

# Unique escape char
my $UNIQ_ESC = "\o{034}";

# Regexes
my $HS_CMD_RGX = qr{ \A/hist_search_(backward | forward)\z }x;

# Utils

# Print string on the weechat core buffer.
sub wprint
{
    my ($str) = @_;
    weechat::print('', $str);
}

# Update the current global history or local buffer history data.
sub update_cmdhist
{
    my ($buffer, $string, $mode) = @_;
    my $target;

    if ($mode eq 'global') {
        $buffer = '';
        $target = $mode;
    }
    # Local
    else {
        $target = $buffer;
    }
    #wprint('%cmd_hist = ' . Dumper \%cmd_hist);
    $cmd_hist{$target} = [];

    my $infolist = weechat::infolist_get('history', $buffer, '');

    while (weechat::infolist_next($infolist)) {
        # Get command and strip leading and trailing whitespace.
        my $cmd = trim(weechat::infolist_string($infolist, 'text'));
        push $cmd_hist{$target}->@*, $cmd;
    }
    weechat::infolist_free($infolist);

    return $target;
}

# Callbacks

# Init command history callback
#
# Initialize the command history hash.
sub init_cmdhist_cb
{
    my ($data, $option, $value) = @_;

    %cmd_hist = ();
    my $mode  = weechat::config_string($conf{'search_mode'});

    # Global history
    if ($mode eq 'global') {
        my %seen;
        my $infolist = weechat::infolist_get('history', '', '');

        while (weechat::infolist_next($infolist)) {
            my $cmd = trim(weechat::infolist_string($infolist, 'text'));
            push $cmd_hist{$mode}->@*, $cmd;
        }
        weechat::infolist_free($infolist);

        # Deduplicate the global command hist array.
        $cmd_hist{$mode} = [ grep { ! $seen{$_}++ } $cmd_hist{$mode}->@* ];
    }
    # Local buffer history
    else {
        # Get list of buffers.
        my $buffers = weechat::infolist_get('buffer', '', '');
        if (! $buffers) {
            wprint("${PROG}\tfailed to get list of buffers");
            return $ERR;
        }

        while (weechat::infolist_next($buffers)) {
            my %seen;
            my $buf_ptr  = weechat::infolist_pointer($buffers, 'pointer');
            my $infolist = weechat::infolist_get('history', $buf_ptr, '');

            while (weechat::infolist_next($infolist)) {
                my $cmd = trim(weechat::infolist_string($infolist, 'text'));
                push $cmd_hist{$buf_ptr}->@*, $cmd;
            }
            weechat::infolist_free($infolist);

            # Deduplicate the local buffer's command hist array.
            $cmd_hist{$buf_ptr} = [ grep { ! $seen{$_}++ } $cmd_hist{$buf_ptr}->@* ];
        }
        weechat::infolist_free($buffers);
    }

    #wprint('%cmd_hist = ' . Dumper \%cmd_hist);
    return $OK;
}

# History add callback
#
# Update the command history hash whenever a command is run.
sub history_add_cb
{
    my ($data, $modifier, $buffer, $string) = @_;

    my $mode   = weechat::config_string($conf{'search_mode'});
    my $target = update_cmdhist($buffer, $string, $mode);
    my %seen;

    # Add the command to history.
    $string = trim $string;
    unshift $cmd_hist{$target}->@*, $string;

    # Deduplicate the command hist array from the respective target mode.
    $cmd_hist{$target} = [ grep { ! $seen{$_}++ } $cmd_hist{$target}->@* ];
    #wprint('%cmd_hist = ' . Dumper \%cmd_hist);

    return $string;
}

# Remove local buffer callback
#
# Whenever a buffer is closed, remove its command history from the command history hash.
sub rm_localbuf_cb
{
    my ($data, $signal, $buffer) = @_;

    delete $cmd_hist{$buffer};
    #wprint('%cmd_hist = ' . Dumper \%cmd_hist);

    return $OK;
}

# Input display callback
#
# Get the current input cursor position.
sub input_display_cb
{
    my ($data, $modifier, $buffer, $string) = @_;

    $input_pos = weechat::buffer_get_integer($buffer, 'input_pos');
    return $string;
}

# Input content callback
#
# Replace the input contents at the cursor position with commands from history.
sub input_content_cb
{
    my ($data, $modifier, $buffer, $string) = @_;

    # Get the command string at the start of input line until the cursor position.
    my $partial = unpack "x0 a$input_pos", $string;

    # Simulate history-search-backward command.
    #
    # Search backward through the history for the string of characters between the
    # start of the current line and the current cursor position (the point). The
    # search string must match at the beginning of a history line. This is a non-
    # incremental search.
    if ($backward) {
        $backward = 0;
        my $mode  = weechat::config_string($conf{'search_mode'});
        my $target;

        $mode eq 'global' ? ($target = $mode)
                          : ($target = $buffer);

        if (exists $cmd_hist{$target}) {
            @bwd_hist = grep { /\A\Q$partial\E/ } $cmd_hist{$target}->@*;
            $bwd_len  = scalar @bwd_hist;
        }
        #wprint('%cmd_hist = ' . Dumper \%cmd_hist);
        #wprint('@bwd_hist = ' . Dumper \@bwd_hist);

        # Delete the unique escape char from input, so the cursor will stay in
        # position on subsequent backward searches.
        weechat::command('', '/input delete_previous_char');

        if (@bwd_hist) {
            # Ensure that the last command (0 index) is not ignored.
            if ($search_pos == 0 && ! $first) {
                $first = 1;
                ++$search_pos;

                return $bwd_hist[0];
            }

            ++$search_pos if (! $first && $search_pos + 1 < $bwd_len);
            $first = 0;

            # Replace input data with the command found in history.
            return $bwd_hist[$search_pos] if $bwd_hist[$search_pos];
        }

        # Remove the unique escape char from string if command was not found in history.
        $string =~ s/$UNIQ_ESC//;
        return $string;
    }
    # Simulate history-search-forward command.
    #
    # Search forward through the history for the string of characters between the start
    # of the current line and the point. The search string must match at the beginning
    # of a history line.  This is a non-incremental search.
    elsif ($forward) {
        $forward = 0;

        weechat::command('', '/input delete_previous_char');

        if (@bwd_hist) {
            --$search_pos if ($search_pos > 0);
            return $bwd_hist[$search_pos] if $bwd_hist[$search_pos];
        }

        $string =~ s/$UNIQ_ESC//;
        return $string;
    }

    # Reset
    @bwd_hist   = ();
    $bwd_len    = 0;
    $first      = 0;
    $search_pos = 0;

    return $string;
}

# History search backward callback
#
# When called, set the backward flags and trigger the input_content_cb() to process input data.
sub hs_backward_cb
{
    my ($data, $buffer, $args) = @_;

    $backward = 1;
    $forward  = 0;

    # Insert a unique \034 escape char (\x1c in hex) to trigger the input_content_cb().
    weechat::command('', '/input insert \x1c');

    return $OK;
}

# History search forward callback
#
# When called, set the forward flags and trigger the input_content_cb() to process
# input data.
sub hs_forward_cb
{
    my ($data, $buffer, $args) = @_;

    $backward = 0;
    $forward  = 1;

    weechat::command('', '/input insert \x1c');

    return $OK;
}

# List keyboard keys that are currently bound to the /hist_search_* commands.
sub hs_list_cb
{
    my ($data, $buffer, $args) = @_;
    my $PREFIX   = "hslist\t";
    my $infolist = weechat::infolist_get('key', '', 'default');
    my $found    = 0;

    wprint("${PREFIX}Current keyboard keys bound to /hist_search_* commands:");

    while (weechat::infolist_next($infolist)) {
        my $key = weechat::infolist_string($infolist, 'key');
        my $cmd = weechat::infolist_string($infolist, 'command');

        if ($cmd =~ $HS_CMD_RGX) {
            $found = 1;
            wprint("  '${key}' => '${cmd}'");

            next;
        }
    }
    weechat::infolist_free($infolist);

    wprint('  none') unless $found;
    return $OK;
}

# Set keybinds callback
#
# Check and set the keyboard binds.
sub set_keybinds_cb
{
    my ($data, $option, $value) = @_;

    my $key_bwd = weechat::config_string($conf{'hist_search_backward'});
    my $key_fwd = weechat::config_string($conf{'hist_search_forward'});

    my $info = <<~"END";
        ${PROG}\t
        ${PROG}\tNote that both backward and forward keybinds must be set, and the script reloaded after.
        ${PROG}\tE.g.
        ${PROG}\t  /set histsearch_readline.key.search_backward "ctrl-p"
        ${PROG}\t  /set histsearch_readline.key.search_forward  "ctrl-n"
        ${PROG}\t  /script reload histsearch_readline.pl
        ${PROG}\t
        ${PROG}\tKeys already bound to a command will be overwritten, and a warn displayed.
        ${PROG}\tIt is not safe to bind a key that do not start with a Ctrl or Meta key.
        ${PROG}\tTo insert a key name in the command line, use Alt+k, and then press the key to bind.
        ${PROG}\tSee '/fset _readline' and '/help key' for details.
        END

    if ($key_bwd eq '') {
        wprint("${PROG}\tkeybind for history-search-backward is not set");
        wprint($info);

        return $ERR;
    }
    if ($key_fwd eq '') {
        wprint("${PROG}\tkeybind for history-search-forward is not set");
        wprint($info);

        return $ERR;
    }

    # Unbind keys that were bound to a command other than /hist_search_* and inform the user.
    {
        my $infolist = weechat::infolist_get('key', '', 'default');

        while (weechat::infolist_next($infolist)) {
            my $key = weechat::infolist_string($infolist, 'key');
            my $cmd = weechat::infolist_string($infolist, 'command');

            if ($key =~ /\A(\Q$key_bwd\E | \Q$key_fwd\E)\z/xi && $cmd !~ $HS_CMD_RGX) {
                wprint("${PROG}\tkey '${key}' was bound to '${cmd}' command");
                weechat::key_unbind('default', $key);

                next;
            }
        }
        weechat::infolist_free($infolist);
    }

    # Set the keybinds.
    {
        weechat::key_bind('default', { $key_bwd => '/hist_search_backward' });
        weechat::key_bind('default', { $key_fwd => '/hist_search_forward' });
    }

    return $OK;
}

# Init and configuration

# Read config file from disk and update the $conf_file pointers.
sub config_read
{
    my $rc = weechat::config_read($conf_file);

    if ($rc != 0) {
        if ($rc == weechat::WEECHAT_CONFIG_READ_MEMORY_ERROR) {
            wprint('', "${PROG}\tnot enough memory to read config file");
        }
        elsif ($rc == weechat::WEECHAT_CONFIG_READ_FILE_NOT_FOUND) {
            wprint('', "${PROG}\tconfig file was not found");
        }
    }

    return $rc;
}

# Handle config errors.
sub chkconf
{
    my ($conf_ptr, $ptr, $type) = @_;

    if ($ptr eq '') {
        wprint('', "${PROG}\tfailed to create config $type");

        weechat::config_free($conf_ptr) if $conf_ptr ne '';
        return 1;
    }
}

# Create config file options of a section.
sub set_opts
{
    my ($conf, $sect, $options) = @_;
    my $opt;

    foreach my $i ($options->@*) {
        $opt = $i->{'option'};

        $conf{$opt} = weechat::config_new_option(
            $conf,
            $sect,
            $i->{'name'},
            $i->{'opt_type'},
            $i->{'desc'},
            $i->{'str_val'},
            $i->{'min_val'},
            $i->{'max_val'},
            $i->{'default'},
            $i->{'value'},
            $i->{'null_val'},
            '', '', '', '', '', '',
        );
    }

    return 1 if chkconf($conf_file, $conf{$opt}, "'${opt}' option");
}

sub config_init
{
    $conf_file = weechat::config_new($PROG, '', '');
    return 1 if chkconf('', $conf_file, 'file');

    # Keybind section
    {
        my $SECT       = 'key';
        my $sect_color = weechat::config_new_section($conf_file, $SECT, 0, 0, '', '', '', '', '', '', '', '', '', '');
        return 1 if chkconf($conf_file, $sect_color, "'${SECT}' section");

        # Options
        my @OPT = (
            {
                'option'   => 'hist_search_backward',
                'name'     => 'search_backward',
                'opt_type' => 'string',
                'desc'     => 'bind a keyboard key to search backward in command history',
                'str_val'  => '',
                'min_val'  => 0,
                'max_val'  => 0,
                'default'  => '',
                'value'    => '',
                'null_val' => 0,
            },
            {
                'option'   => 'hist_search_forward',
                'name'     => 'search_forward',
                'opt_type' => 'string',
                'desc'     => 'bind a keyboard key to search forward in command history',
                'str_val'  => '',
                'min_val'  => 0,
                'max_val'  => 0,
                'default'  => '',
                'value'    => '',
                'null_val' => 0,
            },
        );
        return 1 if set_opts($conf_file, $sect_color, \@OPT);
    }

    # Search section
    {
        my $SECT     = 'search';
        my $sect_dbg = weechat::config_new_section($conf_file, $SECT, 0, 0, '', '', '', '', '', '', '', '', '', '');
        return 1 if chkconf($conf_file, $sect_dbg, "'${SECT}' section");

        # Options
        my @OPT = (
            {
                'option'   => 'search_mode',
                'name'     => 'mode',
                'opt_type' => 'enum',
                'desc'     => 'search command in local buffer history or global history',
                'str_val'  => 'global|local',
                'min_val'  => 0,
                'max_val'  => 0,
                'default'  => 'local',
                'value'    => 'local',
                'null_val' => 0,
            },
        );
        return 1 if set_opts($conf_file, $sect_dbg, \@OPT);
    }

    #wprint('%conf = ' . Dumper \%conf);
    return 0;
}

# Main
if (weechat::register(
        $SCRIPT{'prog'},
        $SCRIPT{'author'},
        $SCRIPT{'version'},
        $SCRIPT{'licence'},
        $SCRIPT{'desc'},
        '',
        ''
    )) {
    # Initialize the script settings.
    {
        # Configuration file.
        return if config_init();
        return if config_read() != 0;

        # Set the keybinds.
        return if set_keybinds_cb() == $ERR;

        # Populate the command history.
        init_cmdhist_cb();
    }

    # Hooks
    {
        # Update an option when it changes.
        weechat::hook_config("${PROG}.key.search_*", 'set_keybinds_cb', '');  # Keybinds
        weechat::hook_config("${PROG}.search.mode",  'init_cmdhist_cb', '');  # Modes: global, local

        # Command-line
        weechat::hook_modifier('input_text_display', 'input_display_cb', '');
        weechat::hook_modifier('input_text_content', 'input_content_cb', '');
        weechat::hook_modifier('history_add', 'history_add_cb', '');
        weechat::hook_signal('buffer_closed', 'rm_localbuf_cb', '');

        # Commands
        #
        # Note that the hist-search-* commands are only used to associate the
        # binded keyboard keys to their respective callbacks.

        # hist-search-backward
        weechat::hook_command(
            'hist_search_backward',
            'search backward in command history',
            '',
            '',
            '',
            'hs_backward_cb',
            ''
        );

        # hist-search-forward
        weechat::hook_command(
            'hist_search_forward',
            'search forward in command history',
            '',
            '',
            '',
            'hs_forward_cb',
            ''
        );

        # hslist
        weechat::hook_command(
            'hslist',
            'list keyboard keys currently bound to the hist_search_backward/forward commands',
            'hslist',
            '',
            '',
            'hs_list_cb',
            ''
        );
    }
}

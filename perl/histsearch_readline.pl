# SPDX-FileCopyrightText: 2025 ryoskzypu <ryoskzypu@proton.me>
#
# SPDX-License-Identifier: MIT-0
#
# histsearch_readline.pl — simulate GNU Readline's history search commands
#
# Description:
#   Simulate GNU Readline's history-search-backward and history-search-forward
#   commands.
#   See:
#     https://wiki.archlinux.org/title/Readline#History
#     https://man.archlinux.org/man/readline.3#history~3
#
#   Commands:
#     /hslist
#       List the keyboard keys that are currently bound to the /hist_search_backward
#       and /hist_search_forward commands.
#
# Bugs:
#   https://github.com/ryoskzypu/weechat_scripts

use v5.26.0;

use strict;
use warnings;
#use feature qw< unicode_strings >;
#use Encode  qw< encode decode >;
use builtin qw< trim >;

# Debug data structures.
use Data::Dumper qw< Dumper >;
$Data::Dumper::Terse = 1;
$Data::Dumper::Useqq = 1;

# Global variables

my %SCRIPT = (
    prog    => 'histsearch_readline',
    version => '1.0',
    author  => 'ryoskzypu <ryoskzypu@proton.me>',
    licence => 'MIT-0',
    desc    => "Simulate GNU Readline's history search commands",
);
my $PROG = $SCRIPT{'prog'};

# Config
my %conf;
my $conf_file;

# Return codes
my $OK  = weechat::WEECHAT_RC_OK;
my $ERR = weechat::WEECHAT_RC_ERROR;

# Command history
my %command_hist;
my @backward_hist;

# Callback flags
my $backward   = 0;
my $forward    = 0;
my $input_pos  = 0;
my $search_pos = 0;
my $back_len   = 0;
my $first      = 0;

# Utils

# Print string on the weechat core buffer.
sub wprint
{
    my ($str) = @_;
    weechat::print('', $str);
}

# Update command history
#
# Update the current global history or local buffer history data.
sub update_cmdhist
{
    my ($buffer, $string, $mode) = @_;
    my $target;

    # Global
    if ($mode eq 'global') {
        $buffer = '';
        $target = $mode;
        $command_hist{$mode} = [];
    }
    # Local
    else {
        $target = $buffer;
        $command_hist{$buffer} = [];
    }
    wprint('%command_hist = ' . Dumper \%command_hist);

    my $infolist = weechat::infolist_get('history', $buffer, '');

    while (weechat::infolist_next($infolist)) {
        my $command = weechat::infolist_string($infolist, 'text');
        $command = trim $command;  # Strip leading and trailing whitespace.
        push @{ $command_hist{$target} }, $command;
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

    %command_hist = ();
    my %seen;
    my $mode = weechat::config_string($conf{'search_mode'});

    # Global history
    if ($mode eq 'global') {
        my $infolist = weechat::infolist_get('history', '', '');

        while (weechat::infolist_next($infolist)) {
            #my $fields = weechat::infolist_fields($infolist);
            my $command = weechat::infolist_string($infolist, 'text');
            $command = trim $command;
            push @{ $command_hist{$mode} }, $command;
        }

        # Deduplicate the global buffer's command hist array.
        $command_hist{$mode} = [ grep { ! $seen{$_}++ } $command_hist{$mode}->@* ];

        weechat::infolist_free($infolist);
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
            my $buffer_ptr = weechat::infolist_pointer($buffers, 'pointer');

            my $infolist = weechat::infolist_get('history', $buffer_ptr, '');

            while (weechat::infolist_next($infolist)) {
                #my $fields = weechat::infolist_fields($infolist);
                my $command = weechat::infolist_string($infolist, 'text');
                $command = trim $command;
                push @{ $command_hist{$buffer_ptr} }, $command;
            }

            # Deduplicate the buffer's command hist array.
            $command_hist{$buffer_ptr} = [ grep { ! $seen{$_}++ } $command_hist{$buffer_ptr}->@* ];

            weechat::infolist_free($infolist);
        }

        weechat::infolist_free($buffers);
    }

    wprint('%command_hist = ' . Dumper \%command_hist);
    return $OK;
}

# History add callback
#
# Update the command history hash when a command is run.
sub history_add_cb
{
    my ($data, $modifier, $buffer, $string) = @_;
    my $mode = weechat::config_string($conf{'search_mode'});
    my %seen;

    my $input = <<~_;
        \$modifier: '${modifier}'
        \$buffer:   '${buffer}'
        \$string:   '${string}'
        _

    wprint($input);

    my $target = update_cmdhist($buffer, $string, $mode);

    # Add the command to history.
    $string = trim $string;
    unshift @{ $command_hist{$target} }, $string;

    # Deduplicate the command hist array from respective target mode.
    $command_hist{$target} = [ grep { ! $seen{$_}++ } $command_hist{$target}->@* ];
    wprint('%command_hist = ' . Dumper \%command_hist);

    return $string;
}

# Input display callback
#
# Get the current input cursor position.
sub input_display_cb
{
    my ($data, $modifier, $buffer, $string) = @_;

    $input_pos = weechat::buffer_get_integer($buffer, 'input_pos');

    my $input = <<~_;
        \$modifier: '${modifier}'
        \$buffer:   '${buffer}'
        \$string:   '${string}'
        \$input_pos: $input_pos
        \$backward:  $backward
        \$forward:   ${forward}\n
        _

    wprint($input);

    return $string;
}

# Input content callback
#
# Replace the input contents at the cursor position with commands from history.
sub input_content_cb
{
    my ($data, $modifier, $buffer, $string) = @_;

    my $input = <<~_;
        \$modifier:  $modifier
        \$buffer:    ${buffer}
        \$string:   '${string}'
        \$backward:  $backward
        \$forward:   ${forward}\n
        _

    #wprint($input);

    # Get the command string at the start of input line until the cursor position.
    my $partial = unpack "x0 a$input_pos", $string;
    wprint("\$partial: '${partial}'");

    # Simulate history-search-backward command.
    #
    # Search backward through the history for the string of characters between the
    # start of the current line and the current cursor position (the point). The
    # search string must match at the beginning of a history line. This is a non-
    # incremental search.
    if ($backward) {
        $backward = 0;

        my $mode = weechat::config_string($conf{'search_mode'});

        $mode eq 'global' ? (@backward_hist = grep { /\A\Q$partial\E/ } $command_hist{$mode}->@*)
                          : (@backward_hist = grep { /\A\Q$partial\E/ } $command_hist{$buffer}->@*);

        $back_len = scalar @backward_hist;

        wprint("\$search_pos: $search_pos");
        wprint("\$back_len:   $back_len");
        wprint('@backward_hist = ' . Dumper \@backward_hist);

        # Delete the unique \034 char from input, so the cursor will stay in position
        # on subsequent backward searches.
        weechat::command('', '/input delete_previous_char');

        if (@backward_hist) {
            # Ensure that the last command (0 index) is not ignored.
            if ($search_pos == 0 && ! $first) {
                $first = 1;
                ++$search_pos;

                return $backward_hist[0];
            }

            ++$search_pos if ($search_pos + 1 < $back_len);
            wprint("\$search_pos: $search_pos");

            # Replace input data with the command found in history.
            return $backward_hist[$search_pos] if $backward_hist[$search_pos];
        }

        # Remove the unique \034 char from string if command was not found in history.
        $string =~ s/\x{1c}//;
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

        if (@backward_hist) {
            --$search_pos if ($search_pos > 0);
            wprint("\$search_pos: $search_pos");

            return $backward_hist[$search_pos] if $backward_hist[$search_pos];
        }

        $string =~ s/\x{1c}//;
        return $string;
    }

    # Reset
    @backward_hist = ();
    $back_len      = 0;
    $first         = 0;
    $search_pos    = 0;

    return $string;
}

# History search backward callback
#
# When called, set the backward flags and trigger the input_content_cb() to process
# input data.
sub hs_backward_cb
{
    my ($data, $buffer, $args) = @_;
    $backward = 1;
    $forward  = 0;

    my $info = <<~_;
        hs_backward_cb():
          \$buffer:    $buffer
          \$args:     '${args}'
          \$backward:  $backward
          \$forward:   ${forward}\n
        _

    wprint($info);
    wprint('Ctrl+p was pressed');
    wprint('');

    # Insert a unique \034 char to trigger the input_content_cb().
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

    my $info = <<~_;
        hs_forward_cb():
          \$buffer:    ${buffer}
          \$args:     '${args}'
          \$backward:  $backward
          \$forward:   ${forward}\n
        _

    wprint($info);
    wprint('Ctrl+n was pressed');
    wprint('');

    # Insert a unique \034 char to trigger the input_content_cb().
    weechat::command('', '/input insert \x1c');

    return $OK;
}

# List keyboard keys that are currently bound to the /hist_search_* commands.
sub hs_list_cb
{
    my ($data, $buffer, $args) = @_;
    my $PREFIX   = "hslist\t";
    my $infolist = weechat::infolist_get('key', '', 'default');

    wprint("${PREFIX}Current keyboard keys bound to /hist_search_* commands:");

    while (weechat::infolist_next($infolist)) {
        my $key = weechat::infolist_string($infolist, 'key');
        my $cmd = weechat::infolist_string($infolist, 'command');

        if ($cmd =~ m{\A/hist_search_(backward|forward)\z}) {
            wprint("  '${key}' => '${cmd}'");
            next;
        }
    }

    weechat::infolist_free($infolist);
    return $OK;
}

# Set keybinds callback
#
# Check and set the keybinds.
sub set_keybinds_cb
{
    my ($data, $option, $value) = @_;

    my $hs_backward = weechat::config_string($conf{'hist_search_backward'});
    my $hs_forward  = weechat::config_string($conf{'hist_search_forward'});

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
        ${PROG}\tSee '/help key' for more details.
        END

    if ($hs_backward eq '') {
        wprint("${PROG}\tkeybind for history search backward is not set");
        wprint($info);

        return $ERR;
    }
    if ($hs_forward eq '') {
        wprint("${PROG}\tkeybind for history search forward is not set");
        wprint($info);

        return $ERR;
    }

    # Unbind keys that were bound to a command and inform the user.
    {
        my $infolist = weechat::infolist_get('key', '', 'default');

        while (weechat::infolist_next($infolist)) {
            #my $fields = weechat::infolist_fields($infolist);
            my $key = weechat::infolist_string($infolist, 'key');
            my $cmd = weechat::infolist_string($infolist, 'command');

            #wprint($fields);
            #wprint("key:     '${key}'");
            #wprint("command: '${cmd}'");

            if ($key =~ /\A(\Q$hs_backward\E | \Q$hs_forward\E)\z/xi) {
                wprint("${PROG}\tkey '${key}' was bound to '${cmd}' command");
                weechat::key_unbind('default', $key);
                next;
            }
        }
        weechat::infolist_free($infolist);
    }

    # Set the keybinds.
    {
        weechat::key_bind('default', { $hs_backward => '/hist_search_backward' });
        weechat::key_bind('default', { $hs_forward  => '/hist_search_forward' });
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
                'desc'     => 'search in global history or buffer local history',
                'str_val'  => 'global|local',
                'min_val'  => 0,
                'max_val'  => 0,
                'default'  => 'global',
                'value'    => 'global',
                'null_val' => 0,
            },
        );
        return 1 if set_opts($conf_file, $sect_dbg, \@OPT);
    }

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

        wprint('%conf = ' . Dumper \%conf);
        # Populate the command history.
        init_cmdhist_cb();
    }

    # Hooks
    {
        # Update an option when it changes.
        weechat::hook_config("${PROG}.key.search_*", 'set_keybinds_cb', '');
        weechat::hook_config("${PROG}.search.mode",  'init_cmdhist_cb', '');

        weechat::hook_modifier('input_text_display', 'input_display_cb', '');
        weechat::hook_modifier('input_text_content', 'input_content_cb', '');
        weechat::hook_modifier('history_add', 'history_add_cb', '');

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
            'List keyboard keys that are currently bound to the hist_search_backward/forward commands.',
            'hslist',
            '',
            '',
            'hs_list_cb',
            ''
        );
    }
}

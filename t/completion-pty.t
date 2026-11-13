## no critic (Modules::RequireVersionVar, Modules::RequireEndWithOne)
# Shell fixtures and raw PTY control bytes must remain literal.
## no critic (ValuesAndExpressions::RequireInterpolationOfMetachars, ValuesAndExpressions::ProhibitEscapedCharacters)
use FindBin qw( $RealBin );
use lib "$RealBin/../local/lib/perl5";

use strict;
use warnings;
use utf8;

use Carp       qw( croak );
use Encode     qw( decode_utf8 encode_utf8 );
use English    qw( -no_match_vars );
use Errno      qw( EINTR EIO );
use IO::Pty    ();
use IO::Select ();
use IPC::Open3 qw( open3 );
use Path::Tiny qw( path tempdir );
use POSIX      ();
use Symbol     qw( gensym );
use Test::More;
use Time::HiRes qw( clock_gettime CLOCK_MONOTONIC );

my $script = path("$RealBin/../nt.pl")->absolute;
my @children;

# Always clean up directly owned PTY children, including after a test failure.
END {
    stop_shell($_) for @children;
}

sub run {
    my (@command) = @_;
    my $err       = gensym;
    my $pid       = open3( my $in, my $out, $err, @command );
    close $in or croak $OS_ERROR;
    local $RS = undef;
    my $stdout = <$out> // q{};
    my $stderr = <$err> // q{};
    waitpid $pid, 0;
    return ( $CHILD_ERROR >> 8, $stdout, $stderr );
}

sub send_input {
    my ( $child, $text ) = @_;
    my $bytes  = encode_utf8($text);
    my $offset = 0;
    while ( $offset < length $bytes ) {
        my $written = syswrite $child->{'pty'}, $bytes, length($bytes) - $offset, $offset;
        next                         if !defined $written && $OS_ERROR == EINTR;
        croak "write PTY: $OS_ERROR" if !defined $written || !$written;
        $offset += $written;
    }
    return;
}

sub read_until {
    my ( $child, $marker ) = @_;
    my $deadline = clock_gettime(CLOCK_MONOTONIC) + 8;
    while ( index( $child->{'pending'}, $marker ) < 0 ) {
        my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
        croak 'PTY timeout: ' . $child->{'pending'}
            if $remaining <= 0 || !$child->{'select'}->can_read($remaining);
        my $read = sysread $child->{'pty'}, my $chunk, 65_536;
        next if !defined $read && $OS_ERROR == EINTR;
        croak 'shell exited early: ' . $child->{'pending'}
            if ( !defined $read && $OS_ERROR == EIO ) || ( defined $read && !$read );
        croak "read PTY: $OS_ERROR" if !defined $read;
        $child->{'pending'} .= $chunk;
    }
    my $end = index( $child->{'pending'}, $marker ) + length $marker;
    return substr $child->{'pending'}, 0, $end, q{};
}

sub start_shell {
    my ( $executable, $shell, $home, $completion ) = @_;
    my $pty = IO::Pty->new;
    $pty->slave->set_winsize( 24, 120 );
    my $pid = fork;
    croak "fork: $OS_ERROR" if !defined $pid;
    if ( !$pid ) {

        # Do not run the test process's END handlers if setup or exec fails.
        eval {
            $pty->make_slave_controlling_terminal or croak 'cannot acquire controlling terminal';
            my $slave = $pty->slave;
            open STDIN,  '<&', $slave or croak $OS_ERROR;
            open STDOUT, '>&', $slave or croak $OS_ERROR;
            open STDERR, '>&', $slave or croak $OS_ERROR;
            close $slave  or croak $OS_ERROR;
            close $pty    or croak $OS_ERROR;
            chdir "$home" or croak $OS_ERROR;
            local @ENV{qw( HOME ZDOTDIR PATH INPUTRC HISTFILE TERM EDITOR VISUAL )}
                = ( "$home", "$home", "$home:$ENV{'PATH'}", '/dev/null', '/dev/null', 'dumb', q{:}, q{:}, );
            my @args = $shell eq 'bash' ? ( '--noprofile', '--norc', '-i' ) : ( '-f', '-i' );
            exec {$executable} $executable, @args or croak "exec: $OS_ERROR";
        };
        print {*STDERR} $EVAL_ERROR;    ## no critic (InputOutput::RequireCheckedSyscalls)
        POSIX::_exit(127);
    }
    $pty->close_slave;
    my $child = { 'pid' => $pid, 'pty' => $pty, 'select' => IO::Select->new($pty), 'pending' => q{} };
    push @children, $child;
    my $setup = $shell eq 'zsh' ? 'bindkey -e; autoload -Uz compinit; compinit -D; ' : q{};

    # Temporary paths have no shell quotes. Shell variables also exercise safe
    # expansion without requiring them to be exported to the nt subprocess.
    $setup .= "source '$completion'; PS1='PTY> '; PS2='MORE> '; " . q{STORE='stores/other store'; raw=$STORE; };
    send_input( $child, $setup . "printf '__READY__\\n'\n" );
    read_until( $child, "__READY__\r\n" );
    return $child;
}

sub stop_shell {
    my ($child) = @_;
    my $pid = delete $child->{'pid'};
    return if !defined $pid;
    kill 'HUP', $pid;
    close $child->{'pty'} or croak $OS_ERROR;
    waitpid $pid, 0;
    return;
}

sub complete {
    my ( $child, $line, %opts ) = @_;
    send_input( $child, $line . ( "\x02" x ( $opts{'left'} // 0 ) ) . "\t" . ( $opts{'append'} // q{} ) );

    # Let the real shell parse the inserted argument, but never execute nt
    # add/delete/edit: prefix the entire command with a harmless printf.
    send_input( $child, "\x01printf '__ARG__%s\\n' \x05; printf '__DONE__\\n'\n" );
    my $out  = read_until( $child, "__DONE__\r\n" );
    my @args = map { decode_utf8($_) } $out =~ /(?:\r?\n)__ARG__([^\r\n]*)/gsmx;
    return ( \@args, $out );
}

sub make_record {
    my ( $home, $store, $key ) = @_;
    my $file = $home->child( $store, "$key.md" );
    $file->parent->mkpath;
    $file->spew_utf8('body');
    return;
}

for my $shell (qw( bash zsh )) {
    subtest $shell => sub {
        my ($executable) = grep { -x $_ && !-d $_ } map {"$_/$shell"} split /:/smx, $ENV{'PATH'};
        plan skip_all => "$shell is not installed" if !defined $executable;
        my $home = tempdir;
        symlink "$script", "$home/nt" or croak $OS_ERROR;
        make_record( $home, '.nt', $_ )
            for (
            'root',          'work/deep/note', 'work/space name',
            q{quote's note}, q{double$`"note}, 'literal$(touch injected)',
            '日本語/note',      'topic:note',     '-banana',
            );
        make_record( $home, 'stores/other store', 'alternate/note' );
        make_record( $home, '$(touch injected)',  'safe/note' );
        $home->child('root')->mkpath;
        my ( $status, $source, $err ) = run( $EXECUTABLE_NAME, "$script", 'completion', $shell );
        is( $status, 0,   'generate completion script' );
        is( $err,    q{}, 'generation is silent on stderr' );
        my $completion = $home->child('completion');
        $completion->spew_raw($source);
        my $child = start_shell( $executable, $shell, $home, $completion );
        my $check = sub {
            my ( $label, $line, $expected, %opts ) = @_;
            my ( $actual, $out ) = complete( $child, $line, %opts );

            # Native ZLE removes one removable directory slash when the dump
            # macro moves the cursor. Do not accept a doubled slash.
            if ( $opts{'directory'} && @{$actual} && $actual->[-1] . q{/} eq $expected->[-1] ) {
                $actual->[-1] .= q{/};
            }
            is_deeply( $actual, [ 'nt', @{$expected} ], $label ) or diag $out;
            ok( !$home->child('injected')->exists, 'no command substitution was executed' );
        };

        $check->( 'command insertion',                 'nt vi',           ['view'] );
        $check->( 'option insertion',                  'nt view --bo',    [ 'view', '--body' ] );
        $check->( 'record key is not a CWD directory', 'nt view roo',     [ 'view', 'root' ] );
        $check->( 'namespace continuation',            'nt add work/de',  [ 'add',  'work/deep/new' ], 'append' => 'new' );
        $check->( 'namespace argument',                'nt list work/de', [ 'list', 'work/deep/' ] );
        for my $prefix ( q{"work/space n}, q{'work/space n}, q{work/space\ n}, 'work/spa' ) {
            $check->( 'quoted or escaped key', "nt view $prefix", [ 'view', 'work/space name' ] );
        }
        $check->( 'apostrophe in single quotes',         q{nt view 'quo},   [ 'view', q{quote's note} ] );
        $check->( 'special characters in double quotes', q{nt view "dou},   [ 'view', q{double$`"note} ] );
        $check->( 'Unicode key',                         'nt view 日本',      [ 'view', '日本語/note' ] );
        $check->( 'Bash word breaks',                    'nt view topic:n', [ 'view', 'topic:note' ] );
        $check->( 'candidate is not executable shell',   'nt view literal', [ 'view', 'literal$(touch injected)' ] );
        for my $base (
            q{"stores/other store"},
            q{stores/other\ store},
            q{"$HOME/stores/other store"},
            q{"${HOME}/stores/other store"},
            q{"$STORE"},
            q{"$raw"},
            )
        {
            my $directory = $base =~ /HOME/smx ? "$home/stores/other store" : 'stores/other store';
            $check->(
                'quoted, escaped, or variable store',
                "nt -b $base view alt",
                [ '-b', $directory, 'view', 'alternate/note' ]
            );
        }
        $check->( 'tilde store', 'nt -b ~/.nt view roo', [ '-b', "$home/.nt", 'view', 'root' ] );
        $check->(
            'store is not executable shell',
            q{nt -b '$(touch injected)' view sa},
            [ '-b', '$(touch injected)', 'view', 'safe/note' ]
        );
        $check->( 'directory completion', 'nt -b stores/oth', [ '-b', 'stores/other store/' ], 'directory' => 1 );
        $check->(
            'quoted directory completion', q{nt -b "stores/other s}, [ '-b', 'stores/other store/' ],
            'directory' => 1,
            'append'    => $shell eq 'zsh' ? q{"} : q{}
        );
        $check->(
            'equals directory completion',
            'nt --base_directory=stores/oth',
            ['--base_directory=stores/other store/'],
            'directory' => 1
        );
        $check->( 'bundled directory completion', 'nt -vbstores/oth', ['-vbstores/other store/'], 'directory' => 1 );
        $check->(
            'bundled base option',
            q{nt -vb"stores/other store" view alt},
            [ '-vbstores/other store', 'view', 'alternate/note' ]
        );
        $check->( 'bundled metadata option', 'nt put -vm status=open roo', [ 'put', '-vm', 'status=open', 'root' ] );
        my $suffix = q{ -b "stores/other store"};
        $check->(
            'store option to right of cursor',
            "nt view alt$suffix",
            [ 'view', 'alternate/note', '-b', 'stores/other store' ],
            'left' => length $suffix
        );

        # These parser cases previously lived in the mocked candidate tests.
        $check->( 'end-of-options marker',               'nt -- view -ban',       [ q{--},  'view',   '-banana' ] );
        $check->( 'boolean option before key',           'nt view --body roo',    [ 'view', '--body', 'root' ] );
        $check->( 'no keys for search expressions',      'nt find roo',           [ 'find', 'roo' ] );
        $check->( 'no second key',                       'nt view root roo',      [ 'view', 'root',  'roo' ] );
        $check->( 'no keys for metadata values',         'nt put --set status=o', [ 'put',  '--set', 'status=o' ] );
        $check->( 'metadata value is not a base option', 'nt put --set -body',    [ 'put',  '--set', '-body' ] );
        stop_shell($child);
        done_testing;
    };
}

done_testing;

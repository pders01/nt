## no critic (Modules::RequireVersionVar, Modules::RequireEndWithOne)
use FindBin qw( $RealBin );
use lib "$RealBin/../local/lib/perl5";

use strict;
use warnings;
use utf8;

use Carp       qw( croak );
use Encode     qw( encode_utf8 );
use English    qw( -no_match_vars );
use IPC::Open3 qw( open3 );
use Path::Tiny qw( path tempdir );
use Symbol     qw( gensym );
use Test::More;

my $script = path("$RealBin/../nt.pl")->absolute;
my $tmp    = tempdir;
my $base   = $tmp->child('store');
my $home   = $tmp->child('home');
$home->mkpath;
local $ENV{'HOME'} = "$home";

sub run {
    my (@command) = @_;
    my $err       = gensym;
    my $pid       = open3( my $in, my $out, $err, map { encode_utf8($_) } @command );
    close $in or croak $OS_ERROR;
    local $RS = undef;
    my $stdout = <$out> // q{};
    my $stderr = <$err> // q{};
    waitpid $pid, 0;
    return ( $CHILD_ERROR >> 8, $stdout, $stderr );
}

sub make_record {
    my ( $root, $key ) = @_;
    my $file = $root->child("$key.md");
    $file->parent->mkpath;
    $file->spew_utf8('not used for completion');
    return;
}

make_record( $home->child('.nt'), 'default/note' );
my @keys = ( 'root', 'work/deep/another', 'work/deep/note', 'work/space name', 'work/日本語' );
make_record( $base, $_ ) for @keys;
my $unicode_base = $tmp->child('store 日本語');
make_record( $unicode_base, '日本語/note' );

# Test the candidate provider directly. Real shell parsing, quoting, cursor
# context, directory completion, and insertion belong to completion-pty.t.
my $harness = <<'SHELL';
# Registration is irrelevant to provider tests; no ZLE APIs are mocked.
compdef() { :; }
source "$1"
nt_executable=$2 nt_command=$3 nt_current=$5 nt_position=$6 nt_end_options=
nt_base=()
[[ -n "$4" ]] && nt_base=(-b "$4")
_nt_candidates
SHELL

for my $shell (qw( bash zsh )) {
    subtest $shell => sub {
        my ( $status, $source, $err ) = run( $EXECUTABLE_NAME, "$script", 'completion', $shell );
        is( $status, 0,   'generation succeeds' );
        is( $err,    q{}, 'generation emits no stderr' );
        my $file = $tmp->child("completion.$shell");
        $file->spew_raw($source);
        my ($executable) = grep { -x $_ && !-d $_ } map {"$_/$shell"} split /:/smx, $ENV{'PATH'};
        if ( !defined $executable ) {
            note "$shell not installed; execution checks skipped";
            done_testing;
            return;
        }
        is( ( run( $executable, '-n', "$file" ) )[0], 0, 'generated script passes syntax check' );

        my $candidates = sub {
            my ( $command, $root, $prefix, $position ) = @_;
            my ( $rc, $out, $error ) = run(
                $executable, '-f',     '-c',         $harness,       'test', "$file",
                "$script",   $command, $root // q{}, $prefix // q{}, $position // 0,
            );
            is( $rc,    0,   'candidate query succeeds' );
            is( $error, q{}, 'candidate query emits no stderr' );
            return [ sort split /\n/smx, $out ];
        };
        is_deeply(
            $candidates->(q{}),
            [ sort qw( init list view add put edit delete find usage completion ) ],
            'exact command set'
        );
        is_deeply(
            $candidates->( q{}, undef, q{-} ),
            [ sort qw( -b --base_directory --json --no-json --meta --body -m --set -v --verbose ) ],
            'exact option set'
        );
        is_deeply( $candidates->('completion'), [qw( bash zsh )], 'only supported shells' );
        is_deeply( $candidates->('view'),       ['default/note'], 'default store key set' );
        my @expected = sort map { encode_utf8($_) } @keys;
        is_deeply( $candidates->( 'view', "$base" ),
            \@expected, 'exact keys without extensions, including spaces and UTF-8' );
        is_deeply( $candidates->( 'view', "$unicode_base" ), [ encode_utf8('日本語/note') ], 'Unicode store key set' );
        is_deeply( $candidates->( 'list', "$base" ),         [ 'work/', 'work/deep/' ],   'unique ancestor namespaces' );
        is_deeply( $candidates->( 'view', "$tmp/missing" ),  [],                          'missing store is silent' );

        make_record( $base, 'new/live' );
        is_deeply(
            $candidates->( 'view', "$base" ),
            [ sort @expected, 'new/live' ],
            'new entries appear without regeneration'
        );
        $base->child('new/live.md')->remove;
        is_deeply( $candidates->( 'view', "$base" ), \@expected, 'deleted entries disappear without regeneration' );
        done_testing;
    };
}

for my $args ( [], ['fish'] ) {
    my ( $status, $out, $err ) = run( $EXECUTABLE_NAME, "$script", 'completion', @{$args} );
    is( $status, 2,   'missing or unsupported shell is a usage error' );
    is( $out,    q{}, 'no partial script on error' );
    like( $err, qr/\Ant:\s expected\s shell:\s bash\s or\s zsh\n\z/smx, 'actionable diagnostic' );
}

done_testing;

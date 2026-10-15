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
use JSON::PP   qw( decode_json );
use Path::Tiny qw( path tempdir );
use Symbol     qw( gensym );
use Test::More;

my $script = path("$RealBin/../nt.pl")->absolute;
my $tmp    = tempdir;
my $base   = $tmp->child('store');

sub start {
    my (@command) = @_;
    my $err       = gensym;
    my $pid       = open3( my $in, my $out, $err, @command );
    return { 'pid' => $pid, 'in' => $in, 'out' => $out, 'err' => $err };
}

sub finish {
    my ( $child, $input ) = @_;
    print { $child->{'in'} } encode_utf8($input) or croak $OS_ERROR;
    close $child->{'in'}                         or croak $OS_ERROR;
    local $RS = undef;
    my $stdout = readline $child->{'out'} // q{};
    my $stderr = readline $child->{'err'} // q{};
    waitpid $child->{'pid'}, 0;
    return ( $CHILD_ERROR >> 8, $stdout, $stderr );
}

sub cli {
    my ( $input, @args ) = @_;
    my $child = start( $EXECUTABLE_NAME, "$script", '-b', "$base", map { encode_utf8($_) } @args );
    return finish( $child, $input );
}

# Signal immediately before reading stdin: add has already checked for an
# existing record. Both children must reach this point before either gets input.
# The hook lives only in the test launcher; production code needs no test seam.
my $launcher = <<'END_LAUNCHER';
use strict;
use warnings;
use Carp qw( croak );
use English qw( -no_match_vars );
use IO::Handle ();
BEGIN {
    *CORE::GLOBAL::readline = sub (*) {
        print STDERR "ready\n" or croak $OS_ERROR;
        STDERR->flush or croak $OS_ERROR;
        return CORE::readline($_[0]);
    };
}
my $script = shift @ARGV;
do $script;
croak $EVAL_ERROR if $EVAL_ERROR;
END_LAUNCHER

sub waiting_add {
    my ( $key, $owner ) = @_;
    my $child = start( $EXECUTABLE_NAME, '-e', $launcher, "$script", '-b', "$base", 'add', $key, '-m', "owner=$owner" );
    is( scalar readline $child->{'err'}, "ready\n", "$owner passed the initial existence check" );
    return $child;
}

subtest 'concurrent adds never overwrite the winner' => sub {

    # A timeout makes a broken rendezvous fail rather than hang the suite.
    local $SIG{'ALRM'} = sub { croak 'concurrent add test timed out' };
    alarm 15;
    my $key    = 'race/new/record';
    my $winner = waiting_add( $key, 'first' );
    my $loser  = waiting_add( $key, 'second' );

    # Keep the loser blocked until the winner has finished. This guarantees the
    # formerly unsafe interleaving without relying on scheduler timing.
    my ( $first_status,  $first_out,  $first_err )  = finish( $winner, "First café\n" );
    my ( $second_status, $second_out, $second_err ) = finish( $loser,  "Second 日本語\n" );
    alarm 0;
    is( $first_status,  0,                    'first add succeeds' );
    is( $first_out,     q{},                  'successful add emits no stdout' );
    is( $first_err,     q{},                  'successful add emits no stderr' );
    is( $second_status, 4,                    'second add reports exists after losing the race' );
    is( $second_out,    q{},                  'losing add emits no stdout' );
    is( $second_err,    "nt: exists: $key\n", 'losing add uses normal exists diagnostic' );
    is( $base->child("$key.md")->slurp_utf8,
        "---\nowner: first\n---\nFirst café\n",
        'winner body and frontmatter are unchanged',
    );
    done_testing;
};

subtest 'normal CLI behavior' => sub {
    my $key = 'work/日本語/note';
    is( ( cli( "Hello café 日本語\n", 'add', $key, '-m', 'title=Résumé' ) )[0],
        0, 'add UTF-8 body and metadata in nested namespace' );
    my ( $status, $json, $err ) = cli( q{}, 'view', $key, '--json' );
    is( $status, 0,   'view succeeds' );
    is( $err,    q{}, 'view emits no stderr' );
    is_deeply(
        decode_json($json),
        { 'key' => $key, 'meta' => { 'title' => 'Résumé' }, 'body' => "Hello café 日本語\n" },
        'UTF-8 is encoded exactly once and frontmatter is parsed',
    );
    my $before = $base->child("$key.md")->slurp_raw;
    is( ( cli( 'replacement', 'add', $key ) )[0],    4,       'duplicate add returns exists' );
    is( $base->child("$key.md")->slurp_raw,          $before, 'duplicate add leaves existing bytes intact' );
    is( ( cli( q{}, 'add', 'empty' ) )[0],           0,       'add empty record' );
    is( ( cli( 'replacement', 'add', 'empty' ) )[0], 4,       'empty record also counts as existing' );
    is( ( cli( q{}, 'add' ) )[0],                    2,       'missing add key remains a usage error' );

    is( ( cli( 'created',         'put', 'upsert/new/note' ) )[0], 0, 'put still creates missing records' );
    is( ( cli( "Updated naïve\n", 'put', $key ) )[0],              0, 'put still replaces bodies' );
    is( ( cli( q{}, 'put', $key, '-m', 'status=done' ) )[0], 0, 'metadata-only put succeeds' );
    my $rec = decode_json( ( cli( q{}, 'view', $key, '--json' ) )[1] );
    is_deeply(
        $rec,
        { 'key' => $key, 'meta' => { 'title' => 'Résumé', 'status' => 'done' }, 'body' => "Updated naïve\n" },
        'put preserves body during metadata-only updates',
    );

    $base->child('raw.md')->spew_utf8("---\n# comment\ntitle: Café\n---\nold\n");
    is( ( cli( 'new', 'put', 'raw' ) )[0],  0, 'put can update raw frontmatter records' );
    is( $base->child('raw.md')->slurp_utf8, "---\n# comment\ntitle: Café\n---\nnew", 'raw frontmatter is preserved' );
    done_testing;
};

subtest 'other create failures remain errors' => sub {

    # A file used as a parent is a portable failure even when tests run as root.
    $base->child('blocked')->spew_utf8('sentinel');
    my ( $status, $out, $err ) = cli( 'body', 'add', 'blocked/note' );
    is( $status, 1,   'non-existence-related failure is not reported as exists' );
    is( $out,    q{}, 'no stdout on failure' );
    like( $err, qr/\Ant:/smx, 'failure uses CLI diagnostics' );
    is( $base->child('blocked')->slurp_utf8, 'sentinel', 'blocking file is unchanged' );
    done_testing;
};

done_testing;

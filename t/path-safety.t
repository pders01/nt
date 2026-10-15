## no critic (Modules::RequireVersionVar, Modules::RequireEndWithOne)
use FindBin qw( $RealBin );
use lib "$RealBin/../local/lib/perl5";

use strict;
use warnings;

use Carp       qw( croak );
use English    qw( -no_match_vars );
use IPC::Open3 qw( open3 );
use JSON::PP   qw( decode_json );
use Path::Tiny qw( path tempdir );
use Symbol     qw( gensym );
use Test::More;

my $script  = path("$RealBin/../nt.pl")->absolute;
my $tmp     = tempdir;
my $base    = $tmp->child('store');
my $outside = $tmp->child('outside');
$outside->mkpath;
$outside->child('secret.md')->spew_utf8('outside sentinel');

# These subprocesses emit only small responses, so neither output pipe fills.
sub run {
    my ( $input, @command ) = @_;
    my $err = gensym;
    my $pid = open3( my $in, my $out, $err, @command );
    print {$in} $input or croak $OS_ERROR;
    close $in          or croak $OS_ERROR;
    local $RS = undef;
    my $stdout = <$out> // q{};
    my $stderr = <$err> // q{};
    waitpid $pid, 0;
    return ( $CHILD_ERROR >> 8, $stdout, $stderr );
}

sub cli {
    my ( $root, $input, @args ) = @_;
    return run( $input, $EXECUTABLE_NAME, "$script", '-b', "$root", @args );
}

sub rejected {
    my ( $root,   $command, $name ) = @_;
    my ( $status, $out,     $err )  = cli( $root, 'overwrite', $command, $name );
    is( $status, 1,   "$command rejects $name" );
    is( $out,    q{}, 'no record data emitted' );
    like( $err, qr/\Ant:\sunsafe\s(?:key|namespace):/smx, 'path error uses CLI diagnostics' );
    unlike( $err, qr/\n\n\z/smx, 'error has a single trailing newline' );
    return;
}

subtest 'unsafe names are rejected even when the store is missing' => sub {
    is( ( cli( $base, q{}, 'init' ) )[0], 0, 'create store' );
    my $missing = $tmp->child('missing');
    my @names   = (
        '../outside/secret', 'a/../../outside/secret', 'a/../secret', q{..},
        q{a/..},             '/tmp/secret',            'C:/secret',   'C:secret',
        'a/C:/secret',       'a/C:secret',             'a\\secret',   q{//server/share},
    );
    for my $root ( $base, $missing ) {
        for my $name (@names) {
            rejected( $root, $_, $name ) for qw( view add put delete edit list );
        }
    }
    is( $outside->child('secret.md')->slurp_utf8, 'outside sentinel', 'outside record unchanged' );
    ok( !$missing->exists, 'invalid writes do not create store' );
    is( ( cli( $missing, q{}, 'list' ) )[0], 0, 'missing store lists successfully' );
    done_testing;
};

subtest 'NUL bytes are rejected before filesystem access' => sub {

    # exec cannot carry a NUL in argv. Construct it in a child before loading
    # the CLI, which otherwise follows the same main() path as normal execution.
    my $launcher = <<'END_LAUNCHER';
use Carp qw( croak );
use English qw( -no_match_vars );
my $script = shift @ARGV;
$ARGV[-1] .= chr 0;
do $script;
croak $EVAL_ERROR if $EVAL_ERROR;
END_LAUNCHER
    for my $command (qw( view add put delete edit list )) {
        my ( $status, $out, $err )
            = run( 'overwrite', $EXECUTABLE_NAME, '-e', $launcher, "$script", '-b', "$base", $command, 'bad', );
        is( $status, 1,   "$command rejects NUL" );
        is( $out,    q{}, 'no record data emitted' );
        like( $err, qr/\Ant:\sunsafe\s(?:key|namespace):/smx, 'path error uses CLI diagnostics' );
    }
    done_testing;
};

subtest 'ordinary record and namespace operations still work' => sub {
    is( ( cli( $base, 'hello',   'add',  'work/projects/note' ) )[0], 0,        'add nested record' );
    is( ( cli( $base, q{},       'view', 'work/projects/note' ) )[1], 'hello',  'view nested record' );
    is( ( cli( $base, q{},       'add',  'work/projects/note' ) )[0], 4,        'add preserves exists status' );
    is( ( cli( $base, 'updated', 'put',  'work/projects/note' ) )[0], 0,        'put existing record' );
    is( ( cli( $base, q{},       'list', 'work' ) )[1], "work/projects/note\n", 'namespace lists relative keys' );
    is_deeply(
        decode_json( ( cli( $base, q{}, 'list', 'work/projects', '--json' ) )[1] ),
        ['work/projects/note'], 'JSON list remains supported',
    );
    is( ( cli( $base, q{}, 'list', './work//projects/' ) )[1], "work/projects/note\n", 'safe relative namespace spelling', );
    is( ( cli( $base, q{}, 'list', q{.} ) )[1],                "work/projects/note\n", 'dot namespace lists the store' );
    is( ( cli( $base, q{}, 'find', 'updated' ) )[1],           "work/projects/note\n", 'find works' );
    is( ( cli( $base, q{}, 'view', 'absent' ) )[0],            3,                      'missing view status' );
    is( ( cli( $base, q{}, 'delete', 'absent' ) )[0],          3,                      'missing delete status' );
    is( ( cli( $base, q{}, 'view' ) )[0],                      2,                      'missing argument status' );
    is( ( cli( $base, q{}, 'find', '[' ) )[0],                 1,                      'invalid pattern status' );

    for my $key ( 'draft..old', './work//safe', 'work/meeting:notes' ) {
        is( ( cli( $base, 'safe', 'put',    $key ) )[0], 0,      "accept safe key $key" );
        is( ( cli( $base, q{},    'view',   $key ) )[1], 'safe', 'safe key round-trips' );
        is( ( cli( $base, q{},    'delete', $key ) )[0], 0,      'remove safe key' );
    }
    done_testing;
};

subtest 'links below the store are rejected, including dangling and internal links' => sub {
    plan skip_all => 'symlinks unavailable' if !symlink $outside, $base->child('escape');
    my %links = (
        'leak.md'      => $outside->child('secret.md'),
        'dangling.md'  => $outside->child('new.md'),
        'dangling-dir' => $tmp->child('nonexistent'),
        'internal'     => $base->child('work'),
        'loop'         => $base,
    );
    for my $name ( sort keys %links ) {
        symlink $links{$name}, $base->child($name) or croak $OS_ERROR;
    }
    for my $key (qw( escape/secret escape/new/deep leak dangling dangling-dir/deep internal/projects/note loop/leak )) {
        rejected( $base, $_, $key ) for qw( view add put delete edit );
    }
    rejected( $base, 'list', $_ ) for qw( escape dangling-dir internal loop leak.md dangling.md );
    rejected( $base, 'view', './escape//secret' );
    is( ( cli( $base, q{}, 'list' ) )[1],             "work/projects/note\n", 'list skips symlink files and directories' );
    is( ( cli( $base, q{}, 'find', 'sentinel' ) )[1], q{},                    'find does not read external symlink' );
    is( $outside->child('secret.md')->slurp_utf8,     'outside sentinel',     'outside record unchanged' );
    ok( !$outside->child('new.md')->exists,  'dangling file target not created' );
    ok( !$outside->child('new')->exists,     'external parents not created' );
    ok( !$tmp->child('nonexistent')->exists, 'dangling directory target not created' );

    my $alias = $tmp->child('alias');
    symlink $base, $alias or croak $OS_ERROR;
    is( ( cli( $alias, q{}, 'view', 'work/projects/note' ) )[1], 'updated',   'configured root may be a symlink' );
    is( ( cli( $alias, q{}, 'list' ) )[1],            "work/projects/note\n", 'list through configured symlink root' );
    is( ( cli( $alias, q{}, 'find', 'updated' ) )[1], "work/projects/note\n", 'find through configured symlink root' );
    rejected( $alias, 'view', 'escape/secret' );
    done_testing;
};

is( ( cli( $base, q{}, 'delete', 'work/projects/note' ) )[0], 0, 'delete nested record' );
ok( !$base->child('work/projects/note.md')->exists, 'nested record removed' );
done_testing;

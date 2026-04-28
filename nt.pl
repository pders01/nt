#!/usr/bin/env perl

use strict;
use warnings;

package NT::Store;

use Carp       qw( croak );
use Path::Tiny qw( path );
use Readonly   qw( Readonly );

Readonly my $FM_RE => qr/\A---\n(.*?)\n---\n(.*)\z/smx;
Readonly my $KV_RE => qr/\A([^:\s][^:]*):\s*(.*)\z/smx;

sub new {
    my ( $class, %opts ) = @_;
    my $base = path( $opts{'base_directory'} // "$ENV{'HOME'}/.nt" );
    return bless { 'base' => $base }, $class;
}

sub init {
    my ($self) = @_;
    $self->{'base'}->mkpath;
    return;
}

sub list {
    my ( $self, $ns ) = @_;
    my $root = $self->{'base'};
    return () if !$root->is_dir;
    my $scope = length $ns ? $root->child($ns) : $root;
    return () if !$scope->is_dir;
    my $it = $scope->iterator( { 'recurse' => 1 } );
    my @keys;
    while ( defined( my $p = $it->() ) ) {
        push @keys, $self->_key_from_path($p) if !$p->is_dir && $p =~ m/[.]md\z/smx;
    }
    return sort @keys;
}

sub get {
    my ( $self, $key ) = @_;
    my $file = $self->_path_for($key);
    return if !$file->is_file;
    my $rec = $self->_parse( scalar $file->slurp_utf8 );
    @{$rec}{qw( key path )} = ( $key, $file );
    return $rec;
}

sub put {
    my ( $self, $key, $rec ) = @_;
    my $file = $self->_path_for($key);
    $file->parent->mkpath;
    $file->spew_utf8( $self->_serialize($rec) );
    return 1;
}

sub remove {
    my ( $self, $key ) = @_;
    my $file = $self->_path_for($key);
    return 0 if !$file->is_file;
    $file->remove;
    return 1;
}

sub find {
    my ( $self, $pattern ) = @_;
    my $re = qr/$pattern/smx;
    return grep {
        my $r = $self->get($_);
        $r->{'body'} =~ $re || $r->{'meta_raw'} =~ $re;
    } $self->list(q{});
}

sub _path_for {
    my ( $self, $key ) = @_;
    croak 'empty key' if !length $key;
    return $self->{'base'}->child("$key.md");
}

sub _key_from_path {
    my ( $self, $file ) = @_;
    my $rel = $file->relative( $self->{'base'} )->stringify;
    $rel =~ s/[.]md\z//smx;
    return $rel;
}

sub _parse {
    my ( $self, $raw ) = @_;
    if ( $raw =~ $FM_RE ) {
        my ( $mr, $body ) = ( $1, $2 );
        my %meta;
        for my $line ( split /\n/smx, $mr ) {
            $meta{$1} = $2 if $line =~ $KV_RE;
        }
        return { 'meta' => \%meta, 'meta_raw' => $mr, 'body' => $body };
    }
    return { 'meta' => {}, 'meta_raw' => q{}, 'body' => $raw };
}

sub _serialize {
    my ( $self, $rec ) = @_;
    my $head = q{};
    if ( length $rec->{'meta_raw'} ) {
        $head = "---\n$rec->{'meta_raw'}\n---\n";
    }
    elsif ( %{ $rec->{'meta'} || {} } ) {
        my $meta = $rec->{'meta'};
        $head = "---\n" . join( q{}, map {"$_: $meta->{$_}\n"} sort keys %{$meta} ) . "---\n";
    }
    return $head . ( $rec->{'body'} // q{} );
}

package main;

use strict;
use warnings;

use Carp         qw( croak );
use English      qw( -no_match_vars );
use Getopt::Long qw( GetOptions :config no_ignore_case bundling );
use JSON::PP     qw( encode_json );
use Path::Tiny   qw( path tempfile );
use Pod::Usage   qw( pod2usage );
use Readonly     qw( Readonly );

our $VERSION = 0.13;

Readonly my $EXIT_OK        => 0;
Readonly my $EXIT_ERROR     => 1;
Readonly my $EXIT_USAGE     => 2;
Readonly my $EXIT_NOT_FOUND => 3;
Readonly my $EXIT_EXISTS    => 4;

Readonly my $COMMANDS => {
    'usage'  => \&_cmd_usage,
    'init'   => \&_cmd_init,
    'list'   => \&_cmd_list,
    'view'   => \&_cmd_view,
    'add'    => \&_cmd_add,
    'put'    => \&_cmd_put,
    'edit'   => \&_cmd_edit,
    'delete' => \&_cmd_delete,
    'find'   => \&_cmd_find,
};

sub main {
    my $opts = {};
    GetOptions(
        'base_directory|b=s' => \$opts->{'base'},
        'json!'              => \$opts->{'json'},
        'meta'               => \$opts->{'meta_only'},
        'body'               => \$opts->{'body_only'},
        'set|m=s@'           => \$opts->{'set'},
        'verbose|v'          => \$opts->{'verbose'},
    ) or exit $EXIT_USAGE;

    my $cmd = shift @ARGV // 'usage';
    my $arg = shift @ARGV;
    my $sub = $COMMANDS->{$cmd} // \&_cmd_usage;

    my $store = NT::Store->new( 'base_directory' => $opts->{'base'} );
    exit $sub->( $store, $arg, $opts );
}

sub _cmd_usage {
    my ( undef, undef, $opts ) = @_;
    if ( $opts->{'verbose'} ) {
        pod2usage(
            {   '-verbose'  => 99,
                '-sections' => 'SYNOPSIS|DESCRIPTION|COMMANDS|OPTIONS|EXAMPLES|EXIT STATUS',
                '-exitval'  => 'NOEXIT',
            }
        );
        return $EXIT_OK;
    }
    print <<'END_USAGE' or croak $OS_ERROR;
nt - markdown filesystem store with namespaces

Usage: nt [options] <command> [arg]

Commands:
  init              Create the store ($HOME/.nt)
  list [ns]         List record keys (optionally scoped to a namespace)
  view <key>        Print a record (--meta or --body for partial)
  add <key>         Create from stdin or $EDITOR (fails if exists)
  put <key>         Upsert from stdin or $EDITOR
  edit <key>        Open existing record in $EDITOR
  delete <key>      Remove a record
  find <pattern>    Print keys matching regex (body or frontmatter)

Common options:
  -b DIR            Base directory (default: $HOME/.nt)
  -m KEY=VALUE      Set frontmatter field on add/put (repeatable)
  --json/--no-json  Force or disable JSON output (auto by TTY)

Pipelines: stdout JSON when not a TTY; stdin replaces body when piped.
Exit codes: 0 ok, 1 error, 2 usage, 3 not-found, 4 exists.

Run `nt usage -v` for examples and full option detail.
END_USAGE
    return $EXIT_OK;
}

sub _cmd_init {
    my ($store) = @_;
    $store->init;
    return $EXIT_OK;
}

sub _cmd_list {
    my ( $store, $ns, $opts ) = @_;
    my @keys = $store->list( $ns // q{} );
    if ( _json_mode($opts) ) {
        print encode_json( \@keys ), "\n" or croak $OS_ERROR;
    }
    else {
        print "$_\n" or croak $OS_ERROR for @keys;
    }
    return $EXIT_OK;
}

sub _cmd_view {
    my ( $store, $key, $opts ) = @_;
    return _die( 'missing key', $EXIT_USAGE ) if !defined $key;
    my $rec = $store->get($key) or return _die( "not found: $key", $EXIT_NOT_FOUND );

    if ( _json_mode($opts) ) {
        my $payload = {
            'key'  => $rec->{'key'},
            'meta' => $rec->{'meta'},
            'body' => $rec->{'body'},
        };
        $payload = $rec->{'meta'} if $opts->{'meta_only'};
        $payload = $rec->{'body'} if $opts->{'body_only'};
        print encode_json($payload), "\n" or croak $OS_ERROR;
        return $EXIT_OK;
    }

    if ( $opts->{'meta_only'} ) {
        print $rec->{'meta_raw'}, "\n" or croak $OS_ERROR if length $rec->{'meta_raw'};
        return $EXIT_OK;
    }
    if ( $opts->{'body_only'} ) {
        print $rec->{'body'} or croak $OS_ERROR;
        return $EXIT_OK;
    }
    print NT::Store->_serialize($rec) or croak $OS_ERROR;
    return $EXIT_OK;
}

sub _cmd_add {
    my ( $store, $key, $opts ) = @_;
    return _die( 'missing key',  $EXIT_USAGE )  if !defined $key;
    return _die( "exists: $key", $EXIT_EXISTS ) if $store->get($key);
    return _write( $store, $key, $opts, undef );
}

sub _cmd_put {
    my ( $store, $key, $opts ) = @_;
    return _die( 'missing key', $EXIT_USAGE ) if !defined $key;
    return _write( $store, $key, $opts, $store->get($key) );
}

sub _cmd_edit {
    my ( $store, $key ) = @_;
    return _die( 'missing key', $EXIT_USAGE ) if !defined $key;
    my $rec = $store->get($key) or return _die( "not found: $key", $EXIT_NOT_FOUND );
    _open_editor( $rec->{'path'} );
    return $EXIT_OK;
}

sub _cmd_delete {
    my ( $store, $key ) = @_;
    return _die( 'missing key', $EXIT_USAGE ) if !defined $key;
    return $store->remove($key) ? $EXIT_OK : _die( "not found: $key", $EXIT_NOT_FOUND );
}

sub _cmd_find {
    my ( $store, $pattern, $opts ) = @_;
    return _die( 'missing pattern',           $EXIT_USAGE ) if !defined $pattern;
    return _die( "invalid pattern: $pattern", $EXIT_ERROR ) if !eval { qr/$pattern/smx; 1 };
    my @keys = $store->find($pattern);
    if ( _json_mode($opts) ) {
        print encode_json( \@keys ), "\n" or croak $OS_ERROR;
    }
    else {
        print "$_\n" or croak $OS_ERROR for @keys;
    }
    return $EXIT_OK;
}

sub _write {
    my ( $store, $key, $opts, $existing ) = @_;
    my $rec     = $existing // { 'meta' => {}, 'meta_raw' => q{}, 'body' => q{} };
    my $stdin   = -t \*STDIN ? undef : do { local $RS = undef; scalar <STDIN> };     ## no critic (InputOutput::ProhibitInteractiveTest)
    my $has_set = $opts->{'set'} && @{ $opts->{'set'} };

    if ( defined $stdin && ( length $stdin || !$has_set ) ) {
        $rec->{'body'} = $stdin;
    }
    elsif ( !defined $stdin && !$has_set ) {
        $rec->{'body'} = _editor_body($rec);
    }

    if ($has_set) {
        for my $kv ( @{ $opts->{'set'} } ) {
            my ( $k, $v ) = split /=/smx, $kv, 2;
            $rec->{'meta'}{$k} = $v // q{};
        }
        $rec->{'meta_raw'} = q{};
    }
    $store->put( $key, $rec );
    return $EXIT_OK;
}

sub _editor_body {
    my ($rec) = @_;
    my $tmp = tempfile( 'SUFFIX' => '.md' );
    $tmp->spew_utf8( $rec->{'body'} // q{} );
    _open_editor($tmp);
    return scalar $tmp->slurp_utf8;
}

sub _open_editor {
    my ($file) = @_;
    my $editor = $ENV{'EDITOR'} || 'vi';
    system $editor, "$file";
    my $rc = $CHILD_ERROR >> 8;
    exit _die( "editor exited $rc", $EXIT_ERROR ) if $rc;
    return;
}

sub _json_mode {
    my ($opts) = @_;
    return defined $opts->{'json'} ? $opts->{'json'} : !-t \*STDOUT;    ## no critic (InputOutput::ProhibitInteractiveTest)
}

sub _die {
    my ( $msg, $code ) = @_;
    print {*STDERR} "nt: $msg\n" or croak $OS_ERROR;
    return $code // $EXIT_ERROR;
}

main();

__END__

=head1 NAME

nt - markdown filesystem store with namespaces

=head1 SYNOPSIS

  nt [-b DIR] [--[no-]json] <command> [arg] [-m KEY=VALUE ...]

=head1 DESCRIPTION

A self-contained, agent-friendly markdown filesystem store. Records
are plain markdown files at C<$base/$namespace/$name.md>, with
optional Jekyll-style frontmatter. The CLI is TTY-aware: it opens
C<$EDITOR> for humans, reads stdin in pipelines, and emits JSON when
stdout is not a terminal. Records without frontmatter round-trip
byte-for-byte, and frontmatter the parser does not understand is
preserved verbatim.

=head1 COMMANDS

=over 4

=item B<init>

Create the base directory.

=item B<list> [I<namespace>]

Print record keys, one per line. Optionally scope to a namespace.

=item B<view> I<key>

Print a record (full file by default). Use C<--meta> for just the
frontmatter, C<--body> for just the body.

=item B<add> I<key>

Strict-create a record. Fails with exit 4 if the key already exists.
Body is read from stdin when piped, else C<$EDITOR> opens.

=item B<put> I<key>

Upsert a record. Same input rules as C<add>. With C<-m> alone (no
piped input), only frontmatter is patched and the body is preserved.

=item B<edit> I<key>

Open an existing record in C<$EDITOR>.

=item B<delete> I<key>

Remove a record.

=item B<find> I<pattern>

Print keys whose body or frontmatter matches the regex.

=item B<usage>

Print this help.

=back

=head1 USAGE

See L</COMMANDS> for available verbs and L</EXAMPLES> for common
flows. Run C<nt usage> for the same overview.

=head1 REQUIRED ARGUMENTS

A command (see L</COMMANDS>). Most commands also take a I<key> (or a
I<pattern>, for C<find>) as the second positional argument.

=head1 OPTIONS

=over 4

=item B<-b, --base_directory> I<dir>

Base directory for the store. Defaults to C<$HOME/.nt>.

=item B<--json> / B<--no-json>

Force JSON or line-based output. Defaults to JSON when stdout is not a
TTY, line-based otherwise.

=item B<--meta>

For C<view>: emit only the frontmatter (raw block, or parsed hash in
JSON mode).

=item B<--body>

For C<view>: emit only the body.

=item B<-m, --set> I<key>=I<value>

For C<add> and C<put>: set a frontmatter key. Repeatable.

=back

=head1 EXAMPLES

  # Initialize the store
  nt init

  # Create a record from stdin
  echo "# Hello" | nt add greetings/hi

  # Create a record with frontmatter, no body
  nt add work/todo -m status=open -m owner=me </dev/null

  # List, view, find
  nt list
  nt list work
  nt view greetings/hi
  nt view work/todo --meta --json
  nt find 'TODO'

  # Patch frontmatter without touching the body
  nt put work/todo -m status=done

  # Pipe and parse
  nt list | jq '.[]'
  nt find pattern | xargs -n1 nt view --body

  # Edit interactively (opens $EDITOR)
  nt edit work/todo

=head1 DIAGNOSTICS

Errors are written to stderr prefixed with C<nt:>. Editor failure
during C<edit>/C<add>/C<put> dies with C<editor exited N>.

=head1 EXIT STATUS

  0  success
  1  generic error
  2  usage error
  3  key not found
  4  key already exists (C<add> only)

=head1 CONFIGURATION

The C<EDITOR> environment variable selects the editor for C<edit> and
the interactive C<add>/C<put> path; defaults to C<vi>.

=head1 DEPENDENCIES

Core: L<Carp>, L<English>, L<Getopt::Long>, L<JSON::PP>, L<Pod::Usage>.
Non-core: L<Path::Tiny>, L<Readonly>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The flat C<key: value> frontmatter writer does not escape values
containing newlines or unbalanced colons. Records that need richer
YAML must be written via stdin so the raw block round-trips verbatim.

=head1 AUTHOR

Paul Derscheid, <me@paulderscheid.xyz>

=head1 LICENSE AND COPYRIGHT

Same terms as Perl itself.

=cut

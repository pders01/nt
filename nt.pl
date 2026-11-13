#!/usr/bin/env perl

use FindBin qw( $RealBin );
use lib "$RealBin/local/lib/perl5";

use strict;
use warnings;

package NT::Store;

use Carp       qw( croak );
use Encode     qw( decode_utf8 );
use English    qw( -no_match_vars );
use Errno      qw( EEXIST );
use Fcntl      qw( O_WRONLY O_CREAT O_EXCL );
use Path::Tiny qw( path );
use Readonly   qw( Readonly );

Readonly my $FM_RE => qr/\A---\n(.*?)\n---\n(.*)\z/smx;
Readonly my $KV_RE => qr/\A([^:\s][^:]*):\s*(.*)\z/smx;

# /a keeps drive letters ASCII without restricting Unicode record names.
Readonly my $UNSAFE_PATH_RE => qr{\A/|[\\\x00]|(?:\A|/)(?:[[:alpha:]]:|[.][.](?:/|\z))}smxa;

sub new {
    my ( $class, %opts ) = @_;
    my $base = path( $opts{'base_directory'} // "$ENV{'HOME'}/.nt" );
    $base = $base->realpath if $base->is_dir;
    return bless { 'base' => $base }, $class;
}

sub init {
    my ($self) = @_;
    $self->{'base'}->mkpath;
    return;
}

sub list {
    my ( $self, $ns ) = @_;
    my $root  = $self->{'base'};
    my $scope = $self->_safe_path( $ns, 'namespace' );
    return () if !$root->is_dir || !$scope->is_dir;

    # readdir returns bytes. Use a byte path for iteration so Unicode parent
    # names do not cause those bytes to be encoded a second time.
    my $scope_name = "$scope";
    utf8::encode($scope_name) if utf8::is_utf8($scope_name);
    my $it = path($scope_name)->iterator( { 'recurse' => 1, 'follow_symlinks' => 0 } );
    my @keys;
    while ( defined( my $p = $it->() ) ) {
        next if -l $p;
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

sub add {
    my ( $self, $key, $rec ) = @_;
    my $file = $self->_path_for($key);
    $file->parent->mkpath;

    # The earlier existence check is only a fast path; this decides who wins.
    my $fh;
    if ( !sysopen $fh, "$file", O_WRONLY | O_CREAT | O_EXCL ) {
        return 0 if $OS_ERROR == EEXIST;
        croak "create $file: $OS_ERROR";
    }
    binmode $fh, ':raw:encoding(UTF-8)' or croak $OS_ERROR;
    print {$fh} $self->_serialize($rec) or croak $OS_ERROR;
    close $fh                           or croak $OS_ERROR;
    return 1;
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
    return $self->_safe_path( $key, 'key', '.md' );
}

sub _safe_path {
    my ( $self, $name, $kind, $suffix ) = @_;

    # Check the original name before normalization or adding the record suffix.
    croak "unsafe $kind: $name" if $name =~ $UNSAFE_PATH_RE;

    my $file = $self->{'base'};
    for my $part ( split m{/}smx, $name . ( $suffix // q{} ) ) {
        next if $part eq q{} || $part eq q{.};
        $file = $file->child($part);

        # lstat semantics also catch dangling links; the configured base is trusted.
        croak "unsafe $kind: symbolic link in $name" if -l $file;
    }
    return $file;
}

sub _key_from_path {
    my ( $self, $file ) = @_;
    my $base = "$self->{'base'}";
    utf8::encode($base) if utf8::is_utf8($base);
    my $rel = decode_utf8( $file->relative($base)->stringify );
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
use Encode       qw( decode_utf8 );
use English      qw( -no_match_vars );
use Getopt::Long qw( GetOptions :config no_ignore_case bundling );
use JSON::PP     ();
use Path::Tiny   qw( path tempfile );
use Pod::Usage   qw( pod2usage );
use Readonly     qw( Readonly );

our $VERSION = 0.31;

# Records hold character data. Everything is decoded on the way in and encoded
# exactly once on the way out; the JSON encoder is deliberately not in utf8 mode
# so that the STDOUT layer stays the single encoding point.
my $JSON = JSON::PP->new;

Readonly my $EXIT_OK        => 0;
Readonly my $EXIT_ERROR     => 1;
Readonly my $EXIT_USAGE     => 2;
Readonly my $EXIT_NOT_FOUND => 3;
Readonly my $EXIT_EXISTS    => 4;

Readonly my $COMMANDS => {
    'usage'      => \&_cmd_usage,
    'init'       => \&_cmd_init,
    'list'       => \&_cmd_list,
    'view'       => \&_cmd_view,
    'add'        => \&_cmd_add,
    'put'        => \&_cmd_put,
    'edit'       => \&_cmd_edit,
    'delete'     => \&_cmd_delete,
    'find'       => \&_cmd_find,
    'completion' => \&_cmd_completion,
};

sub main {
    my $opts = {};

    binmode STDOUT, ':encoding(UTF-8)' or croak $OS_ERROR;
    binmode STDERR, ':encoding(UTF-8)' or croak $OS_ERROR;
    local @ARGV = map { decode_utf8($_) } @ARGV;

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

    my $status = eval {
        my $store = NT::Store->new( 'base_directory' => $opts->{'base'} );
        $sub->( $store, $arg, $opts );
    };
    exit _die( $EVAL_ERROR, $EXIT_ERROR ) if $EVAL_ERROR;
    exit $status;
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
  completion <shell> Print completion script (bash or zsh)

Common options:
  -b DIR            Base directory (default: $HOME/.nt)
  -m KEY=VALUE      Set frontmatter field on add/put (repeatable)
  --json/--no-json  Enable or disable JSON output (default: text)

Pipelines: stdout is text unless --json is set; piped stdin replaces body.
Exit codes: 0 ok, 1 error, 2 usage, 3 not-found, 4 exists.

Run `nt usage -v` for examples and full option detail.
END_USAGE
    return $EXIT_OK;
}

sub _cmd_completion {
    my ( undef, $shell ) = @_;
    return _die( 'expected shell: bash or zsh', $EXIT_USAGE )
        if !defined $shell || ( $shell ne 'bash' && $shell ne 'zsh' );

    # Shared shell-word decoding deliberately does not use eval: completing an
    # argument must never execute substitutions supplied on the command line.
    print <<'SHELL' or croak $OS_ERROR;
_nt_decode() {
    local nt_raw=$1 nt_char nt_next nt_name nt_text nt_decode_quote=
    REPLY=
    case "$nt_raw" in
        '~'|'~/'*) REPLY=$HOME; nt_raw=${nt_raw#\~} ;;
    esac
    while [[ -n "$nt_raw" ]]; do
        nt_char=${nt_raw%"${nt_raw#?}"}
        nt_raw=${nt_raw#?}
        if [[ "$nt_decode_quote" == "'" ]]; then
            if [[ "$nt_char" == "'" ]]; then nt_decode_quote=; else REPLY=$REPLY$nt_char; fi
        elif [[ "$nt_char" == '\' ]]; then
            nt_next=${nt_raw%"${nt_raw#?}"}
            if [[ -z "$nt_decode_quote" || "$nt_next" == '$' || "$nt_next" == '`' || "$nt_next" == '"' || "$nt_next" == '\' ]]; then
                REPLY=$REPLY$nt_next
                nt_raw=${nt_raw#?}
            else
                REPLY=$REPLY$nt_char
            fi
        elif [[ "$nt_char" == '"' ]]; then
            if [[ "$nt_decode_quote" == '"' ]]; then nt_decode_quote=; else nt_decode_quote='"'; fi
        elif [[ "$nt_char" == "'" && -z "$nt_decode_quote" ]]; then
            nt_decode_quote="'"
        elif [[ "$nt_char" == '$' ]]; then
            nt_name=
            if [[ "$nt_raw" == '{'* && "$nt_raw" == *'}'* ]]; then
                nt_text=${nt_raw#\{}
                nt_name=${nt_text%%\}*}
            else
                nt_name=${nt_raw%%[!a-zA-Z0-9_]*}
            fi
            case "$nt_name" in
                ''|[!a-zA-Z_]*|*[!a-zA-Z0-9_]*) REPLY=$REPLY$nt_char ;;
                *)
                    if [[ "$nt_raw" == '{'* ]]; then nt_raw=${nt_raw#*\}}; else nt_raw=${nt_raw#"$nt_name"}; fi
                    _nt_value "$nt_name"
                    REPLY=$REPLY$nt_value
                    ;;
            esac
        else
            REPLY=$REPLY$nt_char
        fi
    done
    nt_quote=$nt_decode_quote
}

_nt_context() {
    local nt_target=$1 nt_index=0 nt_word nt_scan_command= nt_scan_position=0 nt_scan_expect= nt_scan_end_options= nt_cluster nt_char
    shift
    nt_command= nt_position=0 nt_expect= nt_end_options= nt_base=()
    for nt_word in "$@"; do
        if (( nt_index == nt_target )); then
            nt_command=$nt_scan_command nt_position=$nt_scan_position nt_expect=$nt_scan_expect nt_end_options=$nt_scan_end_options
        fi
        _nt_decode "$nt_word"
        nt_word=$REPLY
        (( nt_index += 1 ))
        if [[ -n "$nt_scan_expect" ]]; then
            [[ "$nt_scan_expect" == base ]] && nt_base=(-b "$nt_word")
            nt_scan_expect=
            continue
        fi
        if [[ -z "$nt_scan_end_options" ]]; then
            case "$nt_word" in
                --) nt_scan_end_options=1; continue ;;
                --base_directory) nt_scan_expect=base; continue ;;
                --set) nt_scan_expect=set; continue ;;
                --base_directory=*) nt_base=(-b "${nt_word#*=}"); continue ;;
                --*) continue ;;
                -?*)
                    nt_cluster=${nt_word#-}
                    while [[ -n "$nt_cluster" ]]; do
                        nt_char=${nt_cluster%"${nt_cluster#?}"}
                        nt_cluster=${nt_cluster#?}
                        case "$nt_char" in
                            b|m)
                                if [[ "$nt_char" == b ]]; then nt_scan_expect=base; else nt_scan_expect=set; fi
                                if [[ -n "$nt_cluster" ]]; then
                                    [[ "$nt_scan_expect" == base ]] && nt_base=(-b "$nt_cluster")
                                    nt_scan_expect=
                                fi
                                break
                                ;;
                            v) ;;
                            *) break ;;
                        esac
                    done
                    continue
                    ;;
            esac
        fi
        if [[ -z "$nt_scan_command" ]]; then nt_scan_command=$nt_word; else (( nt_scan_position += 1 )); fi
    done
}

_nt_current_option() {
    local nt_cluster nt_char nt_prefix=-
    nt_directory_prefix=
    [[ -n "$nt_expect" || -n "$nt_end_options" ]] && return 0
    case "$nt_current" in
        --base_directory=*) nt_expect=base; nt_directory_prefix=--base_directory= ;;
        --set=*) nt_expect=set ;;
        -[!-]*)
            nt_cluster=${nt_current#-}
            while [[ -n "$nt_cluster" ]]; do
                nt_char=${nt_cluster%"${nt_cluster#?}"}
                nt_cluster=${nt_cluster#?}
                nt_prefix=$nt_prefix$nt_char
                case "$nt_char" in
                    b) nt_expect=base; nt_directory_prefix=$nt_prefix; break ;;
                    m) nt_expect=set; break ;;
                    v) ;;
                    *) break ;;
                esac
            done
            ;;
    esac
}

_nt_candidates() {
    local nt_key
    if [[ -z "$nt_end_options" && "$nt_current" == -* ]]; then
        printf '%s\n' -b --base_directory --json --no-json --meta --body \
            -m --set -v --verbose
    elif [[ -z "$nt_command" ]]; then
        printf '%s\n' init list view add put edit delete find usage completion
    elif (( nt_position == 0 )); then
        case "$nt_command" in
            view|edit|delete|put)
                "$nt_executable" "${nt_base[@]}" --no-json list 2>/dev/null
                ;;
            list|add)
                while IFS= read -r nt_key; do
                    while [[ "$nt_key" == */* ]]; do
                        nt_key=${nt_key%/*}
                        printf '%s/\n' "$nt_key"
                    done
                done < <("$nt_executable" "${nt_base[@]}" --no-json list 2>/dev/null) | sort -u
                ;;
            completion) printf '%s\n' bash zsh ;;
        esac
    fi
    return 0
}
SHELL

    if ( $shell eq 'bash' ) {
        print <<'BASH' or croak $OS_ERROR;
_nt_value() { nt_value=${!1}; }

_nt_reply() {
    local nt_candidate=${1#"$nt_word_prefix"} nt_suffix=$2
    # Readline handles quotes only when a quote is already open. Otherwise
    # escape explicitly; -o filenames would inspect unrelated files in $PWD.
    case "$nt_quote" in
        "'") nt_candidate=${nt_candidate//\'/\'\\\'\'}; nt_suffix= ;;
        '"')
            nt_candidate=${nt_candidate//\\/\\\\}
            nt_candidate=${nt_candidate//\$/\\\$}
            nt_candidate=${nt_candidate//\`/\\\`}
            nt_candidate=${nt_candidate//\"/\\\"}
            nt_suffix=
            ;;
        *) printf -v nt_candidate '%q' "$nt_candidate" ;;
    esac
    COMPREPLY+=("$nt_candidate$nt_suffix")
}

_nt() {
    local nt_command nt_position nt_expect nt_end_options nt_current nt_quote nt_value REPLY
    local nt_executable=${COMP_WORDS[0]} nt_directory_prefix nt_word_prefix=
    local -a nt_base nt_words
    local nt_candidate nt_word nt_i nt_last nt_join= nt_target=-1 nt_raw_current= nt_suffix=' '
    COMPREPLY=()
    # Reassemble Bash's '=' and ':' word breaks across the entire command,
    # including options to the right of the cursor. Never change global state.
    for ((nt_i=1; nt_i<${#COMP_WORDS[@]}; nt_i++)); do
        nt_word=${COMP_WORDS[nt_i]}
        nt_last=$((${#nt_words[@]} - 1))
        if (( nt_last >= 0 )) && [[ "$nt_word" == = || "$nt_word" == : || -n "$nt_join" ]]; then
            if (( nt_i == COMP_CWORD )); then nt_word_prefix=${nt_words[nt_last]}; fi
            nt_words[nt_last]+=$nt_word
        else
            nt_words+=("$nt_word")
            nt_last=$((${#nt_words[@]} - 1))
        fi
        if (( nt_i == COMP_CWORD )); then nt_target=$nt_last; nt_raw_current=${nt_words[nt_last]}; fi
        nt_join=
        [[ "$nt_word" == = || "$nt_word" == : ]] && nt_join=1
    done
    _nt_context "$nt_target" "${nt_words[@]}"
    # Bash 3 keeps word-break characters inside COMP_WORDS, while newer Bash
    # may split them. The callback's second argument identifies the actual
    # replacement span in either case (including an opening quote).
    if (( $# >= 2 )) && [[ "$nt_raw_current" == *"$2" ]]; then
        nt_word_prefix=${nt_raw_current%"$2"}
    fi
    _nt_decode "$nt_word_prefix"
    nt_word_prefix=$REPLY
    _nt_decode "$nt_raw_current"
    nt_current=$REPLY
    _nt_current_option
    case "$nt_expect" in
        base)
            while IFS= read -r nt_candidate; do
                _nt_reply "$nt_directory_prefix$nt_candidate/" ''
            done < <(compgen -d -- "${nt_current#"$nt_directory_prefix"}")
            return 0
            ;;
        set) return 0 ;;
    esac
    if [[ "$nt_command" == list || "$nt_command" == add ]] && [[ "$nt_current" != -* ]]; then nt_suffix=; fi
    while IFS= read -r nt_candidate; do
        [[ "$nt_candidate" == "$nt_current"* ]] && _nt_reply "$nt_candidate" "$nt_suffix"
    done < <(_nt_candidates)
    return 0
}
complete -o nospace -F _nt nt
BASH
    }
    else {
        print <<'ZSH' or croak $OS_ERROR;
_nt_value() { nt_value=${(P)1}; }

_nt() {
    emulate -L zsh
    setopt extendedglob
    local nt_command nt_position nt_expect nt_end_options nt_current nt_quote nt_value REPLY
    local nt_executable=${words[1]} nt_directory_prefix
    local -a nt_base nt_candidates
    _nt_context $((CURRENT-2)) "${(@)words[2,-1]}"
    _nt_decode "${words[CURRENT]}"
    nt_current=$REPLY
    _nt_current_option
    case "$nt_expect" in
        base)
            [[ -n "$nt_directory_prefix" ]] && compset -P "${(b)nt_directory_prefix}"
            _files -/
            return
            ;;
        set) return 0 ;;
    esac
    nt_candidates=("${(@f)$(_nt_candidates)}")
    if (( ${#nt_candidates} )); then
        if [[ "$nt_command" == list || "$nt_command" == add ]] && [[ "$nt_current" != -* ]]; then
            compadd -S '' -- "${nt_candidates[@]}"
        else
            compadd -- "${nt_candidates[@]}"
        fi
    fi
}
compdef _nt nt
ZSH
    }
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
        print $JSON->encode( \@keys ), "\n" or croak $OS_ERROR;
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
        print $JSON->encode($payload), "\n" or croak $OS_ERROR;
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
    return _write( $store, $key, $opts, undef, 'add' );
}

sub _cmd_put {
    my ( $store, $key, $opts ) = @_;
    return _die( 'missing key', $EXIT_USAGE ) if !defined $key;
    return _write( $store, $key, $opts, scalar $store->get($key), 'put' );
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
        print $JSON->encode( \@keys ), "\n" or croak $OS_ERROR;
    }
    else {
        print "$_\n" or croak $OS_ERROR for @keys;
    }
    return $EXIT_OK;
}

sub _write {
    my ( $store, $key, $opts, $existing, $method ) = @_;
    my $rec   = $existing // { 'meta' => {}, 'meta_raw' => q{}, 'body' => q{} };
    my $stdin = -t \*STDIN ? undef : do { local $RS = undef; scalar <STDIN> };     ## no critic (InputOutput::ProhibitInteractiveTest)
    $stdin = decode_utf8($stdin) if defined $stdin;
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
    return $store->$method( $key, $rec ) ? $EXIT_OK : _die( "exists: $key", $EXIT_EXISTS );
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
    return $opts->{'json'} // 0;
}

sub _die {
    my ( $msg, $code ) = @_;
    chomp $msg;
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
optional Jekyll-style frontmatter. The CLI opens C<$EDITOR> when
stdin is a terminal, reads stdin in pipelines, and emits JSON when
explicitly requested. Records without frontmatter round-trip
byte-for-byte, and frontmatter the parser does not understand is
preserved verbatim.

Keys and namespaces must be relative to the store. Parent components
(C<..>), absolute or drive-qualified paths, backslashes, and NUL bytes
are rejected. Symbolic links below the store root are rejected for direct
access and skipped by C<list> and C<find>. The configured root itself may
be a symbolic link.

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

Strict-create a record. Fails with exit 4 if the key already exists,
including when another process creates it while input is being prepared.
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

=item B<completion> I<bash|zsh>

Print a shell completion script. Source it in Bash with
C<eval "$(nt completion bash)">, or in zsh after C<compinit> with
C<eval "$(nt completion zsh)">. Entries are queried dynamically and
C<-b> / C<--base_directory> select the store used for completion.
No external completion framework is required.

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

Enable or disable JSON output. Output is line-based or raw text by
default; use C<--json> for structured output.

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

  # Pipe and parse JSON explicitly
  nt list --json | jq '.[]'

  # Text output composes directly with Unix tools
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

Path checks do not protect against concurrent replacement of store entries.
Use a store directory writable only by trusted processes.

=head1 AUTHOR

Paul Derscheid, <me@paulderscheid.xyz>

=head1 LICENSE AND COPYRIGHT

Same terms as Perl itself.

=cut

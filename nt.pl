#!/usr/bin/env perl

use strict;
use warnings;

use Carp         qw( carp croak );
use English      qw( -no_match_vars);
use Getopt::Long qw( GetOptions );
use IPC::Open3   qw( open3 );
use Path::Tiny   qw( path );
use Pod::Usage   qw( pod2usage );
use Readonly     qw( Readonly );

use Symbol 'gensym';

our $VERSION = 0.01;

Readonly my $COMMANDS => {
    usage  => 1,
    init   => 1,
    list   => 1,
    add    => 1,
    edit   => 1,
    delete => 1,
};

Readonly my $CONFIG => {
    base_directory => "$ENV{'HOME'}/.nt",
    glow           => 1,
    gum            => 1,
};

sub main {
    my $options = {};
    if ( !GetOptions( 'base_directory|b=s' => \$options->{'base_directory'} ) ) {
        croak('Error in command line arguments');
    }

    $options->{'command'} = _validate( 'command', ( shift @ARGV ) // 'usage' );
    $options->{'name'}    = shift @ARGV;

    {   usage  => sub { _usage() },
        init   => sub { _init() },
        list   => sub { _list() },
        add    => sub { _add( $options->{'name'} ) },
        edit   => sub { _edit( $options->{'name'} ) },
        delete => sub { _delete( $options->{'name'} ) },
    }->{ $options->{'command'} }->();

    return;
}

sub _usage {
    pod2usage();

    return;
}

sub _init {
    if ( -d $CONFIG->{'base_directory'} ) {
        return;
    }

    my $path = _get_path();
    if ( !$path ) {
        return;
    }

    $path->mkpath;

    return;
}

sub _list {
    if ( !-d $CONFIG->{'base_directory'} ) {
        return;
    }

    my $path = _get_path();
    if ( !$path ) {
        return;
    }

    my $files = [ $path->children(qr/^[^.]/smx) ];
    if ( $CONFIG->{'gum'} ) {
        my $file   = _prompt($files);
        my $action = _prompt( [ 'view', 'edit' ] );
        if ( $action eq 'view' ) {
            _view_file($file);

            return;
        }

        if ( $action eq 'edit' ) {
            _edit_file($file);

            return;
        }

        return;
    }

    for my $file ( $files->@* ) {
        print "$file\n" or croak $OS_ERROR;
    }

    return;
}

sub _prompt {
    my $choices = shift;

    my ( $prompt, $choice );
    if ( $CONFIG->{'gum'} ) {
        $prompt = join q{ }, 'gum', 'choose', $choices->@*;
        $choice = qx/$prompt/;

        return $choice;
    }

    return $choice;
}

sub _view_file {
    my $file = shift;

    if ( $CONFIG->{'glow'} ) {
        system 'glow', '-p', $file;

        return;
    }

    return;
}

sub _add {
    my $name = shift;
    if ( !$name ) {
        return;
    }

    my $path = _get_path( [$name] );
    if ( !$path ) {
        return;
    }

    $path->touch;

    return;
}

sub _edit {
    my $name = shift;
    if ( !$name ) {
        return;
    }

    my $path = _get_path( [$name] );
    if ($path) {
        return;
    }

    _edit_file($path);

    return;
}

sub _edit_file {
    my $file = shift;

    my $editor = $ENV{'EDITOR'} || 'vi';

    system $editor, $file;

    my $exit_status = $CHILD_ERROR >> 8;
    if ( $exit_status != 0 ) {
        croak "Editor exited with non-zero status: $exit_status";
    }

    return;
}

sub _delete {
    my $name = shift;
    if ( !$name ) {
        return;
    }

    my $path = _get_path( [$name] );
    if ( !$path ) {
        return;
    }

    if ( !$path->remove ) {
        croak "Couldn't delete $name";
    }

    return;
}

sub _validate {
    my ( $type, $param ) = @_;

    return { command => sub { $COMMANDS->{$param} } }->{$type}->() ? $param : 0;
}

sub _get_path {
    my $components = shift;

    $components //= [];

    my $path = path( join q{/}, $CONFIG->{'base_directory'}, $components->@* );

    return $path;
}

main();

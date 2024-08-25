#!/usr/bin/env perl

use strict;
use warnings;

use Carp         qw( carp croak );
use English      qw( -no_match_vars);
use Getopt::Long qw( GetOptions );
use IPC::Open3   qw( open3 );
use List::Util   qw( reduce );
use Path::Tiny   qw( path );
use Pod::Usage   qw( pod2usage );
use Readonly     qw( Readonly );

use Symbol 'gensym';

our $VERSION = 0.02;

Readonly my $COMMANDS => {
    usage  => 1,
    init   => 1,
    list   => 1,
    view   => 1,
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

    {   usage   => sub { _usage() },
        init    => sub { _init() },
        list    => sub { _list() },
        view    => sub { _view( $options->{'name'} ) },
        add     => sub { _add( $options->{'name'} ) },
        edit    => sub { _edit( $options->{'name'} ) },
        delete  => sub { _delete( $options->{'name'} ) },
        default => sub { _usage() },
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

sub _view {
    my $name = shift;
    if ( !$name ) {
        return;
    }

    if ( !-d $CONFIG->{'base_directory'} ) {
        return;
    }

    my $path = _get_path( [$name] );
    if ( !$path ) {
        return;
    }

    #my $file = ( reduce { $a->{ $b->basename } = $b; $a } {}, $path->children(qr/^[^.]/smx) )->{$name};
    #if ( !$file ) {
    #    return;
    #}

    _view_file($path);

    return;
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

    return { command => sub { $COMMANDS->{$param} } }->{$type}->() ? $param : 'default';
}

sub _get_path {
    my $components = shift;

    $components //= [];

    my $path = path( join q{/}, $CONFIG->{'base_directory'}, $components->@* );

    return $path;
}

main();

=head1 NAME

nt - A script to manage a collection of notes with commands to initialize, list, add, edit, and delete notes.

=head1 SYNOPSIS

nt [options] <command> [name]

 Options:
   -b, --base_directory  Set the base directory for storing notes (default: $HOME/.nt)

 Commands:
   usage                Display the usage information
   init                 Initialize the notes directory
   list                 List all notes
   view                 View an existing note with the specified name
   add [name]           Add a new note with the specified name
   edit [name]          Edit an existing note with the specified name
   delete [name]        Delete an existing note with the specified name

=head1 DESCRIPTION

This script provides a command-line interface for managing a collection of notes stored in a directory. It supports basic operations such as initializing a storage directory, listing notes, adding new notes, editing existing notes, and deleting notes.

=head1 OPTIONS

=over 4

=item B<-b, --base_directory>

Specify the base directory where notes are stored. If not provided, the default is C<$HOME/.nt>.

=back

=head1 COMMANDS

=over 4

=item B<usage>

Displays the usage information and exits.

=item B<init>

Initializes the base directory for storing notes if it doesn't already exist.

=item B<list>

Lists all notes in the base directory. If the "gum" command is enabled in the configuration, it will prompt the user to view or edit a selected note.

=item B<view [name]>

Opens the note in the base directory with the specified name.

=item B<add [name]>

Adds a new note with the specified name. The note will be created as an empty file in the base directory.

=item B<edit [name]>

Edits an existing note with the specified name. The script will open the note in the editor specified by the C<$EDITOR> environment variable or default to "vi".

=item B<delete [name]>

Deletes the note with the specified name from the base directory.

=back

=head1 CONFIGURATION

The script uses a configuration hashref to store settings such as the base directory, and whether to use external tools like "glow" and "gum".

=over 4

=item B<$CONFIG-E<gt>{'base_directory'}>

The directory where all notes are stored. Defaults to C<$HOME/.nt>.

=item B<$CONFIG-E<gt>{'glow'}>

A flag indicating whether to use the "glow" tool for rendering markdown files.

=item B<$CONFIG-E<gt>{'gum'}>

A flag indicating whether to use the "gum" tool for interactive prompts.

=back

=head1 EXAMPLES

=over 4

=item Initialize the notes directory:

    nt init

=item List all notes:

    nt list

=item Add a new note called "meeting_notes":

    nt add meeting_notes

=item Edit an existing note called "meeting_notes":

    nt edit meeting_notes

=item Delete a note called "meeting_notes":

    nt delete meeting_notes

=back

=head1 AUTHOR

Paul Derscheid, <me@paulderscheid.xyz>

=head1 VERSION

This documentation refers to version 0.02 of nt.

=head1 COPYRIGHT AND LICENSE

This script is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut

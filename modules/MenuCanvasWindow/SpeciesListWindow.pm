
### MenuCanvasWindow::SpeciesListWindow

package MenuCanvasWindow::SpeciesListWindow;

use strict;
use warnings;
use Carp;
use Try::Tiny;
use Tk::DialogBox;
use base 'MenuCanvasWindow';
use EditWindow::LoadColumns;
use CanvasWindow::SequenceSetChooser;
use Bio::Otter::Git;
use Bio::Vega::Utils::URI qw( open_uri );

sub new {
    my ($pkg, @args) = @_;

    @args = (@args, 220, 150, 'ose') if 1 == @args;
    # Default params:
    #
    # x width: wide enough to show full title text (worksforme size),
    # and for comfortable yellow-sticky-messages
    #
    # ose: size fitting doesn't account for 'o' scrollbar.  Leave east
    # on, we won't need the south.

    my $self = $pkg->SUPER::new(@args);

    my $canvas = $self->canvas;
    $canvas->Tk::bind('<Button-1>', sub{
            $self->deselect_all;
            $self->select_dataset;
        });
    my $open_command = sub{
        unless ($self->open_dataset) {
            $self->message("No dataset selected - click on a name to select one");
        }
    };
    $canvas->Tk::bind('<Double-Button-1>',  $open_command);
    $canvas->Tk::bind('<Return>',           $open_command);
    $canvas->Tk::bind('<KP_Enter>',         $open_command);
    $canvas->Tk::bind('<Control-o>',        $open_command);
    $canvas->Tk::bind('<Control-O>',        $open_command);
    $canvas->Tk::bind('<Escape>', sub{ $self->deselect_all });

    my $recover_command = sub{ $self->recover_some_sessions; };
    $canvas->Tk::bind('<Control-r>',    $recover_command);
    $canvas->Tk::bind('<Control-R>',    $recover_command);

    my $quit_command = sub{
        $self->canvas->toplevel->destroy;
        $self = undef;  # $self gets nicely DESTROY'd with this
    };
    $canvas->Tk::bind('<Control-q>',    $quit_command);
    $canvas->Tk::bind('<Control-Q>',    $quit_command);
    $canvas->toplevel
        ->protocol('WM_DELETE_WINDOW',  $quit_command);

    my $top = $canvas->toplevel;


    # FILE MENU
    my $file_menu = $self->make_menu('File');

    $file_menu->add
       ('command',
        -label      => 'Open',
        -accelerator => 'Ctrl+O',
        -underline  => 1,
        -command    => $open_command);

    $file_menu->add
       ('command',
        -label      => "Recover sessions",
        -accelerator => 'Ctrl+R',
        -underline  => 1,
        -command    => $recover_command,
       );

    $file_menu->add
       ('command',
        -label      => 'Quit',
        -accelerator => 'Ctrl+Q',
        -underline  => 1,
        -command    => $quit_command,
       );


    # HELP MENU
    my $help_menu = $self->make_menu('Help', 0, 'right');
    $help_menu->add
      ('command',
       -label => 'About Otterlace...',
       -underline => 0,
       -command => [ $self, 'show_about' ]);

    $help_menu->add
      ('command',
       -label => 'Show Error Log',
       -underline => 11,
       -command => [ $self, 'show_log' ]);

    return $self;
}


sub about_text {
    my $vsn = Bio::Otter::Git->as_text;
    # Any number of URLs may be inserted.  If we want images or other
    # markup, it's time to break out a new class.
    return <<"TEXT";
This is Otterlace version $vsn\n
Otterlace web page
  http://www.sanger.ac.uk/resources/software/otterlace/
TEXT
}

sub show_about {
    my ($self) = @_;

    $self->{'_about'} ||= do {
        my $A = $self->top_window->DialogBox
          (-title => 'About Otterlace',
           -buttons => [qw[ Close ]]);
        $A->Tk::bind('<Escape>', [ $A, 'Exit' ]);

        my $content = $self->about_text;

        my ($x, $y) = (30, 0);
        foreach my $ln (split /\n/, $content) {
            $y++;
            $x = length($ln) if length($ln) > $x;
        }

        my $txt = $A->ROText
          (-bg => 'white',
           -height => $y, -width => $x,
           -selectborderwidth => 0,
           -borderwidth => 0,
           -font => [qw[ Helvetica 20 normal ]])->pack
            (-side => 'top', -fill => 'both', -expand => 1);

        foreach my $seg (split m{(\w+://\S+)}, $content) {
            my @tag;
            push @tag, 'link' if $seg =~ m{://};
            $txt->insert(end => $seg, @tag);
        }

        $txt->tagConfigure(link => -foreground => 'blue', -underline => 1, -font => [qw[ Courier 16 normal ]]);
        $txt->tagBind(link => '<Button-1>', [ $self, 'about_hyperlink', $txt, Tk::Ev('@') ]);
        $txt->configure(-state => 'disabled');

        $A;
    };

    $self->{'_about'}->Show;

    return ();
}

# Find the link near click & open it
sub about_hyperlink {
    my ($self, $txt, $at) = @_;
    my @idx = $txt->tagPrevrange(link => $at);
    my $ln = $txt->get(@idx);
#    warn "click! args=(@_) idx=(@idx) ln=$ln";
    open_uri($ln);
    return ();
}


sub show_log{
    my ($self) = @_;

    require TransientWindow::LogWindow;
    require Bio::Otter::LogFile;

    my $tw = $self->{'__tw_log'};
    unless($tw){
        $tw = TransientWindow::LogWindow->new
          ($self->top_window(),
           'Otter: log file - ' . Bio::Otter::LogFile->current_logfile);
        $tw->initialise();
        $tw->draw();
        $self->{'__tw_log'} = $tw;
    }
    $tw->show_me();

    return;
}



sub Client {
    my ($self, $Client) = @_;

    if ($Client) {
        $self->{'_Client'} = $Client;
    }
    return $self->{'_Client'};
}

sub select_dataset {
    my ($self) = @_;

    return if $self->delete_message;
    my $canvas = $self->canvas;
    if (my ($current) = $canvas->find('withtag', 'current')) {
        $self->highlight($current);
    } else {
        $self->deselect_all;
    }

    return;
}

sub open_dataset {
    my ($self) = @_;

    return 1 if $self->recover_some_sessions;

    my ($obj) = $self->list_selected;
    return 0 unless $obj;

    my $canvas = $self->canvas;
    $canvas->Busy;
    foreach my $tag ($canvas->gettags($obj)) {
        if ($tag =~ /^DataSet=(.+)/) {
            my $name = $1;
            my $client = $self->Client;
            my $ds = $client->get_DataSet_by_name($name);
            $ds->load_client_config;

            my $top = $self->{'_sequence_set_chooser'}{$name};
            if (Tk::Exists($top)) {
                $top->deiconify;
                $top->raise;
            } else {
                $top = $canvas->Toplevel(-title => "otter: Assembly List $name");
                my $ssc = CanvasWindow::SequenceSetChooser->new($top);

                $ssc->name($name);
                $ssc->Client($client);
                $ssc->DataSet($ds);
                $ssc->SpeciesListWindow($self);
                $ssc->draw;

                $self->{'_sequence_set_chooser'}{$name} = $top;
            }
            $canvas->Unbusy;
            return 1;
        }
    }
    $canvas->Unbusy;

    return 0;
}

sub draw {
    my ($self) = @_;

    my $canvas = $self->canvas;

    $canvas->toplevel->withdraw;
    my @dsl = $self->Client->get_all_DataSets;
    $canvas->toplevel->deiconify;
    $canvas->toplevel->raise;
    $canvas->toplevel->focus;

    my $font = $self->font_fixed_bold;
    my $size = $self->font_size;
    my $row_height = int $size * 1.5;
    for (my $i = 0; $i < @dsl; $i++) {
        my $data_set = $dsl[$i];
        my $x = $size;
        my $y = $row_height * (1 + $i);
        $canvas->createText(
            $x, $y,
            -text   => $data_set->name,
            -font   => $font,
            -anchor => 'nw',
            -tags   => ['DataSet=' . $data_set->name],
            );
    }
    $self->fix_window_min_max_sizes;

    return;
}

sub recover_some_sessions {
    my ($self) = @_;

    my $client = $self->Client();
    my $recoverable_sessions = $client->sessions_needing_recovery();

    if (@$recoverable_sessions) {
        my %session_wanted = map { $_->[0] => 1 } @$recoverable_sessions;

        my $rss_dialog = $self->canvas->toplevel->DialogBox(
            -title => 'otter: Recover Sessions',
            -buttons => ['Recover', 'Cancel'],
        );
        $rss_dialog->Tk::bind('<Escape>', sub { $rss_dialog->Subwidget('B_Cancel')->invoke });

        $rss_dialog->add('Label',
            -wrap    => 400,
            -justify => 'left',
            -text    => join("\n\n",
                "You have one or more lace sessions on this computer which are not"
                . " associated with a running otterlace process.",

                "This should not happen, except where lace has crashed or it has"
                . " been exited by pressing the exit button in the 'Choose Dataset'"
                . " window.",

                "You will need to recover and exit these sessions. There may be"
                . " locks left in the otter database or some of your work which has"
                . " not been saved.",

                "Please contact anacode if you still get an error when you attempt"
                . " to exit the session, or have information about the error which"
                . " caused a session to be left.",
                ),
        )->pack(-side=>'top', -fill=>'x', -expand=>1);

        foreach my $rec (@$recoverable_sessions) {
            my ($session_dir, $date, $title) = @$rec;
            my $full_session_title = sprintf "%s - %s", scalar localtime($date), $title;
            my $cb = $rss_dialog->add('Checkbutton',
                -text     => $full_session_title,
                -variable => \$session_wanted{$session_dir},
                -onvalue  => 1,
                -offvalue => 0,
                -anchor   => 'w',
            )->pack(-side=>'top', -fill=>'x', -expand=>1);
        }

        my $answer = $rss_dialog->Show();

        my @selected_recs = grep { $session_wanted{$_->[0]} } @$recoverable_sessions;

        if ($answer=~/recover/i && @selected_recs) {
            try {
                my $canvas = $self->canvas;

                foreach my $rec (@selected_recs) {
                    my ($session_dir, $date, $title) = @$rec;

                    # Bring up GUI
                    my $adb = $client->recover_session($session_dir);

                    my $top = $canvas->Toplevel(
                        -title  => 'otter: Select Column Data to Load',
                    );

                    my $lc = EditWindow::LoadColumns->new($top);
                    $lc->AceDatabase($adb);
                    $lc->SpeciesListWindow($self);
                    $lc->initialize;
                    $lc->change_checkbutton_state('deselect');
                    $lc->load_filters;
                    $top->withdraw;
                }
            }
            catch {
                $self->exception_message(
                    $::_, 'Error recovering lace sessions');
            };
            # XXX: we should make a stronger protest if it fails - maybe a pop up error dialog, or put a sticker on the session itself (if it exists).  Also, some errors have already been eaten (e.g. in RT#231368)
            return 1;
        } else {
            return 0;
        }
    } else {
        return 0;
    }
}


1;

__END__

=head1 NAME - MenuCanvasWindow::SpeciesListWindow

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk



package MenuCanvasWindow::XaceSeqChooser;

use strict;
use 5.006_001;  # For qr support
use Carp qw{ cluck confess };
use Tk::Dialog;
use Tk::DialogBox;
use Symbol 'gensym';
use Scalar::Util 'weaken';

use Hum::Ace::SubSeq;
use Hum::Ace::Locus;
use Hum::Ace::Method;
use Hum::Ace::XaceRemote;
use Hum::Ace::Assembly;
use Hum::Ace::AceText;
use Hum::Ace;
use Hum::Analysis::Factory::ExonLocator;
use Hum::Conf qw{ PFETCH_SERVER_LIST };
use Hum::Sort qw{ ace_sort };
use Hum::ClipboardUtils qw{ text_is_zmap_clip evidence_type_and_name_from_text };
use EditWindow::Dotter;
use EditWindow::Exonerate;
use EditWindow::Clone;
use EditWindow::LocusName;
use MenuCanvasWindow::ExonCanvas;
use MenuCanvasWindow::GenomicFeatures;
use MenuCanvasWindow::ZMapSeqChooser;
use Bio::Otter::Lace::Defaults;

use base 'MenuCanvasWindow';

sub new {
    my( $pkg, $tk ) = @_;
    
    my $self = $pkg->SUPER::new($tk);

    $self->populate_menus;
    $self->make_search_panel;
    $self->bind_events;
    $self->minimum_scroll_bbox(0,0, 380,200);

    return $self;
}

sub AceDatabase {
    my( $self, $AceDatabase ) = @_;
    
    if ($AceDatabase) {
        $self->{'_AceDatabase'} = $AceDatabase;
    }
    return $self->{'_AceDatabase'};
}

sub drop_AceDatabase {
    my $self = shift;
    
    $self->{'_AceDatabase'} = undef;
}

sub SequenceNotes {
    my ($self, $sn) = @_ ;
    
    if ($sn){
        $self->{'_sequence_notes'} = $sn ;
    }
    return $self->{'_sequence_notes'} ;
}

sub EviCollection {
    my( $self, $EviCollection ) = @_;
    
    if ($EviCollection) {
        $self->{'_EviCollection'} = $EviCollection;
    }
    return $self->{'_EviCollection'};
}

sub initialize {
    my( $self ) = @_;
    
    # take GeneMethods from methods.ace file
    $self->set_known_GeneMethods();
    
    unless ($self->AceDatabase->write_access) {
        $self->menu_bar()->Label(
            -text       => 'Read Only',
            -foreground => 'red',
            -padx       => 6,
            )->pack(
                    -side => 'right',
                    );
    }

    $self->draw_subseq_list;
    $self->populate_clone_menu;
    $self->zMapWriteDotZmap;
    $self->zMapWriteDotGtkrc;
    $self->zMapLaunchZmap;
    $self->top_window->raise;
}

sub menu_bar {
    my( $self, $bf ) = @_;
    
    if ($bf) {
        $self->{'_menu_bar'} = $bf;
    }
    return $self->{'_menu_bar'};
}

sub clone_menu {
    my( $self, $clone_menu ) = @_;
    
    if ($clone_menu) {
        $self->{'_clone_menu'} = $clone_menu;
    }
    return $self->{'_clone_menu'};
}

sub set_known_GeneMethods{
    my ($self) = @_ ;

    my $lst = $self->{'_gene_methods_list'} = [
        $self->Assembly->MethodCollection->get_all_transcript_Methods
        ];
    my $idx = $self->{'_gene_methods'} = {};
    %$idx = map {$_->name, $_} @$lst;
}

sub get_GeneMethod {
    my( $self, $name ) = @_;
    
    my( $meth );
    unless ($meth = $self->{'_gene_methods'}{$name}) {
        confess "No such Method '$name'";
    }
    return $meth;
}

sub get_all_GeneMethods {
    my( $self ) = @_;
    
    return @{$self->{'_gene_methods_list'}};
}

sub get_all_mutable_GeneMethods {
    my( $self ) = @_;
    
    my $list = $self->{'_gene_methods_list'} || [];
    return grep $_->mutable, @$list;
}

sub get_default_mutable_GeneMethod {
    my( $self ) = @_;
   
    my @possible = grep $_->transcript_type eq 'coding', $self->get_all_mutable_GeneMethods;
    if (my ($supp) = grep $_->name eq 'Coding', @possible) {
        # "Coding" is the default method, if it is there
        return $supp;
    }
    elsif (@possible)  {
        return $possible[0];
    } else {
        $self->message("Unable to get a default GeneMethod");
        return;
    }
}

sub get_Locus {
    my( $self, $name ) = @_;
    
    my( $locus );
    if (ref($name)) {
        $locus = $name;
        $name = $locus->name;
    }
    
    if (my $cached = $self->{'_locus_cache'}{$name}) {
        return $cached;
    } else {
        unless ($locus) {
            $locus = Hum::Ace::Locus->new;
            $locus->name($name);
        }
        $self->{'_locus_cache'}{$name} = $locus;
        return $locus;
    }
}

sub set_Locus {
    my( $self, $locus ) = @_;
    
    my $name = $locus->name;
    $self->{'_locus_cache'}{$name} = $locus;
}

sub get_all_Loci {
    my( $self ) = @_;    
    my $lc = $self->{'_locus_cache'};
    return values %$lc;
}

sub list_Locus_names {
    my( $self ) = @_;    
    return sort {lc $a cmp lc $b} map $_->name, $self->get_all_Loci;
}

sub empty_Locus_cache {
    my( $self ) = @_;
    
    $self->{'_locus_cache'} = undef;
}

sub update_Locus {
    my( $self, $new_locus ) = @_;
     
    $self->set_Locus($new_locus);
    
    my $locus_name = $new_locus->name;

    foreach my $sub_name ($self->list_all_SubSeq_names) {
        my $sub = $self->get_SubSeq($sub_name) or next;
        my $old_locus = $sub->Locus or next;
        
        if ($old_locus->name eq $locus_name) {
            # Replace locus in subseq with new copy
            $sub->Locus($new_locus);
            
            # Is there an edit window open?
            if (my $ec = $self->get_subseq_edit_window($sub_name)) {
                $ec->update_Locus($new_locus);
            }
        }
    }
}

sub fetch_SubSeqs_by_locus_name {
   my( $self, $locus_name ) = @_;
   
   my @list;
   foreach my $name ($self->list_all_SubSeq_names) {
       my $sub = $self->get_SubSeq($name) or next;
       my $locus = $sub->Locus or next;
       if ($locus->name eq $locus_name) {
           push(@list, $sub);
       }
   }
   return @list;
}


#------------------------------------------------------------------------------------------

sub make_menu {
    my( $self, $name, $pos, @rest ) = @_;
    
    $pos ||= 0;
    
    my $menu_frame = $self->menu_bar
        or confess "No menu_bar";
    my $button = $menu_frame->Menubutton(
        -text       => $name,
        -underline  => $pos,
        #-padx       => 8,
        #-pady       => 6,
        );
    $button->pack(
        -side       => 'left',
        );
    my $menu = $button->Menu(
        -tearoff    => 0,
        @rest,
    );
    $button->configure(
        -menu       => $menu,
    );
    
    return $menu;
}

sub attach_xace {
    my( $self ) = @_;
    
    if (my $xwid = $self->get_xace_window_id) {
        my $xrem = Hum::Ace::XaceRemote->new($xwid);
        $self->xace_remote($xrem);
    } else {
        warn "no xwindow id: $xwid";
    }
}

sub xace_process_id {
    my( $self, $xace_process_id ) = @_;
    
    if ($xace_process_id) {
        $self->{'_xace_process_id'} = $xace_process_id;
    }
    return $self->{'_xace_process_id'};
}

sub launch_xace {
    my( $self ) = @_;
    
    $self->kill_xace;
    
    if (my $path = $self->ace_path) {
        if (my $pid = fork) {
            $self->xace_process_id($pid);
            $self->get_xwindow_id_from_readlock;
        }
        elsif (defined($pid)) {
            no warnings;
            exec('xace', '-fmapcutcoords', $path);
            exit(1);
        }
        else {
            confess "Error: can't fork : $!";
        }
    } else {
        warn "Error: ace_path not set";
    }
}

sub kill_xace {
    my( $self ) = @_;
    
    if (my $pid = $self->xace_process_id) {
        warn "Killing xace process '$pid'\n";
        kill 9, $pid;
    }
}

sub get_xwindow_id_from_readlock {
    my( $self ) = @_;
    
    local(*LOCK_DIR, *LOCK_FILE);

    my $pid  = $self->xace_process_id or confess "xace_process_id not set";
    my $path = $self->ace_path        or confess "ace_path not set";
    
    # Find the readlock file for the process we just launched
    my $lock_dir = "$path/database/readlocks";
    my( $lock_file );
    my $wait_seconds = 120;
    for (my $i = 0; $i < $wait_seconds; $i++, sleep 1) {
        opendir LOCK_DIR, $lock_dir or confess "Can't opendir '$lock_dir' : $!";
        ($lock_file) = grep /\.$pid$/, readdir LOCK_DIR;
        closedir LOCK_DIR;
        if ($lock_file) {
            $lock_file = "$lock_dir/$lock_file";
            last;
        }
    }
    unless ($lock_file) {
        warn "Can't find xace readlock file in '$lock_dir' for process '$pid' after waiting for $wait_seconds seconds\n";
        return 0;
    }
    
    my( $xwid );
    for (my $i = 0; $i < $wait_seconds; $i++, sleep 1) {
        # Extract the WindowID from the readlock file
        open LOCK_FILE, $lock_file or confess "Can't read '$lock_file' : $!";
        while (<LOCK_FILE>) {
            #warn "Looking at: $_";
            if (/WindowID: (\w+)/) {
                $xwid = $1;
                last;
            }
        }
        close LOCK_FILE;
        
        last if $xwid;
    }
    if ($xwid) {
        my $xrem = Hum::Ace::XaceRemote->new($xwid);
        $self->xace_remote($xrem);
        return 1;
    } else {
        warn "WindowID was not found in lock file - outdated version of xace?";
        return 0;
    }
}

sub populate_menus {
    my( $self ) = @_;
    
    my $menu_frame = $self->menu_bar
        or confess "No menu_bar";
    my $top = $menu_frame->toplevel;
    
    # File menu
    my $file = $self->make_menu('File');
    
    # Save annotations to otter
    my $save_command = sub {
        unless ($self->close_all_edit_windows) {
            $self->message('Not saving because some editing windows are still open');
            return;
        }
        $self->save_data(1);
        };
    $file->add('command',
        -label          => 'Save',
        -command        => $save_command,
        -accelerator    => 'Ctrl+S',
        -underline      => 0,
        );
    $top->bind('<Control-s>', $save_command);
    $top->bind('<Control-S>', $save_command);
  
    # Resync with database
    my $resync_command = sub { $self->resync_with_db };
    $file->add('command',
        -label          => 'Resync',
        -hidemargin     => 1,
        -command        => $resync_command,
        -accelerator    => 'Ctrl+R',
        -underline      => 0,
        );
    $top->bind('<Control-r>', $resync_command);
    $top->bind('<Control-R>', $resync_command);

    # Close window
    my $exit_command = sub {
        $self->exit_save_data or return;
        $self->top_window->destroy;
        };
    $file->add('command',
        -label          => 'Close',
        -command        => $exit_command,
        -accelerator    => 'Ctrl+W',
        -underline      => 0,
        );
    $top->bind('<Control-w>', $exit_command);
    $top->bind('<Control-W>', $exit_command);
    $top->protocol('WM_DELETE_WINDOW', $exit_command);
    
    # Subseq menu
    my $subseq = $self->make_menu('SubSeq', 1);
    
    # Edit subsequence
    my $edit_command = sub{
        $self->edit_subsequences;
        };
    $subseq->add('command',
        -label          => 'Edit',
        -command        => $edit_command,
        -accelerator    => 'Ctrl+E',
        -underline      => 0,
        );
    $top->bind('<Control-e>', $edit_command);
    $top->bind('<Control-E>', $edit_command);
    
    # Close all open subseq windows
    my $close_subseq_command = sub{
        $self->close_all_subseq_edit_windows;
        };
    $subseq->add('command',
        -label          => 'Close all',
        -command        => $close_subseq_command,
        -accelerator    => 'F4',
        -underline      => 0,
        );
    $top->bind('<F4>', $close_subseq_command);
    $top->bind('<F4>', $close_subseq_command);

    # Copy selected subseqs to holding pen
    my $copy_subseq = sub{
        $self->copy_selected_subseqs;
        };
    $subseq->add('command',
        -label          => 'Copy',
        -command        => $copy_subseq,
        -accelerator    => 'Ctrl+C',
        -underline      => 0,
        );
    $top->bind('<Control-c>', $copy_subseq);
    $top->bind('<Control-C>', $copy_subseq);

    # Paste selected subseqs, realigning them to the genomic sequence
    my $paste_subseq = sub{
        eval {
            $self->paste_selected_subseqs;
        };
        if ($@) {
            $self->exception_message($@);
        }
    };
    $subseq->add('command',
        -label          => 'Paste',
        -command        => $paste_subseq,
        -accelerator    => 'Ctrl+V',
        -underline      => 0,
        );
    $top->bind('<Control-v>', $paste_subseq);
    $top->bind('<Control-V>', $paste_subseq);
    
    #  --- Separator ---
    $subseq->add('separator');
    
    # New subsequence
    my $new_command = sub{
        $self->edit_new_subsequence;
        };
    $subseq->add('command',
        -label          => 'New',
        -command        => $new_command,
        -accelerator    => 'Ctrl+N',
        -underline      => 0,
        );
    $top->bind('<Control-n>', $new_command);
    $top->bind('<Control-N>', $new_command);
    
    # Make an variant of the current selected sequence
    my $variant_command = sub{
        $self->make_variant_subsequence;
        };
    $subseq->add('command',
        -label          => 'Variant',
        -command        => $variant_command,
        -accelerator    => 'Ctrl+I',
        -underline      => 2,
        );
    $top->bind('<Control-i>', $variant_command);
    $top->bind('<Control-I>', $variant_command);
    
    # Delete subsequence
    my $delete_command = sub {
        $self->delete_subsequences;
        };
    $subseq->add('command',
        -label          => 'Delete',
        -command        => $delete_command,
        -accelerator    => 'Ctrl+D',
        -underline      => 0,
        );
    $top->bind('<Control-d>', $delete_command);
    $top->bind('<Control-D>', $delete_command);

    ### Unimplemented methods
    #$subseq->add('command',
    #    -label          => 'Merge',
    #    -command        => sub{ warn "Called Merge" },
    #    -accelerator    => 'Ctrl+M',
    #    -underline      => 0,
    #    -state          => 'disabled',
    #    );
    #$subseq->add('command',
    #    -label          => 'AutoMerge',
    #    -command        => sub{ warn "Called AutoMerge" },
    #    -accelerator    => 'Ctrl+U',
    #    -underline      => 0,
    #    -state          => 'disabled',
    #    );
    #
    # What did I intend this command to do?
    #$subseq->add('command',
    #    -label          => 'Transcript',
    #    -command        => sub{ warn "Called Transcript" },
    #    -accelerator    => 'Ctrl+T',
    #    -underline      => 0,
    #    );

    my $clone_menu = $self->make_menu("Clone");
    $self->clone_menu($clone_menu);

    my $tools_menu = $self->make_menu("Tools");

    # Launch Zmap
    my $zmap_launch_command = sub { $self->zMapLaunchZmap };
    $tools_menu->add('command',
               -label          => 'Launch ZMap',
               -command        => $zmap_launch_command,
               -accelerator    => 'Ctrl+Z',
               -underline      => 7,
               );
    $top->bind('<Control-z>', $zmap_launch_command);
    $top->bind('<Control-Z>', $zmap_launch_command);

    $zmap_launch_command = sub { $self->zMapLaunchInAZmap };
    $tools_menu->add('command',
               -label          => 'Launch In A ZMap',
               -command        => $zmap_launch_command,
               -underline      => 7,
               );

    # Launce xace
    my $xace_launch_command = sub { $self->launch_xace };
    # Hide menu item, but keep keyboard shortcut:
    # $tools_menu->add('command',
    #     -label          => 'Launch Xace',
    #     -command        => $xace_launch_command,
    #     -accelerator    => 'Ctrl+L',
    #     -underline      => 7,
    #     );
    $top->bind('<Control-l>', $xace_launch_command);
    $top->bind('<Control-L>', $xace_launch_command);
     
    ## Attach xace
    #my $xace_attach_command = sub { $self->attach_xace };
    #$tools_menu->add('command',
    #    -label          => 'Attach Xace',
    #    -command        => $xace_attach_command,
    #    -accelerator    => 'Ctrl+X',
    #    -underline      => 0,
    #    );
    #$top->bind('<Control-x>', $xace_attach_command);
    #$top->bind('<Control-X>', $xace_attach_command);

    # Genomic Features editing window
    my $gf_command = sub { $self->launch_GenomicFeatures };
    $tools_menu->add('command' ,
        -label          => 'Genomic Features',    
        -command        => $gf_command,
        -accelerator    => 'Ctrl+G',
        -underline      => 0,
    );
    $top->bind('<Control-g>', $gf_command);
    $top->bind('<Control-G>', $gf_command);    
   
    ## Spawn dotter Ctrl .
    my $run_dotter_command = sub { $self->run_dotter };
    $tools_menu->add('command',
        -label          => 'Dotter Zmap hit',
        -command        => $run_dotter_command,
        -accelerator    => 'Ctrl+.',
        -underline      => 0,
        );
    $top->bind('<Control-period>',  $run_dotter_command);
    $top->bind('<Control-greater>', $run_dotter_command);
    
    ## Spawn exonerate Ctrl .
    my $run_exon_command = sub { $self->run_exonerate };
    $tools_menu->add('command',
        -label          => 'Exonerate Zmap hit/Column',
        -command        => $run_exon_command,
        -accelerator    => 'Ctrl+X',
        -underline      => 0,
        );
    $top->bind('<Control-x>', $run_exon_command);
    $top->bind('<Control-X>', $run_exon_command);
        
    # Show dialog for renaming the locus attached to this subseq
    my $rename_locus = sub { $self->rename_locus };
    $tools_menu->add('command',
        -label          => 'Rename locus',
        -command        => $rename_locus,
        -accelerator    => 'Ctrl+Shift+L',
        -underline      => 1,
        );
    $top->bind('<Control-Shift-L>', $rename_locus);
    

    # Show dialog for renaming the locus attached to this subseq
    my $re_authorize = sub { $self->AceDatabase->Client->do_authentication; };
    $tools_menu->add('command',
        -label          => 'Re-authorize',
        -command        => $re_authorize,
        -accelerator    => 'Ctrl+Shift+A',
        -underline      => 3,
        );
    $top->bind('<Control-Shift-A>', $re_authorize);
    

    # (Re)start local pfetch server
    if ($PFETCH_SERVER_LIST->[0][0] eq 'localhost') {
        $tools_menu->add('command',
            -label          => 'Restart local pfetch server',
            -command        => sub{
                my $client = $self->AceDatabase->Client;
                # Make sure that we are authorized here by running a query against the server
                my $user = $client->do_authentication;
                warn "User '$user' is authenticated\n";
                $client->fork_local_pfetch_server;
                },
            #-accelerator    => 'Ctrl+P',
            -underline      => 0,
            );
    }

    $tools_menu->add('command',
               -label          => 'Load column data',
               -command        => sub {
                                    if($self->show_lcd_dialog() eq 'Load') {
                                        $top->Busy;
                                            # assuming DataFactory has already been initialized by AceDatabase.pm
                                        if($self->AceDatabase->topup_pipeline_data_into_ace_server()) {
                                            $self->resync_with_db;
                                            $self->zMapLaunchZmap;
                                        }
                                        $top->Unbusy;
                                    }
                                },
    );

    $subseq->bind('<Destroy>', sub{
        $self = undef;
    });
}

sub show_lcd_dialog {
    my ($self) = @_;

    my $lcd_dialog = $self->top_window()->DialogBox( -title => 'Load column data', -buttons => ['Load', 'Cancel'] );

    my $DataFactory = $self->AceDatabase->pipeline_DataFactory();
    my $n2f = $DataFactory->get_names2filters();
    foreach my $filter_name (@{ $DataFactory->get_all_filter_names() }) {
        my $filter = $n2f->{$filter_name};
        my $cb = $lcd_dialog->add('Checkbutton',
            -text => $filter_name,
            -variable => \$filter->{_wanted},
            -onvalue => 1,
            -offvalue => 0,
            -anchor => 'w',
            $filter->done() ? ( -selectcolor => 'green' ) : (),
        )->pack(-side=>'top', -fill => 'x', -expand => 1);

            # keep it permanently selected:
        if($filter->done()) {
            $cb->configure(-command => sub { $cb->select(); });   
        }
    }

    return $lcd_dialog->Show();
}

sub populate_clone_menu {
    my ($self) = @_;
    
    my $clone_menu = $self->clone_menu;
    foreach my $clone ($self->Assembly->get_all_Clones) {
        my $name = $clone->name;
        $clone_menu->add('command',
            -label          => $clone->clone_name,
            # Not an accelerator - just for formatting!
            -accelerator    => $clone->accession_version,
            -command        => sub{ $self->edit_Clone($name) },
            );
    }
    
    $clone_menu->bind('<Destroy>', sub{
        $self = undef;
    });
}

sub bind_events {
    my( $self ) = @_;
    
    my $canvas = $self->canvas;

    $canvas->Tk::bind('<Button-1>', [
        sub{ $self->left_button_handler(@_); },
        Tk::Ev('x'), Tk::Ev('y') ]);
    $canvas->Tk::bind('<Shift-Button-1>', [
        sub{ $self->shift_left_button_handler(@_); },
        Tk::Ev('x'), Tk::Ev('y') ]);
    $canvas->Tk::bind('<Double-Button-1>', [
        sub{
            $self->left_button_handler(@_);
            $self->edit_double_clicked;
            },
        Tk::Ev('x'), Tk::Ev('y') ]);
    
    $canvas->Tk::bind('<Escape>',   sub{ $self->deselect_all        });    
    $canvas->Tk::bind('<Return>',   sub{ $self->edit_double_clicked });    
    $canvas->Tk::bind('<KP_Enter>', sub{ $self->edit_double_clicked });

    # Clipboard
    $canvas->SelectionHandle( sub{ $self->selected_text_to_clipboard(@_) });
    
    # Object won't get DESTROY'd without:
    $canvas->Tk::bind('<Destroy>', sub{
        #cluck "Dealing with <Destroy> call";
        $self = undef;
        });
}

sub highlight {
    my $self = shift;
    
    $self->SUPER::highlight(@_);
    
    my $canvas = $self->canvas;
    $canvas->SelectionOwn(
        -command    => sub{ $self->deselect_all; },
    );
    weaken $self;
}

sub GenomicFeatures {
    my ($self, $gfs) = @_ ;

    if(defined($gfs)){
        $self->{_gfs} = $gfs;
        weaken($self->{_gfs});
    }
    return $self->{_gfs};
}

sub launch_GenomicFeatures {
    my( $self ) = @_;
    eval {
        if(my $gfs = $self->GenomicFeatures()) {

            my $gfw = $gfs->top_window();
            $gfw->deiconify;
            $gfw->raise;
        } else {
            my $gfw = $self->canvas->Toplevel;

            $gfs = MenuCanvasWindow::GenomicFeatures->new($gfw);
            $self->GenomicFeatures($gfs);
            $gfs->XaceSeqChooser($self);
            $gfs->initialize;
        }
    };
    if ($@) {
        my $msg = "Error creating GenomicFeatures window: $@";
        warn $msg;
        $self->exception_message($msg);
    }
}

sub close_GenomicFeatures {
    my $self = shift @_;

    if(my $gfs = $self->GenomicFeatures()) {
        $gfs->try2save_and_quit();
    }
}

{
    my( @holding_pen );

    sub copy_selected_subseqs {
        my( $self ) = @_;
        
        # Empty holding pen
        @holding_pen = ();
        
        my @select = $self->list_selected_subseq_names;
        unless (@select) {
            $self->message('Nothing selected');
            return;
        }
        foreach my $name (@select) {
            my $sub = $self->get_SubSeq($name)->clone;
            $sub->is_archival(0);
            push(@holding_pen, $sub);
        }
    }

    sub paste_selected_subseqs {
        my( $self ) = @_;
        
        unless (@holding_pen) {
            $self->message('No SubSequences on clipboard');
            return;
        }
        
        my $assembly = $self->Assembly;
        
        # The ExonLoacator finds exons in a genomic sequence
        my $finder = Hum::Analysis::Factory::ExonLocator->new;
        $finder->genomic_Sequence($assembly->Sequence);

        my( @msg, @new_subseq, $i );
        foreach my $sub (@holding_pen) {
            my $name = $sub->name;
            my $exon_seq = $sub->exon_Sequence_array;
            my $fs = $finder->find_best_Feature_set($exon_seq);
            my @exons = $sub->get_all_Exons;
            my( $strand, @new_exons, $done_msg );
            for (my $i = 0; $i < @exons; $i++) {
                my $feat = $fs->[$i] or next;
                my $ex = Hum::Ace::Exon->new;
                $ex->start($feat->seq_start);
                $ex->end($feat->seq_end);
                $strand ||= $feat->seq_strand;
                push(@new_exons, $ex);
            }
            
            if (@new_exons) {
                my $new = $sub->clone;
                my( $temp_name );
                do {
                    $temp_name = sprintf "TEMP-%03d", ++$i;
                } while ($self->get_SubSeq($temp_name));
                #my $temp_name = sprintf "TEMP-%03d", ++$i;
                $new->name($temp_name);
                $new->strand($strand);
                $new->replace_all_Exons(@new_exons);
                $new->clone_Sequence($assembly->Sequence);
                $assembly->add_SubSeq($new);
                if ($sub->translation_region_is_set) {
                    eval {
                        $new->set_translation_region_from_cds_coords($sub->cds_coords);
                    };
                    if ($@) {
                        push(@msg, "Failed to set translation region - check translation of '$temp_name'");
                        $new->translation_region($new->start, $new->end);
                    }
                }
                $new->Locus($self->get_Locus($sub->Locus->name));
                ### set locus gene_type_prefix() here ?
                $self->add_SubSeq($new);
                push(@new_subseq, $new);
                print STDERR $new->ace_string;
            } else {
                $self->message("Got zero exons from realigning '$name'");
            }
        }
        $self->draw_subseq_list;
        $self->highlight_by_name(map $_->name, @new_subseq);
        $self->message(@msg) if @msg;
        foreach my $new (@new_subseq) {
            $self->make_exoncanvas_edit_window($new);
        }
    }
}

sub exit_save_data {
    my( $self ) = @_;

    my $adb = $self->AceDatabase;
    unless ($adb->write_access) {
        $adb->error_flag(0);
        $self->close_GenomicFeatures;
        $self->kill_xace;
        return 1;
    }
    
    $self->close_all_edit_windows or return;
    
    # Ask the user if any changes should be saved
    my $dialog = $self->top_window()->Dialog(
        -title          => 'Otter save?',
        -bitmap         => 'question',
        -text           => "Save any changes to otter server?",
        -default_button => 'Yes',
        -buttons        => [qw{ Yes No Cancel }],
        );
    my $ans = $dialog->Show;

    if ($ans eq 'Cancel') {
        return;
    }
    elsif ($ans eq 'Yes') {
        # Return false if there is a problem saving
        $self->save_data(0) or return;
    }

    # Will not want xace any more
    $self->kill_xace;

    # Unsetting the error_flag means that AceDatabase
    # will remove its directory during DESTROY.
    $adb->error_flag(0);
    
    return 1;
}

sub close_all_edit_windows {
    my( $self ) = @_;
    
    $self->close_all_subseq_edit_windows or return;
    $self->close_all_clone_edit_windows or return;
    $self->close_GenomicFeatures;
    return 1;
}

sub save_data {
    my( $self, $update_ace ) = @_;

    # update_ace should be true unless object is exiting 
    # i.e. when called from ->exit_save_data()

    unless ($self->AceDatabase->write_access) {
        warn "Read only session - not saving\n";
        return 1;   # Can't save - but is OK
    }
    my $top = $self->top_window();

    $top->Busy;

    eval{
        my $ace_data = $self->AceDatabase->save_ace_to_otter;
        # update_ace should be true unless this object is exiting
        if ($update_ace and $ace_data) {
            $self->save_ace($ace_data);
            # resync here!
            $self->resync_with_db;
        }
    };
    my $err = $@;
    
    $top->Unbusy;
    # $top->raise;  # Not needed, now that we don't restart xace
    
    if ($err) {
        $self->exception_message($err, 'Error saving to otter');
        return 0;
    } else {
        return 1;
    }
}

sub edit_double_clicked {
    my( $self ) = @_;
    
    return unless $self->list_selected;
    
    my $canvas = $self->canvas;
    $canvas->Busy;
    $self->edit_subsequences;
    $canvas->Unbusy;
}

sub left_button_handler {
    my( $self, $canvas, $x, $y ) = @_;

    return if $self->delete_message;

    $self->deselect_all;
    if (my ($obj) = $canvas->find('withtag', 'current')) {
        $self->highlight($obj);
    }
}

sub shift_left_button_handler {
    my( $self, $canvas, $x, $y ) = @_;

    return if $self->delete_message;

    if (my ($obj) = $canvas->find('withtag', 'current')) {
        if ($self->is_selected($obj)) {
            $self->remove_selected($obj);
        } else {
            $self->highlight($obj);
        }
    }
}

sub make_search_panel {
    my ($self) = @_;

    my $top = $self->top_window();
    my $search_frame = $top->Frame();
    $search_frame->pack(-side => 'top');
    
    my $search_box = $search_frame->Entry(
        -width => 22,
        );
    $search_box->pack(-side => 'left');
    
    $search_frame->Frame(-width => 6)->pack(-side => 'left');
    
    # Is hunting in CanvasWindow?
    my $hunter = sub{
	    $top->Busy;
	    $self->hunt_for_Entry_text($search_box);
	    $top->Unbusy;
    };
    my $button = $search_frame->Button(
         -text      => 'Find',
         -command   => $hunter,
         -underline => 0,
         )->pack(-side => 'left');

    my $clear_command = sub {
        $search_box->delete(0, 'end');
        };
    my $clear = $search_frame->Button(
        -text      => 'Clear',
        -command   => $clear_command,
        -underline => 2,
        )->pack(-side => 'left');
    $top->bind('<Control-e>',   $clear_command);
    $top->bind('<Control-E>',   $clear_command);
    
    $search_box->bind('<Return>',   $hunter);
    $search_box->bind('<KP_Enter>', $hunter);
    $top->bind('<Control-f>',       $hunter);
    $top->bind('<Control-F>',       $hunter);

    $button->bind('<Destroy>', sub{
        $self = undef;
        });
}


sub hunt_for_Entry_text {
    my ($self, $entry) = @_; 

    # Searches for the text given in the supplied Entry in
    # the acedb string representation of all the subsequences.

    my $canvas = $self->canvas;
    my( $query_str, $regex );
    eval{
	    $query_str = $entry->get();
	    $query_str =~ s{([^\w\*\?\\])}{\\$1}g;
	    $query_str =~ s{\*}{.*}g;
	    $query_str =~ s{\?}{.}g;
	    $regex =  qr/($query_str)/i;
    };
    return unless $query_str;
    # warn $query_str;
    # warn $regex;
    $canvas->delete('msg');
    $self->deselect_all();

    my @matching_sub_names;
    foreach my $name ($self->list_all_SubSeq_names) {
        my $sub = $self->get_SubSeq($name) or next;
        my $str = $sub->ace_string;
        if (my ($hit) = $str =~ /$regex/) {
            push(@matching_sub_names, $name);
        }
    }
    if (@matching_sub_names) {
        $self->highlight_by_name(@matching_sub_names);
    } else {
        $self->message("Can't find '$query_str'");
        return;        
    }
}


sub ace_handle {
    my( $self ) = @_;
    
    return $self->AceDatabase->aceperl_db_handle;
}

sub ace_path {
    my( $self ) = @_;
    
    return $self->AceDatabase->home;
}

sub save_ace {
    my $self = shift;
    
    my $val;
    eval { $val = $self->AceDatabase->ace_server->save_ace(@_) };
    if ($@) {
        $self->exception_message($@, "Error saving to acedb");
        confess "Error saving to acedb: $@";
    } else {
        return $val;
    }
}

sub resync_with_db {
    my( $self ) = @_;
    
    
    unless ($self->close_all_edit_windows) {
        $self->message("All editor windows must be closed before a ReSync");
        return;
    }
    
    $self->canvas->Busy(
        -recurse => 0,
        );
    
    $self->empty_Assembly_cache;
    $self->empty_SubSeq_cache;
    $self->empty_Locus_cache;
    
    # Redisplay
    $self->draw_subseq_list;
    
    $self->canvas->Unbusy;
}

sub max_seq_list_length {
    return 1000;
}

sub slice_name {
    my( $self ) = @_;
    
    my $slice_name;
    unless ($slice_name = $self->{'_slice_name'}) {
        my $adbh = $self->ace_handle;
        my @slice_list = map $_->name,
            $adbh->fetch(Assembly => '*');
        if (@slice_list > 1) {
            $self->message("Error: more than 1 assembly in database:", @slice_list);
            return;
        }
        $slice_name = $self->{'_slice_name'} = $slice_list[0];
    }
    return $slice_name;
}

sub edit_subsequences {
    my( $self, @sub_names ) = @_;
    
    @sub_names = $self->list_selected_subseq_names
        unless @sub_names;
    foreach my $sub_name (@sub_names) {
        # Just show the edit window if present
        next if $self->raise_subseq_edit_window($sub_name);
        
        # Get a copy of the subseq
        if (my $sub = $self->get_SubSeq($sub_name)) {
            my $edit = $sub->clone;
            $edit->otter_id($sub->otter_id);
            $edit->translation_otter_id($sub->translation_otter_id);
            $edit->is_archival($sub->is_archival);
        
            $self->make_exoncanvas_edit_window($edit);
        } else {
            warn "Failed to get_SubSeq($sub_name)";
        }
    }
}

sub edit_new_subsequence {
    my( $self ) = @_;
    
    my @sub_names = $self->list_selected_subseq_names;
    my $clip      = $self->get_clipboard_text || '';

    my( @subseq );
    foreach my $sn (@sub_names) {
        my $sub = $self->get_SubSeq($sn);
        push(@subseq, $sub);
    }
    
    my ($new);
    if (@subseq) {
        $new = Hum::Ace::SubSeq->new_from_subseq_list(@subseq);
    }
    else {
        $new = Hum::Ace::SubSeq->new_from_clipboard_text($clip);
        $new->clone_Sequence($self->Assembly->Sequence);
    }
    
    my ($region_name, $max) = $self->region_name_and_next_locus_number($new);
    
    my $prefix = Bio::Otter::Lace::Defaults::fetch_gene_type_prefix() || '';
    my $loc_name = $prefix ? "$prefix:$region_name.$max" : "$region_name.$max";
    my $locus = $self->get_Locus($loc_name);
    $locus->gene_type_prefix($prefix);

    my $seq_name = "$loc_name-001";
    
    # Check we don't already have a sequence of this name
    if ($self->get_SubSeq($seq_name)) {
        # Should be impossible, I hope!
        $self->message("Tried to make new SubSequence name but already have SubSeq named '$seq_name'");
        return;
    }

    $new->name($seq_name);
    $new->Locus($locus);
    my $gm = $self->get_default_mutable_GeneMethod or confess "No default mutable GeneMethod";    
    $new->GeneMethod($gm);
    # Need to initialise translation region for coding transcripts
    if ($gm->transcript_type eq 'coding') {
        $new->translation_region($new->translation_region);
    }

    $self->add_SubSeq_and_paste_evidence($new, $clip);
}

sub region_name_and_next_locus_number {
    my ($self, $new) = @_;
    
    my $most_3prime = $new->strand == 1 ? $new->end : $new->start;
    
    my $assembly = $self->Assembly;
    # Check that our coordinate is not off the end of the assembly
    if ($most_3prime and ($most_3prime < 0 or $most_3prime > $assembly->Sequence->sequence_length)) {
        $most_3prime = undef;
    }
    my $region_name = $most_3prime
        ? $assembly->clone_name_overlapping($most_3prime)
        : $assembly->name;
    warn "Looking for clone overlapping '$most_3prime' found '$region_name'";
    
    # Trim sequence version from accession if clone_name ends .SV
    $region_name =~ s/\.\d+$//;

    # Now get the maximum locus number for this root
    my $regex = qr{^(?:[^:]+:)?$region_name\.(\d+)}; # qr is a Perl 5.6 feature
    my $max = 0;
    foreach my $sub ($assembly->get_all_SubSeqs) {
        my ($n) = $sub->name =~ /$regex/;
        if ($n and $n > $max) {
            $max = $n;
        }
    }
    $max++;
    
    return ($region_name, $max);
}

sub make_variant_subsequence {
    my( $self ) = @_;
    
    my $clip      = $self->get_clipboard_text || '';
    my @sub_names = $self->list_selected_subseq_names;
    unless (@sub_names) {
        @sub_names = $self->list_was_selected_subseq_names;
    }

    # warn "Got subseq names: (@sub_names)";
    unless (@sub_names) {
        $self->message("No subsequence selected");
        return;
    }
    elsif (@sub_names > 1) {
        $self->message("Can't make a variant from more than one selected sequence");
        return;
    }
    my $name = $sub_names[0];
    my $sub = $self->get_SubSeq($name);
    my $assembly = $self->Assembly;
    
    # Work out a name for the new variant
    my $var_name = $name;
    if ($var_name =~ s/-(\d{3,})$//) {
        my $root = $var_name;

        # Now get the maximum variant number for this root
        my $regex = qr{^$root-(\d{3,})$};
        my $max = 0;
        foreach my $sub ($assembly->get_all_SubSeqs) {
            my ($n) = $sub->name =~ /$regex/;
            if ($n and $n > $max) {
                $max = $n;
            }
        }

        $var_name = sprintf "%s-%03d", $root, $max + 1;
    
        # Check we don't already have the variant we are trying to create
        if ($self->get_SubSeq($var_name)) {
            $self->message("Tried to create variant '$var_name', but it already exists! (Should be impossible)");
            return;
        }
    } else {
        $self->message(
            "SubSequence name '$name' is not in the expected format " .
            "(ending with a dash followed by three or more digits).",
            "Perhaps you want to use the \"New\" funtion instead?",
            );
        return;
    }
    
    # Make the variant
    my $var = $sub->clone;
    $var->name($var_name);
    $var->empty_evidence_hash;
    $var->empty_remarks;
    $var->empty_annotation_remarks;
    
    if (text_is_zmap_clip($clip)) {
        my $clip_sub = Hum::Ace::SubSeq->new_from_clipboard_text($clip);
        $var->replace_all_Exons($clip_sub->get_all_Exons);
    }
    
    $self->add_SubSeq_and_paste_evidence($var, $clip);
}

sub add_SubSeq_and_paste_evidence {
    my ($self, $sub, $clip) = @_;
    
    $self->Assembly->add_SubSeq($sub);

    $self->add_SubSeq($sub);
    $self->draw_subseq_list;
    $self->highlight_by_name($sub->name);
    
    my $ec = $self->make_exoncanvas_edit_window($sub);
    $ec->merge_position_pairs;  # Useful if multiple overlapping evidence selected
    my $clip_evi = evidence_type_and_name_from_text($self->ace_handle, $clip);
    if (keys %$clip_evi) {
        $ec->EvidencePaster->add_evidence_type_name_hash($clip_evi);
    }    
}

sub delete_subsequences {
    my( $self ) = @_;
    
    # Make a list of editable SubSeqs from those selected,
    # which we are therefore allowed to delete.
    my @sub_names = $self->list_selected_subseq_names;
    my( @to_die );
    foreach my $sub_name (@sub_names) {
        my $sub = $self->get_SubSeq($sub_name);
        if ($sub->GeneMethod->mutable) {
            push(@to_die, $sub);
        }
    }
    return unless @to_die;

    # Check that none of the sequences to be deleted are being edited    
    my $in_edit = 0;
    foreach my $sub (@to_die) {
        $in_edit += $self->raise_subseq_edit_window($sub->name);
    }
    if ($in_edit) {
        $self->message("Must close edit windows before calling delete");
        return;
    }
    
    # Check that the user really wants to delete them
    my( $question );
    if (@to_die > 1) {
        $question = join('',
            "Really delete these subsequences?\n\n",
            map("  $_\n", map($_->name, @to_die)),
            );
    } else {
        $question = "Really delete this subsequence?\n\n  "
            . $to_die[0]->name ."\n";
    }
    my $dialog = $self->top_window()->Dialog(
        -title          => 'Delete subsequenes?',
        -bitmap         => 'question',
        -text           => $question,
        -default_button => 'Yes',
        -buttons        => [qw{ Yes No }],
        );
    my $ans = $dialog->Show;

    return if $ans eq 'No';
    
    # Make ace delete command for subsequences
    my $ace = '';
    my @xml;
    foreach my $sub (@to_die) {
        # Only attempt to delete sequences which have been saved
        if ($sub->is_archival) {
            my $sub_name   = $sub->name;
            my $clone_name = $sub->clone_Sequence->name;
            $ace .= qq{\n\-D Sequence "$sub_name"\n}
                . qq{\nSequence "$clone_name"\n}
                . qq{-D Subsequence "$sub_name"\n};
            push @xml, $sub->zmap_delete_xml_string;
        }
    }
    
    # Delete from acedb database and Zmap
    $self->save_ace($ace);
    $self->send_zmap_commands(@xml);
    
    # Remove from our objects
    foreach my $sub (@to_die) {
        $self->delete_SubSeq($sub);
    }
    
    $self->draw_subseq_list;
}

sub make_exoncanvas_edit_window {
    my( $self, $sub ) = @_;
    
    my $sub_name = $sub->name;
#    warn "subsequence-name $sub_name " ;
#    warn "locus " . $sub->Locus->name ;
    my $canvas = $self->canvas;
    
    # Make a new window
    my $top = $canvas->Toplevel;
    
    # Make new MenuCanvasWindow::ExonCanvas object and initialize
    my $ec = MenuCanvasWindow::ExonCanvas->new($top, 345, 50);
    $ec->name($sub_name);
    $ec->XaceSeqChooser($self);
    $ec->SubSeq($sub);
    $ec->initialize;
    
    $self->save_subseq_edit_window($sub_name, $ec);
    
    return $ec;
}

sub raise_subseq_edit_window {
    my( $self, $name ) = @_;
    
    confess "no name given" unless $name;
    
    if (my $ec = $self->get_subseq_edit_window($name)) {
        my $top = $ec->canvas->toplevel;
        $top->deiconify;
        $top->raise;
        return 1;
    } else {
        return 0;
    }
}

sub get_subseq_edit_window {
    my( $self, $name ) = @_;
    
    return $self->{'_subseq_edit_window'}{$name};
}

sub list_all_subseq_edit_window_names {
    my( $self ) = @_;
    
    return keys %{$self->{'_subseq_edit_window'}};
}

sub save_subseq_edit_window {
    my( $self, $name, $ec ) = @_;
    
    $self->{'_subseq_edit_window'}{$name} = $ec;
    weaken($self->{'_subseq_edit_window'}{$name});
}

sub delete_subseq_edit_window {
    my( $self, $name ) = @_;
    
    delete($self->{'_subseq_edit_window'}{$name});
}

sub rename_subseq_edit_window {
    my( $self, $old_name, $new_name ) = @_;
    
    my $win = $self->get_subseq_edit_window($old_name)
        or return;
    $self->delete_subseq_edit_window($old_name);
    $self->save_subseq_edit_window($new_name, $win);
}

sub close_all_subseq_edit_windows {
    my( $self ) = @_;

    foreach my $name ($self->list_all_subseq_edit_window_names) {
        my $ec = $self->get_subseq_edit_window($name) or next;
        $ec->window_close or return 0;
    }
    
    return 1;
}

sub draw_subseq_list {
    my( $self ) = @_;
    
    my $canvas = $self->canvas;
    
    my $slist = [];
    my $counter = 1;
    foreach my $clust ($self->get_all_Subseq_clusters) {
    #foreach my $clust ($self->get_ace_sorted_SubSeqs) {
        push(@$slist, "") if @$slist;
        push(@$slist, @$clust);
    }
    
    $self->draw_sequence_list($slist);
    $self->fix_window_min_max_sizes;
}

sub get_ace_sorted_SubSeqs {
    my ($self) = @_;
    
    my $assembly = $self->Assembly;
    return [sort { ace_sort($a->name, $b->name) } $assembly->get_all_SubSeqs];
}

sub get_all_Subseq_clusters {
    my( $self ) = @_;
    
    my $assembly = $self->Assembly;
    my @subseq = sort {
           $a->start  <=> $b->start
        || $a->end    <=> $b->end
        || $a->strand <=> $b->strand
        } $assembly->get_all_SubSeqs;
    my $first = $subseq[0] or return;
    my( @clust );
    my $ci = 0;
    $clust[$ci] = [$first];
    my $x      = $first->start;
    my $y      = $first->end;
    my $strand = $first->strand;
    for (my $i = 1; $i < @subseq; $i++) {
        my $this = $subseq[$i];
        if ($this->strand == $strand
            and $this->start <= $y
            and $this->end   >= $x)
        {
            push(@{$clust[$ci]}, $this);
            $x = $this->start if $this->start < $x;
            $y = $this->end   if $this->end   > $y;
        } else {
            $ci++;
            $clust[$ci] = [$this];
            $x      = $this->start;
            $y      = $this->end;
            $strand = $this->strand;
        }
    }
    
    foreach my $c (@clust) {
        $c = [sort { ace_sort($a->name cmp $b->name) } @$c];
    }
    
    return sort {$a->[0]->start <=> $b->[0]->start} @clust;
}

sub edit_Clone {
    my ($self, $name) = @_;
    
    my $clone = $self->Assembly->get_Clone($name);

    # show Clone EditWindow
    my $cew;
    unless ($cew = $self->{'_clone_edit_window'}{$name}) {
        $cew = EditWindow::Clone->new($self->top_window->Toplevel(
            -title => sprintf("Clone: %s", $clone->clone_name),
            ));
        $cew->XaceSeqChooser($self);
        $cew->Clone($clone);
        $cew->initialise;
        $self->{'_clone_edit_window'}{$name} = $cew;
        weaken($self->{'_clone_edit_window'}{$name});
    }
    my $top = $cew->top;
    $top->deiconify;
    $top->raise;
}

sub close_all_clone_edit_windows {
    my ($self) = @_;
    
    if (my $cew_hash = $self->{'_clone_edit_window'}) {
        foreach my $win (values %$cew_hash) {
            next unless $win;   # Already closed
            $win->close_window or return;
        }
    }
    
    return 1;
}

sub Assembly {
    my( $self ) = @_;
    
    my $canvas = $self->canvas;
    my $slice_name = $self->slice_name;
    my $ace  = $self->ace_handle;
    
    unless ($self->{'_assembly'}) {
        use Time::HiRes 'gettimeofday';
        my $before = gettimeofday();
        $canvas->Busy(
            -recurse => 0,
            );
 
        my( $assembly );
        eval {
            $assembly = Hum::Ace::Assembly->new;
            $assembly->name($slice_name);
            $assembly->express_data_fetch($ace);
        };
        if ($@) {
            $self->exception_message($@, "Can't fetch Assembly '$slice_name'");
            return;
        }

        foreach my $sub ($assembly->get_all_SubSeqs) {
            $self->add_SubSeq($sub);

            # Ignore loci from non-editable SubSeqs
            next unless $sub->is_mutable;
            if (my $s_loc = $sub->Locus) {
                my $locus = $self->get_Locus($s_loc);
                $sub->Locus($locus);
            }
        }

        $self->{'_assembly'} = $assembly;
        $self->set_known_GeneMethods;
        
        my $after  = gettimeofday();
        $canvas->Unbusy;
        printf "Express fetch for '%s' took %4.3f\n", $self->slice_name, $after - $before;
    }
    return $self->{'_assembly'};
}

sub empty_Assembly_cache {
    my( $self ) = @_;
    
    $self->{'_assembly'} = undef;
}

sub replace_SubSeq {
    my( $self, $sub, $old_name ) = @_;
    
    my $sub_name = $sub->name;
    $old_name ||= $sub_name;
    $self->Assembly->replace_SubSeq($sub, $old_name);
    if ($sub_name ne $old_name) {
        $self->{'_subsequence_cache'}{$old_name} = undef;
        $self->rename_subseq_edit_window($old_name, $sub_name);
    }
    $self->{'_subsequence_cache'}{$sub_name} = $sub;

    my $locus = $sub->Locus;
    if (my $prev_name = $locus->drop_previous_name) {
        warn "Unsetting otter_id for locus '$prev_name'\n";
        $self->get_Locus($prev_name)->drop_otter_id;
    }
    $self->set_Locus($locus);

    ### Update all subseq edit windows
    $self->draw_subseq_list;
}

sub add_SubSeq {
    my( $self, $sub ) = @_;
    
    my $name = $sub->name;
    #cluck("Adding SubSeq '$name'");
    if ($self->{'_subsequence_cache'}{$name}) {
        confess "already have SubSeq '$name'";
    } else {
        $self->{'_subsequence_cache'}{$name} = $sub;
    }
}

sub delete_SubSeq {
    my( $self, $sub ) = @_;
    
    my $name = $sub->name;
    $self->Assembly->delete_SubSeq($name);
    
    if ($self->{'_subsequence_cache'}{$name}) {
        $self->{'_subsequence_cache'}{$name} = undef;
        return 1;
    } else {
        return 0;
    }
}

sub get_SubSeq {
    my( $self, $name ) = @_;
    
    confess "no name given" unless $name;
    return $self->{'_subsequence_cache'}{$name};
}

sub list_all_SubSeq_names {
    my ($self) = @_ ;

    if (my $sub_hash = $self->{'_subsequence_cache'}) {
        return keys %$sub_hash;
    } else {
        return;
    }
}

sub empty_SubSeq_cache {
    my( $self ) = @_;
    
    $self->{'_subsequence_cache'} = undef;
}

sub row_count {
    my( $self, $slist ) = @_;
    
    my $rows = $self->{'_row_count'};
    unless ($rows) {
        # Work out number of rows to keep chooser
        # window roughly square.  Also a lower and
        # an upper limit of 20 and 40 rows.  
        my $total_name_length = 0;
        foreach my $sub (grep $_, @$slist) {
            $total_name_length += length($sub->name);
        }
        $rows = int sqrt($total_name_length);
        if ($rows < 20) {
            $rows = 20;
        }
        elsif ($rows > 40) {
            $rows = 40;
        }
        
        $self->{'_row_count'} = $rows;
    }
    
    return $rows;
}

sub draw_sequence_list {
    my( $self, $slist ) = @_;


    my $canvas = $self->canvas;
    my $size = $self->font_size;
    my $pad  = int($size / 6);
    my $half = int($size / 2);
    
    my $rows = $self->row_count($slist);
    
    # Delete everything apart from messages
    $canvas->delete('!msg');

    my $x = 0;
    my $y = 0;
    for (my $i = 0; $i < @$slist; $i++) {
        if (my $sub = $slist->[$i]) {
            # Have a subseq - and not a gap in the list.

            my $style = 'bold';
            my $color = 'black';
            
            if ($sub->GeneMethod->name =~ /_trunc$/) {
                $color = '#999999';
            }
            elsif (! $sub->is_mutable) {
                $style = 'normal';
            }

	        $canvas->createText(
		        $x, $y,
		        -anchor     => 'nw',
		        -text       => $sub->name,
		        -font       => $style eq 'bold' ? $self->font_fixed_bold : $self->font_fixed,
		        -tags       => ['subseq', 'searchable'],
		        -fill       => $color,
		        );
        }
        
        if (($i + 1) % $rows) {
            $y += $size + $pad;
        } else {
            $y = 0;
            my $x_max = ($canvas->bbox('subseq'))[2];
            $x = $x_max + ($size * 2);
        }
    }
    
    # Raise messages above everything else
    eval{
        $canvas->raise('msg', 'subseq');
    };
}

sub xace_remote {
    my( $self, $xrem ) = @_;
    
    if ($xrem) {
        my $expected = 'Hum::Ace::XaceRemote';
        confess "'$xrem' is not an '$expected'"
            unless (ref($xrem) and $xrem->isa($expected));
        $self->{'_xace_remote'} = $xrem;
    }
    return $self->{'_xace_remote'};
}

sub get_xace_window_id {
    my( $self ) = @_;
    
    my $mid = $self->message("Please click on the xace main window with the cross-hairs");
    $self->delete_message($mid);
    local *XWID;
    open XWID, "xwininfo |"
        or confess("Can't open pipe from xwininfo : $!");
    my( $xwid );
    while (<XWID>) {
        # xwininfo: Window id: 0x7c00026 "ACEDB 4_9c, lace bA314N13"

      # HACK
      # above format NOT returnd by xwininfo on Sun OS 5.7:
      #  tace version:
      #  ACEDB 4_9r,  build dir: RELEASE.2003_05_01
      # 2 lines before modified to support xace at RIKEN

        # BEFORE: if (/Window id: (\w+) "([^"]+)/) {
        if (/Window id: (\w+) "([^"]+)/ || /Window id: (\w+)/) {
            my $id   = $1;
            my $name = $2;
	    # BEFORE: if ($name =~ /^ACEDB/){
            if ($name =~ /^ACEDB/ || $name eq '') {
                $xwid = $id;
                $self->message("Attached to:\n$name");
            } else {
                $self->message("'$name' is not an xace main window");
            }
        }
    }
    if (close XWID) {
        return $xwid;
    } else {
        $self->message("Error running xwininfo: $?");
    }
}

sub highlight_by_name {
    my( $self, @names ) = @_;

    $self->highlight($self->subseq_names_to_canvas_obj(@names));
}

sub highlight_by_name_without_owning_clipboard {
    my ($self, @names) = @_;
    
    if (my @obj_list = $self->subseq_names_to_canvas_obj(@names)) {
        $self->CanvasWindow::highlight(@obj_list);
    }
}

sub subseq_names_to_canvas_obj {
    my ($self, @names) = @_;
    
    my $canvas = $self->canvas;
    my %select_name = map {$_, 1} @names;
    
    my( @to_select );
    foreach my $obj ($canvas->find('withtag', 'subseq')) {
        my $n = $canvas->itemcget($obj, 'text');
        if ($select_name{$n}) {
            push(@to_select, $obj);
        }
    }
    return @to_select;
}

sub canvas_obj_to_subseq_names {
    my ($self, @obj_list) = @_;
    
    my $canvas = $self->canvas;

    my( @names );
    foreach my $obj (@obj_list) {
        if (grep $_ eq 'subseq', $canvas->gettags($obj)) {
            my $n = $canvas->itemcget($obj, 'text');
            push(@names, $n);
        }
    }
    return @names;    
}

sub list_selected_subseq_names {
    my( $self ) = @_;
    
    return $self->canvas_obj_to_subseq_names($self->list_selected);
}

sub list_was_selected_subseq_names {
    my( $self ) = @_;
    
    return $self->canvas_obj_to_subseq_names($self->list_was_selected);
}

sub rename_locus {
    my ($self, $locus_name) = @_;
    
    warn "Renaming locus";
    
    unless ($self->close_all_subseq_edit_windows) {
        $self->message('Must close all clone editing windows before renaming locus');
        return;
    }
    
    if (my $ren_window = $self->{'_locus_rename_window'}) {
        $ren_window->top->destroy;
    }
    my $parent = $self->top_window;
    my $top = $parent->Toplevel(-title => 'rename locus');
    $top->transient($parent);
    my $lr = EditWindow::LocusName->new($top);
    $lr->XaceSeqChooser($self);
    $lr->locus_name_arg($locus_name);
    $lr->initialise;
    $self->{'_locus_rename_window'} = $lr;
    weaken($self->{'_locus_rename_window'});
    
    return 1;
}

sub run_dotter {
    my( $self ) = @_;
    
    my $dw = $self->{'_dotter_window'};
    unless ($dw) {
        my $parent = $self->top_window();
        my $top = $parent->Toplevel(-title => 'run dotter');
        $top->transient($parent);
        $dw = EditWindow::Dotter->new($top);
        $dw->initialise;
        $self->{'_dotter_window'} = $dw;
    }
    $dw->update_from_XaceSeqChooser($self);
    
    return 1;
}

sub run_exonerate {
    my( $self ) = @_;

    my $ew = $self->{'_exonerate_window'};
    unless ($ew) {
        my $parent = $self->top_window();
        my $top = $parent->Toplevel(-title => 'run exonerate');
        $top->transient($parent);
        $ew = EditWindow::Exonerate->new($top);
        $ew->initialise($self->AceDatabase);
        $self->{'_exonerate_window'} = $ew;
    }
    $ew->update_from_XaceSeqChooser($self);

    return 1;
}

sub send_zmap_commands {
    my ($self, @xml) = @_;

    my $xr = $self->zMapGetXRemoteClientForView();
    unless ($xr) {
        warn "No current window.";
        return;
    }
    warn "Sending window '", $xr->window_id, "' this xml:\n", @xml;

    my @a = $xr->send_commands(@xml);

    for(my $i = 0; $i < @xml; $i++){
        my ($status, $xmlHash) = parse_response($a[$i]);
        if ($status =~ /^2\d\d/) { # 200s
            print STDERR "OK\n";
        } else {
            my $error = $xmlHash->{'error'}{'message'};
            print STDERR "ERROR: $a[$i]\n$error\n";
            $self->xremote_cache->remove_clients_to_bad_windows();
            die $error;
        }
    }    
}

sub DESTROY {
    my( $self ) = @_;
    
    warn "Destroying XaceSeqChooser for ", $self->ace_path, "\n";

    $self->zMapKillZmap;

    $self->drop_AceDatabase;
    if (my $sn = $self->SequenceNotes){
        # then refresh locks
        # warn "lock refresh should now happen\n";
        $sn->refresh_column(7) ; ## locks column
        # warn "lock refresh should have happened\n";
        # need to clean up the sequenceNotes reference
        ### No you don't!
        ###delete $self->{'_sequence_notes'} ;
    }
}

1;

__END__

=head1 NAME - MenuCanvasWindow::XaceSeqChooser

=head1 AUTHOR

James Gilbert B<email> jgrg@sanger.ac.uk


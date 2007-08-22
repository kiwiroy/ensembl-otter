package Bio::Otter::ServerScriptSupport;

use strict;

use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::Otter::DBSQL::DBAdaptor;
use Bio::Vega::DBSQL::DBAdaptor;
use Bio::Otter::Author;
use Bio::Vega::Author;
use Bio::Otter::Version;
use Bio::Otter::Lace::TempFile;

use SangerWeb;

use base 'CGI';

CGI->nph(1);

sub new {
    my $pkg = shift;
    
    my $self = $pkg->SUPER::new(@_);
    $self->authorized_user;
    return $self;
}

sub dataset_name {
    my( $self ) = @_;
    
    my $dataset_name;
    unless ($dataset_name = $self->{'_dataset_name'}) {
        $self->{'_dataset_name'} = $dataset_name = $self->require_argument('dataset');
    }
    return $dataset_name;
}


############## getters: ###########################

sub running_headcode {
    my $self = shift @_;

    #return $ENV{PIPEHEAD};    # the actual running code (0=>rel.19, 1=>rel.20+)
    return 1;
}

sub csn {   # needed by logging mechanism
    my $self = shift @_;

    my $csn;
    unless ($csn = $self->{'_current_script_name'}) {
        ($csn) = $ENV{'SCRIPT_NAME'} =~ m{([^/]+)$};
        die "Can't parse script name from '$ENV{SCRIPT_NAME}'"
          unless $csn;
        $self->{'_current_script_name'} = $csn;
    }
    return $csn
}

sub otter_version {
    my ($self) = @_;
    
    my $ver;
    unless ($ver = $self->{'_otter_version'}) {
        ($ver) = $ENV{'SCRIPT_NAME'} =~ m{/otter/(\d+)/};
        die "Unexpected script location '$ENV{SCRIPT_NAME}'"
          unless $ver;
        $self->{'_otter_version'} = $ver;
    }
    return $ver;
}

sub server_root {
    my ($self) = @_;
    
    my $root;
    unless ($root = $self->{'server_root'}) {
        $root = $ENV{'DOCUMENT_ROOT'};
        # Trim off the trailing /dir
        $root =~ s{/[^/]+$}{}
          or die "Unexpected DOCUMENT_ROOT format '$ENV{DOCUMENT_ROOT}'";
        $self->{'server_root'} = $root;
    }
    return $root;
}

sub species_hash {
    my $self = shift @_;

    my $sp;
    unless ($sp = $self->{'_species_hash'}) {
        $sp = $self->read_species_dat_file;
        $self->remove_unauthorized_species($sp);
        $self->{'_species_hash'} = $sp;
    }
    return $sp;
}

sub remove_unauthorized_species {
    my ($self, $sp) = @_;
    
    my $user = $self->authorized_user;
    my $allowed = $self->users_hash->{$user};
    foreach my $species (keys %$sp) {
        delete($sp->{$species}) unless $allowed->{$species};
    }
}

sub read_species_dat_file {
    my ($self) = @_;
    
    # '/GPFS/data1/WWW/SANGER_docs/data/otter/48/species.dat';
    my $file = join('/', $self->server_root, 'data', 'otter', $self->otter_version, 'species.dat');

    open my $dat, $file or die "Can't read species file '$file' : $!";

    my $cursect = undef;
    my $defhash = {};
    my $curhash = undef;

    while (<$dat>) {
        next if /^\#/;
        next unless /\w+/;
        chomp;

        if (/\[(.*)\]/) {
            if (!defined($cursect) && $1 ne "defaults") {
                die "ERROR: First section in species.dat should be defaults\n";
            }
            elsif ($1 eq "defaults") {
	            #print STDERR "Got default section\n";
                $curhash = $defhash;
            }
            else {
                $curhash = {};
                foreach my $key (keys %$defhash) {
                    $key =~ tr/a-z/A-Z/;
                    $curhash->{$key} = $defhash->{$key};
                }
            }
            $cursect = $1;
            $sp->{$cursect} = $curhash;

        }
        elsif (/(\S+)\s+(\S+)/) {
            #print "Reading entry $1 $2\n";
            $curhash->{$1} = $2;
        }
    }

    close $dat or die "Error reading '$file' : $!";

    # Have finished with defaults, so we can remove them.
    delete $sp->{'defaults'};

    return $sp;
}

sub users_hash {
    my ($self) = @_;
    
    my $usr;
    unless ($usr = $self->{'_users_hash'}) {
        my $usr_file = join('/', $self->server_root, 'data', 'otter', $self->otter_version, 'users.txt');
        $usr = $self->{'_users_hash'} = $self->read_user_file($usr_file);
    }
    return $usr;
}

sub read_user_file {
    my ($self, $usr_file) = @_;
    
    my $usr_hash = {};
    if (open my $list, $usr_file) {
        while (<$list>) {
            s/#.*//;            # Remove comments
            s/(^\s+|\s+$)//g;   # Remove leading or trailing spaces
            next if /^$/;       # Skip lines which are now blank
            my ($user_name, @allowed_datasets) = split;
            foreach my $ds (@allowed_datasets) {
                $usr_hash->{$user_name}{$ds} = 1;
            }
        }
        close $list or die "Error reading '$list'; $!";
    }
    return $usr_hash;
}

sub dataset_param {     # could move out into a separate class, living on top of species.dat
    my ($self, $param) = @_;

        # Check the dataset has been entered:
    my $dataset = $self->dataset_name;

        # get the overriding dataset options from species.dat 
    my $dbinfo   = $self->species_hash()->{$dataset} || $self->error_exit("Unknown data set $dataset");

        # get the defaults from species.dat
    my $defaults = $self->species_hash()->{'defaults'};

    return $dbinfo->{$param} || $defaults->{$param};
}

sub dataset_headcode {
    my $self = shift @_;

    return $self->dataset_param('HEADCODE');
}

sub authorized_user {
    my ($self) = @_;
    
    my $user;
    unless ($user = $self->{'_authorized_user'}) {
        my $sw = SangerWeb->new({ cgi => $self });
        my $auth_flag = 0;
        if ($user = $sw->username) {
            if ($user =~ /^[a-z1-9]+$/) {
                # Internal users (simple user name)
                $auth_flag = 1;
            } else {
                # Check external users (email address)
                $auth_flag = 1 if $self->users_hash->{$user};
            }
        }
        if ($auth_flag) {
            $self->{'_authorized_user'} = $user;
        } else {
            $self->unauth_exit('User not authorized');
        }
    }
    return $user;
}

############## I/O: ################################

sub log {
    my ($self, $line) = @_;

    return unless $self->param('log');

    print STDERR '['.$self->csn()."] $line\n";
}
    
sub send_response{
    my ($self, $response, $wrap) = @_;

    print $self->header(
        -status => 200,
        -type   => 'text/plain',
        );

    if ($wrap) {
        print $self->wrap_response($response);
    } else {
        print $response;
    }
}

sub wrap_response {
    my ($self, $response) = @_;
    
    return qq{<?xml version="1.0" encoding="UTF-8"?>\n}
      . qq{<otter schemaVersion="$SCHEMA_VERSION" xmlVersion="$XML_VERSION">\n}
      . $response
      . qq{</otter>\n};
}

sub unauth_exit {
    my ($self, $reason) = @_;
    
    print $self->header(
        -status => 403,
        -type   => 'text/plain',
        ), $reason;
    exit(1);
}

sub error_exit {
    my ($self, $reason) = @_;

    chomp($reason);

    print $self->header(
        -status => 500,
        -type   => 'text/plain',
        ),
      $self->wrap_response(" <response>\n    ERROR: $reason\n </response>\n");
    $self->log("ERROR: $reason\n");

    exit(1);
}

sub require_argument {
    my ($self, $argname) = @_;

    my $value = $self->param($argname);
    
    if (defined $value) {
        return $value;
    } else {
        $self->error_exit("No '$argname' argument defined");
    }
}

sub return_emptyhanded {
    my $self = shift @_;

    $self->send_response('', 1);
    exit(0); # <--- this forces all the scripts to exit normally
}

sub tempfile_from_argument {
    my $self      = shift @_;
    my $argname   = shift @_;

    my $file_name = shift @_ || $self->csn().'_'.$self->require_argument('author').'.xml';

    my $tmp_file = Bio::Otter::Lace::TempFile->new;
    $tmp_file->root('/tmp');
    $tmp_file->name($file_name);
    my $full_name = $tmp_file->full_name();

    $self->log("Dumping the data to the temporary file '$full_name'");

    my $write_fh = eval{
        $tmp_file->write_file_handle();
    } || $self->error_exit("Can't write to '$full_name' : $!");
    print $write_fh $self->require_argument($argname);

    return $tmp_file;
}

############# Creation of an Author object from arguments #######

sub make_Author_obj {
    my ($self, $author_name) = @_;

    $author_name ||= $self->authorized_user;
    
    #my $author_email = $self->require_argument('email');
    my $class        = $self->running_headcode() ? 'Bio::Vega::Author' : 'Bio::Otter::Author';

    return $class->new(-name => $author_name, -email => $author_name);
}

sub fetch_Author_obj {
    my ($self, $author_name) = @_;

    $author_name ||= $self->authorized_user;

    if($self->running_headcode() != $self->dataset_headcode()) {
        $self->error_exit("RunningHeadcode != DatasetHeadcode, cannot fetch Author");
    }

    my $author_adaptor = $self->otter_dba()->get_AuthorAdaptor();

    my $author_obj;
    eval{
        $author_obj = $author_adaptor->fetch_by_name($author_name);
    };
    if($@){
        $self->error_exit("Failed to get an author.\n$@") unless $author_obj;
    }
    return $author_obj;
}

############## DB connections and slices: #######################

sub otter_dba {
    my $self = shift @_;

    if ($self->{'_odba'}) {            # cached value
        return $self->{'_odba'};
    }

    ########## CODEBASE tricks ########################################

    my $running_headcode = $self->running_headcode();
    my $dataset_headcode = $self->dataset_headcode();

    my $adaptor_class = $running_headcode
        ? ( $dataset_headcode
                ? 'Bio::Vega::DBSQL::DBAdaptor'     # headcode anyway, get the best adaptor
                : 'Bio::EnsEMBL::DBSQL::DBAdaptor'  # new pipeline of the old otter, get the minimal adaptor
          )
        : ( $dataset_headcode
                ? 'Bio::EnsEMBL::DBSQL::DBAdaptor'  # old pipeline of the new otter, get the minimal adaptor
                : 'Bio::Otter::DBSQL::DBAdaptor'    # oldcode anyway, get the best adaptor
        );

    ########## AND DB CONNECTION #######################################

    my( $odba, $dnadb );

    if(my $dbname = $self->dataset_param('DBNAME')) {
        eval {
           $odba = $adaptor_class->new( -host       => $self->dataset_param('HOST'),
                                        -port       => $self->dataset_param('PORT'),
                                        -user       => $self->dataset_param('USER'),
                                        -pass       => $self->dataset_param('PASS'),
                                        -dbname     => $dbname,
                                        -group      => 'otter',
                                        -species    => $self->dataset_name,
                                        );
        };
        $self->error_exit("Failed opening otter database [$@]") if $@;

        $self->log("Connected to otter database");
    } else {
		$self->error_exit("Failed opening otter database [No database name]");
    }

    if(my $dna_dbname = $self->dataset_param('DNA_DBNAME')) {
        eval {
            $dnadb = new Bio::EnsEMBL::DBSQL::DBAdaptor( -host      => $self->dataset_param('DNA_HOST'),
                                                         -port      => $self->dataset_param('DNA_PORT'),
                                                         -user      => $self->dataset_param('DNA_USER'),
                                                         -pass      => $self->dataset_param('DNA_PASS'),
                                                         -dbname    => $dna_dbname,
                                                         -group     => 'dnadb',
                                                         -species   => $self->dataset_name,
                                                         );
        };
        $self->error_exit("Failed opening dna database [$@]") if $@;
        $odba->dnadb($dnadb);
        
        $self->log("Connected to dna database");
    }

    return $self->{'_odba'} = $odba;
}

sub satellite_dba {
    my ($self, $metakey, $satehead) = @_;

    if(!defined($satehead)) { # not just 'false', but truly undefined
        $satehead = $self->running_headcode();
    }

    # Note: as multiple satellite_db's can be used, we have to explicitly send $metakey

    $metakey ||= '';

        # It may well be true that the caller
        # is interested in features from otter_db itself.
        # (This is NOT the default behaviour,
        #  so he has to specify it by setting metakey='.')

    if($metakey eq '.') {
        $self->log("Connecting to the otter_db itself");
        return $self->otter_dba();      # so $satehead is ignored
    }

    my $kind;

    if(! $metakey) {
        $metakey = $satehead
            ? 'pipeline_db_head'
            : 'pipeline_db';
        $kind = 'pipeline DB'
    } else {
        $kind = 'satellite DB';
    }

    if($self->{_sdba}{$metakey}) {
        $self->log("Get the cached [$metakey] adapter...");
        return $self->{_sdba}{$metakey};
    }

    $self->log("connecting to the ".($satehead?'NEW':'OLD')." schema $kind using [$metakey] meta entry...");

    my $running_headcode = $self->running_headcode();
    my $adaptor_class = ($running_headcode || $satehead)
            ? 'Bio::EnsEMBL::DBSQL::DBAdaptor'  # get the minimal adaptor (may be extended to Vega in future)
            : 'Bio::Otter::DBSQL::DBAdaptor';   # get the best adaptor for old API satellite

    my ($opt_str) = @{ $self->otter_dba()->get_MetaContainer()->list_value_by_key($metakey) };

    if(!$opt_str) {
        $self->error_exit("Could not find meta entry for '$metakey' satellite db");
    } elsif($opt_str =~ /^\=otter/) { # can't guarantee it is specifically '_head'
        return $self->otter_dba();    # and can't pass it further
    } elsif($opt_str =~ /^\=pipeline/) { # can't guarantee it is specifically '_head'
        return $self->satellite_dba('', $satehead);
    } elsif($opt_str =~ /^\=(\w+)$/) {
        return $self->satellite_dba($1, $satehead);
    }

    my %anycase_options = (eval $opt_str);
    if ($@) {
        $self->error_exit("Error evaluating '$opt_str' : $@");
    }

    my %uppercased_options = ();
    while( my ($k,$v) = each %anycase_options) {
        $uppercased_options{uc($k)} = $v;
    }
    
    my $sdba = $adaptor_class->new(%uppercased_options)
        || $self->error_exit("Couldn't connect to '$metakey' satellite db");

    $self->error_exit("No connection parameters for '$metakey' in otter database")
        unless (keys %uppercased_options);

        # if it's needed AND we can...
    $sdba->assembly_type($self->otter_dba()->assembly_type()) unless ($satehead || $running_headcode);

    $self->log("... with parameters: ".join(', ', map { "$_=".$uppercased_options{$_} } keys %uppercased_options ));

    return $self->{_sdba}{$metakey} = $sdba;
}

sub get_slice { # codebase-independent version for scripts
    my ($self, $dba, $cs, $name, $type, $start, $end, $strand, $csver) = @_;

    my $slice;

    $cs ||= 'chromosome'; # can't make a slice without cs

    if($self->running_headcode()) {

        $strand ||= 1;
        if(!$csver && ($cs eq 'chromosome')) {
            $csver = 'Otter';
        }

            # The following statement ensures
            # that we use 'assembly type' as the chromosome name
            # only for Otter chromosomes.
            # EnsEMBL chromosomes will have simple names.
        my ($segment_attr, $segment_name);
        ($segment_attr, $segment_name) = (($cs eq 'chromosome') && ($csver eq 'Otter'))
            ? ('type', $type)
            : ('name', $name);

        $self->error_exit("$cs '$segment_attr' attribute not set ") unless $segment_name;

        $slice =  $dba->get_SliceAdaptor()->fetch_by_region(
            $cs,
	        $segment_name,
            $start,
            $end,
            $strand,
            $csver,
        );

    } else { # not running_headcode()

        $self->error_exit("$cs 'name' attribute not set") unless $name;

        if($cs eq 'chromosome') {
            $start ||= 1;

            eval {
                my $chr_obj = $dba->get_ChromosomeAdaptor()->fetch_by_chr_name($name);
                $end ||= $chr_obj->length();
            };
            if($@) {
                $self->log("Could not get chromosome '$name', returning an empty list");
                $self->return_emptyhanded();
            }

            $slice = $dba->get_SliceAdaptor()->fetch_by_chr_start_end(
                $name,
                $start,
                $end,
            );

            if($slice and ! @{ $slice->get_tiling_path() } ) {
                $self->log('Could not get a slice, probably not (yet) loaded into satellite db');
                $self->return_emptyhanded();
            }
        } elsif($cs eq 'contig') {
            eval {
                $slice = $dba->get_RawContigAdaptor()->fetch_by_name(
                    $name,
                );
            };
            if($@) {
                $self->log("Could not get contig '$name', returning an empty list");
                $self->return_emptyhanded();
            }

        } else {
            $self->error_exit("Other coordinate systems are not supported");
        }

    }

    if(not $slice) {
        $self->log('Could not get a slice, probably not (yet) loaded into satellite db');
        $self->return_emptyhanded();
    }

    return $slice;
}

sub cached_csver { # with optional override

    my ($self, $metakey, $cs, $override) = @_; # metakey can even be '.' or ''

    return $self->{_target_asm}{$metakey}{$cs}
         = $override
        || $self->{_target_asm}{$metakey}{$cs}
        || (   ($cs eq 'chromosome')
            && eval { # FIXME: why does it have to be 'eval'?
                my ($asm_def) = @{ $self->satellite_dba($metakey)
                                   ->get_MetaContainer()->list_value_by_key('assembly.default') };
                $asm_def;
           }
           )
        || 'UNKNOWN';
}

sub get_mapper_dba {
    my ($self, $metakey, $cs, $csver_orig, $csver_remote, $name, $type) = @_;

    if(!$metakey) {
        $self->log("Working with pipeline_db directly, no remapping is needed.");
        return;
    } elsif($metakey eq '.') {
        $self->log("Working with otter_db directly, no remapping is needed.");
        return;
    }

    my $csver = $self->cached_csver($metakey, $cs, $csver_remote);
    if($cs eq 'chromosome') {
        if($csver =~/^otter$/i) {
            $self->log("Working with another Otter database, no remapping is needed.");
            return;
        } elsif($csver eq 'UNKNOWN') {
            $self->log("The database's default assembly is not set correctly");
            $self->return_emptyhanded();
        }
    }

    if(!$self->running_headcode()) {
        $self->log("Working with unknown OLD API database, please do the remapping on client side.");
        return;
    }

    ## What remains is head version of a non-otter satellite_db

        # Currently we keep assembly equivalency information in the pipeline_db_head seq_region_attrib.
        # Once otter_db is converted into new schema, we can keep this information there.
    my $pdba = $self->satellite_dba( '' ); # it will be NEW pipeline by exclusion

        # this slice does not have to be completely defined (no start/end/strand),
        # as we only need it to get the attributes
    my $pipe_slice = $self->get_slice($pdba, $cs, $name, $type, undef, undef, undef, $csver_orig);

    my %asm_is_equiv = map { ($_->value() => 1) } @{ $pipe_slice->get_all_Attributes('equiv_asm') };

    if($asm_is_equiv{$csver}) { # we can simply rename instead of mapping

        $self->log("This $cs is equivalent to '$name' in our reference '$csver' assembly");
        return (undef, $csver);

    } else { # assemblies are guaranteed to differ!

        my $mapper_metakey = "mapper_db.${csver}";

        if( my $mdba = $self->satellite_dba($mapper_metakey) ) {
            return ($mdba, $csver);
        } else {
            $self->log("No '$mapper_metakey' defined in meta table => cannot map between assemblies => exiting");
            $self->return_emptyhanded();
        }
    }
}

sub fetch_mapped_features {
    my ($self, $feature_name, $call_parms) = @_;

    my $fetching_method = shift @$call_parms;

    my $cs           = $self->param('cs')           || 'chromosome';
    my $csver_orig   = $self->param('csver')        || undef;
    my $csver_remote = $self->param('csver_remote') || undef;
    my $metakey      = $self->param('metakey')      || ''; # defaults to pipeline
    my $name         = $self->param('name');
    my $type         = $self->param('type');
    my $start        = $self->param('start');
    my $end          = $self->param('end');
    my $strand       = $self->param('strand');

    my $sdba = $self->satellite_dba( $metakey );
    my ($mdba, $csver) = $self->get_mapper_dba( $metakey, $cs, $csver_orig, $csver_remote, $name, $type);

    my $features = [];

    if($mdba) {
        $self->log("Proceeding with mapping code");

        my $original_slice_on_mapper = $self->get_slice($mdba, $cs, $name, $type, $start, $end, $strand, $csver_orig);
        my $proj_segments_on_mapper = $original_slice_on_mapper->project( $cs, $csver );

        my $sa_on_target = $sdba->get_SliceAdaptor();

        foreach my $segment (@$proj_segments_on_mapper) {
            my $projected_slice_on_mapper = $segment->to_Slice();

            my $target_slice_on_target = $sa_on_target->fetch_by_region(
                $projected_slice_on_mapper->coord_system()->name(),
                $projected_slice_on_mapper->seq_region_name(),
                $projected_slice_on_mapper->start(),
                $projected_slice_on_mapper->end(),
                $projected_slice_on_mapper->strand(),
                $projected_slice_on_mapper->coord_system()->version(),
            );

            my $target_fs_on_target_segment
                = $target_slice_on_target->$fetching_method(@$call_parms) ||
                $self->error_exit("Could not fetch anything - analysis may be missing from the DB");

            $self->log('***** : '.scalar(@$target_fs_on_target_segment)." ${feature_name}s found on the slice");

            foreach my $target_feature (@$target_fs_on_target_segment) {

                if($target_feature->can('propagate_slice')) {
                    $target_feature->propagate_slice($projected_slice_on_mapper);
                } else {
                    $target_feature->slice($projected_slice_on_mapper);
                }

                if( my $transferred = $target_feature->transfer($original_slice_on_mapper) ) {
                    push @$features, $transferred;
                } else {
                    my $fname = sprintf( "%s [%d..%d]", 
                                        $target_feature->display_id(),
                                        $target_feature->start(),
                                        $target_feature->end() );
                    $self->log("Could not transfer $feature_name $fname from {".$target_feature->slice->name."} onto {".$original_slice_on_mapper->name.'}');
                }
            }
        }

    } else {
        $self->log("No mapping is needed, just fetching");

        my $original_slice = $self->get_slice($sdba, $cs, $name, $type, $start, $end, $strand, $csver);

        $features = $original_slice->$fetching_method(@$call_parms)
            || $self->error_exit("Could not fetch anything - analysis may be missing from the DB");
    }

    $self->log("Total of ".scalar(@$features).' '.join('/', grep { defined($_) && !ref($_) } @$call_parms)
              ." ${feature_name}s have been sent to the client");

    return $features;
}

1;


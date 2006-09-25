package Bio::Vega::ContigLockBroker;

use strict;
use Bio::EnsEMBL::Utils::Exception qw ( throw warning );
use Bio::Vega::ContigLock;

my $client_hostname='deskpro014581';

sub client_hostname {
    my( $hostname ) = @_;
    if ($client_hostname) {
        $client_hostname = $hostname;
    }
    return $client_hostname;
}


### CloneLockBroker should have an Author and a CloneLockAdaptor attached
### so it doesn't need to inherit from BaseAdaptor


##ported/tested
sub check_locks_exist_by_slice {
  my ($slice,$author,$db) = @_;
  if (!defined($slice)) {
	 throw("Can't check contig locks on a slice if no slice");
  }
  if (!defined($author)) {
	 throw("Can't check contig locks on a slice with no author");
  }
  if (!$slice->isa("Bio::EnsEMBL::Slice")) {
	 throw("[$slice] is not a Bio::EnsEMBL::Slice");
  }
  if (!$author->isa("Bio::Vega::Author")) {
	 throw("[$author] is not a Bio::Vega::Author");
  }
  my $contig_list = Contig_listref_from_Slice($slice);
  my $aptr = $db->get_ContigLockAdaptor;
  my $sa=$db->get_SliceAdaptor();
  my( @locks );
  foreach my $contig (@$contig_list) {
	 my $ctg_seq_region_id=$sa->get_seq_region_id($contig);
	 my $lock = $aptr->fetch_by_contig_id($ctg_seq_region_id)
		or throw(sprintf "Contig [%s] not locked by [%s]\n", $ctg_seq_region_id,$author->name);
	 unless ($lock->author->name eq $author->name) {
		throw("Author [" . $author->name . "] doesn't own lock for $contig");
	 }
	 push(@locks, $lock);
  }
  return @locks;
}

##ported
sub check_no_locks_exist_by_slice {
  my ($self,$slice,$author,$db) = @_;
  if (!defined($slice)) {
	 throw("Can't check clone locks on a slice if no slice");
  }
  if (!defined($author)) {
	 throw("Can't check clone locks on a slice with no author");
  }
  if (!$slice->isa("Bio::EnsEMBL::Slice")) {
	 throw("[$slice] is not a Bio::EnsEMBL::Slice");
  }
  if (!$author->isa("Bio::Vega::Author")) {
	 throw("[$author] is not a Bio::Vega::Author");
  }
  my $contig_list = Contig_listref_from_Slice($slice);
  my $aptr       = $self->get_ContigLockAdaptor;
  my $sa=$db->get_SliceAdaptor();
  foreach my $contig (@$contig_list) {
	 my $ctg_seq_region_id=$sa->get_seq_region_id($contig);
	 throw("Contig '". $contig->seq_region_name ."' is locked\n")
		if $aptr->fetch_by_contig_id($ctg_seq_region_id);
  }
  return 1;
}

##ported && tested
sub lock_clones_by_slice {
  my ($slice,$author,$db) = @_;
  if (!defined($slice)) {
	 throw("Can't lock clones on a slice if no slice");
  }
  if (!defined($author)) {
	 throw("Can't lock clones on a slice with no author");
  }
  if (!$slice->isa("Bio::EnsEMBL::Slice")) {
	 throw("[$slice] is not a Bio::EnsEMBL::Slice");
  }
  if (!$author->isa("Bio::Vega::Author")) {
	 throw("[$author] is not a Bio::Vega::Author");
  }
  my $contig_list = Contig_listref_from_Slice($slice);
  my $aptr       = $db->get_ContigLockAdaptor;
  my $sa=$db->get_SliceAdaptor;
  my( @new,               # locks we manange to create
		@existing,          # locks that already existed
		%existing_contig,    # contigs that had locks existing (for nice error message)
	 );

  foreach my $contig (@$contig_list) {

	 my $ctg_seq_region_id = $sa->get_seq_region_id($contig)
		or throw('Contig does not have dbID set');
	 my $lock = Bio::Vega::ContigLock->new(
													  -author     => $author,
													  -contig_id   => $ctg_seq_region_id,
													  -hostname   => $client_hostname,
													 );
	 eval {
		$db->get_ContigLockAdaptor->store($lock);
	 };

	 if ($@) {
		my $exlock = $db->get_ContigLockAdaptor->fetch_by_contig_id($ctg_seq_region_id);
		if ($exlock){
		push(@existing, $exlock);
				die "\n\n***:$exlock";
	 }
		$existing_contig{$ctg_seq_region_id} = $contig;
	 } else {
		push(@new, $lock);
	 }
  }
  if (@existing) {
	 # Unlock any that we just locked (could do this with rollback?)
	 foreach my $lock (@new) {
		$aptr->remove($lock);
	 }
	 # Give a nicely formatted error message about what is already locked
	 my $lock_error_str = "Can't lock contigs because some are already locked:\n";
	 foreach my $lock (@existing) {
		#die "@existing";
		my $contig = $existing_contig{$lock->contig_id};
		my $ctg_seq_region_id = $sa->get_seq_region_id($contig);
		  $lock_error_str .= sprintf "  '%s' has been locked by '%s' since %s\n",
			 $ctg_seq_region_id, $lock->author->name, scalar localtime($lock->timestamp);
	 }
	 throw($lock_error_str);
  }
}

##ported
sub remove_by_slice {
  my ($slice,$author,$db) = @_;
  my $contig_list = Contig_listref_from_Slice($slice);
  my $aptr       = $db->get_ContigLockAdaptor;
  my $sa=$db->get_SliceAdaptor;
  #print STDERR "\n\n****Ia m called from remove locks @$contig_list\n\n";
  #use Data::Dumper;
  #print STDERR Dumper($slice);
  foreach my $contig (@$contig_list) {
	 my $ctg_seq_region_id=$sa->get_seq_region_id($contig);
	 if (my $lock = $db->get_ContigLockAdaptor->fetch_by_contig_id($ctg_seq_region_id)) {
		unless ($lock->author->name eq $author->name) {
		  throw("Author [" . $author->name . "] doesn't own lock for $contig");
		}
		$aptr->remove($lock);
	 } else {
		warning("Can't unlock contig [$contig]. Lock doesn't exist");
	 }
  }
}

##ported/tested
sub Contig_listref_from_Slice {

  my ($slice)  = @_;
  my $contig_list = [];
  my $slice_projection = $slice->project('contig');
  foreach my $seg (@$slice_projection) {

	 my $contig_slice = $seg->to_Slice();
	 #my $assembly_offset = $contigslice->start()-1;
	 #$contig_slice->start($contig_seg->from_start+ $assembly_offset);
	 push(@$contig_list, $contig_slice);
  }

  return $contig_list;
}




1;

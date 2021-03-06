package Bio::Otter::Lace::OnTheFly::QueryValidator;

use namespace::autoclean;
use Moose;

with 'MooseX::Log::Log4perl';

use Carp;
use List::MoreUtils qw{ uniq };

use Bio::Otter::Lace::OnTheFly::Utils::SeqList;
use Bio::Otter::Lace::OnTheFly::Utils::Types;

use Bio::Vega::Evidence::Types qw{ new_evidence_type_valid seq_is_protein };

has accession_type_cache => ( is => 'ro', isa => 'Bio::Otter::Lace::AccessionTypeCache', required => 1 );

has seqs                 => ( is => 'ro', isa => 'ArrayRef[Hum::Sequence]', default => sub{ [] } );
has accessions           => ( is => 'ro', isa => 'ArrayRef[Str]',           default => sub{ [] } );

has lowercase_poly_a_t_tails => ( is => 'ro', isa => 'Bool', default => undef );

has problem_report_cb    => ( is => 'ro', isa => 'CodeRef', required => 1 );
has long_query_cb        => ( is => 'ro', isa => 'CodeRef', required => 1 );
has progress_cb          => ( is => 'ro', isa => 'CodeRef' );

has max_query_length     => ( is => 'ro', isa => 'Int', default => 10000 );

has confirmed_seqs       => (
    is       => 'ro',
    isa      => 'SeqListClass',
    lazy     => 1,
    builder  => '_build_confirmed_seqs',
    init_arg => undef,
    handles  => [qw( seqs_by_name seq_by_name )],
    );

has seqs_by_type         => ( is => 'ro', isa => 'HashRef[ArrayRef[Hum::Sequence]]',
                              lazy => 1, builder => '_build_seqs_by_type', init_arg => undef );

# Internal attributes
#
has _acc_type_full_cache => ( is => 'ro', isa => 'HashRef[ArrayRef[Str]]',
                              default => sub{ {} }, init_arg => undef );

has _warnings            => ( is => 'ro', isa => 'HashRef', default => sub{ {} }, init_arg => undef );

sub BUILD {
    my $self = shift;
    # not sure how much processing to do here
    # none for now, only if it becomes necessary for multiple methods
    return;
}

sub _build_confirmed_seqs {     ## no critic (Subroutines::ProhibitUnusedPrivateSubroutines)
    my ($self) = @_;

    {
        my @seq_accs      = map { $_->name } @{$self->seqs};
        my @supplied_accs = @{$self->accessions};

        # We work on the union of the supplied sequences and supplied accession ids
        my @accessions = ( @seq_accs, @supplied_accs );
        return Bio::Otter::Lace::OnTheFly::Utils::SeqList->new( seqs => [] ) unless @accessions; # nothing to do

        $self->logger->debug('n(accessions) = ', scalar @accessions);

        # identify the types of all the accessions supplied
        my $cache = $self->accession_type_cache;
        # The populate method will fetch the latest version of
        # any accessions which are supplied without a SV into
        # the cache object.
        &{$self->progress_cb}('Fetching accession info') if $self->progress_cb;
        $cache->populate(\@accessions);
    }

    $self->_augment_supplied_sequences;
    my @to_fetch = $self->_check_augment_supplied_accessions;
    $self->_fetch_sequences(@to_fetch);

    # tell the user about any missing sequences or remapped accessions

    # might it be better to pass the unprocessed warning lists to the callback and let
    # them be processed according to the context and graphics framework?

    if (%{$self->_warnings}) {
        my $formatted_msgs = $self->_format_warnings;
        &{$self->problem_report_cb}( $formatted_msgs );
    }

    # check for unusually long query sequences

    my @confirmed_seqs;

    for my $seq (@{$self->seqs}) {
        if ($seq->sequence_length > $self->max_query_length) {
            my $okay = &{$self->long_query_cb}( {
                name   => $seq->name,
                length => $seq->sequence_length,
                                                 } );
            if ($okay) {
                push @confirmed_seqs, $seq;
            }
        }
        else {
            push @confirmed_seqs, $seq;
        }
    }

    if ($self->lowercase_poly_a_t_tails) {
        for my $seq (@confirmed_seqs) {
            my $s = $seq->uppercase;
            $s =~ s/(^T{6,}|A{6,}$)/lc($1)/ge;
            $seq->sequence_string($s);
        }
    }

    return Bio::Otter::Lace::OnTheFly::Utils::SeqList->new( seqs => \@confirmed_seqs );
}

sub _build_seqs_by_type {       ## no critic (Subroutines::ProhibitUnusedPrivateSubroutines)
    my $self = shift;

    my %seqs_by_type;
    foreach my $seq (@{$self->confirmed_seqs->seqs}) {
        my $type = $seq->type;
        unless ($type && new_evidence_type_valid($type))
        {
            unless ($type =~ /^OTF_AdHoc_/) { # may be already set by EditWindow::Exonerate->entered_seqs()
                $type = seq_is_protein($seq->sequence_string) ? 'OTF_AdHoc_Protein' : 'OTF_AdHoc_DNA';
            }
        }
        push @{ $seqs_by_type{ $type } }, $seq;
    }

    return \%seqs_by_type;
}

sub seq_types {
    my $self = shift;
    return keys %{$self->seqs_by_type};
}

sub seqs_for_type {
    my ($self, $type) = @_;
    return $self->seqs_by_type->{$type};
}

# add type and full accession information to the supplied sequences
# modifies sequences in $self->seqs
#
sub _augment_supplied_sequences {
    my $self = shift;

    for my $seq (@{$self->seqs}) {
        my $name = $seq->name;
        my $entry = $self->_acc_type_full($name);
        if ($entry) {
            my ($type, $full_acc) = @$entry;
            ### Might want to be paranoid and check that the sequence of
            ### supplied sequences matches the pfetched sequence where the
            ### names of sequences are public accessions.
            $seq->type($type);
            $seq->name($full_acc);
            if ($name ne $full_acc) {
                $self->_add_remap_warning( $name => $full_acc );
            }
        } else {
            $self->_save_seq_to_acc_info($seq);
        }
    }
    return;
}

sub _check_augment_supplied_accessions {
    my $self = shift;

    my $supplied_accs = $self->accessions;

    my @to_fetch;
    foreach my $acc ( @$supplied_accs ) {

        my $entry = $self->_acc_type_full($acc);

        unless ($entry) {
            # No point trying to fetch invalid accessions
            $self->_add_missing_warning($acc, "unknown accession or illegal evidence type");
            next;
        }

        my ($type, $full) = @$entry;
        if ($type eq 'SRA') {
            $self->_add_missing_warning($acc, 'illegal evidence type: SRA');
            next;
        }

        push(@to_fetch, $full);

        if ($acc ne $full) {
            $self->_add_remap_warning( $acc => $full );
        }

    }
    return @to_fetch;
}

# Adds sequences to $self->seqs
#
sub _fetch_sequences {
    my ($self, @to_fetch) = @_;

    my $cache = $self->accession_type_cache;

    @to_fetch = uniq @to_fetch;
    $self->logger->debug('Need seq for: ', join(',', @to_fetch) || '<none>');

    foreach my $acc (@to_fetch) {

        my ($type, $full) = @{$self->_acc_type_full($acc)};
        unless ($type) {
            $self->_add_missing_warning($acc => 'illegal evidence type');
            next;
        }

        my $info = $cache->feature_accession_info($acc);
        unless ($info) {
            $self->logger->error("No info for '$acc' - this should not happen");
            $self->_add_missing_warning($acc => 'internal error');
            next;
        }

        unless ($info->{currency} and $info->{currency} eq 'current') {
            $self->_add_missing_warning($acc => 'obsolete SV');
            next;
        }

        unless ($info->{sequence}) {
            $self->_add_missing_warning($acc => 'no sequence');
            next;
        }

        my $seq = Hum::Sequence->new;
        $seq->name($full);
        $seq->type($type);
        $seq->sequence_string($info->{sequence});

        # Will this ever get hit?
        if ($full ne $acc) {
            $self->logger->error("_fetch_sequences called with partial acc.sv for '$acc','$full'");
            $self->_add_remap_warning($acc => $full);
        }

        push(@{$self->seqs}, $seq);
    }

    return;
}

# implements the local micro-cache - including caching misses

sub _acc_type_full {
    my ($self, $acc) = @_;

    my $local_cache = $self->_acc_type_full_cache;
    if (exists $local_cache->{$acc}) {
        my $cached_entry = $local_cache->{$acc};
        return $cached_entry;
    }

    my ($type, $full) = $self->accession_type_cache->type_and_name_from_accession($acc);
    my $new_entry;
    $new_entry = [ $type, $full ] if ($type and $full);
    return $local_cache->{$acc} = $new_entry;
}

sub _save_seq_to_acc_info {
    my ($self, $seq) = @_;

    my $local_cache = $self->_acc_type_full_cache;
    my $name = $seq->name;
    my $type = $seq->type;

    if ($local_cache->{$name}) {
        $self->logger->warn("_save_seq_to_acc_info: replacing entry for '$name'");
    }

    my $entry = {
        acc_sv          => $name,
        # taxon_id
        evi_type        => $type,
        description     => $seq->description || 'User-supplied sequence for on-the-fly alignment',
        source          => $type,
        # currency
        sequence_length => $seq->sequence_length,
        sequence        => $seq->sequence_string,
    };
    $self->accession_type_cache->save_accession_info($entry);
    return $local_cache->{$name} = [ $type, $name ];
}

# warnings

sub _add_warning {
    my ($self, $type, $warning) = @_;
    my $list = $self->_warnings->{$type} ||= [];
    push @{$list}, $warning;
    return;
}

sub _add_remap_warning {
    my ($self, $old, $new) = @_;
    my $remap_warnings = $self->_warnings->{remapped} ||= [];
    $self->_add_warning( remapped => [ $old => $new ] );
    return;
}

sub _add_missing_warning {
    my ($self, $acc, $msg) = @_;
    $self->_add_warning( missing => [ $acc => $msg ] );
    return;
}

# FIXME: remove, and related 'unclaimed' warning handling
#
# sub _add_unclaimed_warning {
#     my ($self, $acc) = @_;
#     $self->_add_warning( unclaimed => $acc );
#     return;
# }

sub _format_warnings {
    my $self = shift;
    my $warnings = $self->_warnings;

    my ($missing_msg, $remapped_msg, $unclaimed_msg) = ( ('') x 3 );

    if ($warnings->{missing}) {
        my @missing = @{$warnings->{missing}};
        $missing_msg = join("\n", map { sprintf("  %s %s", @{$_}) } @missing);
        $missing_msg =
            "I did not find any sequences for the following accessions:\n\n$missing_msg\n"
    }

    if ($warnings->{remapped}) {
        my @remapped = @{$warnings->{remapped}};
        $remapped_msg = join("\n", map { sprintf("  %s to %s", @{$_}) } @remapped);
        $remapped_msg =
            "The following supplied accessions have been mapped to full ACCESSION.SV:\n\n$remapped_msg\n"
    }

    if ($warnings->{unclaimed}) {
        my @unclaimed = @{$warnings->{unclaimed}};
        $unclaimed_msg =
            "The following sequences were fetched, but didn't map back to supplied names:\n\n"
            . join('', map { "  $_\n" } @unclaimed);
    }
    return( {
        missing   => $missing_msg,
        remapped  => $remapped_msg,
        unclaimed => $unclaimed_msg,
            } );
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

# EOF

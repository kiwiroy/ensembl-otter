
package Bio::Otter::SpeciesDat;

# Read a set of datasets from a file.
#
# Author: lg4

use strict;
use warnings;

use Try::Tiny;
use Carp;
use Bio::Otter::SpeciesDat::DataSet;

# Consider using Bio::Otter::Server::Config->SpeciesDat or
# $server->allowed_datasets instead.
sub new {
    my ($pkg, $file) = @_;
    my $dataset_hash = _dataset_hash($file);
    my %dataset;
    while (my ($name, $info) = each %$dataset_hash) {
        try {
            $dataset{$name} = Bio::Otter::SpeciesDat::DataSet->new($name, $info);
        } catch {
            croak "Dataset $name from $file: $_";
        };
    }
    my $new = {
        _dataset  => \%dataset,
        _datasets => [ values %dataset ],
    };
    bless $new, $pkg;
    return $new;
}

sub dataset {
    my ($self, $name) = @_;
    my $ds = $self->{_dataset}{$name}
      or confess "No such dataset '$name'";
    return $ds;
}

sub datasets {
    my ($self) = @_;
    carp 'B:O:SD->datasets deprecated';
    # because it provides write access to internals,
    # and (surprising within e-o) arrayref semantics instead of list
    return $self->{_datasets};
}

sub all_datasets {
    my ($self) = @_;
    return @{ $self->{_datasets} };
}

# The datasets which can benefit an otter_config config sections
sub all_datasets_no_alias {
    my ($self) = @_;
    my @ds = $self->all_datasets;
    @ds = grep { !defined $_->ALIAS } @ds; # exclude those which ALIAS another
    return @ds;
}

sub _dataset_hash {
    my ($filename) = @_;

    my $cursect = undef;
    my $defhash = {};
    my $curhash = undef;
    my $sp = {};

    my $do_line = sub {
        return if /^\#/;
        return unless /\w+/;
        chomp;

        if (/\[(.*)\]/) {
            if (!defined($cursect) && $1 ne "defaults") {
                die "Error: first section in species.dat should be 'defaults'";
            }
            elsif ($1 eq "defaults") {
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

        } elsif (/(\S+)\s+(\S+)/) {
            my $key   = uc $1;
            my $value =    $2;
            $curhash->{$key} = $value;
        }
    };

    open my $dat, '<', $filename or die "Can't read species file '$filename' : $!";
    while (<$dat>) { $do_line->(); }
    close $dat or die "Error reading '$filename' : $!";

    # Have finished with defaults, so we can remove them.
    delete $sp->{'defaults'};

    return $sp;
}

1;

__END__

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk


package Bio::Otter::Server::Support;

use strict;
use warnings;

=head1 NAME

Bio::Otter::Server::Support - common parent for MFetcher/B:O:Server::Support::{Local,Web}

=cut

use Try::Tiny;

use Bio::Otter::Server::Config;

sub new { # just to make it possible to instantiate an object
    my ($pkg, @arguments) = @_;

    my $self = bless { @arguments }, $pkg;
    return $self;
}

sub SpeciesDat {
    my ($self) = @_;
    return $self->{_SpeciesDat} ||= Bio::Otter::Server::Config->SpeciesDat;
}

sub dataset {
    my ($self, $dataset) = @_;

    if($dataset) {
        $self->{'_dataset'} = $dataset;
    }

    return $self->{'_dataset'} ||=
        $self->dataset_default;
}

sub dataset_default {
    my ($self) = @_;
    my $dataset_name = $self->dataset_name;
    die "dataset_name not set" unless $dataset_name;
    my $dataset = $self->SpeciesDat->dataset($dataset_name);
    die "no dataset" unless $dataset;
    return $dataset;
}

sub dataset_name {
    die "no default dataset name";
}

sub otter_dba {
    my ($self, @args) = @_;

    if($self->{'_odba'} && !scalar(@args)) {   # cached value and no override
        return $self->{'_odba'};
    }

    my $adaptor_class = 'Bio::Vega::DBSQL::DBAdaptor';

    if(@args) { # let's check that the class is ok
        my $odba = shift @args;
        try { $odba->isa($adaptor_class) }
            or die "The object you assign to otter_dba must be a '$adaptor_class'";
        return $self->{'_odba'} = $odba;
    }

    return $self->{'_odba'} ||=
        $self->dataset->otter_dba;
}

sub require_argument {
    my ($self, $argname) = @_;

    my $value = $self->param($argname);

    die "No '$argname' argument defined"
        unless defined $value;

    return $value;
}

sub require_arguments {
    my ($self, @arg_names) = @_;

    my %params = map { $_ => $self->require_argument($_) } @arg_names;
    return \%params;
}

############# Creation of an Author object #######

sub make_Author_obj {
    my ($self) = @_;

    my $author_name = $self->authorized_user;
    #my $author_email = $self->require_argument('email');

    return Bio::Vega::Author->new(
        -name  => $author_name,
        -email => $author_name,
        );
}


=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk

=cut

1;
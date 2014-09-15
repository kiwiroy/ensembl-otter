#!/usr/bin/env perl

use strict;
use warnings;
use 5.010;

package Bio::Otter::Script::ConfigMetakeys;
use parent 'Bio::Otter::Utils::Script';

use Log::Log4perl qw(:easy);
use Net::hostent;
use Try::Tiny;

use Bio::Otter::Lace::Defaults;

sub ottscript_options {
    return ( dataset_mode => 'one_or_all' );
}

sub ottscript_validate_args {
    my ($self, $opt, $args) = @_;

    $args ||= [];
    my $mode = shift @$args;
    $mode                       or $self->usage_error("<mode> must be specified");
    $mode =~ /^(check|config)$/ or $self->usage_error('<mode> must be one of: check, config');
    $self->mode($mode);

    return;
}

sub setup {
    my ($self) = @_;
    Log::Log4perl->easy_init;
    Bio::Otter::Lace::Defaults::do_getopt or die "do_getopt failed";
    $self->client->get_server_otter_config;
    return;
}

sub process_dataset {
  my ($self, $dataset) = @_;

  my $ds_name = $dataset->name;

  my $server_ds = $dataset->otter_sd_ds;
  if ($server_ds->ds_all_params->{RESTRICTED}) {
      say "Skipping (since RESTRICTED): ", $ds_name if $self->verbose;
      return;
  }

  my $client_ds = $self->client->get_DataSet_by_name($ds_name);
  $client_ds->load_client_config;

 FILTER: foreach my $filter ( @{$client_ds->filters} ) {

      my $metakey = $filter->metakey;
      next unless $metakey;
      say sprintf "\t%s\t%s", $filter->name, $metakey if $self->verbose;

      my ($raw_hostname, $hostname);
      try {
          my $dba = $server_ds->satellite_dba($metakey);
          $raw_hostname = $dba->dbc->host;
          my $hostent = gethostbyname($raw_hostname);
          $hostname = $hostent->name;
      }
      catch {
          say STDERR "$ds_name:$metakey connection FAILED: $_";
      };
      next FILTER unless $hostname;
      say sprintf "\t\t%s\t%s\t(%s)", $metakey, $hostname, $raw_hostname if $self->verbose;
      $self->add_translation($ds_name, $metakey, $hostname) if $self->mode eq 'config';
  }
  return;
}

{
    my %translations_by_metakey;

    sub add_translation {
        my ($self, $ds_name, $metakey, $hostname) = @_;
        my $translation = $translations_by_metakey{$metakey} ||= {};
        $translation->{$ds_name} = $hostname;
        if (exists $translation->{default}) {
            if (my $default_hostname = $translation->{default}) {
                unless ($hostname eq $default_hostname) {
                    say STDERR "WARNING: processing $ds_name - $metakey has differing resolutions: ",
                        join ',', grep {$_ ne 'default'} keys %$translation;
                    $translation->{default} = undef;
                }
            }
        } else {
            $translation->{default} = $hostname;
        }
        return;
    }

    sub finish {
        my ($self) = @_;
        return unless $self->mode eq'config';

        # Pivot the hashes, choosing 'default' if available
        my %translations_by_dataset;
        while (my ($metakey, $translation_by_mk) = each %translations_by_metakey) {
            if (my $default = $translation_by_mk->{default}) {
                $translation_by_mk = { default => $default };
            } else {
                delete $translation_by_mk->{default};
            }
            while (my ($ds_name, $hostname) = each %$translation_by_mk) {
                my $translation_by_ds = $translations_by_dataset{$ds_name} ||= {};
                $translation_by_ds->{$metakey} = $hostname;
            }
        }

        $self->config_for('default', $translations_by_dataset{default});
        delete $translations_by_dataset{default};

        foreach my $ds_name (sort keys %translations_by_dataset) {
            $self->config_for($ds_name, $translations_by_dataset{$ds_name});
        }
        return;
    }

    sub config_for {
        my ($self, $ds_name, $translations) = @_;
        say "[${ds_name}.metakey_to_resource_bin]";
        foreach my $metakey (sort keys %$translations) {
            say $metakey, "=", $translations->{$metakey};
        }
        say '';
        return;
    }
}

sub mode {
    my ($self, @args) = @_;
    ($self->{'mode'}) = @args if @args;
    my $mode = $self->{'mode'};
    return $mode;
}

sub client {
    my ($self) = @_;
    my $client = $self->{'client'};
    return $client if $client;
    $client = Bio::Otter::Lace::Defaults::make_Client;
    return $self->{'client'} = $client;
}

# End of module

package main;

$|++;                           # unbuffer stdout for sane interleaving with stderr
Bio::Otter::Script::ConfigMetakeys->import->run;

exit;

# EOF

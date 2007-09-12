#!/usr/local/bin/perl

=head1 NAME

dump_all_pipeline - script to dump pipeline database to a .sql file

=head1 SYNOPSIS

dump_all_pipeline [options]

Options:

    --conffile, --conf=FILE             read script parameters from FILE
                                        (default: conf/Conversion.ini)
    --pipedbname=NAME                   use pipeline database NAME
    --pipehost=HOST                     use pipeline database host HOST
    --pipeport=PORT                     use pipeline database port PORT
    --pipeuser=USER                     use pipeline database user USER
    --pipepass=PASS                     use pipeline database password PASS

    --logfile, --log=FILE               log to FILE (default: *STDOUT)
    --logpath=PATH                      write logfile to PATH (default: .)
    -v, --verbose                       verbose logging (default: false)
    -i, --interactive=0|1               run script interactively (default: true)
    -n, --dry_run, --dry=0|1            don't write results to database
    -h, --help, -?                      print help (this message)


=head1 DESCRIPTION

This script uses MySQLdump to read a pipeline database into a file that can be used
to create a new Vega database. Only the structure for tables in the pipeline database
will be read into the file, with the exceptions of tables that are defined in the
HEREDOC at the end of the script.

Transfer of features from the dna_ and protein_align_feature tables can be prevented using
the -no_feature option

=head1 LICENCE

This code is distributed under an Apache style licence:
Please see http://www.ensembl.org/code_licence.html for details

=head1 AUTHOR

Steve Trevanion <st3@sanger.ac.uk>

=head1 CONTACT

Post questions to the EnsEMBL development list ensembl-dev@ebi.ac.uk

=cut

use strict;
use warnings;
no warnings 'uninitialized';

use FindBin qw($Bin);
use vars qw($SERVERROOT);

BEGIN {
    $SERVERROOT = "$Bin/../../../..";
    unshift(@INC, "$SERVERROOT/ensembl-otter/modules");
    unshift(@INC, "$SERVERROOT/ensembl/modules");
    unshift(@INC, "modules");
    unshift(@INC, "$SERVERROOT/bioperl-live");
}

use Getopt::Long;
use Pod::Usage;
use Data::Dumper;
use Bio::EnsEMBL::Utils::ConversionSupport;
use Slice;

$| = 1;

my $support = new Bio::EnsEMBL::Utils::ConversionSupport($SERVERROOT);

# parse options
$support->parse_common_options(@_);
$support->parse_extra_options(
	'pipedbname=s',
	'pipehost=s',
	'pipeport=s',
	'pipeuser=s',
	'no_feature=s',
	'sql_dump_location=s',
	'file_name=s',
);
$support->allowed_params(
	'pipedbname',
	'pipehost',
	'pipeport',
	'pipeuser',
	'no_feature',
	'sql_dump_location',
	'file_name',
	$support->get_common_params,
);
$support->check_required_params(
	'pipedbname',
	'pipehost',
	'pipeport',
	'pipeuser',
	'sql_dump_location',
	'dbname',
);
if ($support->param('help') or $support->error) {
    warn $support->error if $support->error;
    pod2usage(1);
}

# ask user to confirm parameters to proceed
$support->confirm_params;

# get log filehandle and print heading and parameters to logfile
$support->init_log;

#for debugging, are we dumping align_features (can be slow) or just the table structure
my $no_feature = $support->param('no_feature') || '';

#character set
my $character_set='latin1';

#database type
my $dbtype='MyISAM';

#open file to dump the sql into
my $filename = $support->param('file_name') || ($support->param('pipedbname') . '_create.sql');
my $file = $support->param('sql_dump_location') . '/' . $filename;
open(OUT,">$file") || die "cannot open $file";

# connect to pipeline database and get adaptors
my $pdba = $support->get_database('core','pipe');
my $pdbh = $pdba->dbc->db_handle;

#read all tables;
my %table_constraints;
map { $_ =~ s/`//g; $table_constraints{$_} = 's'; } $pdbh->tables;

#read details of constrained tables from HEREDOC
my $txt = &constraints;
TABLE:
foreach my $line (split(/\n/,$txt)){
	next if ($line =~ /^\s*$/);
	next if ($line =~ /^\#/);
	if ($line=~/^(.+)\#/){
		$line=$1;
	}
		
	my ($table,$constraint) = split(/\s+/,$line);
		
	#sanity check
	if ($table && (! exists($table_constraints{$table}))) {
		$support->log_warning("You have definitions for a table ($table) that is not found in the pipeline database. Skipping\n\n");
		next TABLE;
	}

	#skip tables to ignore
	if ($constraint eq 'i') {
		$table_constraints{$table} = 'i';
		next TABLE;
	}
		
	#if we don't want to dump align_features features for then set type to 's'
	if ($table=~/align_feature$/ && $no_feature) {
		$support->log("\'no_feature\' option used: skipping features from $table\n");
		$table_constraints{$table} = 's';
		next TABLE;
	}
	
	if ($constraint eq 'd') {
		$table_constraints{$table} = 'd';
	}
	#further sanity check
	elsif ($constraint ne 'a') {
		$support->log_warning("Constraint ($constraint) for table ($table)not understood. Skipping\n\n");
		next TABLE;
	}
}

warn Dumper(%table_constraints);
#Do some logging		
my $log = "The following tables will be ignored (ie not put into Vega):\n";
foreach my $table (keys %table_constraints) {
	$log .="\t$table\n" if ($table_constraints{$table} eq 'i');
}
$log .= "The following tables will be dumped with all their data:\n";
foreach my $table (keys %table_constraints) {
	$log .= "\t$table\n" if ($table_constraints{$table} eq 'd');
}
$log .= "The rest of the pipeline tables will be copied just with their structure (no data):\n";
foreach my $table (keys %table_constraints) {
	$log .= "\t$table\n" if ($table_constraints{$table} eq 's');
}
unless ($support->user_proceed("$log\nDo you want to proceed ?")) {
	exit;
}

#########################
# create mysql commands #
#########################

#initialise mysqldump statements
my $cs;
if(my $character_set) {$cs="--default-character-set=\"$character_set\"";}
my $sei;
if(my $opt_c) {$sei='--skip-extended-insert';}
my $user   = $support->param('pipeuser');
my $dbname = $support->param('pipedbname');
my $host   = $support->param('pipehost');
my $port   = $support->param('pipeport');

my $mcom   = "mysqldump --opt --skip-lock-tables $sei $cs --single-transaction -q -u $user -P $port -h $host $dbname";

#create statements
my @mysql_commands;

while (my ($table,$condition) = each (%table_constraints) ) {
	next if ($condition eq 'i');
	if ($condition eq 's') {
		push @mysql_commands, "$mcom -d $table";
	}
	elsif ($condition eq 'd') {
		push @mysql_commands, "$mcom $table";
	}
}

##################
# do the dumping #
##################
	
warn Dumper(\@mysql_commands);
	
if (!$support->param('dry_run')) {
	foreach my $command (@mysql_commands) {
		open(MYSQL,"$command |") || die "cannot open mysql";
		my $enable;
		my $flag_disable;
		while (<MYSQL>) {
			s/(TYPE|ENGINE)=(\w+)/$1=$dbtype/;
			if (/ALTER\sTABLE\s\S+\sENABLE\sKEYS/){
				$enable=$_;
			}
			elsif (/ALTER\sTABLE\s\S+\sDISABLE\sKEYS/){
				if(!$flag_disable){
					# only write once
					$flag_disable=1;
					print OUT;
				}
			}
			else {
				print OUT;
			}
		}
		print OUT $enable if ($enable);
		close(MYSQL);
	}
	$support->log("SQL for dumped to $file\n");
}
else {
	$support->log("\nNo SQL dumped since this is a dry run\n");
}

close(OUT);

$support->finish_log;

#######################################################################
# define the contraints on tables where data is to be transferred     #
# all tables not specified here will have only their structure copied #
#######################################################################

# All tables are by default dumped with just structure. Tables for which data is also to be dumped
# are defined here [d] as are those to be completely ignored [i]

sub constraints {
	my $txt;
	$txt=<<ENDOFTEXT;
dna_align_feature_history        i
hit_description                  i
input_id_analysis                i
input_id_seq_region              i
input_id_type_analysis           i
job                              i
job_status                       i
protein_align_feature_history    i
rule_conditions                  i
rule_goal                        i

assembly                         d
seq_region                       d
meta_coord                       d
coord_system                     d
dna                              d
dna_align_feature                d
protein_align_feature            d
analysis                         d
attrib_type                      d
meta                             d
prediction_exon                  d
prediction_transcript            d
repeat_consensus                 d
repeat_feature                   d
ENDOFTEXT
	return $txt;
}

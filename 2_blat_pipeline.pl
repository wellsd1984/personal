#!/usr/bin/perl

# 2_blat_pipeline.pl
# Dr. Xiaolin Wu & Daria W. Wells

# This script is used after the ISA debarcoding script.  It requires BLAT to
# be installed and hg19 to be downloaded. It reads the demultiplexed and
# split LTR sequences, passes them through various quality filters, performs BLAT alignment,
# then reports the highest quality sequences that lie on the same chromosome within 10kb
# of each other.  The user may choose to filter reads sequence by defining $filter_sequence.
# The sequence can be a regular expression to filter out multiple sequences.

use 5.18.4;
use strict;
use warnings;

use lib '/Users/wellsd2/Desktop/perl_scripts/ISA/current_pipeline'; # Change this path to the location of your modules.
use ISAbatchFilter;
use ISAblatFilter;
use ISAdataReformat;

die "\nNo data files specified on the command line\n" unless @ARGV;

# Define $filter_sequence if desired.
my $filter_sequence = undef;
# BLAT will align to your HIV genome if $align_to_HIV is "Y". Anything
# else and HIV will be skipped.
my $align_to_HIV = "Y";

# Edit these values to suit your system.
my $pipeline = '/Users/wellsd2/Desktop/perl_scripts/ISA/current_pipeline/';
my $path2genome = "/Users/wellsd2/Public/hg38db"; # The path to the human chromosome files
my $path2blat = "/Applications/Blat/blat"; # The path of the BLAT application
my $path2HIV = "/Users/wellsd2/Public/HIV_genome/HIV1_complete_genome.fa"; # Path to the HIV genome
my @chromosomes = glob "$path2genome/*.fa"; # List of hg19 chromosomes for alignment

foreach my $data_file (@ARGV) {
	$pipeline .= '/' unless $pipeline =~ m/\/$/;
	
	my $path2ooc = $pipeline.'11.ooc';
	my $path2uclust = $pipeline.'uclust';
	my ($LTR, $name) = ($data_file =~ /([35]LTR)\/(.*)\.txt\.gz/); # Remove .txt.gz from the file name.
	my $folder = $LTR."/".$name;
 	mkdir "$folder" or die "\nFolder $folder already exists.\nWere you about to overwrite your data?\n"; # Create the folder where the results files will be stored.
	
	# Record which file is being analyzed.
	
 	my $nowtime = localtime;
 	open my $log_fh,">>","$folder/blat_log.txt" or die "\nUnable to print to log file in main script: $!";
 	print $log_fh "Analysis started at $nowtime\n\n$data_file\n\n";
 	close $log_fh;
 	
 	print "Processing $data_file...\n";
 	
#  	If the filter sequence is defined
 	if (defined $filter_sequence) {
 		ISAbatchFilter::batch_filter_1_internal($filter_sequence, $LTR, $data_file, $folder);
 		$data_file = "PEread_LTR_NonInternal_linker.txt";
 	}
#  	Filter out reads shorter than 20 bases long.
 	ISAbatchFilter::batch_filter_2_length20($data_file,$LTR,$folder);
#  	Filter out reads with quality scores less than 20.
 	ISAbatchFilter::batch_filter_3_q20($LTR,$folder);
#  	Make fasta files for alignment.
 	ISAbatchFilter::make_unique_pair_fasta($LTR,$folder);

#	Align the fasta files to human and HIV
#  	Example alignment command:
#  	/Applications/Blat/blat /Path/to/hg19db/hg19chromFA/chr1.2bit ./PEread_LTR_NonInternal_linker_long_UniquePairWct_F.fa -ooc=11.ooc PEread_LTR_NonInternal_linker_long_UniquePair_F_chr1.psl  -minScore=16 -stepSize=8
#  	Align the forward and reverse reads. $s stands for strand.
	my $fasta_file = "$folder/PEread_LTR_NonInternal_linker_long_UniquePairWct_"; # The base of the fasta file name
	my $blat_out = "$folder/PEread_LTR_NonInternal_linker_long_UniquePair_"; # The base of the BLAT output file name
 	 
 	foreach my $s (qw(F R)) {
 		my @args;
 		foreach my $path2chr (@chromosomes) {

			$path2chr =~ m/(chr.*)\.fa/;
			my $chr = $1;
			my $path2data = $fasta_file.$s.'.fa';
			my $path2output = $blat_out.$chr.'_'.$s.'.psl';
 			# Create the command for each chromosome.
 			@args = ($path2blat, $path2chr, $path2data, "-ooc=$path2ooc", $path2output, "minScore=16 -stepSize=8");
			system("@args");

 		}
 		if ($align_to_HIV eq 'Y') {
 			my $path2output = $blat_out.'_HIV'.$s.'.psl';
 			@args[1,4] = ($path2HIV, $path2output);
 			system("@args");
 		}
 		# Concatenate the BLAT output .psl files from each chromosome into one file text file
 		# then delete all of the .psl files. 
 		system("cat $folder/*.psl >>$folder/PEread_LTR_NonInternal_linker_long_UniquePair_$s"."_blat.txt");
  		system("rm $folder/*.psl");
	
   	}
  	
  	# @libs contains the file name templates for the forward (read 1) and reverse (read 2) reads.
  	my @libs=("$folder/PEread_LTR_NonInternal_linker_long_UniquePair_F","$folder/PEread_LTR_NonInternal_linker_long_UniquePair_R");
  	
 	# Filter out alignments from the BLAT output that start more than 3 bases into the 
 	# sequence and are shorter than 20 bases.	
 	print "\nFiltering alignments shorter than 20 bases...\n";   
 	ISAblatFilter::blat_filter1($_,$folder) foreach @libs;
 	
	# Filtering alignments to repetitive regions 
 	print "Filtering alignments to repetitive regions...\n";
 	ISAblatFilter::blat_filter2($_,$folder) foreach @libs;

  	# Combine the read 1 and read 2 blat results
  	print "Combining paired-end data...\n";
	my $repeat_alignments = ISAblatFilter::blat_filter3($folder);

 	# Filter out reads where the left and right coordinates aren't on the same chromosome, 
 	# are on the same strand, or are more than 10kb apart.
 	print "Filtering mismatched read pair alignments...\n";
 	ISAblatFilter::blat_filter4($folder,$repeat_alignments);
 	
 	# Merge integration sites if they meet all of the following criteria:
		#	1.	The breakpoints are within 10 bases of each other.
		#	2.	The MIDs differ by no more than two bases. (Hamming distance)
		#	3.	The site with the larger count is greater than double the smaller count plus 1. (count score)
	print "Merging reads with small IS or breakpoint base variation...\n";
 	ISAblatFilter::blat_filter5($folder);

 	# Make new file names for the data files.
	my $blatresults_filtered2="$name"."_blat.txt";
	my $blatresults_filtered3="$name"."_blat_annotated.txt";
	my $blatresults_filtered4="$name"."_blat_annotated_with_fuzz.txt";
	
 	# Predict which integration sites might be the result of mis-priming.
  	system("mv $folder/PairedEndRIS_filter2.txt $folder/$blatresults_filtered2");
  	
  	print "Adding mis-priming and sequence info to the results...\n";
 	ISAdataReformat::annotate_blat_file($blatresults_filtered2,$LTR,$name,$path2genome,$folder);

	# Sort the fasta file by sequence length for uClust.
 	print "Sorting the data for Uclust...\n";
 	ISAdataReformat::sort_fasta_by_length($folder);
 	# Run uClust.
 	system("$path2uclust --input $folder/Read1_insert.fa --uc $folder/Read1_insert.uc --id 0.90");
	# Reformat the uClust output
	
	print "Re-sorting the Uclust data...\n";
	ISAdataReformat::resort_Uclust($name,$folder);

  	# Move files into ./$folder for storage and organization.
 	system("mv $folder/PEread_LTR_NonInternal_linker_long_UniquePairWct.txt ./$folder/unique_paired-end_reads.txt");
 	system("mv $folder/PEread_LTR_NonInternal_linker_long_UniquePairWct_F.fa ./$folder/read1_fasta_for_alignment.fa");
 	system("mv $folder/PEread_LTR_NonInternal_linker_long_UniquePairWct_R.fa ./$folder/read2_fasta_for_alignment.fa");
 	system("mv $folder/$blatresults_filtered2 ./$folder/merged_integration_sites.txt");
 	system("mv $folder/$blatresults_filtered3 ./$folder/final_annotated_integration_sites_report.txt");
 	system("mv $folder/$blatresults_filtered4 ./$folder/annotated_integration_sites_report_with_fuzz.txt"); 	
 	system("mv $folder/PEread_LTR_NonInternal_linker_long_UniquePairWct_F_R_blat.txt ./$folder/combined_unfiltered_match_pairs.txt");
  	system("mv $folder/PEread_LTR_NonInternal_linker_long_UniquePairWct_F_R_for_Uclust.txt ./$folder/all_read1_coordinates_for_Uclust.txt");
 	system("mv $folder/PEread_LTR_NonInternal_linker_long_UniquePair_F_blat.txt ./$folder/read1_blat_results.txt");
 	system("mv $folder/PEread_LTR_NonInternal_linker_long_UniquePair_F_blat.txt_filter1 ./$folder/read1_blat_results_high_quality.txt");
 	system("mv $folder/PEread_LTR_NonInternal_linker_long_UniquePair_F_blat.txt_filter2_bestMatch ./$folder/read1_blat_results_best_alignments.txt");
 	system("mv $folder/PEread_LTR_NonInternal_linker_long_UniquePair_F_blat.txt_filter2_repeatMatch ./$folder/read1_blat_results_repetitive_regions.txt");
 	system("mv $folder/PEread_LTR_NonInternal_linker_long_UniquePair_R_blat.txt ./$folder/read2_blat_results.txt");
 	system("mv $folder/PEread_LTR_NonInternal_linker_long_UniquePair_R_blat.txt_filter1 ./$folder/read2_blat_results_high_quality.txt");
 	system("mv $folder/PEread_LTR_NonInternal_linker_long_UniquePair_R_blat.txt_filter2_bestMatch ./$folder/read2_blat_results_best_alignments.txt");
 	system("mv $folder/PEread_LTR_NonInternal_linker_long_UniquePair_R_blat.txt_filter2_repeatMatch ./$folder/read2_blat_results_repetitive_regions.txt");
 	system("mv $folder/PairedEndRIS_filter1.txt ./$folder/filtered_out_unmatched_read_loci.txt");
 	system("mv $folder/Read1_insert.fa ./$folder/read1_sorted_by_length_for_Uclust.fa");
  	system("mv $folder/Read1_insert.uc ./$folder/Uclust_results_raw.txt");
 	
}

exit;
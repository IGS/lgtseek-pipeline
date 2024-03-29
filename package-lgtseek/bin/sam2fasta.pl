#!/usr/bin/perl

eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell
=head1 NAME

sam2fasta.pl

=head1 SYNOPSIS

    sam2fasta.pl
       --file_list=/path/to/file/list || --input=/path/to/input.sam
       [--output_file=/path/to/outputfile.fasta # Will be used as a base to generate _N.fastq files if --fastq=1
       --host=foobar.com
       --combine_mates=1 # To concat the sequence/quality into one string
       --tmp_dir=/path/to/temp
       --fastq=1
       --hlgt=1
       --paired=1 # Defaults to 1
       --assume_uniq=1 # To ignore how many times you see a read. Good for single large files.
       --help]

=cut

use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev);
use Pod::Usage;
use File::Basename;
use Bio::Perl;
use LGT::Common;
$|++;

my %options = ();
my $results = GetOptions (\%options,
              'file_list:s',
              'input=s',
              'output_file:s',
              'tmp_dir:s',
              'fastq:s',
              'host:s',
              'base_list:s',
              'out_list:s',
              'combine_mates:s',
              'hlgt:s',
              'samtools_bin:s',
              'paired:s',
              'assume_uniq:s',
              'gzip:s',
              'help|h') || pod2usage();

# display documentation
if( $options{'help'} ){
    pod2usage( {-exitval=>0, -verbose => 1, -output => \*STDOUT} );
}

my $samtools = $options{'samtools_bin'} ? $options{'samtools_bin'} : '/usr/local/bin/samtools';
my $paired = defined($options{paired}) ? $options{paired} : 1;
my $working_reads = {};
my $reads_seen = {};
my $seen_outputs = {};

my $out;
my $out1;
my $out2;
my $combinedout;
my $path;
my $name;
my $suffix;
my @outfiles;
my @outbases;

if($options{file_list}) {
    open IN1, "<$options{file_list}" or die "Couldn't open file list: $options{file_list}\n";
    if($options{output_file}) {
        &set_output('');
    }
    while(<IN1>) {
        chomp;
        if(!$options{output_file} && !$options{hlgt}) {
            &set_output($_);
        }
        print "Processing $_\n";
        if($options{hlgt}) {
            &process_file_hlgt($_);
        }
        else {
            &process_file2($_);
        }
    }
}
elsif($options{input}) {
    &set_output($options{input});
    if($options{hlgt}) {
        &process_file_hlgt($options{input});
    }
    else {
        &process_file2($options{input});
    }
}

close IN1;

if($options{base_list}) {
    open OUTBASE, ">$options{base_list}" or die "Cannot open $options{base_list} for writing: $!\n";
    foreach my $name (@outbases){
        print OUTBASE "$path/$name\n";
    }
    close OUTBASE;
}
if($options{out_list}) {
    open OUTLIST, ">$options{out_list}" or die "Cannot open $options{out_list} for writing: $!\n";
    print OUTLIST join("\n",@outfiles);
    close OUTLIST;
}

if($options{gzip}) {
    map {
        print `gzip $_`;
    } @outfiles;
}

# Determine file format of input, and create the appropriate output_file
sub set_output {
    my $input = shift;
    if($options{output_file}) {
        $input = $options{output_file};
    }

    ($name,$path,$suffix) = fileparse($input, (qr/.fastq$||.fasta$||.fna$||.fq||.fsa||.bam$||.sam$||.sam.gz$/));
    $path =~ s/\/$//;
    if($options{fastq} && $options{combine_mates}) {
		# Combine two Fastq files into one output if options specify it
        if($seen_outputs->{"$path/$name.fastq"}) {
            open $combinedout, ">>$path/$name.fastq" or die "Unable to open $path/$name.fastq\n";
        }
        else {
            open $combinedout, ">$path/$name.fastq" or die "Unable to open $path/$name.fastq\n";
            push(@outfiles,"$path/$name.fastq");
        }
        $seen_outputs->{"$path/$name.fastq"} = 1;
    } elsif($options{fastq} && $paired) {
		# ... else treat as two different fastq outputs if paired-end
        if($seen_outputs->{"$path/$name\_1.fastq"}) {
            open $out1, ">>$path/$name\_1.fastq" or die "Unable to open $path/$name\_1.fastq\n";
        }
        else {
            open $out1, ">$path/$name\_1.fastq" or die "Unable to open $path/$name\_1.fastq\n";
            push(@outfiles,"$path/$name\_1.fastq");
            push(@outbases, "$name"); # Kind of a hack to do this here
        }
        if($seen_outputs->{"$path/$name\_2.fastq"}) {
            open $out2, ">>$path/$name\_2.fastq" or die "Unable to open $path/$name\_2.fastq\n";
        }
        else {
            open $out2, ">$path/$name\_2.fastq" or die "Unable to open $path/$name\_2.fastq\n";
            push(@outfiles,"$path/$name\_2.fastq");
        }
        $seen_outputs->{"$path/$name\_1.fastq"} = 1;
        $seen_outputs->{"$path/$name\_2.fastq"} = 1;

    } elsif($options{fastq}) {
		# ... else treat as single-end fastq
        if($seen_outputs->{"$path/$name.fastq"}) {
            open $out, ">>$path/$name.fastq" or die "Unable to open $path/$name.fastq\n";
        }
        else {
            open $out, ">$path/$name.fastq" or die "Unable to open $path/$name.fastq\n";
            push(@outfiles, "$path/$name.fastq");
        }
        $seen_outputs->{"$path/$name.fastq"} = 1;
        push(@outbases, "$name");
    } else {
		# Else it's a fasta file
        if($seen_outputs->{"$path/$name.fasta"}) {
            open $out, ">$path/$name.fasta" or die "Couldn't output file list: $options{output_file}\n";
        }
        else {
            open $out, ">$path/$name.fasta" or die "Couldn't output file list: $options{output_file}\n";
            push(@outfiles,"$path/$name.fasta");
        }
        $seen_outputs->{"$path/$name.fasta"} = 1;

        push(@outbases, "$name");
    }
}

# Basic sam2fasta(q) conversion. Nothing fancy here.
sub process_file2 {
    my $file = shift;

    my ($name,$path,$suffix) = fileparse($file,'.sam*');


    # Copy the file if it's remote.
    if($options{host} && $options{tmp_dir}) {
        # copy file
        my $cmd = "scp $options{host}:$file $options{tmp_dir}";
        &run_cmd($cmd);
        $file = "$options{tmp_dir}/$name$suffix";
    }
    my $infh;
    # Unzip
    if($file =~ /.sam.gz/) {
        open($infh, "<:gzip", $file) or die "Unable to open $file\n";
    }elsif($file =~ /.bam/) {
        open($infh, "-|", "$samtools view $file") or die "Unable to run samtools view on $file\n";
    }else {
        open($infh, "<$file")  or die "Unable to open $file\n";
    }


    # Read file
    while(<$infh>) {
        my @fields = split;


        # Don't do anything if we've already seen this read and have gotten both mates.
        if(!$paired || !$reads_seen->{$fields[0]}) {

            # Parse the flag
            my $flag = parse_flag($fields[1]);

            # Skip if this is a secondary alignment
            next if($flag->{secondary});

            # Pull out the sequence and quality fields
            my $seq = $fields[9];
            my $qual = $fields[10];

            # Check if we are reversed.
            if($flag->{qrev}) {
                $seq = revcom_as_string($fields[9]);
                $qual = reverse $fields[10];
            }

            if(!$working_reads->{$fields[0]}) {
                $working_reads->{$fields[0]} = {};
            }

            # Make a little object with the read info in it. Key this on read id and decimal flag number
            $working_reads->{$fields[0]}->{$fields[1]} = {'qual' => $qual,'seq' => $seq,'fields' => \@fields,'flag' => $flag};

            # If we have seen both mates go in here (this is a bit of a HACK)
            if(keys %{$working_reads->{$fields[0]}} == 2 || !$paired) {
                if(!$options{assume_uniq}) {
                    $reads_seen->{$fields[0]}=1;
                }
                my $count = 0;
                if(keys %{$working_reads->{$fields[0]}} > 1) {
                    $count = 1;
                }

                my $combined = undef;
                foreach my $f (keys %{$working_reads->{$fields[0]}}) {

                    if($options{combine_mates}) {
                        if($combined) {
                            $combined->{seq}.= $working_reads->{$fields[0]}->{$f}->{seq};
                            $combined->{qual}.= $working_reads->{$fields[0]}->{$f}->{qual};
                        }
                        else {
                            $combined->{seq} = $working_reads->{$fields[0]}->{$f}->{seq};
                            $combined->{qual} = $working_reads->{$fields[0]}->{$f}->{qual};
                            $combined->{fields} = $working_reads->{$fields[0]}->{$f}->{fields};
                        }
                    } elsif($options{fastq}) {
                        &print_fastq($working_reads->{$fields[0]}->{$f});
                    } else {
                        print $out '>'.$fields[0];
                        if($count) {
                            print $out "/$count";
                        }
                        print $out "\n";
                        print $out $working_reads->{$fields[0]}->{$f}->{seq}."\n";
                        $count++;
                    }
                }
                if($combined) {
                    if($options{fastq}) {
                        &print_fastq($combined);
                    } else {
                        print $out '>'.$fields[0];
                        print $out "\n";
                        print $out $combined->{seq}."\n";
                    }
                }
                delete($working_reads->{$fields[0]});
            }
        }
    }
    close $infh;


}
sub process_file_hlgt {
    my $file = shift;

    my ($fname,$fpath,$fsuffix) = fileparse($file,'.sam*');



    if($options{host} && $options{tmp_dir}) {
        # copy file
        my $cmd = "scp $options{host}:$file $options{tmp_dir}/";
        &run_cmd($cmd);
        $file = "$options{tmp_dir}/$fname$fsuffix";
        ($fname,$fpath,$fsuffix) = fileparse($file,'.sam*');
    }
    my $infh;
    # Unzip
    if($file =~ /.sam.gz/) {
        open($infh, "<:gzip", $file) or die "Unable to open sam.gz $file\n";
    }else {
        open($infh, "<$file")  or die "Unable to open sam $file\n";
    }

    my $run = '';
    print STDERR "$fname\n";
    if($fname =~ /_([^_]+).sam/) {
        $run = $1;
    }

    if(!$options{output_file} && $run) {
        # This is a HACK since this file never existed.
        print "Calling $fpath/$run.sam\n";
        &set_output("$fpath/$run.sam");
    }

    while(<$infh>) {
        my @fields = split;

        if(!$reads_seen->{$fields[0]}) {
            if(!$working_reads->{$fields[0]}) {
                $working_reads->{$fields[0]} = {};
            }
            my $flag = parse_flag($fields[1]);
            next if($flag->{secondary});
            my $seq = $fields[9];
            my $qual = $fields[10];
            if($flag->{qrev}) {
                $seq = revcom_as_string($fields[9]);
                $qual = reverse $fields[10];
            }
            if(!$working_reads->{$fields[0]}->{$seq} && !$flag->{'qunmapped'}) {
                $working_reads->{$fields[0]}->{$seq} = {'flag' => $flag,
                                                        'seq' => $seq,
                                                        'subj' => $fields[2],
                                                        'fields' => \@fields,
                                                        'qual' => $qual};
            }
            if(keys %{$working_reads->{$fields[0]}} == 2) {
                $reads_seen->{$fields[0]} = 1;

                if($options{combine_mates}) {
                    my $combined = {};
                    foreach my $s (keys %{$working_reads->{$fields[0]}}) {
                        my $obj = $working_reads->{$fields[0]}->{$s};
                        $combined->{seq} .= $obj->{seq};
                        $combined->{qual} .= $obj->{qual};
                        $combined->{fields} = $obj->{fields};
                    }
                    &print_fastq($combined);
                }
                else {
                    foreach my $s (keys %{$working_reads->{$fields[0]}}) {
                        my $obj = $working_reads->{$fields[0]}->{$s};
                        if($obj->{subj} =~ /^chr/) {
                            if($options{fastq}) {
                                print "About to print a line\n";
                                &print_fastq($obj);
                            }
                        else {
                            print $out '>'.$fields[0].'_human'."\n";
                            print $out $obj->{seq}."\n";
                        }
                        }
                        else {
                            if($options{fastq}) {
                                &print_fastq($obj);
                            }
                            else {
                                print $out '>'.$fields[0].'_bac'."\n";
                                print $out $obj->{seq}."\n";
                        }
                        }
                    }
                }
                delete($working_reads->{$fields[0]});
            }
        }
    }
    close $infh;

}

sub print_fastq {
    my $obj = shift;
    my $fh;
    if(!$paired) {
        $fh = $out;
    }
    elsif($options{combine_mates}) {
        $fh = $combinedout;
    }
    elsif($obj->{flag}->{first}) {
        $fh = $out1;
    }
    else {
        $fh = $out2;
    }
    print $fh '@'.$obj->{fields}->[0]."\n";
    print $fh $obj->{seq}."\n";
    print $fh "+\n";
    print $fh $obj->{qual}."\n"
}
sub run_cmd {

    my $cmd = shift;

    `$cmd`;
    if($?) {
        print STDERR "$cmd\n\n$?";
    }
   # print "$cmd\n";
}
sub dec2bin {
    my $str = unpack("B32", pack("N", shift));
    $str =~ s/^0+(?=\d)//;   # otherwise you'll get leading zeros
    return $str;
}

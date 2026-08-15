#!/usr/bin/env perl
use strict;
use warnings;

my ($path, $expected_ranks) = @ARGV;
die "usage: validate_rank_shuffle.pl FILE RANKS\n"
    unless defined $expected_ranks && $expected_ranks =~ /^\d+$/
        && $expected_ranks > 1;

open my $handle, '<:raw', $path or die "cannot open $path: $!\n";
my (%rank_to_file, %file_seen);
while (my $line = <$handle>) {
    next unless $line =~ /^task\s+(\d+)\s+reading\s+.*\.(\d{8})\s*$/;
    my ($rank, $file) = (0 + $1, 0 + $2);
    die "rank $rank reported more than one read target\n"
        if exists $rank_to_file{$rank};
    die "out-of-range rank $rank\n" if $rank >= $expected_ranks;
    die "out-of-range file index $file\n" if $file >= $expected_ranks;
    $rank_to_file{$rank} = $file;
    $file_seen{$file}++;
}
close $handle or die "cannot close $path: $!\n";

die "expected $expected_ranks rank mappings, found "
    . scalar(keys %rank_to_file) . "\n"
    unless keys(%rank_to_file) == $expected_ranks;
die "rank shuffle omitted or duplicated a file\n"
    unless keys(%file_seen) == $expected_ranks
        && !grep { $_ != 1 } values %file_seen;
die "double -Z left every rank on its own file\n"
    unless grep { $rank_to_file{$_} != $_ } keys %rank_to_file;

print join(',', map { $rank_to_file{$_} } 0 .. $expected_ranks - 1), "\n";

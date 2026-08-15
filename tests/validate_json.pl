#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(decode_json);
use Scalar::Util qw(looks_like_number);

my ($path, $expected_api, $expected_tasks, $expected_transfer,
    $expected_block, $expected_fpp) = @ARGV;
die "usage: validate_json.pl FILE API TASKS TRANSFER BLOCK FPP\n"
    unless defined $expected_fpp;

open my $handle, '<:raw', $path or die "cannot open $path: $!\n";
local $/;
my $text = <$handle>;
close $handle or die "cannot close $path: $!\n";

die "JSON output is unexpectedly small\n" unless defined $text && length($text) > 256;
my $document = eval { decode_json($text) };
die "JSON decode failed: $@\n" if $@;
die "top level must be an object\n" unless ref($document) eq 'HASH';

for my $key ('Version', 'Began', 'Finished', 'Command line', 'tests', 'summary') {
    die "missing top-level key: $key\n" unless exists $document->{$key};
}

die "tests must be a non-empty array\n"
    unless ref($document->{tests}) eq 'ARRAY' && @{$document->{tests}} == 1;

die "summary must be a non-empty array\n"
    unless ref($document->{summary}) eq 'ARRAY' && @{$document->{summary}} >= 2;

for my $key ('Version', 'Began', 'Finished', 'Command line') {
    die "$key must be a non-empty string\n"
        unless !ref($document->{$key}) && length($document->{$key}) > 0;
}

my $saw_write = 0;
my $saw_read = 0;
for my $test (@{$document->{tests}}) {
    die "test entry must be an object\n" unless ref($test) eq 'HASH';
    die "test Parameters missing\n" unless ref($test->{Parameters}) eq 'HASH';
    my $api = $test->{Parameters}->{api};
    die "expected API $expected_api, found " . (defined $api ? $api : '<missing>') . "\n"
        unless defined $api && uc($api) eq uc($expected_api);
    for my $check (
        ['tasksPerNode', $expected_tasks],
        ['transferSize', $expected_transfer],
        ['blockSize', $expected_block],
        ['filePerProc', $expected_fpp],
        ['segmentCount', 2],
    ) {
        my ($key, $expected) = @$check;
        my $actual = $test->{Parameters}->{$key};
        die "invalid Parameters.$key\n"
            unless defined $actual && looks_like_number($actual)
                && $actual == $expected;
    }
    die "test Results missing\n" unless ref($test->{Results}) eq 'ARRAY';
    for my $result (@{$test->{Results}}) {
        next unless ref($result) eq 'HASH';
        next unless defined $result->{access};
        if ($result->{access} eq 'write' || $result->{access} eq 'read') {
            for my $key ('bwMiB', 'blockKiB', 'xferKiB', 'iops', 'totalTime') {
                die "invalid Results.$key\n"
                    unless defined $result->{$key}
                        && looks_like_number($result->{$key})
                        && $result->{$key} >= 0;
            }
            die "wrong Results.blockKiB\n"
                unless $result->{blockKiB} == $expected_block / 1024;
            die "wrong Results.xferKiB\n"
                unless $result->{xferKiB} == $expected_transfer / 1024;
            $saw_write = 1 if $result->{access} eq 'write';
            $saw_read = 1 if $result->{access} eq 'read';
        }
    }
}

die "write result missing\n" unless $saw_write;
die "read result missing\n" unless $saw_read;

my %summary_access;
for my $summary (@{$document->{summary}}) {
    next unless ref($summary) eq 'HASH';
    next unless defined $summary->{operation}
        && ($summary->{operation} eq 'write' || $summary->{operation} eq 'read');
    die "wrong summary API\n"
        unless defined $summary->{API} && uc($summary->{API}) eq uc($expected_api);
    for my $check (
        ['numTasks', $expected_tasks],
        ['transferSize', $expected_transfer],
        ['blockSize', $expected_block],
        ['filePerProc', $expected_fpp],
        ['segmentCount', 2],
    ) {
        my ($key, $expected) = @$check;
        my $actual = $summary->{$key};
        die "invalid summary.$key\n"
            unless defined $actual && looks_like_number($actual)
                && $actual == $expected;
    }
    $summary_access{$summary->{operation}} = 1;
}

die "write summary missing\n" unless $summary_access{write};
die "read summary missing\n" unless $summary_access{read};

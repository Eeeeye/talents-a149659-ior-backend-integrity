#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP qw(decode_json);
use Scalar::Util qw(looks_like_number);

my ($path) = @ARGV;
die "usage: validate_json_multi.pl FILE\n" unless defined $path;

open my $handle, '<:raw', $path or die "cannot open $path: $!\n";
local $/;
my $text = <$handle>;
close $handle or die "cannot close $path: $!\n";

my $document = eval { decode_json($text) };
die "JSON decode failed: $@\n" if $@;
die "top level must be an object\n" unless ref($document) eq 'HASH';

for my $key ('Version', 'Began', 'Finished', 'Command line') {
    die "$key must be a non-empty string\n"
        unless exists $document->{$key} && !ref($document->{$key})
            && length($document->{$key}) > 0;
}

my @expected = (
    { api => 'POSIX', tasks => 2, transfer => 8192, block => 65536,
      fpp => 1, segments => 1 },
    { api => 'MPIIO', tasks => 2, transfer => 16384, block => 98304,
      fpp => 1, segments => 2 },
);

die "tests must contain both RUN entries\n"
    unless ref($document->{tests}) eq 'ARRAY'
        && @{$document->{tests}} == @expected;
die "summary must contain both operations for both RUN entries\n"
    unless ref($document->{summary}) eq 'ARRAY'
        && @{$document->{summary}} >= 4;

for my $index (0 .. $#expected) {
    my $spec = $expected[$index];
    my $test = $document->{tests}->[$index];
    die "test $index must be an object\n" unless ref($test) eq 'HASH';
    die "test $index Parameters missing\n"
        unless ref($test->{Parameters}) eq 'HASH';
    my $parameters = $test->{Parameters};
    die "test $index API mismatch\n"
        unless defined $parameters->{api}
            && uc($parameters->{api}) eq $spec->{api};

    for my $check (
        ['tasksPerNode', 'tasks'],
        ['transferSize', 'transfer'],
        ['blockSize', 'block'],
        ['filePerProc', 'fpp'],
        ['segmentCount', 'segments'],
    ) {
        my ($field, $expected_field) = @$check;
        my $actual = $parameters->{$field};
        die "test $index invalid Parameters.$field\n"
            unless defined $actual && looks_like_number($actual)
                && $actual == $spec->{$expected_field};
    }

    die "test $index Results missing\n"
        unless ref($test->{Results}) eq 'ARRAY';
    my %operations;
    for my $result (@{$test->{Results}}) {
        next unless ref($result) eq 'HASH'
            && defined $result->{access}
            && ($result->{access} eq 'write' || $result->{access} eq 'read');
        for my $field ('bwMiB', 'blockKiB', 'xferKiB', 'iops', 'totalTime') {
            die "test $index invalid Results.$field\n"
                unless defined $result->{$field}
                    && looks_like_number($result->{$field})
                    && $result->{$field} >= 0;
        }
        $operations{$result->{access}} = 1;
    }
    die "test $index write/read results missing\n"
        unless $operations{write} && $operations{read};
}

my %summary_seen;
for my $entry (@{$document->{summary}}) {
    next unless ref($entry) eq 'HASH' && defined $entry->{operation}
        && ($entry->{operation} eq 'write' || $entry->{operation} eq 'read');
    for my $index (0 .. $#expected) {
        my $spec = $expected[$index];
        next unless defined $entry->{API} && uc($entry->{API}) eq $spec->{api};
        next unless defined $entry->{transferSize}
            && defined $entry->{blockSize}
            && $entry->{transferSize} == $spec->{transfer}
            && $entry->{blockSize} == $spec->{block};
        for my $check (
            ['numTasks', 'tasks'],
            ['filePerProc', 'fpp'],
            ['segmentCount', 'segments'],
        ) {
            my ($field, $expected_field) = @$check;
            die "summary $index invalid $field\n"
                unless defined $entry->{$field}
                    && looks_like_number($entry->{$field})
                    && $entry->{$field} == $spec->{$expected_field};
        }
        $summary_seen{"$index:$entry->{operation}"} = 1;
    }
}

for my $index (0 .. $#expected) {
    for my $operation ('write', 'read') {
        die "summary missing $operation for test $index\n"
            unless $summary_seen{"$index:$operation"};
    }
}

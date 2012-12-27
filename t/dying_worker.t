#!/usr/bin/perl

use 5.010;
use strict;
use warnings;
use utf8;

use Test::More;

use threads;
use Thread::Pipeline;

my @data = ( 1 .. 5 );

my $p = Thread::Pipeline->new([
        die_on_3 => { sub => sub { die if $_[0] eq 3 } },
    ]);

$p->enqueue($_)  for @data;
$p->no_more_data();

my @r = $p->get_results();


is( scalar @r, scalar @data - 1, 'result size' );


done_testing();



package Thread::Pipeline;

# $Id$

# NAME: Thread::Pipeline
# ABSTRACT: multithreaded pipeline manager

=head1 SYNOPSIS

    my %blocks = (
        map1 => { sub => \&mapper, num_threads => 2, main_input => 1, out => 'map2' },
        map2 => { sub => \&another_mapper, num_threads => 5, out => [ 'log', 'reduce' ] },
        reduce => { sub => \&reducer, need_finalize => 1, out => '_out' },
        log => { sub => \&logger },
    );

    # create pipeline
    my $pipeline = Thread::Pipeline->new( \%blocks );

    # fill its input queue
    for my $data_item ( @data_array ) {
        $pipeline->enqueue( $data_item );
    }

    # say that there's nothing more to process
    $pipeline->no_more_data();

    # get results from pipeline's output queue
    my @results = $pipeline->get_results();

=cut


use 5.010;
use strict;
use warnings;
use utf8;
use Carp;

use threads;
use threads::shared;
use Thread::Queue::Any;


=method new

    my $pl = Thread::Pipeline->new( $blocks_description );

Constructor.
Creates pipeline object, initializes blocks if defined.

Blocks description is a hashref { $id => $descr, ... }
or an arrayref [ $id => $lite_descr, ... ] (see add_block).
For arrayrefs constructor assumes direct block chain
and automatically adds 'main_input' and 'out' fields.

=cut

sub new {
    my ($class, $blocks, %opt) = @_;
    my $self :shared = shared_clone {
        blocks      => {},
        out_queue   => Thread::Queue::Any->new(),
        input_ids   => [],
    };
    bless $self, $class;

    if ( ref $blocks eq 'HASH' ) {
        while ( my ($id, $info) = each %$blocks ) {
            $self->add_block( $id => $info );
        }
    }
    elsif ( ref $blocks eq 'ARRAY' ) {
        for my $i ( 0 .. @$blocks/2 - 1 ) {
            my ( $id, $info, $next_id ) = @$blocks[ $i*2 .. $i*2+2 ];
            my %block = %$info;
            $block{main_input} //= 1  if $i == 0;
            $block{out} //= $next_id // '_out';
            $self->add_block( $id => \%block );
        }
    }

    return $self;
}


=method add_block

    my %block_info = (
        sub => \&worker_sub,
        num_threads => $num_of_threads,
        out => $next_block_id,
    );
    $pl->add_block( $block_id => \%block_info );

Add new block to the pipeline.
Worker threads and associated incoming queue would be created.

Block info is a hash containing keys:
    * sub - worker coderef (required)
    * num_threads - number of parallel threads of worker, default 1
    * out - id of block where processed data should be sent, use '_out' for pipeline's main output
    * main_input - mark this block as default for enqueue
    * post_sub - code that run when all theads ends
    * need_finalize - run worker with undef when queue is finished

Worker is a sub that will be executed with two params: &worker_sub($data, $pipeline).
When $data is undefined that means that it is latest data item in sequence.

=cut

sub add_block {
    my ($self, $block_id, $block_info, %opt) = @_;

    my $queue :shared = Thread::Queue::Any->new();
    my $block = shared_clone {
        queue => $queue,
    };

    my $threads_num :shared = $block_info->{num_threads} || 1;
    my $thread_sub = sub {
        while (1) {
            # get incoming data block
            my $in_data = $queue->dequeue();

            # process it
            # ??? eval?
            my $out_data;
            if ( defined $in_data || $block_info->{need_finalize} ) {
                $out_data = $block_info->{sub}->( $in_data, $self );
            }

            # send result to next block
            if ( defined $out_data && $block_info->{out} ) {
                $self->enqueue( $out_data, block => $block_info->{out} );
            }

            # finish work if incoming data was undefined
            last if !defined $in_data;
        }

        lock $threads_num;
        $threads_num --;

        # send undef to next block
        if ( !$threads_num ) {
            $block_info->{post_sub}->()  if $block_info->{post_sub};
            if ( $block_info->{out} && $block_info->{out} ne '_out' ) {
                $self->no_more_data($block_info->{out});
            }
        }

        return;
    };

    my @threads = map { threads->create($thread_sub) } ( 1 .. $threads_num ); 
    $block->{threads} = shared_clone \@threads;

    $self->{blocks}->{$block_id} = $block;
    push @{ $self->{input_ids} }, $block_id  if $block_info->{main_input};

    return $self;
}


=method enqueue

    $pl->enqueue( $data, %opts );

Puts the data into block's queue
Options:
    * block - id of block, default is pipeline's main input block

=cut

sub enqueue {
    my ($self, $data, %opt) = @_;

    my $ids = $opt{block} || $self->{input_ids};

    for my $block_id ( @{ ref $ids ? $ids : [$ids]  } ) {
        if ( $block_id eq '_out' ) {
            $self->{out_queue}->enqueue($data);
        }
        else {
            my $block = $self->{blocks}->{$block_id};
            croak "Unknown block id: $block_id"  if !$block;
            $block->{queue}->enqueue( $data );
        }
    }

    return $self;
}


=method no_more_data

    $pl->no_more_data( %opts );

=cut

sub no_more_data {
    my ($self, $ids) = @_;
    $ids ||= $self->{input_ids};

    for my $block_id ( @{ ref $ids ? $ids : [$ids]  } ) {
        my $num = $self->get_threads_num($block_id);
        my $block = $self->{blocks}->{$block_id};
        $block->{queue}->enqueue( undef )  for ( 1 .. $num );
    }

    return $self;
}



=method get_results

    my @result = $pl->get_results();

Wait for all pipeline operations to finish.
Returns content of outlet queue

=cut

sub get_results {
    my ($self, %opt) = @_;

    for my $block ( values %{ $self->{blocks} } ) {
        for my $thread ( @{ $block->{threads} } ) {
            $thread->join();
        }
    }

    my @result;
    while ( my @items = $self->{out_queue}->dequeue_dontwait() ) {
        push @result, @items;
    }

    return @result;
}


=method get_threads_num

    my $num = $pl->get_threads_num($block_id);

=cut

sub get_threads_num {
    my ($self, $block_id) = @_;

    my $block = $self->{blocks}->{$block_id};
    croak "Unknown block id: $block_id"  if !$block;

    return scalar @{ $block->{threads} };
}



1;

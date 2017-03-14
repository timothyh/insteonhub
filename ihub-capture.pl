#!/usr/bin/perl -w

use strict;

use FindBin;
use lib "$FindBin::Bin/../lib/perl5";

use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
use Time::HiRes qw(usleep sleep);

use AnyEvent;
use AnyEvent::Strict;
use AnyEvent::IO qw(:DEFAULT :flags);

use InsteonHub::Hub;
use InsteonHub::Config;

readConfig(1,0,0,0);

InsteonHub::Hub::init(
    host           => $hub_conf{host},
    port           => $hub_conf{port},
    user           => $hub_conf{user},
    password       => $hub_conf{password},
    passive        => $hub_conf{passive},
    clear_buffer   => 0,
    clear_on_start => 0,
    poll_interval  => $hub_conf{poll_interval},
    fast_interval  => $hub_conf{fast_interval},
);

my $status_cmd = "buffstatus.xml";

my $delay = $hub_conf{poll_interval};

my $prev  = '';
my $count = 0;

my $max_fast_polls =
  int( 2.0 * $hub_conf{poll_interval} / $hub_conf{fast_interval} );

my $out_fh;

if ( defined($output) && $output ne '-' ) {
        aio_open $output, O_CREAT | O_RDWR, 0666, sub {
            ($out_fh) = @_
              or AE::log fatal => "$output: $!";
        };
};

sub buffer_cb {
    my ( $body, $hdr ) = @_;

    return
      unless ( $body =~ m{<response><BS>([0-9A-F]+)</BS></response>} );

    my $buff = $1;

    if ( $buff eq $prev ) {
        $count++;
        $delay = $hub_conf{poll_interval} if ( $count >= $max_fast_polls );
        return if ( $count > 1 );
    }
    else {
	$prev  = $buff;
	$delay = $hub_conf{fast_interval};
	$count = 0;
    }

	my $txt = AnyEvent::Log::format_time(AnyEvent->time)." $buff\n";

        if ( $out_fh ) {
	    aio_write $out_fh, $txt, sub { AE::log error => "Buffer write: $!" unless @_; };
	}
	else {
		print $txt;
	}
}

my $fetch_timer = AnyEvent->timer(
	after    => 0.05,
	cb       => \&fetch_cb,
);

sub fetch_cb {
    InsteonHub::Hub::_getNow( $status_cmd, \&buffer_cb );
	$fetch_timer = AnyEvent->timer(
		after    => $delay,
		cb       => \&fetch_cb,
	);
}

my $timeout_timer = AnyEvent->timer(
        after    => $duration,
        cb       => sub {
                InsteonHub::Hub::exit_when_ready(2);
        },
) if ( defined $duration );

AnyEvent->condvar->recv;

1;

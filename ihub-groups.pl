#!/usr/bin/perl -w
#
use strict;

use FindBin;
use lib "$FindBin::Bin/../lib/perl5";

use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
use Digest::MD5 qw(md5 md5_hex md5_base64);

use AnyEvent;
use AnyEvent::Strict;

use InsteonHub::Utils;
use InsteonHub::Hub;
use InsteonHub::Config;

my $link_db_query = 0;

my $trace = 0;

sub obj_cb {
    my ($obj) = @_;

    return
      unless ( exists $obj->{plm_command} );

    AE::log trace => Dumper $obj if ($trace);

    if ( $obj->{plm_command} =~ m{^0257 } ) {
        my $linkid = hex( $obj->{all_link_group} );

        AE::log debug => "Group: $linkid Device: $obj->{linked_device}";

        unless ( exists $linked_groups[$linkid] ) {
            my $name = sprintf( "linked_%03d", $linkid );
            $linked_groups[$linkid]{name} = $name;
            $groups{$name}{name}          = $name;
            $groups{$name}{linked_id}     = $linkid;
        }
        my $ptr = \%{ $linked_groups[$linkid] };

        $ptr->{devices}{ $obj->{linked_device} } = 1;
        $ptr->{md5} =
          md5_base64( join( '', sort( keys %{ $ptr->{devices} } ) ) );

        AE::log trace => "Group $linkid " . Dumper $ptr if ($trace);

        # Don't continue to query the link db unless we initiated
        # the query.

        if ( ( AnyEvent->now - $link_db_query ) < 30.0 ) {
            InsteonHub::Hub::get_link_db(1);
            $link_db_query = AnyEvent->now;
        }
    }
}

sub display_results {
    AE::log trace => Dumper \@linked_groups if ($trace);

    foreach my $i ( 0 .. scalar(@linked_groups) ) {
        next unless ( exists $linked_groups[$i] );

        my @tmp;

        for my $id ( sort( keys %{ $linked_groups[$i]{devices} } ) ) {
            push @tmp,
              ( exists $devices{$id}{name} ) ? $devices{$id}{name} : $id;
        }

        printf "%-12s(%03d) => %s\n", $linked_groups[$i]{name}, $i,
          join( ' ', sort(@tmp) );
    }
}

readConfig( 1, 0, 1, 1 );

if ( $hub_conf{passive} ) {
	die "This command will not work while hub configured in passive mode. Use --no-hub-passive to override.\n";
}

AnyEvent::Log::logger trace => \$trace;
$trace = $trace ? 1 : 0;

if ($trace) {
    AE::log trace => Dumper \%devices;
    AE::log trace => Dumper \%names;
}

InsteonHub::Hub::init(
    host           => $hub_conf{host},
    port           => $hub_conf{port},
    user           => $hub_conf{user},
    password       => $hub_conf{password},
    clear_on_start => 0,
    clear_buffer   => 0,
    passive        => $hub_conf{passive},
    ignore_dups    => 0,
    poll_interval  => $hub_conf{poll_interval},
    fast_interval  => $hub_conf{fast_interval},
    callback       => \&obj_cb,
);

my $idle_timer = AnyEvent->timer(
    after    => 15.0,
    interval => 2.0,
    cb       => \&idle_cb,
);

sub idle_cb {
    return unless ($link_db_query);

    # Wait for 5 secs of inactivity before exiting
    return unless ( ( AnyEvent->now - $link_db_query ) > 5 );

    display_results();

    exit(0);
}

$link_db_query = AnyEvent->now;
InsteonHub::Hub::get_link_db(0);

warn "Please wait ...... this may take some time\n";
my $cv = AnyEvent->condvar;

$cv->recv;

1;

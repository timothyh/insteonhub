#!/usr/bin/perl -w
#
use strict;

use FindBin;
use lib "$FindBin::Bin/../lib/perl5";

use Data::Dumper;
use Time::HiRes qw(usleep sleep);

use AnyEvent;
use AnyEvent::Strict;

use InsteonHub::Hub;
use InsteonHub::Config;
use InsteonHub::Utils;

my %grps;
my %devs;

my $state     = undef;
my $x10_house = 0;

my $trace;

my $ins_cmd = undef;

sub obj_cb {
    my ($obj) = @_;

    return
      unless ( exists $obj->{plm_command} );

    AE::log trace => Dumper $obj if ($trace);

    return unless ( $obj->{plm_command} =~ m{^0250 } );

    return unless ( $obj->{cmd_1} =~ m{^$ins_cmd } );

    if ( $obj->{cmd_2} =~ m{^([A-F0-9][A-F0-9])\s+Group}i ) {
        my $grp = hex($1);
        delete $grps{$grp};
    }
    else {
        delete $devs{ $obj->{from_address} };
    }

    # Exit if acknowledgement has been received for all
    # devices.
 
    InsteonHub::Hub::exit_when_ready(0)
      unless ( ( keys %devs ) + ( keys %grps ) );
}

sub raw_cb {
    my ($rawmsg) = @_;

    AE::log trace => $rawmsg;

    print AnyEvent::Log::format_time( AnyEvent->time ) . " $rawmsg\n"
      if ($verbose);

}

readConfig();

if ( $hub_conf{passive} ) {
        die "This command will not work while hub configured in passive mode. Use --no-hub-passive to override.\n";
}

die "No action defined\n" unless ( defined $action );

if    ( is_true($action) )  { $state = 'on'; }
elsif ( is_false($action) ) { $state = 'off'; }
elsif ( is_true( $action, 'all_lights_on' ) ) { $x10_house = 1; $state = 'on'; }
elsif ( is_false( $action, 'all_lights_off' ) ) {
    $x10_house = 1;
    $state     = 'off';
}
elsif ( is_true( $action, 'all_units_on', 'all_on' ) ) {
    $x10_house = 1;
    $state     = 'on';
}
elsif ( is_false( $action, 'all_units_off', 'all_off' ) ) {
    $x10_house = 1;
    $state     = 'off';
}

die "Invalid action: $action\n" unless defined($state);

$ins_cmd = ( $state eq 'on' ) ? '11' : '13';

for my $name (@ARGV) {

    $name = lc $name;
    my $id;

    if ( exists $groups{$name} ) {

        # Group reference
        if ( defined $groups{$name}{linked_id} ) {
            $id = $groups{$name}{linked_id};

            AE::log debug => "Set group $name linked id: $id to action $state";
            $grps{$id} = 1;
        }
        elsif ( exists $groups{$name}{devices} ) {
            foreach my $id ( sort( keys %{ $groups{$name}{devices} } ) ) {
                $devs{$id} = 1;
            }
        }
        else {
            warn "Group $name - Incomplete definition\n";
        }
        next;
    }

    if ( exists $names{$name} ) {

        # Device alias
        $id = $names{$name};
    }
    elsif ( is_x10_house($name) && $x10_house ) {
        $id = uc $name;
    }
    elsif ( is_x10($name) ) {
        $id = uc $name;
    }
    elsif ( is_insteon($name) ) {
        $id = uc $name;
        $id =~ s/\.//g;
    }
    else {
        warn "Unknown device: $name action $state\n";
        next;
    }

    if ( exists $devices{$id} && $devices{$id}{ignore} ) {
        AE::log debug => "Name: $name - device $id ignored";
    }
    else {
        AE::log debug => "Name: $name Set $id to action $state";

        $devs{$id} = 1;
    }
}

die "Nothing to do\n" unless ( ( keys %devs ) + ( keys %grps ) );

InsteonHub::Hub::init(
    host           => $hub_conf{host},
    port           => $hub_conf{port},
    user           => $hub_conf{user},
    password       => $hub_conf{password},
    clear_buffer   => 0,
    clear_on_start => 0,
    passive        => $hub_conf{passive},
    ignore_dups    => 0,
    poll_interval  => $hub_conf{poll_interval},
    fast_interval  => $hub_conf{fast_interval},
    capture_log    => undef,
    callback       => \&obj_cb,
    callback_raw   => \&raw_cb,
);

sub cmd_cb {
    for my $id ( keys %grps ) {
        InsteonHub::Hub::group_set( $id, $state );
    }

    for my $id ( keys %devs ) {
        InsteonHub::Hub::device_set( $id, $state );

        # Only wait for Insteon devices to complete
        delete $devs{$id} unless ( is_insteon($id) );
    }

    if ($wait) {
        InsteonHub::Hub::exit_when_ready(0)
          unless ( ( keys %devs ) + ( keys %grps ) );
    }
    else {
        InsteonHub::Hub::exit_when_ready(0);
    }

}

my $fetch_timer = AnyEvent->timer(
    after => 0.005,
    cb    => \&cmd_cb,
);

my $timeout_timer = AnyEvent->timer(
    after => $duration,
    cb    => sub {
        InsteonHub::Hub::exit_when_ready(2);
    },
) if ( defined $duration );

AnyEvent->condvar->recv;

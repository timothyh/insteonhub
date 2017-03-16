#!/usr/bin/perl -w
#
use strict;

use FindBin;
use lib "$FindBin::Bin/../lib/perl5";

use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
use Digest::MD5 qw(md5 md5_hex md5_base64);

use JSON::PP;

use Time::HiRes;    # Just a reminder that AnyEvent needs this
use POSIX qw(strftime);

use AnyEvent;
use AnyEvent::Strict;
use AnyEvent::MQTT;

use InsteonHub::Utils;
use InsteonHub::Hub;
use InsteonHub::Config;

my $fmt_simple = 1;
my $fmt_json   = 0;

my $link_db_query = 0;

my $mqtt;
my $trace = 0;

my $mqtt_updated = 0;

my $passthru = 0;

sub raw_cb {
    return unless ( $passthru > 0 );

    my ($msg) = @_;

    send_mqtt_message( $mqtt_conf{passthru_topic}, $msg, 0, 0 );
}

sub obj_cb {
    my ($obj) = @_;

    return
      unless ( exists $obj->{plm_command} );

    AE::log trace => Dumper $obj if ($trace);

    if ( $obj->{plm_command} =~ m{^0257 } ) {
        my $linkid = hex( $obj->{all_link_group} );

        AE::log debug =>
          "Group: $linkid Device: $obj->{linked_device} Role: $obj->{bit_6}";

        # Only care about responder devices where 'PLM is controller'
        if ( $obj->{bit_6} =~ m{controller}i ) {
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
        }

        # Did we originate query - If so continue it
        if ( $hub_conf{query_groups} ) {

            # Don't continue to query the link db unless we initiated
            # the query.
            # Avoids multiple instances of this daemon stepping on
            # each other.

            if ( ( AnyEvent->now - $link_db_query ) < 30.0 ) {
                InsteonHub::Hub::get_link_db(1);
                $link_db_query = AnyEvent->now;
            }
        }
    }
    elsif ( $obj->{plm_command} =~ m{^0250 } ) {
        my $device = $obj->{from_address};
        if ( ( defined $obj->{to_address} )
            and $obj->{to_address} =~ m{^0000(\d\d)$} )
        {
            $device .= ':' . $1 unless ( $1 eq '01' );
        }
        my $level;
        my $state;
        my $linkid;
        if ( defined $obj->{cmd_1} ) {
            if ( $obj->{cmd_1} =~ m{^00 } ) {
                $level = 100 * hex( substr( $obj->{cmd_2}, 0, 2 ) ) / 255;
                $state = ( $level > 1 ) ? 'on' : 'off';
            }
            elsif ( $obj->{cmd_1} =~ m{^19 } ) {
                $level = 100 * hex( substr( $obj->{cmd_2}, 0, 2 ) ) / 255;
                $state = ( $level > 1 ) ? 'on' : 'off';
            }
            elsif ( $obj->{cmd_1} =~ m{^11 } ) {
                $level = 100 * hex( substr( $obj->{cmd_2}, 0, 2 ) ) / 255;
                $state = 'on';
            }
            elsif ( $obj->{cmd_1} =~ m{^13 } ) {
                $level = 0;
                $state = 'off';
            }
        }
        if ( defined $obj->{cmd_2}
            and $obj->{cmd_2} =~ m{^([A-F0-9][A-F0-9])\s+Group}i )
        {
            $linkid = hex($1);

            if ( exists $linked_groups[$linkid] ) {
                my $name = $linked_groups[$linkid]{name};
                AE::log debug =>
                  "Linked group: $linkid name: $name state: $state";

                my @devs = ();

                if (    ( exists $linked_groups[$linkid]{devices} )
                    and ( keys %{ $linked_groups[$linkid]{devices} } ) )
                {
                    @devs = keys %{ $linked_groups[$linkid]{devices} };
                }
                elsif ( ( exists $groups{$name}{devices} )
                    and ( keys %{ $groups{$name}{devices} } ) )
                {
                    @devs = keys %{ $groups{$name}{devices} };
                }
                else {
                    # Should not happen
                    AE::log error => "Linked group with no devices: $linkid";
                }
                foreach my $dev ( sort @devs ) {
                    update_state( $dev, $state, $level );
                }
            }
            else {
                AE::log error => "Unknown linked group: $linkid";
            }
        }
        else {
            update_state( $device, $state, $level );
        }
    }
}

sub update_state {
    my ( $device, $state, $level ) = @_;

    return unless ( defined $state );

    unless ( exists $devices{$device} ) {
        AE::log warn => "New device id: $device";
        $devices{$device} = $devices{default};
    }
    my $ptr = \%{ $devices{$device} };

    return if ( $ptr->{ignore} );

    $state = is_true($state) ? 'on' : 'off';
    $level = undef unless ( $ptr->{dim} );

    unless ( $ptr->{type} =~ m{^(sensor|remote)$} ) {
        if ( ( AnyEvent->now - $ptr->{timestamp} )
            le $hub_conf{state_change_time} )
        {
            if ( $state eq $ptr->{state} ) {
                return unless ( defined $level );
                return if ( $level == $ptr->{level} );
            }
        }
    }

    my $now = strftime( "%Y-%m-%dT%H:%M:%S", localtime );

    my $id = ( defined $ptr->{id} ) ? $ptr->{id} : $device;

    my %status;
    if ($fmt_json) {
        %status = ( id => $id, state => $state, timestamp => $now );
        $status{level} = $level if ( defined $level );
    }

    my $retain = $devices{$device}{retain} ? 1 : 0;
    my $qos = $devices{$device}{qos} ? $devices{$device}{qos} : 0;

    if ( defined $ptr->{name} ) {
        my $topic = "$mqtt_conf{name_prefix}/$ptr->{name}";
        if ($fmt_json) {
            send_mqtt_json( $topic, \%status, $retain, $qos );
            $status{name} = $ptr->{name};
        }
        if ($fmt_simple) {
            send_mqtt_message( "$topic/state", $state, $retain, $qos );
            send_mqtt_message( "$topic/level", $level, $retain, $qos )
              if ( defined $level );
        }
    }
    {
        my $topic = "$mqtt_conf{device_prefix}/$id";
        if ($fmt_json) {
            send_mqtt_json( $topic, \%status, $retain, $qos );
        }
        if ($fmt_simple) {
            send_mqtt_message( "$topic/state", $state, $retain, $qos );
            send_mqtt_message( "$topic/level", $level, $retain, $qos )
              if ( defined $level );
        }
    }
    $ptr->{level} = $level if ( defined $level );
    $ptr->{state} = $state;

    $ptr->{timestamp} = AnyEvent->now;
}

sub send_mqtt_json {
    my ( $device, $hash, $retain, $qos ) = @_;

    send_mqtt_message( $device, encode_json($hash), $retain, $qos );
}

sub send_mqtt_message {
    my ( $topic, $message, $retain, $qos, ) = @_;

    $retain = $retain ? 1    : 0;
    $qos    = $qos    ? $qos : 0;

    AE::log debug =>
      "Send to \"$topic\" retain: $retain qos: $qos message: \"$message\"";

    $mqtt->publish(
        topic   => $topic,
        message => $message,
        retain  => $retain,
        qos     => $qos,
    );
}

sub mqtt_error_cb {
    my ( $fatal, $message ) = @_;

    if ($fatal) {
        AE::log fatal => "$message - Exiting";
        exit(1);
    }
    else {
        AE::log alert => "$message";
    }
}

sub idle_cb {
    InsteonHub::Hub::exit_when_ready(10) if ( changedConfig() );

    if ( $mqtt_conf{'idle'} gt 10.0 ) {
        my $inactivity = AnyEvent->now - $mqtt_updated;
        if ( $inactivity >= ( $mqtt_conf{'idle'} - 0.2 ) ) {
            AE::log alert => "No MQTT activity for $inactivity secs. Exiting";
            InsteonHub::Hub::exit_when_ready(10);
            return;
        }
        if ( defined( $mqtt_conf{ping_topic} )
            and ( $inactivity >= ( $mqtt_conf{'idle'} / 2.0 ) ) )
        {
            send_mqtt_message(
                "$mqtt_conf{device_prefix}/$mqtt_conf{ping_topic}/set",
                strftime(
                    $fmt_json
                    ? '{"timestamp":"%Y-%m-%dT%H:%M:%S"}'
                    : '%Y-%m-%dT%H:%M:%S',
                    localtime
                ),
                0, 0,
            );
        }
    }
}

sub receive_mqtt_set {
    my ( $topic, $payload ) = @_;

    $mqtt_updated = AnyEvent->now;

    AE::log trace => "Received $topic payload: $payload";

    unless ( $topic =~ m{^.*/([^/]+)/set$} ) {
        AE::log error => "Unexpected message - topic: $topic payload: $payload";
        return;
    }

    my $name = lc $1;

    return
      if ( defined( $mqtt_conf{ping_topic} )
        and ( $name eq $mqtt_conf{ping_topic} ) );

    if ( $name eq "passthru" ) {
        $passthru = 1 if ( is_true($payload)  && $passthru == 0 );
        $passthru = 0 if ( is_false($payload) && $passthru == 1 );
        return;
    }

    if ( defined( $mqtt_conf{restart_topic} )
        and ( $name eq $mqtt_conf{restart_topic} ) )
    {
        AE::log error => "Restart requested";
        InsteonHub::Hub::exit_when_ready(10) if ( is_true($payload) );
        return;
    }

    unless ( is_true($payload) || is_false($payload) ) {
        AE::log error => "Unexpected state - name: $name payload: $payload";
        return;
    }
    my $action = is_true($payload);

    my $id;

    if ( exists $groups{$name} ) {

        # Group reference
        if ( defined $groups{$name}{linked_id} ) {
            $id = $groups{$name}{linked_id};

            if ( exists $linked_groups[$id] ) {
                AE::log debug =>
                  "Set group $name linked id: $id to payload: $payload";
                InsteonHub::Hub::group_set( $id, $action );
            }
            else {
                AE::log warn =>
                  "Group $name references unknown link group: $id";
            }
        }
        elsif ( exists $groups{$name}{devices} ) {
            foreach $id ( sort( keys %{ $groups{$name}{devices} } ) ) {
                InsteonHub::Hub::device_set( $id, $action );
            }
        }
        else {
            AE::log warn => "Group $name - Incomplete definition";
        }
        return;
    }

    if ( exists $names{$name} ) {

        # Device alias
        $id = $names{$name};
    }
    elsif ( is_x10($name) ) {
        $id = uc $name;
    }
    elsif ( is_insteon($name) ) {
        $id = uc $name;
        $id =~ s/\.//g;
    }
    else {
        AE::log warn => "Unknown device: $name payload: $payload";
        return;
    }

    AE::log debug => "Name: $name Set $id to payload: $payload";

    InsteonHub::Hub::device_set( $id, $action );
}

sub receive_passthru_send {
    my ( $topic, $payload ) = @_;

    $mqtt_updated = AnyEvent->now;

    InsteonHub::Hub::_hubSend( $payload, 'low',
        sub { AE::log debug => "Passthru message \"$payload\" sent"; } );
}

################################################################################

readConfig();

if    ( is_true $mqtt_conf{passthru} )        { $passthru = 1; }
elsif ( is_false $mqtt_conf{passthru} )       { $passthru = 0; }
elsif ( lc $mqtt_conf{passthru} eq 'always' ) { $passthru = 2; }
elsif ( lc $mqtt_conf{passthru} eq 'never' )  { $passthru = -1; }
else {
    AE::log error => "Invalid passthru setting: $mqtt_conf{passthru}";
}

if ( $logfile && $logfile ne '-' ) {
    my $path = strftime( $logfile, localtime );
    $AnyEvent::Log::LOG->log_to_file($path);
}

AnyEvent::Log::logger trace => \$trace;
$trace = $trace ? 1 : 0;

logConfig() if ($trace);

my $restart_timer;
if ($restart_at) {
    my $when = secs_from_now($restart_at);

    if ( $when > 0 ) {
        AE::log info => "Restart in $when secs";
        $restart_timer = AnyEvent->timer(
            after => $when,
            cb    => sub { InsteonHub::Hub::exit_when_ready(10); },
        );
    }
}

InsteonHub::Hub::init(
    host           => $hub_conf{host},
    port           => $hub_conf{port},
    user           => $hub_conf{user},
    password       => $hub_conf{password},
    clear_buffer   => $hub_conf{clear_buffer},
    clear_on_start => $hub_conf{clear_on_start},
    passive        => $hub_conf{passive},
    ignore_dups    => $hub_conf{ignore_dups},
    poll_interval  => $hub_conf{poll_interval},
    fast_interval  => $hub_conf{fast_interval},
    capture_log    => $hub_conf{capture_log},
    callback       => \&obj_cb,
    callback_raw   => \&raw_cb,
);

$mqtt = AnyEvent::MQTT->new(
    host             => $mqtt_conf{host},
    port             => $mqtt_conf{port},
    user_name        => $mqtt_conf{user},
    password         => $mqtt_conf{password},
    on_error         => \&mqtt_error_cb,
    keep_alive_timer => 60,
);

if ( defined $mqtt_conf{format} ) {
    $fmt_simple = 0;
    $fmt_json   = 0;
    for my $fmt ( split /,/, lc $mqtt_conf{format} ) {
        $fmt_simple = 1 if ( $fmt eq 'simple' );
        $fmt_json   = 1 if ( $fmt eq 'json' );
    }
    AE::log fatal => "Invalid output format: $mqtt_conf{format}"
      unless ( $fmt_simple || $fmt_json );
}

my $idle_timer = AnyEvent->timer(
    after    => 30.0,
    interval => 60.0,
    cb       => \&idle_cb,
);

$mqtt_updated = AnyEvent->now;

$mqtt->subscribe(
    topic    => "$mqtt_conf{device_prefix}/+/set",
    callback => \&receive_mqtt_set,
  )->cb(
    sub {
        AE::log note =>
          "subscribed to MQTT topic $mqtt_conf{device_prefix}/+/set";
    }
  );

$mqtt->subscribe(
    topic    => "$mqtt_conf{name_prefix}/+/set",
    callback => \&receive_mqtt_set,
  )->cb(
    sub {
        AE::log note =>
          "subscribed to MQTT topic $mqtt_conf{name_prefix}/+/set";
    }
  );

if ( is_true( $mqtt_conf{passthru} ) || is_false( $mqtt_conf{passthru} ) ) {
    $mqtt->subscribe(
        topic    => "$mqtt_conf{passthru_topic}/set",
        callback => \&receive_mqtt_set,
      )->cb(
        sub {
            AE::log note =>
              "subscribed to MQTT topic $mqtt_conf{passthru_topic}/set";
        }
      );
}

if ( $mqtt_conf{passthru_send} ) {
    $mqtt->subscribe(
        topic    => "$mqtt_conf{passthru_topic}/send",
        callback => \&receive_passthru_send,
      )->cb(
        sub {
            AE::log note =>
              "subscribed to MQTT topic $mqtt_conf{passthru_topic}/send";
        }
      );
}

$link_db_query = AnyEvent->now;

InsteonHub::Hub::get_link_db(0) if ( $hub_conf{query_groups} );

foreach my $id ( sort( keys(%devices) ) ) {

    next if ( $id eq 'default' );

    next if ( $devices{$id}{type} =~ m{^(unknown|sensor|remote)$} );

    AE::log trace => "Fetch status for $id";

    InsteonHub::Hub::device_status($id);
}

# Orderly exit on SIGTERM
my $w1 = AnyEvent->signal(
    signal => "TERM",
    cb     => sub { InsteonHub::Hub::exit_when_ready(0); }
);
my $w2 = AnyEvent->signal(
    signal => "USR1",
    cb     => sub { InsteonHub::Hub::exit_when_ready(10); }
);

AnyEvent->condvar->recv;

1;

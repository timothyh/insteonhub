package InsteonHub::Config;

use strict;
use base qw(Exporter);

our @ISA    = qw(Exporter);    # Use our.
our @EXPORT = qw(
  readConfig
  changedConfig
  logConfig
  printConfig
  $action
  %hub_conf
  %mqtt_conf
  %devices
  %groups
  %names
  %types
  @linked_groups
  $loglevel
  $input
  $output
  $verbose
  $duration
  $set
  $state
  $level
  $logfile
  $wait
  $restart_at
);

use FindBin;
my $config = "/etc/insteonhub.yaml:$FindBin::Bin/../etc/insteonhub.yaml";

use File::stat;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;

use Getopt::Long qw(GetOptionsFromArray);
use Digest::MD5 qw(md5 md5_hex md5_base64);

use YAML;

use AnyEvent;
use AnyEvent::Log;
use AnyEvent::Strict;

use InsteonHub::Utils;
#
# Try and define meaningful defaults
#
our %hub_conf = (
    format            => 'simple',
    host              => 'insteonhub',
    port              => 25105,
    id                => undef,
    poll_interval     => 1.0,
    fast_interval     => 0.2,
    ignore_dups       => 1,
    state_change_time => 600.0,
    clear_buffer      => 0,
    clear_on_start    => 1,
    query_groups      => 1,
    user              => undef,
    password          => undef,
    passive           => 0,
);

our %mqtt_conf = (
    device_prefix  => 'home/insteon',
    host           => 'localhost',
    idle           => 600.0,
    name_prefix    => 'home',
    passthru       => 0,
    passthru_send  => 0,
    passthru_topic => 'home/insteon/passthru',

    # Will be used as $device_prefix/$ping_topic/set
    ping_topic    => '_ping',
    port          => 1883,
    restart_topic => '_restartnow',
    user          => undef,
    password      => undef,
);

my %default_device = (
    type      => 'unknown',
    state     => 'unknown',
    dim       => 0,
    retain    => 0,
    ignore    => 0,
    timestamp => 0,
    x10       => 0,
);

# Bit mask - 1 => Responder, 2 => Controller
my %types = (
    remote => 2,
    sensor => 2,
    switch => 3,
    light  => 1,
    outlet => 1,
);

my @from_env =
  qw( MQTT_HOST MQTT_USER MQTT_PASSWORD MQTT_PORT HUB_ID HUB_HOST HUB_PORT HUB_USER HUB_PASSWORD );

my %boolopts = (
    hub_passive        => 1,
    hub_clear_on_start => 1,
    hub_ignore_dups    => 1,
    hub_query_groups   => 1,
    mqtt_passthru_send => 1,
    dim                => 1,
    retain             => 1,
    ignore             => 1,
);

our %devices;
our %names;

our %groups;
our @linked_groups;

our $loglevel   = undef;
our $logfile    = undef;
our $input      = undef;
our $output     = '-';
our $verbose    = 0;
our $duration   = undef;
our $set        = 0;
our $state      = undef;
our $level      = undef;
our $action     = undef;
our $wait       = 0;
our $restart_at = undef;

my @files;
my $help  = 0;
my $quick = 0;

my $config_mtime = 0;

my %opts = (
    'config-files|c=s' => \$config,
    'action|a=s'       => \$action,
    'set|s'            => \$set,
    'state|S=s'        => \$state,
    'level|l=f'        => \$level,
    'duration|D=f'     => \$duration,
    'input|i=s'        => \$input,
    'output|o=s'       => \$output,
    'log-level|L=s'    => \$loglevel,
    'log-file=s'       => \$logfile,
    'verbose|v!'       => \$verbose,
    'quick|q!'         => \$quick,
    'wait|w!'          => \$wait,
    'help|h|?'         => \$help,
);

sub readConfig {
    my ( $parse_hub, $parse_mqtt, $parse_devices, $parse_groups ) = @_;

    $parse_devices = 1 unless ( defined $parse_devices );
    $parse_groups  = 1 unless ( defined $parse_groups );
    $parse_mqtt    = 1 unless ( defined $parse_mqtt );
    $parse_hub     = 1 unless ( defined $parse_hub );

    $config = $ENV{HUB_CONFIG} if ( $ENV{HUB_CONFIG} );

    Getopt::Long::Configure( "pass_through", "bundling" );

    my $res = GetOptions(%opts);

    die("Print usage text\n") unless ($res);
    die("Print help text\n") if ($help);

    if ($quick) {
        $parse_groups  = 0;
        $parse_devices = 0;
    }

    my $trace = 0;

    $AnyEvent::Log::FILTER->level($loglevel) if ( defined $loglevel );
    AnyEvent::Log::logger trace => \$trace;
    $trace = $trace ? 1 : 0;

    foreach my $f ( split ':', $config ) {
        my $res = stat($f);
        next unless ( defined $res );
        push @files, $f;
        $config_mtime = $res->mtime if ( $res->mtime > $config_mtime );
    }

    while ( my ( $key, $value ) = each %default_device ) {
        next if ( $key =~ m{^(name|id)$} );
        $devices{default}{$key} = $value;
    }

    my ( $conf_loglevel, $conf_logfile, $conf_restart_at );

    foreach my $file (@files) {
        my $conf = eval { YAML::LoadFile($file) };
        next unless ($conf);

        $conf_loglevel   = $conf->{log_level};
        $conf_logfile    = $conf->{log_file};
        $conf_restart_at = $conf->{restart_at};

        if ($parse_hub) {
            while ( my ( $key, $value ) = each %{ $conf->{hub} } ) {
                $hub_conf{$key} =
                  $boolopts{"hub_$key"} ? is_true($value) : $value;
            }
        }
        if ($parse_mqtt) {
            while ( my ( $key, $value ) = each %{ $conf->{mqtt} } ) {
                $mqtt_conf{$key} =
                  $boolopts{"mqtt_$key"} ? is_true($value) : $value;
            }
        }

        if ( exists $conf->{default} ) {
            while ( my ( $key, $value ) = each %{ $conf->{default} } ) {
                $devices{default}{$key} =
                  $boolopts{$key} ? is_true($value) : $value;
            }
        }

        if ( $parse_devices && defined( $conf->{devices} ) ) {
            foreach my $i ( 0 .. scalar( @{ $conf->{devices} } ) - 1 ) {
                my $id = $conf->{devices}[$i]{id};
                unless ( defined $id ) {
                    AE::log error => "Invalid device config: "
                      . Dumper( $conf->{devices}[$i] );
                    next;
                }

                my $errcnt = 0;

                if ( is_insteon($id) ) {
                    $id = uc $id;
                    $id =~ s/\.//g;

                    # Hack - Treat button 1 on switch/remote as device
                    $id = $1 if ( $id =~ m{^(......):01$} );
                }

                # Check for X10 devices
                elsif ( is_x10($id) ) {
                    $id = uc $id;

                    # Add X10 checks
                }
                else {
                    AE::log error => "Invalid Insteon device id: "
                      . $conf->{devices}[$i]{id};
                    $errcnt++;
                }

                if ( exists $devices{$id} ) {
                    AE::log error =>
"Duplicate entry for device id: $conf->{devices}[$i]{id} - ignored";
                    $errcnt++;
                }
                my $type       = $conf->{devices}[$i]{type};
                my $responder  = 0;
                my $controller = 0;
                if ( defined $type ) {
                    if ( exists $types{$type} ) {
                        $controller = $types{$type} & 2;
                        $responder  = $types{$type} & 1;
                    }
                    else {
                        AE::log error => "device $id: unknown type: $type";
                        $errcnt++;
                    }
                }
                else {
                    AE::log error => "device $id: type not defined";
                    $errcnt++;
                }

                next if $errcnt;

                # Start with defaults
                while ( my ( $key, $value ) = each %{ $devices{default} } ) {
                    $devices{$id}{$key} = $value;
                }

                $devices{$id}{ignore} = 0;

                while ( my ( $key, $value ) = each %{ $conf->{devices}[$i] } ) {
                    $devices{$id}{$key} =
                      $boolopts{$key} ? is_true($value) : $value;
                }
                $devices{$id}{device}     = $id;
                $devices{$id}{timestamp}  = 0;
                $devices{$id}{state}      = 'unknown';
                $devices{$id}{x10}        = is_x10($id);
                $devices{$id}{controller} = $controller ? 1 : 0;
                $devices{$id}{responder}  = $responder ? 1 : 0;

                delete $devices{$id}{name};
                my $name = $conf->{devices}[$i]{name};
                if ( defined $name ) {
                    $name = lc $name;
                    if ( exists $names{$name} ) {
                        AE::log error =>
"Duplicated name for $conf->{devices}[$i]{id}: $conf->{devices}[$i]{name} - ignored";
                    }
                    else {
                        $devices{$id}{name} = $name;
                        $names{$name} = $id unless ( $devices{$id}{ignore} );
                    }
		}
            }
        }

        if ( $parse_groups && defined( $conf->{groups} ) ) {
            foreach my $i ( 0 .. scalar( @{ $conf->{groups} } ) - 1 ) {
                my $ptr = \%{ $conf->{groups}[$i] };

                my $name = $ptr->{name};
                unless ( defined $name ) {
                    AE::log error => "Unamed group - ignoring: $i";
                    next;
                }

                $name = lc $name;

                AE::log warn => "Multiple group definitions for: $name\nMerging"
                  if ( exists $groups{$name} );

                AE::log warn =>
"Matching group and device names: $name\nDevice name will be ignored"
                  if ( exists $names{$name} );

                if ( exists $ptr->{linked_id} ) {
                    my $linkid = $ptr->{linked_id};
                    if ( is_group $linkid ) {
                        $groups{$name}{linked_id} = $linkid;
                        $linked_groups[$linkid]{name} = $name;
                    }
                    else {
                        AE::log error =>
                          "Group $name, invalid link id: $linkid";
                    }
                }

                foreach my $id ( @{ $ptr->{devices} } ) {
                    my $idtmp;

                    if ( exists $names{ lc $id } ) {
                        $idtmp = $names{ lc $id };
                    }
                    elsif ( is_x10($id) ) {
                        $idtmp = uc $id;
                    }
                    elsif ( is_x10_house($id) ) {
                        $idtmp = uc $id;
                    }
                    elsif ( is_insteon($id) ) {
                        $idtmp = uc $id;
                        $idtmp =~ s/\.//g;
                    }
                    else {
                        AE::log error =>
                          "Invalid device id in group $name: $id";
                        next;
                    }

                    if ( exists $devices{$idtmp} ) {
                        if ( $devices{$idtmp}{ignore} ) {
                            AE::log error =>
                              "Group $name: Ignoring device: $id";
                            next;
                        }

                        unless ( $devices{$idtmp}{responder} ) {
                            AE::log error =>
                              "Group $name: sensor or remote ignored: $id";
                            next;
                        }
                    }
                    else {
                        AE::log warn => "Unknown device id in group $name: $id";
                    }

                    $groups{$name}{devices}{$idtmp} = 1;
                }

                $groups{$name}{md5} =
                  md5_base64(
                    join( '', sort( keys %{ $groups{$name}{devices} } ) ) );
                $groups{$name}{id} = $ptr->{id} if ( defined $ptr->{id} );
            }
        }
    }

    # Environment overrides config file
    foreach (@from_env) {
        my $value = $ENV{ uc $_ };
        next unless ( defined $value );

        my ( $section, $key ) = split( '_', lc $_, 2 );

        $value = $boolopts{ lc $_ } ? is_true($value) : $value;

        $hub_conf{$key}  = $value if ( $parse_hub  && $section eq 'hub' );
        $mqtt_conf{$key} = $value if ( $parse_mqtt && $section eq 'mqtt' );
    }

    $loglevel   ||= $conf_loglevel;
    $logfile    ||= $conf_logfile;
    $restart_at ||= $conf_restart_at;

    if ( defined $loglevel ) {
        $AnyEvent::Log::FILTER->level($loglevel);
        AnyEvent::Log::logger trace => \$trace;
        $trace = $trace ? 1 : 0;
    }

    #AE::log trace => Dumper \%groups if ($trace);
    my %extended;

    if ($parse_hub) {
        foreach my $item ( keys %hub_conf ) {
            my $tmp = "hub_$item";
            my $bool = ( $boolopts{$tmp} ) ? 1 : 0;
            $tmp =~ s/_/-/g;

            $extended{ ( $bool ? "$tmp!" : "$tmp=s" ) } = \$hub_conf{$item};
        }
    }
    if ($parse_mqtt) {
        foreach my $item ( keys %mqtt_conf ) {
            my $tmp = "mqtt_$item";
            my $bool = ( $boolopts{$tmp} ) ? 1 : 0;
            $tmp =~ s/_/-/g;

            $extended{ ( $bool ? $tmp : "$tmp=s" ) } = \$mqtt_conf{$item};
        }
    }

    if ( $parse_hub || $parse_mqtt ) {
        AE::log trace => Dumper \%extended if ($trace);

        Getopt::Long::Configure("default");

        $res = GetOptions(%extended);

        die("Print usage text\n") unless ($res);
    }

    if ($parse_hub) {
        if ( defined $hub_conf{id} ) {
            if ( is_insteon( $hub_conf{id} ) ) {
                my $id = uc $hub_conf{id};
                $id =~ s/\.//g;
                %{ $devices{$id} } = (
                    id        => $hub_conf{id},
                    device    => $id,
                    name      => "insteon_hub",
                    type      => "hub",
                    state     => "unknown",
                    dim       => 0,
                    ignore    => 0,
                    retain    => 0,
                    timestamp => 0,
                );
                $hub_conf{id} = $id;
            }
            else {
                AE::log error => "Invalid hub id: $hub_conf{id}";
            }
        }
        else {
            AE::log error => "Hub id is not defined";
        }
    }
}

# Easy way of watching for config file changes

sub changedConfig {
    foreach my $f (@files) {
        if ( stat($f)->mtime > $config_mtime ) {
            AE::log alert => "Config file $f changed";
            return 1;
        }
    }
    return 0;
}

sub logConfig {
    AE::log trace => Dumper \%mqtt_conf;
    AE::log trace => Dumper \%hub_conf;
    AE::log trace => Dumper \%devices;
    AE::log trace => Dumper \%names;
    AE::log trace => Dumper \%groups;
}

sub printConfig {

    local $Data::Dumper::Quotekeys = 0;
    local $Data::Dumper::Pair      = ': ';
    local $Data::Dumper::Terse     = 1;
    local $Data::Dumper::Indent    = 1;

    print "Hub Config => " . Dumper \%hub_conf;
    print "MQTT Config => " . Dumper \%mqtt_conf;
    print "Devices => " . Dumper \%devices;
    print "Device Names => " . Dumper \%names;
    print "Groups => " . Dumper \%groups;
}

1;

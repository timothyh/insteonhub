#!/usr/bin/perl -w
#
use strict;

use FindBin;
use lib "$FindBin::Bin/../lib/perl5";

use Data::Dumper;
$Data::Dumper::Sortkeys = 1;

use Time::HiRes;    # Just a reminder that AnyEvent needs this
use POSIX qw(strftime);

use AnyEvent;
use AnyEvent::Strict;
use AnyEvent::Log;

use InsteonHub::Utils;
use InsteonHub::Hub;
use InsteonHub::Config;

my $trace     = 0;
my $timestamp = 'undefined';

sub obj_cb {
    my ($obj) = @_;

    if ($verbose) {
        if ( $timestamp eq 'undefined' ) {
            delete $obj->{timestamp};
        }
        else {
            print "$timestamp:";
            $obj->{timestamp} = parse_date($timestamp);
        }
        if ( defined $obj->{all_link_group} ) {
            my $linkid = hex( $obj->{all_link_group} );
            if ( defined $linked_groups[$linkid]{name} ) {
                $obj->{group_name} = $linked_groups[$linkid]{name};
            }
        }
        if (   defined( $obj->{from_address} )
            && defined( $devices{ $obj->{from_address} }{name} ) )
        {
            $obj->{from_name} = $devices{ $obj->{from_address} }{name};
            $obj->{from_type} = $devices{ $obj->{from_address} }{type};
        }
        if (   defined( $obj->{to_address} )
            && defined( $devices{ $obj->{to_address} }{name} ) )
        {
            $obj->{to_name} = $devices{ $obj->{to_address} }{name};
            $obj->{to_type} = $devices{ $obj->{to_address} }{type};
        }
        print Dumper $obj;
    }
    else {
        print(( ( $timestamp eq 'undefined' ) ? '' : $timestamp . ' ' )
            . $obj->{raw_message}
              . "\n" );
    }
    AE::log trace => Dumper $obj if ($trace);
}

readConfig();

if ( $logfile && $logfile ne '-' ) {
    my $path = strftime( $logfile, localtime );
    $AnyEvent::Log::LOG->log_to_file($path);
}

AnyEvent::Log::logger trace => \$trace;
$trace = $trace ? 1 : 0;

{
    no warnings 'redefine';
    sub AnyEvent::Log::format_time($) { $timestamp }
}

InsteonHub::Hub::init(
    host           => '',
    port           => $hub_conf{port},
    user           => '',
    password       => '',
    clear_buffer   => 0,
    clear_on_start => 0,
    passive        => 1,
    ignore_dups    => 0,
    callback       => \&obj_cb,
);

my $buff;

while ( $buff = <STDIN> ) {
    chomp $buff;

    if ( $buff =~ m{^(.*)\s+([0-9A-F]+)$} ) {
        $timestamp = $1;
        $buff      = $2;
    }

    InsteonHub::Hub::_process_hub_buffer($buff);
}
1;

package InsteonHub::Utils;

use strict;
use base qw(Exporter);

our @ISA    = qw(Exporter);    # Use our.
our @EXPORT = qw(
  is_true
  is_false
  is_x10
  is_insteon
  is_group
  is_x10_house
  is_level
  midnight
  parse_date
  secs_to_midnight
  secs_from_now
);

use Data::Dumper;
use MIME::Base64;
use Time::HiRes qw(time);

use AnyEvent::Log;

# Handle various ways of saying yes/no, true/false, on/off
sub is_true {
    my ( $input, @special ) = @_;

    return 0 unless ( defined $input );

    if ( $input =~ /^\d+$/ ) {
        return 0 if ( $input == 0 );
        return 1;
    }

    $input = lc $input;

    for my $v ( 'true', 'on', 'yes', @special ) {
        return 1 if ( $input eq $v );
    }

    for my $v ( 'false', 'off', 'no' ) {
        return 0 if ( $input eq $v );
    }

    AE::log trace => "Invalid boolean: " . $input;

    return 0;
}

sub is_false {
    my ( $input, @special ) = @_;

    return 0 unless ( defined $input );

    if ( $input =~ /^\d+$/ ) {
        return 1 if ( $input == 0 );
        return 0;
    }

    $input = lc $input;

    for my $v ( 'false', 'off', 'no', @special ) {
        return 1 if ( $input eq $v );
    }

    for my $v ( 'true', 'on', 'yes' ) {
        return 0 if ( $input eq $v );
    }

    AE::log trace => "Invalid boolean: " . $input;

    return 0;
}

# Validate string is a valid X10 device
# Between A1 and P16
sub is_x10 {
    my ($id) = @_;

    $id = uc $id;

    return 0 unless ( $id =~ m{^[A-P](\d+)$} );

    return 0 unless ( $1 >= 1 && $1 <= 16 );

    return 1;
}

# Validate string is a valid Insteon device id
#  XXXXXX or XXXXXX:NN or XX.XX.XX or XX.XX.XX:NN
sub is_insteon {
    my ($id) = @_;

    $id = uc $id;

    # Check for valid characters
    return 0 unless ( $id =~ m{^[0-9A-F:.]+} );

    # Remove periods
    $id =~ s/^(..)\.(..)\./$1$2/;

    my ( $tmpid, $button ) = split( ':', $id, 2 );

    return 0 unless ( length($tmpid) == 6 );

    if ( defined $button ) {
        return 0 unless ( $button =~ m{^\d\d$} );
        return 0 unless ( $button > 0 );
    }
    return 1;
}

sub is_x10_house {
    my ($id) = @_;

    return ( $id =~ m{^[A-P]$}i ) ? 1 : 0;
}

sub is_group {
    my ($val) = @_;

    return 0 unless ( $val =~ m{^[0-9]+$} );

    return ( $val >= 0 && $val <= 255 ) ? 1 : 0;
}

sub is_level {
    my ($val) = @_;

    return 0 unless ( $val =~ m{^[0-9.]+$} );

    return ( $val >= 0.0 && $val <= 1.0 ) ? 1 : 0;
}

# Return previous midnight localtime in secs since epoch
sub midnight {
    my $time = time;
    my @time = localtime($time);
    my $secs = ( $time[2] * 3600 ) + ( $time[1] * 60 ) + $time[0];

    return $time - $secs;
}

# Return secs to next midnight
sub secs_to_midnight {
    my @time = localtime();
    my $secs = ( $time[2] * 3600 ) + ( $time[1] * 60 ) + $time[0];

    return ( 24 * 3600 ) - $secs + 1;
}

# Parse a random date string
# Any string acceptable to date command can be used
sub parse_date {
    my ($str) = @_;

    my $secsstr = `date --date '$str' '+%s.%N' 2> /dev/null`;
    chomp $secsstr;

    return length($secsstr) ? ( 0.0 + $secsstr ) : -1;
}

# Return secs to next instance of random time
# Date portion of any string is ignored
sub secs_from_now {
    my $secsstr = parse_date(@_);

    return -1 unless ( $secsstr > 0 );

    # my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
    my @tgt     = localtime( int( $secsstr + 0.5 ) );
    my @now     = localtime(time);
    my $nowsecs = $now[0] + ( $now[1] * 60 ) + ( $now[2] * 3600 );
    my $tgtsecs = $tgt[0] + ( $tgt[1] * 60 ) + ( $tgt[2] * 3600 );

    my $secs = $tgtsecs - $nowsecs;
    $secs += ( 24 * 3600 ) if ( $secs <= 1 );

    return $secs;
}
1;

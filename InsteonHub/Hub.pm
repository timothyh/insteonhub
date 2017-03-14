package InsteonHub::Hub;

use strict;

use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
use MIME::Base64;
use POSIX qw(strftime);

use AnyEvent;
use AnyEvent::Log;
use AnyEvent::IO qw(:DEFAULT :flags);

use LWP::UserAgent;
use HTTP::Request::Common;

use Insteon::MessageDecoder;
use InsteonHub::Utils;

my %conf = (
    host => 'insteonhub',
    port => 25105,

    # Buffer must have at least this many chars
    # before being cleared - 0 means don't clear
    clear_buffer   => 0,
    clear_on_start => 0,

    # These values calculated by trial and error
    # Impacts responsiveness to Insteon remotes and sensors
    poll_interval => 1.0,
    fast_interval => 0.2,

    # Defines delay between Insteon commands
    cmd_interval => 1.5,

    ignore_dups => 1,

    passive => 0,

    #user => '',
    #password => '',
    #callback => \cb
    #callback_raw => \cb

    #capture_log => '',
);

my $hub_url;

my $auth;
my %hdrs;

# Commands to send to Hub
#
my $buffer_cmd = 'buffstatus.xml';
my $clear_cmd  = '1?XB=M=1';
#
# PLM Commands
#
#'3?02620E79860F1000=I=3'
my $id_cmd = '0262%6.6s0F1000';
#
#3?02620E79860F1900=I=3
my $status_cmd = '0262%6.6s051902';
#
my $device_on_cmd  = '0262%6.6s0F11FF';
my $device_off_cmd = '0262%6.6s051300';

my $group_on_cmd  = '0261%02d1100';
my $group_off_cmd = '0261%02d1300';

my $first_link_db_cmd = '0269';
my $next_link_db_cmd  = '026A';

my $hub_info_cmd = '0260';
#
# Insteon commands to just ignore
# Format is 'cmd' => length of command (bytes from buffer)
#
my %ignore_cmd = ( '027F' => 6, '027A' => 6, '0277' => 6, '0260' => 16 );

# Complete previous receive buffer
my $rawprev  = '';
my $sizeprev = 0;

# Messages to be processed
my $rawbuff = '';

# Message sequence - Increments from startup
my $msgseq = 1;

# Last message processed
my $rawmsgprev = '';

my $fetch_timer;
my $fifo_timer;
my $reopen_timer;

my @fifo_high;
my @fifo_low;

my $trace = 0;

my $max_fast_polls = 10;

my $capturelog_fh   = undef;
my $capturelog_skip = 0;

my $exit_when_ready = 0;
my $exitstatus      = undef;

sub init {
    my %args = @_;

    for my $n ( keys(%args) ) { $conf{$n} = $args{$n}; }

    AnyEvent::Log::logger trace => \$trace;
    $trace = $trace ? 1 : 0;

    AE::log trace => Dumper( \%conf ) if ($trace);

    $hub_url = "http://$conf{host}:$conf{port}";

    $auth = encode_base64("$conf{user}:$conf{password}");
    chomp($auth);

    $max_fast_polls = int( 2.0 * $conf{poll_interval} / $conf{fast_interval} );

    $rawbuff  = '';
    $rawprev  = '';
    $sizeprev = 0;

    if ( $conf{capture_log} ) {
        open_log(
            $conf{capture_log},
            sub {
                ($capturelog_fh) = @_
                  or AE::log alert => "$conf{capture_log}: $!";
            }
        );
    }

    %hdrs = ( Authorization => 'Basic ' . $auth );

    $fetch_timer = AnyEvent->timer(
        after    => 0.1,
        interval => $conf{poll_interval},
        cb       => \&getHubBuffer,
    );

    $fifo_timer = AnyEvent->timer(
        after    => 0.2,
        interval => $conf{cmd_interval},
        cb       => \&fifo_cb,
    );

    clearHubBuffer() if $conf{clear_on_start};
}

sub open_log {
    my ( $pat, $cb ) = @_;

    my $filename = strftime( $pat, localtime );
    aio_open $filename, O_CREAT | O_RDWR | O_APPEND, 0666, $cb;
}

sub exit_when_ready {
    my ($tmp) = @_;
    $exitstatus = $tmp if ( defined $tmp );

    $exit_when_ready = 1;
}

my $last_poll = 0;

sub getHubBuffer {
    return
      unless (
        ( AnyEvent->now - $last_poll ) >= ( $conf{fast_interval} / 2.0 ) );

    _getNow( $buffer_cmd, \&_process_request );

    $last_poll = AnyEvent->now;
}

sub clearHubBuffer {
    return if ( $conf{passive} );

    _getNow( $clear_cmd, sub { AE::log debug => "Hub buffer cleared"; } );
}

sub get_hub_info {
    _hubSend( $hub_info_cmd, 'low',
        sub { AE::log debug => "Hub information requested"; } );
}

sub device_status {
    my ($device) = @_;

    _hubSend( sprintf( $status_cmd, $device ),
        'low', sub { AE::log debug => "Status requested for $device"; } );
}

sub get_link_db {
    my ($next) = @_;

    if ( $next eq 0 ) {
        _hubSend( $first_link_db_cmd, 'low',
            sub { AE::log debug => "First link DB requested"; } );
    }
    else {
        _hubSend( $next_link_db_cmd, 'low',
            sub { AE::log debug => "Next link DB requested"; } );
    }
}

sub device_id {
    my ($device) = @_;

    _hubSend( sprintf( $id_cmd, $device ),
        'low', sub { AE::log debug => "Id requested for $device"; } );
}

sub x10_set {
    my ( $device, $state, $level ) = @_;
}

sub insteon_set {
    my ( $device, $state, $level ) = @_;

    if ( defined $state ) {
        if ( is_true($state) ) {
            _hubSend( sprintf( $device_on_cmd, $device ),
                'high', sub { AE::log debug => "Device $device on"; } );
        }
        elsif ( is_false($state) ) {
            _hubSend( sprintf( $device_off_cmd, $device ),
                'high', sub { AE::log debug => "Device $device off"; } );
        }
    }
}

sub device_set {
    my ( $id, $state, $level ) = @_;

    if ( is_x10($id) ) {

        # X10
        x10_set( $id, $state, $level );
    }
    elsif ( is_insteon($id) ) {
        insteon_set( $id, $state, $level );
    }
}

sub group_set {
    my ( $group, $state, $level ) = @_;

    if ( defined $state ) {
        if ( is_true($state) ) {
            _hubSend( sprintf( $group_on_cmd, $group ),
                'high', sub { AE::log debug => "Group $group on"; } );
        }
        elsif ( is_false($state) ) {
            _hubSend( sprintf( $group_off_cmd, $group ),
                'high', sub { AE::log debug => "Group $group off"; } );
        }
    }
}

sub fifo_cb {
    my $next;

    if (@fifo_high) {
        $next = shift @fifo_high;
    }
    elsif (@fifo_low) {
        $next = shift @fifo_low;
    }
    else {
        return;
    }
    _getNow( @{$next} );

    _start_fast_poll();
}

sub _hubSend {
    my ( $cmd, $pri, $cb ) = @_;

    return if ( $conf{passive} );

    $cmd = '3?' . $cmd . '=I=3';

    my @param = ( $cmd, $cb );

    if ( $pri eq 'now' ) {
        _getNow(@param);
        _start_fast_poll();
    }
    elsif ( $pri eq 'high' ) {
        push @fifo_high, \@param;
    }
    elsif ( $pri eq 'low' ) {
        push @fifo_low, \@param;
    }
    else {
        AE::log error => "Unexpected priority: $pri message: $cmd";
    }
}

sub _getNow {

    my ( $cmd, $cb ) = @_;

    AE::log trace => "Get $cmd";

    my $ua = LWP::UserAgent->new();

    my $request = GET $hub_url . '/' . $cmd;
    $request->authorization_basic( $conf{user}, $conf{password} );

    my $response = $ua->request($request);

    if ( $response->is_success ) {
        $cb->( $response->decoded_content, $response->headers );
    }
    else {
        AE::log fatal => "Error from hub: " . $response->status_line;
    }
}

my $idle_polls;
my $fast_timer;

sub _start_fast_poll {
    unless ($fast_timer) {
        AE::log debug => "Start fast polling";

        # Throw in some extra polls when activity happening
        $fast_timer = AnyEvent->timer(
            after    => ( $conf{fast_interval} ),
            interval => ( $conf{fast_interval} ),
            cb       => \&getHubBuffer
        );
    }
    $idle_polls = 0;
}

sub _stop_fast_poll {
    if ($fast_timer) {
        AE::log debug => "Stop fast polling";
        undef $fast_timer;
    }
}

sub _process_request {
    my ( $body, $hdr ) = @_;

    unless ( $body =~ m{<response><BS>([0-9A-F]+)</BS></response>}i ) {

        # Unexpected message
        AE::log note => "Unexpected:" . Dumper( $hdr, $body );
        return;
    }

    my $buff = $1;

    my $msgcnt = _process_hub_buffer($buff);

    if ( ( $msgcnt >= 0 ) || @fifo_high || @fifo_low ) {
        _start_fast_poll();

        $idle_polls = 0;
    }
    else {
        exit($exitstatus) if ($exit_when_ready);

        $idle_polls += 1;

        _stop_fast_poll() if ( $idle_polls >= $max_fast_polls );
    }

    return unless ( $msgcnt == -1 );

    # Duplicate non-empty buffer
    # Do we need to clear the hub buffer?

    return unless ( $conf{clear_buffer} );

    # This allows for 2 additional "normal" polls before clearing
    return unless ( $idle_polls >= ( $max_fast_polls + 2 ) );

    my $size = hex( substr $buff, -2 );
    return unless ( $size >= $conf{clear_buffer} );

    if ($trace) {
        $buff =~ s/000000+/00..00/;
        AE::log trace => "clearing hub buffer\n$buff";
    }
    else {
        AE::log debug => "clearing hub buffer";
    }
    clearHubBuffer();
}

sub _write_hub_buffer {
    my ($raw) = @_;

    return unless $capturelog_fh;

    $raw = AnyEvent::Log::format_time( AnyEvent->now ) . " $raw\n";

    aio_write $capturelog_fh, $raw, sub {
        AE::log error => "Buffer write: $!" unless @_;
    };
}

#
# Returns
#   -2 => Empty buffer
#   -1 => Duplicate buffer (ignored)
#   0  => Incomplete message
#   > 0 => # of messages processed
#
sub _process_hub_buffer {

    # Current buffer
    my ($raw) = @_;

    # Ignore a buffer with all '0's
    unless ( $raw =~ /[^0]/ ) {
        AE::log trace => "Ignoring empty buffer";
        $rawprev  = '';
        $sizeprev = 0;
        _write_hub_buffer($raw) unless ( $capturelog_skip == 1 );
        $capturelog_skip = 1;
        return -2;
    }

    # Has buffer changed since previous poll
    if ( $raw eq $rawprev ) {
        AE::log trace => "Ignoring duplicate buffer";
        _write_hub_buffer($raw) unless ( $capturelog_skip == 2 );
        $capturelog_skip = 2;
        return -1;
    }

    _write_hub_buffer($raw);
    $capturelog_skip = 0;

    my $size = length $raw;

    # Is this a hub buffer or Insteon message
    # Extended messages are 24 bytes
    if ( $size <= 30 ) {

        # Single Insteon message
        $rawbuff = $raw;
    }
    else {
        # Hub buffer
        # Last two chars of buffer define length of usable string
        $size = hex( substr $raw, -2 );

        if ( $size == 0 ) {
            AE::log trace => "Ignoring zero length buffer";
            $rawprev  = '';
            $sizeprev = 0;
            return -2;
        }

        my $tmpprev = substr( $rawprev, 0, $sizeprev );
        $rawprev = $raw;

        $raw = substr( $raw, 0, $size );

        if (    ( $size >= $sizeprev )
            and ( substr( $raw, 0, $sizeprev ) eq $tmpprev ) )
        {

         # The received string is just the previous one with appended characters
            $rawbuff = $rawbuff . substr( $raw, $sizeprev );
        }
        else {
            # Hub buffer has wrapped
            $rawbuff = $rawbuff . $raw;
        }
    }

    $sizeprev = $size;

    my $skipped = '';

    # Messages processed this iteration
    my $msgcnt = 0;

    while ( length $rawbuff ) {
        unless ( substr( $rawbuff, 0, 2 ) eq '02' ) {
            $skipped .= substr( $rawbuff, 0, 2 );
            $rawbuff = substr( $rawbuff, 2 );
            next;
        }
        if ( length $skipped ) {
            AE::log info => "Skipping $skipped";
        }

        $skipped = '';

        my $cmd = uc( substr( $rawbuff, 0, 4 ) );

        if ( ( $cmd eq '02' ) or ( $cmd eq '0200' ) ) {
            AE::log info => "Unformed command: $cmd";
            last;
        }

        # Ignore messages known not to be handled by MessageDecoder
        my $cmdlen;
        my $ignore;
        if ( $ignore_cmd{$cmd} ) {
            $cmdlen = $ignore_cmd{$cmd};
            $ignore = 1;
        }
        else {
            $cmdlen =
              eval { Insteon::MessageDecoder::insteon_cmd_len( $cmd, 0, 0 ); };
            AE::log debug => join( '\n', $@ ) if $@;
            unless ( defined $cmdlen ) {
                AE::log info => "Unknown Insteon command: $cmd";
                $rawbuff = substr( $rawbuff, 2 );
                next;
            }

            # Change bytes to nibbles
            $cmdlen *= 2;
        }

        $msgcnt++;

        if ( length($rawbuff) < $cmdlen ) {
            AE::log warn => "Short message: $rawbuff";

            # It's possible a circuit-breaker is needed here
            # to stop an infinite loop.
            # leave for next iteration
            last;
        }

        # Is there an ACK(06) or NAK(15)
        $cmdlen += 2 if ( substr( $rawbuff, $cmdlen, 2 ) =~ m{^(06|15)} );

        my $rawmsg = substr( $rawbuff, 0, $cmdlen );
        AE::log trace => "Processing $rawmsg";

        if ( $conf{'ignore_dups'} and ( $rawmsg eq $rawmsgprev ) ) {
            $rawbuff = substr( $rawbuff, $cmdlen );
            next;
        }
        $rawmsgprev = $rawmsg;

        if ( $conf{callback_raw} ) {
            $conf{callback_raw}->($rawmsg);
        }
        if ( !$ignore && $conf{callback} ) {
            my $res = eval { Insteon::MessageDecoder::plm_decode($rawmsg); };
            AE::log debug => join( '\n', $@ ) if $@;

            if ( $res =~ /message length too short for plm command/i ) {

                # Should never happen
                AE::log alert => "Short message: $rawmsg";

                # leave for next iteration
                last;
            }

            my %m = (
                timestamp   => AnyEvent->now,
                raw_message => $rawmsg,
                sequence    => $msgseq,
            );
            for ( split( "\n", $res ) ) {
                s/^\s*//;
                s/\s*$//;
                my ( $name, $value ) = split( /\s*:\s*/, $_, 2 );
                if ( $value =~ /^..:..:..$/ ) {
                    $value = uc $value;
                    $value =~ s/[^0-9A-F]//g;
                }
                else {
                    $value =~ s/[^\w\d\s.:-]//g;
                }
                $name =~ s/[^\w\d]+/_/gi;
                $m{ lc $name } = $value;
            }

            $conf{callback}->( \%m );
        }
        $msgseq++;

        $rawbuff = substr( $rawbuff, $cmdlen );
    }

    return $msgcnt;
}

1;

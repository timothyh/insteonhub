#!/usr/bin/perl -w
#
use strict;

use FindBin;
use lib "$FindBin::Bin/../lib/perl5";

use InsteonHub::Config;

readConfig();

printConfig() if ( $verbose );

1;


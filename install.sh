#!/bin/bash --
#
# Sample installation script
#

TOPDIR=/usr/local

ETCDIR=/etc
VARDIR=/var

BINDIR=$TOPDIR/bin
SBINDIR=$TOPDIR/sbin
LIBDIR=$TOPDIR/lib/perl5
CAPTDIR=$VARDIR/lib/insteonhub/capture
LOGDIR=$VARDIR/log/insteonhub
CONFIG=$ETCDIR/insteonhub.yaml

APPUSER=ihub:ihub

# Programs to be installed

TOBIN="ihub-check ihub-capture ihub-cmd ihub-groups ihub-replay"
TOSBIN="ihub-mqtt"

echo Creating Directories
for D in $BINDIR $SBINDIR $ETCDIR $LIBDIR $CAPTDIR $LOGDIR ; do
	[ -d $D ] && continue
	echo mkdir $D
	mkdir -p $D
	chown $APPUSER $D
done

echo Installing Modules
cp -pr Insteon InsteonHub $LIBDIR

for P in $TOBIN; do
	echo copy $P.pl to $BINDIR/$P
	cp -p $P.pl $BINDIR/$P
done
for P in $TOSBIN; do
	echo copy $P.pl to $SBINDIR/$P
	cp -p $P.pl $SBINDIR/$P
done

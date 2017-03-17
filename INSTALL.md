## Installation

The following packages should be installed:

Ubuntu/Raspbian:
git libyaml-perl libanyevent-perl libmodule-pluggable-perl make g++

CentOS7:
git perl-AnyEvent-AIO perl-AnyEvent-HTTP perl-YAML make

And the following Perl modules are needed. They will probably have to be installed from CPAN.

Net::MQTT::Message AnyEvent::MQTT

There is a sample installation script provided - install.sh. This installs to the following
directories in /usr/local

- bin - utility programs
- sbin - ihub-mqtt daemon
- lib/perl5 - Perl modules

It creates
- /var/log/insteonhub

And enables the ihub-mqtt service

Note the install script has been only lightly tested.

A configuration file, /etc/insteonhub.yaml, is needed before the service can be started.
A sample is in the configs directory.

The ihub-check command can be used o verify the configuration file.

Once the config file has been created, start the ihub-mqtt servic.

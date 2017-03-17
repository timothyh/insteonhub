# Insteon Hub to MQTT Broker and associated utilities

This is an interface between an Insteon Hub and an MQTT Broker.

### Features

Current functionality includes:
- Publishes device on/off state changes as MQTT messages:
- Handles multi-button Insteon remotes
- Receives MQTT set commands to control Insteon Devices
- Option to publish raw Insteon messages
- Support for groups both Hub linked groups and implemented by gateway
- Miscellaneous utilities to help with debugging and communicating with Hub.

Planned functionality includes:
- Support for controlling X10 devices - outgoing only
- Dimmer/multi-level support`
- Some support for MQTT QoS

Completely Out of scope includes:
- Monitoring X10 - 2014 hub doesn't appear to support incoming X10 messages
- Any type of in-built automation - This is intended as a gateway only

Tested in a small household with the following Insteon devices:
- Insteon Hub (2014) - Model 2245-222
- Insteon LED Bulbs
- Insteon 8 button remote
- Insteon On/Off (non-dimmer) wall switches

Note this does not use the Insteon API, and so does not require a developer key. Instead it polls
the hub directly for Insteon messages. Use at your own risk.

### Acknowledgments

A key component is the Insteon::MessageDecoder module used unchanged from the MisterHouse project.

See https://github.com/hollie/misterhouse/blob/stable/lib/Insteon/MessageDecoder.pm

### Contains

- ihub-capture.pl - Utility to poll Hub and write captured buffers to a file
- ihub-check.pl - Verify config files - -v displays interpretation of config file(s)
- ihub-cmd.pl - Issue device commands directly to Hub
- ihub-groups.pl - Poll Hub for linked groups
- ihub-mqtt.pl - Actual MQTT gateway
- ihub-replay.pl - Replays captured data as individual messages. -v includes interpretation of message

- ihub-mqtt.init - Traditional UNIX startup script 
- ihub-mqtt.service - Systemd service definition

- configs - Directory containing sample config files

### Warning

This is (and always will be) a work in progress. Use at your own risk.

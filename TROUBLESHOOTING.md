# Random Collection of Troubleshooting Notes

### ihub-mqtt won't start up
- Do you have a working config file - use 'ihub-check -v -c path_to_config' to verify config file and that it is being
interpreted as intended.
- Are the Insteon Hub credentials correct - Check log files for 401 error
  If in doubt, look on the outside of the hub for credentials.
- Is the Hub host correctly defined? Using the Insteon app, the IP address can be found at
  Settings -> Edit Settings -> House -> Local IP
- Is ihub-mqtt connecting correctly to the MQTT broker

### Individual Insteon Device doesn't power up/down when requested

Use Insteon app to:-
- verify that the hub knows about the device.
- That device powers up/down when requested by hub. If it doesn't then nothing else will work.

### Device(s) power up/down when ihub-mqtt (re)starts

Most likely there's a retained message in the MQTT broker instructing this to happen. Retained messages can be removed usin
g mosquitto_pub along the lines of:
  $ mosquitto_pub -t home/insteon/mydevice/set -n -r

### Messages in log "warn  InsteonHub::Hub: Short message:..."

These can be ignored - Just means hub was polled a an inconvenient time.

### essages in log "info  InsteonHub::Hub: Skipping ...."

Unfamiliar Insteon messages where received from hub. Most likely cause is that the hub got busy and we missed some
characters. It's also possible that this was caused by an unfamiliar Insteon device.

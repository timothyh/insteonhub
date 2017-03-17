## Minimal Usage Instructions

- ihub-capture -o capture_file -D duration_in_secs
- ihub-check -c config_file -v
- ihub-cmd -a [on|off] devices_names or device_ids
- ihub-groups
- ihub-mqtt
- ihub-replay -i capture_file -v

## Full Options

--config-files or -c - followed by colon seperated list of config files.
Defines config files to be used. When multiple config files are defined, last one wins.

--action or -a followed by 'on' or 'off' - Defines operation for ihub-cmd

--duration or -D - How long to wait before exiting in seconds

--input or -i - followed by input filename

--output or -i - followed by output filename

--log-level or -L - followed by log level
Defines minimal level for logging. Uses AnyEvent::Log level definitions

--log-file - Defines log file

--wait or -w - With ihub-cmd, wait for confirmation that Insteon command has been executed.

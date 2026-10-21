# Patrol Keep-alive

A patrol runs every fixed interval (default 60 seconds, configurable 10~86400; intervals above 60 are split into slices so configuration hot-reload and feature checks stay responsive).

## What It Does

- After boot, services carrying the green start tag (i.e. "auto-start & keep-alive" enabled) are started automatically
- Each patrol checks start-tagged services and restarts those that are not running or were killed by the system
- Interval changes take effect within one minute and interrupt the old interval immediately
- Service logs over 1 MB rotate, keeping the most recent 1/4 for context while preventing unbounded growth
- If start/stop features are enabled, their checks run with each patrol

## What It Does Not Do

- Never kills running stop-tagged services, so temporarily started services are not mistakenly killed
- Holds no WakeLock by default; enable Wake Lock in Basic Settings to reduce Doze delays (unsupported on some kernels)

# check_rancher
Nagios/MRTG plugin for checking Rancher API

To use this, you should first set up an API User and Key for the Environment
that you wish to test.  Place this information in a configuration file that
can be read by the script.

Example configurations for both Nagios and MRTG are in the directory.

You can run separate checks for cpu/mem/swap/load/disk/certificates or you
can group them together by Environment.

Stacks may be tested individually.

If you have problems, try running from the commandline using '-d' for debug
mode, which gives you more information.  Make sure your API user has access to
the Environment you are testing, and make sure your monitoring host can 
connect to the API port.  Remember to set the SSL option if you have SSL on
the API (which is a good idea).

I would suggest treating the entire Environment as a single Nagios host, rather
than having a separate object for each Environment host.

Default thresholds can be set in the config file (if you use one); you can 
override these on a per-Host basis using Labels like: nagios.cpu.warn=80

Usage: check_rancher [-N|-M][-d][-h]
             [-c configfile]
             [-H host][-p port][-S][-U user -K key]
             [-t timeout][-T globaltimeout]
             [-E environment][-s stack]
             [-i itemlist]

-d : debug
-M : MRTG mode
-N : Nagios mode
-S : Use SSL
-E : Rancher environment
-s : Rancher stack
-c : Specify configuration file
-i : Comma-separated list of metric items to check. Can include:
     certificates,cpu,memory,disk,swap
     This only applies to Environment checks.


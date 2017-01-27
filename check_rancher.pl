#! /usr/bin/perl 
# vim:ts=4
#
# Check the Rancher Docker cluster for Nagios/MRTG
#
# Syntax:  check_rancher [-M|-N] [-d] [-h] 
#            [-c configfile]
#            [-H hostname][-p port][-S][-U user -K key]
#            [-T globaltimeout][-t fetchtimeout]
#            [-E environment][-s stack]
#            [-t itemlist]
#

use strict; 
use LWP::UserAgent;
use Getopt::Long;
use CGI qw( escapeHTML );
use JSON;
use Data::Dumper;
#use Time::HiRes qw( usleep ualarm gettimeofday tv_interval );
use Date::Parse;

my( $VERSION ) = "0.1";

my( $MRTG ) = 0; # MRTG or Nagios mode
my( $TIME ) = -1;
my( $MESSAGE ) = "";
my( $PERFSTATS ) = "";
my( $STATUS ) = 0;
my( $A, $B ) = ('U','U');
my( $TIMEOUT ) = 10; #seconds
my( $GTIMEOUT ) = 20; #seconds
my( $USERNAME, $PASSWORD ) = ('','');
my( $LOGFILE ) = "/tmp/check.log";
my( $DEBUG ) = 0;
my( $ENV,$STACK ) = ('','');
my( $HOSTNAME, $PORT, $SSL ) = ('localhost',80,0);
my( $ENDPOINT ) = "";
my( $URL );
my( $ITEMS ) = "cert,cpu,mem,disk,swap";

my( %config ) = (
	'cpu.warn' => 80, #percent used
	'cpu.crit' => 90,
	'mem.warn' => 90, #percent used
	'mem.crit' => 99,
	'disk.warn' => 80, #percent used
	'disk.crit' => 90,
	'load.warn' => 50, # 5min load average
	'load.crit' => 100,
	'swap.warn' => 1,  # pages
	'swap.crit' => 10000,
	'cert.warn' => 7,  # days remaining
	'cert.crit' => 1,
);

use vars qw/$opt_i $opt_h $opt_d $opt_M $opt_N $opt_H $opt_c $opt_U $opt_K $opt_T $opt_t $opt_E $opt_S $opt_s $opt_p $opt_o $opt_f/;
my( $ua );
my( $res, $req ) = ('','');
my($json,$content);
my($starttime);
####################################################################
# get credentials
sub LWP::UserAgent::get_basic_credentials {
	my ($self, $realm, $url, $isproxy) = @_;
	print "Returning u=$USERNAME,p=$PASSWORD\n" if($DEBUG);
	return $USERNAME,$PASSWORD;
}
################################################################
sub escape($) {
	my($x) = $_[0];
	$x=~s/([^a-zA-Z0-9_.-])/uc sprintf("&#x%02x;",ord($1))/eg;
	return $x;
}

sub output {
	if($MRTG) {
		$MESSAGE =~ s/\\n.*//;
		print "$A\n$B\n\n$MESSAGE\n";
		exit $STATUS;
	} 

	if(!$MESSAGE) { 
		$MESSAGE = "Status: $STATUS";
	}
	print "$MESSAGE";
	print "|$PERFSTATS" if($PERFSTATS);
	print "\n";
	exit $STATUS;
}
####################################################################
# Fetching

sub fetchurl($$) {
	my($url,$p) = @_;

    # Create a request
	print "Fetching: $url\n" if($DEBUG);
	if($p) {
        $req = HTTP::Request->new(POST=>$url);
		$req->content($p);
	} else {
		$req = HTTP::Request->new(GET=>$url);
	}
	$req->content_type('application/json');
	$req->header("Accept"=>"application/json");
	$req->authorization_basic($USERNAME,$PASSWORD);

    # Pass request to the user agent and get a response back
	$url =~ s/ /+/g;
	print "--> Retrieving $url ".(($p and (length($p)<40))?"($p)":"")."\n" 
		if($DEBUG);
	$res = $ua->request($req);

	if(!$res) { 
		$MESSAGE = "API Failure: No response.";
		if($ENV) {
			$STATUS = 3;
		} else {
			$STATUS = 2;
		}
		output;
	}
	print "--> Done. (".$res->code.")\n" if($DEBUG);

    # Check the outcome of the response
	if($DEBUG) { 
		open LOG, ">>$LOGFILE"; 
		print LOG "-------------------------------------------------------------------------\n$url\n$p\n".$res->status_line."\n".$res->content."\n"; 
		close LOG; 
	} 
    if (!$res->is_success) {
		print "See logfile $LOGFILE for content\n" if($DEBUG);
        $MESSAGE = "API Error: ".$res->status_line;
    }

	return $res->content;
}

sub dohelp() {
	print "Usage: check_rancher [-N]|-M][-d][-h]\n             [-c configfile]\n            [-H host][-p port][-S][-U user -K key]\n             [-t timeout][-T globaltimeout]\n             [-E environment [-s stack|-o hostobject]]\n             [-i itemlist]";
	print "-d : debug\n";
	print "-M : MRTG mode\n";
	print "-N : Nagios mode\n";
	print "-H : Specify Rancher server hostname/IP\n";
	print "-p : Specify Rancher API port (default 80)\n";
	print "-S : Use SSL\n";
	print "-E : Rancher environment\n";
	print "-s : Rancher stack\n";
	print "-c : Specify configuration file\n";
	print "-i : Comma-separated list of metric items to check. Can include:\n";
	print "     certificates,cpu,memory,disk,swap\n";
	print "     This only applies to Environment checks.\n";
	print "-o : Specify host object.  This is used by MRTG mode.\n";
	exit 3;
}

sub readconfig($) {
	my($file) = $_[0];
	if(! -r $file) {
		$MESSAGE = "Unable to read $file";
		$STATUS = 3;
		output;
	}
	print "Reading config from $file\n" if($DEBUG);
	open CFG,"<$file" or do {
		$MESSAGE = "Unable to read $file";
		$STATUS = 3;
		output;
	};
	while ( <CFG> ) {
		next if( /^\s*#/ );
		next if( /^\s*$/ );
		chomp;
		if( /^\s*(\S+)\s*=\s*(.*)/ ) {
			$config{lc $1} = $2;
			print "$1 = $2\n" if($DEBUG);
		} else {
			print "Bad config line: $_\n" if($DEBUG);
		}
	}
	close CFG;

	$HOSTNAME = $config{hostname} if(defined $config{hostname});
	$PORT     = $config{port}     if(defined $config{port});
	$USERNAME = $config{username} if(defined $config{username});
	$PASSWORD = $config{key}      if(defined $config{key});
	$ENV      = $config{environment} if(defined $config{environment});
	$SSL      = $config{ssl}      if(defined $config{ssl});
	$STACK    = $config{stack}    if(defined $config{stack});
}

########################################################################
sub getthresh($$) {
	my($type) = lc $_[0];
	my($obj) = $_[1];
	my($warn,$crit)=(-1,-1);

	# Defaults as in config
	$warn = $config{"$type.warn"} if(defined $config{"$type.warn"});
	$crit = $config{"$type.crit"} if(defined $config{"$type.crit"});

	# Any override in the labels?
	if($obj and $obj->{labels}) {
		$warn = $obj->{labels}{"nagios.$type.warn"}
			if(defined $obj->{labels}{"nagios.$type.warn"});
		$crit = $obj->{labels}{"nagios.$type.crit"}
			if(defined $obj->{labels}{"nagios.$type.crit"});
	}

	return ($warn,$crit);
}

########################################################################
sub checkenv($$) {
	my( $data ) = $_[0];
	my( $host ) = $_[1];
	my( $envid ) = $data->{id};
	my($json,$url);
	my( $w, $c );
	my( $totcpu, $totmem, $numhosts ) = (0,0);

	$STATUS = 0;
	$MESSAGE = "";

	print "-- Checking status\n" if($DEBUG);

	if( $data->{state} ne "active" ) {
		if( $data->{state} =~ /activating|registering|requested|updating/ ) {
			$STATUS = 1;
		} else { $STATUS = 2; }
		$MESSAGE = "Environment status: ".$data->{state};
		return;
	}

	print "-- Checking hosts\n" if($DEBUG);
	$MESSAGE = "Environment status: ".$data->{state};
	# Retrieve hosts data
	$url = "$ENDPOINT/projects/$envid/hosts/";
	$json = decode_json( fetchurl( $url, '' ) );
	if(!$json) {
		$STATUS = 3; $MESSAGE = "API error"; return;
	}
	
	# Threshold host CPU/MEM/Disk
	foreach my $idx ( 0..$#{$json->{data}} ) {
		my $state = $json->{data}[$idx]{state};
		my $name = $json->{data}[$idx]{name};
		my $v;

		next if($state eq "inactive"); # skip inactive hosts
		next if($host and ($name ne $host)); # selected host only
	
		# Check attributes of host
		my $info = $json->{data}[$idx]{info};
		$numhosts += 1;
		
		if($ITEMS =~ /cpu/) {
			# CPU usage threshold; take avg of all cores
			($w,$c) = getthresh("cpu",$json->{data}[$idx]);
			$v = 0;
			foreach ( @{$info->{cpuInfo}{cpuCoresPercentages}} ) {
				$v += $_;
			}
			$v /= $info->{cpuInfo}{count};
			$totcpu += $v;
			$v = (int($v*100))/100;
			if(!$MRTG) {
				if( $v >= $c ) {
					$MESSAGE .= "\\nCRIT: Host $name: CPU $v\%";
					$STATUS = 2;
				} elsif( $v >= $w ) {
					$MESSAGE .= "\\nWARN: Host $name: CPU $v\%";
					$STATUS = 1 if(!$STATUS);
				}
			}
			if($host) { 
				$PERFSTATS .= "cpu=$v\%;$w;$c;0;100 ";
			} else {
				$PERFSTATS .= "cpu$name=$v\%;$w;$c;0;100 ";
			}
			if($DEBUG) { print "Host $name: CPU = $v\%\n"; }
		}
		if($ITEMS =~ /mem/) {
			# MEM usage threshold; use %
			($w,$c) = getthresh("mem",$json->{data}[$idx]);
			$v = 100.0 - (($info->{memoryInfo}{memFree}/$info->{memoryInfo}{memTotal})*100.0);
			$totmem += $v;
			$v = (int($v*100))/100;
			if(!$MRTG) {
				if( $v >= $c ) {
					$MESSAGE .= "\\nCRIT: Host $name: Memory $v\%";
					$STATUS = 2;
				} elsif( $v >= $w ) {
					$MESSAGE .= "\\nWARN: Host $name: Memory $v\%";
					$STATUS = 1 if(!$STATUS);
				}
			} 
			if($host) {
				$PERFSTATS .= "mem=$v\%;$w;$c;0;100 ";
			} else {
				$PERFSTATS .= "mem$name=$v\%;$w;$c;0;100 ";
			}
			if($DEBUG) { print "Host $name: Memory = $v\%\n"; }
		}
		if($ITEMS =~ /load/ ) {
			# loadAvg 5min threshold
			($w,$c) = getthresh("load",$json->{data}[$idx]);
			$v = $info->{cpuInfo}{loadAvg}[1];
			if(!$MRTG) {
				if( $v >= $c ) {
					$MESSAGE .= "\\nCRIT: Host $name: LoadAvg $v";
					$STATUS = 2;
				} elsif( $v >= $w ) {
					$MESSAGE .= "\\nWARN: Host $name: LoadAvg $v";
					$STATUS = 1 if(!$STATUS);
				}
			}
			if($host) {
				$A = $v; $B = 'U';
				$PERFSTATS .= "load=$v;$w;$c;0; ";
			} else {
				$PERFSTATS .= "load$name=$v;$w;$c;0; ";
			}
			if($DEBUG) { print "Host $name: LoadAvg = $v\n"; }
		}
		if($ITEMS =~ /swap/ and !$MRTG) {
			# swap threshold
			($w,$c) = getthresh("swap",$json->{data}[$idx]);
		}
		if($ITEMS =~ /disk/ and !$MRTG) {
			my(@patterns,$exclude);
			my($diskprob) = 0;
			# Disk thresholds; use % on each disk
			($w,$c) = getthresh("disk",$json->{data}[$idx]);
			$exclude = $config{"disk.exclude"};
			$exclude = $json->{data}[$idx]{labels}{"nagios.disk.exclude"}
				if(defined $json->{data}[$idx]{labels}{"nagios.disk.exclude"});
			$exclude = "" if(!$exclude);
			@patterns = split( /\s*,\s*/,$exclude );
DISK:		foreach my $disk ( keys %{$info->{diskInfo}{mountPoints}} ) {
				$v = $info->{diskInfo}{mountPoints}{$disk}{percentUsed};
				foreach ( @patterns ) {
					next DISK if( $_ and $disk =~ /$_/ );
				}
				if( $v >= $c ) {
					$MESSAGE .= "\\nCRIT: Host $name: $disk: Used $v\%";
					$STATUS = 2; $diskprob = 1;
				} elsif( $v >= $w ) {
					$MESSAGE .= "\\nWARN: Host $name: $disk: Used $v\%";
					$STATUS = 1 if(!$STATUS); 
					$diskprob = 1;
				}
				if($DEBUG) { print "Host $name: $disk: Usage = $v\%\n"; }
			}
			#$MESSAGE .= "\\nAll disks on $name OK" if(!$diskprob);
		}
	}
	if( $numhosts > 0 ) {
		if($ITEMS =~ /cpu/) {
			$totcpu /= $numhosts;
			$A = $totcpu;
			$PERFSTATS = "allcpu=$totcpu\%;;;0;100 $PERFSTATS";
		}
		if($ITEMS =~ /mem/) {
			$totmem /= $numhosts;
			$B = $totmem;
			$PERFSTATS = "allmem=$totmem\%;;;0;100 $PERFSTATS";
		}
	}
	$PERFSTATS .= "hosts=$numhosts ";

	if($ITEMS =~ /cert/ and !$MRTG) { # meaningless in MRTG mode
		# Certificate thresholds
		($w,$c) = getthresh("cert",undef);
		# retrieve all known certs
		$url = "$ENDPOINT/projects/$envid/certificates/";
		$json = decode_json( fetchurl( $url, '' ) );
		if(!$json) {
			$STATUS = 3; $MESSAGE = "API error"; return;
		}

		# loop through and test each expiry date
		foreach my $cert ( @{$json->{data}} ) {	
			next if($cert->{type} ne "certificate");
			next if($cert->{state} ne "active");
			my($cn) = $cert->{CN};
			my($expires) = str2time($cert->{expiresAt});
			if($expires< time ) {
				$STATUS = 2;
				$MESSAGE .= "\\nCertificate $cn has expired!";
				next;
			}
			my($daysleft) = ($expires-time)/(24*3600);
			if($daysleft <= $c ) {
				$STATUS = 2;
				$MESSAGE .= "\\nCertificate $cn expires in $daysleft days";
				next;
			} elsif( $daysleft <= $w ) {
				$STATUS = 1 if(!$STATUS);
				$MESSAGE .= "\\nCertificate $cn expires in $daysleft days";
				next;
			}
		}

	}

	$MESSAGE = "Environment OK" if(!$MESSAGE);
}

########################################################################
sub checkstack($) {
	my( $data ) = $_[0];
	my( $stkid ) = $data->{id};
	my( $envid ) = $data->{accountId};
	my($json,$url);
	my($cnt) = 0;

	$STATUS = 0;
	$MESSAGE = "Stack OK";

	print "-- Checking stack status\n" if($DEBUG);

	if( $data->{state} ne "active" ) {
		$STATUS = 2;
		if( $data->{state} =~ /activating|cancel|upgrade|request|rolling-back/ ) {
			$STATUS = 1;
		}
		
		$MESSAGE = "Environment status: ".$data->{state};
		if($STATUS==2) { $B = 0; } else { $B = 1; }
		return;
	}
	$MESSAGE = "Stack is ".$data->{state};

	print "-- Checking stack services\n" if($DEBUG);

	# Retrieve svc data
	$url = "$ENDPOINT/projects/$envid/environments/$stkid/services/";
	$json = decode_json( fetchurl( $url, '' ) );
	if(!$json) {
		$STATUS = 3; $MESSAGE = "API error"; return;
	}
	
	# Check services
	foreach my $idx ( 0..$#{$json->{data}} ) {
		my $state = $json->{data}[$idx]{state};
		my $name = $json->{data}[$idx]{name};

		$cnt += $json->{data}[$idx]{scale};
		$MESSAGE .= "\\n* $name : $state";
		next if($state eq "active");
		if( $state =~ /inactive|remove/ ) { $STATUS = 2; next; }
		next if($STATUS);
		if( $state =~ /activating|cancel|register|update|upgrade|rolling/ ) {
			$STATUS = 1;
		}
	}

	# MRTG counts.  Not really meaningful for Stacks.
	$A = $cnt;
	if( $STATUS == 2 ) { $B = 0; } else { $B = 1; }
}

########################################################################
# MAIN

# process arguments: at least MRTG/Nagios mode, and warn/crit for Nagios
$Getopt::Long::autoabbrev = 0;
$Getopt::Long::ignorecase = 0;
GetOptions('h|help','d|debug','M|mrtg|MRTG','N|Nagios|nagios',
    'H|host|rancher_host=s','p|port=i','S|SSL|ssl',
	'c|config|config_file=s','U|user|username=s',
	'K|pass|password|key=s','t|timout=i','T|globaltimeout=i',
	'E|env|environment=s','s|stack=s',
	'i|items=s',
	'o|obj|object=s','f|fs|filesystem|disk=s'
	);
dohelp() if($opt_h);
$DEBUG=1 if($opt_d);
readconfig($opt_c) if($opt_c);
$DEBUG=1 if($opt_d);
$MRTG = 0 if($opt_N);
$MRTG = 1 if($opt_M);
$USERNAME = $opt_U if($opt_U);
$PASSWORD = $opt_K if($opt_K);
$TIMEOUT = $opt_t if($opt_t);
$GTIMEOUT = $opt_T if($opt_T);
$PORT = $opt_p if($opt_p);
$SSL = 1 if($PORT == 443);
$SSL = $opt_S if(defined $opt_S);
$ENV = $opt_E if($opt_E);
$STACK = $opt_s if($opt_s);
$ITEMS = $opt_i if($opt_i);
$HOSTNAME = $opt_H if($opt_H);

#$starttime = [gettimeofday];

# Create and set up the useragent
$ua = LWP::UserAgent->new;
$ua->agent("check_rancher/$VERSION");
$ua->timeout($TIMEOUT) ;

###########################################################
# First, get a list of Environments.
# We also test the API at this point.
# url/post/contenttype/desc/fatal
$ENDPOINT = "http".($SSL?"s":"")."://$HOSTNAME:$PORT/v1";
$URL = "$ENDPOINT/projects/";
$content = fetchurl( $URL, '' );
$json = decode_json($content);

if( !$content or !(ref $json) or !defined $json->{'type'} ) {
	if($ENV) {
		$STATUS = 3;
	} else {
		$STATUS = 2;
	}
	$MESSAGE = "No valid response form API.";
	output;
}
if($json->{type} eq "error" or !$res->is_success )  {
	if($ENV) {
		$STATUS = 3;
		$MESSAGE = "API Error: ".$json->{'message'};
	} else {
		$STATUS = 1;
		$MESSAGE = "API is sane, but cannot access: ".$json->{'message'};
	}
	output;
}
if(!defined $json->{data}) {
	$STATUS = 3;
	$STATUS = 0 if(!$ENV);
	$MESSAGE = "No environments defined";
	output;
}
if(!$ENV) { # API test only
	$MESSAGE = "API Working Correctly ("
		.($#{$json->{data}}+1)
		." environments available to this ID)";
	$STATUS = 0;
	output;
}

#print Dumper($json) if($DEBUG);

######################################################
# Now we try to identify the environment

my($envid) = 0;
my($idx);
foreach $idx ( 0..$#{$json->{data}} ) {
	if( $json->{data}[$idx]{name} eq $ENV ) {
		$envid = $json->{data}[$idx]{id};
		last;
	}
}
if(!$envid) {
	if($STACK) {
		# Stack status unknown
		$STATUS = 3;
		$MESSAGE = "Unknown Environment '$ENV'";
	} else {
		$STATUS = 2;
		$MESSAGE = "Environment '$ENV' not defined";
	}
	output;
}

######################################################
# Environment checks
if(!$STACK) {
	checkenv($json->{data}[$idx],$opt_o);
} else {
	$URL = "$ENDPOINT/projects/$envid/environments/";
	$content = fetchurl( $URL, '' );
	$json = decode_json($content);
	if(!$json or !(ref $json) or !defined $json->{data}) {
		$STATUS = 3;
		$MESSAGE = "Unexpected JSON returned";
		output;
	}
	my($stk) = 0;
	foreach my $idx ( 0..$#{$json->{data}} ) {
		if( $json->{data}[$idx]{name} eq $STACK ) {
			$stk = $json->{data}[$idx]; # should pass hash, not just ID (frisbee23)
			last;
		}
	}
	if(!$stk) {
		$STATUS = 2;
		$MESSAGE = "Stack '$STACK' unknown in environment '$ENV'";
		output;
	}
	checkstack($stk);
}

#if(tv_interval($starttime)>=$GTIMEOUT ) {
#	$STATUS = 3;
#	$MESSAGE = "Global timeout reached.";
#	output;
#}

# exit
output;
# NOT REACHED
exit -1;

#! /usr/bin/perl

use warnings;
use strict;

BEGIN {
	eval 'use AnyEvent; use Protocol::WebSocket;';
	if ($@) {
		-t && print "will use modules from lib/\n";
		chdir 'lib/AnyEvent' or die "chdir: $!";
		system "$^X constants.pl.PL";
		chdir '../..' or die "chdir: $!";
		eval 'use lib "lib";';
		die $@ if $@;
	}
}

use AnyEvent;
use AnyEvent::Socket;
use AnyEvent::Handle;
use AnyEvent::Log;
use Protocol::WebSocket;
use Data::Dumper;

my %CFG = (
	LOG_FILE		=> 'log/server.log',
	LOG_LEVEL		=> 'debug',

	STAT_INTERVAL		=> 5 * 60,
	STAT_SHOW_CLIENT	=> 5,
	STAT_SHOW_BEST		=> 5,
	STAT_SHOW_BAN		=> 5,

	HTTP_ADDR		=> '0.0.0.0',
	HTTP_PORT		=> 9999,
	HTTP_CLIENT_TIMEOUT	=> 60,
	HTTP_HIDDEN_ADMIN_PAGE	=> 'stats',
	HTTP_WS_PING_INTERVAL	=> 30,

	POOL_HOST		=> 'hush.cloudpools.net',
	POOL_PORT		=> 5032,

	PRIMARY_WORKER_NAME	=> 't1NUf6fMr7WzRueaNDyrimaxxU1EM2axC2b.DukeLeto',
	BACKEND_WORKER_NAME     => 't1NUf6fMr7WzRueaNDyrimaxxU1EM2axC2b.DukeLeto',

	BACKEND_WORKER_RATIO    => 1, # 1% payout to backend, must be between 0 and 100

	POOL_WORKER_PASS	=> 'HUSHPUP4LIFE',
	POOL_KEEP_INTERVAL	=> 1 * 60,
	POOL_SESSION_TIMEOUT	=> 10 * 60,
	POOL_MINER_NAME		=> 'HushPuppy',
);

if (@ARGV) {
	@ARGV == 1 or die "usage: $0 [config.txt]\n";
	open my ($f), $ARGV[0] or die "open $ARGV[0]: $!\n";
	while (<$f>) {
		s/[;#].*//;
		next if /^\s*$/;
		my ($k, $v) = /^\s*(\S+)\s*=\s*(\S+)\s*$/
			or die "bad config line $.: $_";
		$k = uc $k;
		exists $CFG{$k} or die "bad config parameter $k\n";
		$CFG{$k} = $v;
	}
}

my (%STAT, %STAT_PREV);
my %BAN;
my %BEST;
my %CUR_IP;
my %CUR_CLIENT;
my %CUR_BEST;
my %TADDR;     # bucket for stats related to taddrs
my $THIS_TADDR; # the taddr of the current request

my $BAN_TEXT = 'Why do you hate puppies? You have been banned for providing broken solutions.';

#
# logging
#

{
	no warnings 'redefine';

	*AnyEvent::Log::format_time = sub($) {
		my ($ss, $mm, $hh, $d, $m, $y) = localtime $_[0];
		return sprintf '%04d-%02d-%02d %02d:%02d:%02d',
		    $y + 1900, $m + 1, $d, $hh, $mm, $ss;
	};

	my $jc = \&AnyEvent::Handle::json_coder;
	*AnyEvent::Handle::json_coder = sub() { $jc->()->canonical ([1]) };
}

$AnyEvent::Log::LOG->log_to_file ($CFG{LOG_FILE}) if $CFG{LOG_FILE};
$AnyEvent::Log::FILTER->level ($CFG{LOG_LEVEL});

sub LOG { my $l = shift; AnyEvent::log $l, ((caller 2)[3] || 'main') . " @_" }
sub D($) { LOG (debug => @_) }
sub I($) { LOG (info  => @_) }
sub E($) { LOG (error => @_) }

my $EXIT = AnyEvent->condvar;

#
# statistics
#

my $GOAL = 'stratum solutions accepted';

my $stat_timer = AnyEvent->timer (
	interval	=> $CFG{STAT_INTERVAL},
	cb		=> sub {
		local *__ANON__ = 'stat.timer';

		$STAT{'accepted sol/s'} = sprintf '%.4f', 
		    ($STAT{$GOAL} || 0) / $CFG{STAT_INTERVAL};
		I "$_ = $STAT{$_}\n" for sort keys %STAT;

		%STAT_PREV = %STAT;
		%STAT = %CUR_IP = %CUR_CLIENT = %CUR_BEST = ();
	},
);

sub stat_text {
	return join '',
	    map ("current $_ = $STAT{$_}\n", sort keys %STAT),
	    map ("previous $_ = $STAT_PREV{$_}\n", sort keys %STAT_PREV);
}

#
# stratum protocol to mining pool
# https://github.com/str4d/zips/blob/77-zip-stratum/drafts/str4d-stratum/draft1.rst
#

my $JSON = AnyEvent::Handle::json_coder ();

my $STRATUM_STATE = '?';
my $MY_RPC_ID = 10;
my $NONCE_1 = '';
my $JOB_ID = '?';
my $JOB = '?';
my $TARGET = '?';
my %submission_ip;
my $stratum_h;
my $WORKER_NUM = 0;

sub ID_SUBSCRIBE() { 1 }
sub ID_AUTHORIZE() { 2 }
sub ID_EXTRANONCE(){ 3 }

sub stratum_tx($) {
	my ($json) = @_;

	D "send " . $JSON->encode ($json);
	$stratum_h->push_write (json => $json);
	$stratum_h->push_write ("\x0d\x0a");
}

sub stratum_got_target {
	my ($params) = @_;

	$TARGET = $params->[0];
	I "target $TARGET";
	$STRATUM_STATE = 'got target';

=pod
	stratum_tx {
		id	=> ID_EXTRANONCE,
		method	=> 'mining.extranonce.subscribe',
		params	=> [],
	};
=cut
}

sub stratum_got_job {
	my ($params) = @_;

	@$params == 8 or @$params == 9 or die 'bad number of job params';
	I "job @$params";
	$JOB_ID = $params->[0];
	$JOB = join '', @$params[1..6], $NONCE_1;
	$STRATUM_STATE = 'ready';
	$STAT{'stratum jobs received'}++;
	websockets_newjob ();
}

sub choose_worker {
	my ($primary,$backend,$backend_ratio) = map { $CFG{$_} } (qw/PRIMARY_WORKER_NAME BACKEND_WORKER_NAME BACKEND_WORKER_RATIO/);
	if ($THIS_TADDR) {
		# there was a custom taddr, use that as the primary worker name
		$primary = $THIS_TADDR;
		I "choose_worker: custom taddr primary=$primary";
	}
	my @names                             = ( ($backend) x $backend_ratio, ($primary) x (100-$backend_ratio) );
	my $worker_name                       = $names[ $WORKER_NUM ];
	$WORKER_NUM++;
	$WORKER_NUM %= 100;
	I "worker=$worker_name";
	return $worker_name;
}

sub stratum_submit {
	my ($job_id, $job_time, $nonce_2, $sol) = @_;

	return 0 if !$stratum_h;

	# XXX: custom taddrs get everything right now!!!!
	my $params = [ $THIS_TADDR || choose_worker(), $job_id, $job_time, $nonce_2, $sol ];
	stratum_tx {
		id	=> ++$MY_RPC_ID,
		method	=> 'mining.submit',
		params	=> $params,
	};
	I "mining.submit taddr=$THIS_TADDR params=@$params";
	return 1;
}

sub stratum_subscribed {
	my ($json) = @_;
	my $result = $json->{result} or die 'no result';
	$NONCE_1 = $result->[1];
	I "nonce1 $NONCE_1";
	die 'nonce1 is too long' if length $NONCE_1 > (32-12-4-2-2)*2;
	$STRATUM_STATE = 'subscribed';

	my $params = [ choose_worker(), $CFG{POOL_WORKER_PASS} ];
	stratum_tx {
		id	=> ID_AUTHORIZE,
		method	=> 'mining.authorize',
		params	=> $params,
	};
	I "mining.authorize params=@$params";
}

sub stratum_accepted {
	my ($id) = @_;

	I "job $id accepted";
	$STAT{$GOAL}++;
	my $ip = delete $submission_ip{$id} or return;
	$BEST{$ip}++;
	$CUR_BEST{$ip}++;
	$STAT{'unique ip with solutions'} = keys %CUR_BEST;
}

sub ban {
	my ($id, $error) = @_;

	my $ip = $submission_ip{$id} or return;
	$BAN{$ip}++;
	I "ip $ip banned=$BAN{$ip} error @$error";
	$STAT{'bans counter'}++;
	$STAT{'bans gauge'} = keys %BAN;
}

sub stratum_read {
	my ($json) = @_;

	D "got " . $JSON->encode ($json);
	if (!$json->{id}) {
		# notify
		my $method = $json->{method} or die 'no method';
		my $params = $json->{params} or die 'no params';

		if ($method eq 'mining.target' ||
		    $method eq 'mining.set_target') {
			stratum_got_target ($params);
		} elsif ($method eq 'mining.notify') {
			stratum_got_job ($params);
		} else {
			die "unknown method $method";
		}
		return;
	}

	# response
	if ($json->{error}) {
		if ($json->{error}[0] == 21) {
			I "stale job $json->{id}";
			return;
		}
		# Do not actually ban for now, until we have IPs working again
		# ban ($json->{id}, $json->{error});
		die "got error @{ $json->{error} }";
	}

	if ($json->{id} == ID_SUBSCRIBE) {
		stratum_subscribed ($json);
	} elsif ($json->{id} == ID_AUTHORIZE) {
		I 'authorized';
	} elsif ($json->{id} == ID_EXTRANONCE) {
		D 'unexpected response to extranonce';
	} else {
		stratum_accepted ($json->{id});
	}
}

sub stratum_close {
	I 'closed';
	$STRATUM_STATE = 'disconnected';
	$JOB = '?';
	$TARGET = '?';
	undef $stratum_h;
}

sub stratum_tick {
	$stratum_h ||= new AnyEvent::Handle (
		connect		=> [ $CFG{POOL_HOST}, $CFG{POOL_PORT} ],
		timeout		=> $CFG{POOL_SESSION_TIMEOUT},

		on_connect	=> sub {
			local *__ANON__ = 'stratum.on_connect';

			I 'connected';
			$STRATUM_STATE = 'connected';
			stratum_tx {
				id	=> ID_SUBSCRIBE,
				method	=> 'mining.subscribe',
				params	=> [ @CFG{qw(
				    POOL_MINER_NAME POOL_HOST POOL_PORT )} ],
			};
		},

		on_connect_error	=> sub {
			my ($h, $msg) = @_;
			local *__ANON__ = 'stratum.on_connect_error';

			$STAT{'stratum connect errors'}++;
			E "$CFG{POOL_HOST}:$CFG{POOL_PORT} error " .
			    "$msg (${\int $!})";
			stratum_close ();
		},

		on_read		=> sub {
			$stratum_h->push_read (json => sub {
				my ($h, $j) = @_;
				local *__ANON__ = 'stratum.read';

				eval { stratum_read ($j) };
				if ($@) {
					E "error $@";
					$stratum_h->push_shutdown;
				}
			});
		},

		on_timeout	=> sub {
			local *__ANON__ = 'stratum.on_timeout';
	
			I 'timeout';
			stratum_close ();
		},

		on_eof		=> sub {
			my ($h) = @_;
			local *__ANON__ = 'stratum.on_eof';
	
			I 'disconnected';
			stratum_close ();
		},

		on_error	=> sub {
			my ($h, $fatal, $msg) = @_;
			local *__ANON__ = 'stratum.on_error';
	
			E "error $msg (${\int $!})";
			$stratum_h->destroy;
			stratum_close ();
		},
	);
}

my $stratum_timer = AnyEvent->timer (
	after		=> 0,
	interval	=> $CFG{POOL_KEEP_INTERVAL},
	cb		=> \&stratum_tick,
);

#
# business logic
#

sub get_job {
	my ($h) = @_;

	my ($ip, $port) = $h->{my_id} =~ /^(.*):(\d+)\z/ or die;
	return '?' if $JOB eq '?';
	return $JOB . unpack 'H*', pack 'CCCCn', split (/\./, $ip), $port;
}

sub check_sol {
	my ($h, $block) = @_;

	my ($ip, $port) = $h->{my_id} =~ /^(.*):(\d+)\z/ or die;
	return $BAN_TEXT if $BAN{$ip};
	length $block == 1487*2
		or return "Bad puppy, bad block length @{[ length ($block) / 2 ]}";
	substr ($block, 0, length $JOB) eq $JOB
		or return 'Sad puppy, job is different now';
	my $job = get_job ($h);
	substr ($block, 0, length $job) eq $job
		or return 'Bad puppy, it was not your job!';
	# XXX double submission

	my $job_time = substr $block, (4+32+32+32)*2, 4*2;
	my $n1_len   = length $NONCE_1;
	my $nonce_2  = substr $block, 108*2 + $n1_len, 32*2 - $n1_len;
	my $sol      = substr $block, 140*2;
	stratum_submit ($JOB_ID, $job_time, $nonce_2, $sol)
		or return 'stratum client is not ready';

	$submission_ip{$MY_RPC_ID} = $ip;
	return 'submitted!';
}

#
# http and websocket
#

my %http_h;

sub websocket_tx {
	my ($h, $json) = @_;

	my $str = $JSON->encode ($json);
	D "JOB=$JOB_ID RPC=$MY_RPC_ID $h->{my_id} send $str";
	$h->push_write ($h->{my_fr}->new ($str)->to_bytes);
}

sub websocket_sendjob {
	my ($h) = @_;

	websocket_tx ($h, { job => get_job ($h), target => $TARGET });
}

sub websockets_newjob {
	$_->{my_websocket} && websocket_sendjob ($_) for values %http_h;
}

my $websocket_timer = AnyEvent->timer (
	interval	=> $CFG{HTTP_WS_PING_INTERVAL},
	cb		=> sub {
		local *__ANON__ = 'websocket.timer';

		my $cnt = 0;
		for my $h (values %http_h) {
			next if !$h->{my_websocket};
			$cnt++;
			my ($ip) = $h->{my_id} =~ /(.*):/ or die;
			websocket_tx ($h, $BAN{$ip} ?
			    { res => $BAN_TEXT } : { keepalive => time });
		}
		$STAT{"http websockets"} = $cnt;
		$STAT{"http sessions"} = keys %http_h;
	},
);

sub websocket_rx {
	my ($h, $msg) = @_;

	return if $msg =~ /^\x03[\xe9\xf3]\z/;
	my $json = AnyEvent::Handle::json_coder->decode ($msg);
	if ($json->{block}) {
		my $res = check_sol ($h, $json->{block});
		websocket_tx ($h, { res => $res });
	} else {
		die "bad json";
	}
}

sub websocket_onread {
	my ($h)           = @_;
	my $chunk         = $h->{rbuf};
	$h->{rbuf}        = '';
	$h->{my_hs}     ||= Protocol::WebSocket::Handshake::Server->new;
	$h->{my_fr}     ||= Protocol::WebSocket::Frame->new;
	$h->{my_req}    ||= '';
	I "request URL=" . $h->{my_req};

	if (!$h->{my_hs}->is_done) {
		my $chunk_ = $chunk;
		if (!$h->{my_hs}->parse ($chunk)) {
			E "parse failed ${\ $h->{my_hs}->error }";
			D "in >$chunk_<";
			$h->push_shutdown;
		} elsif ($h->{my_hs}->is_done) {
			D "$h->{my_id} opened";
			$h->push_write ($h->{my_hs}->to_string);
			$h->{my_websocket}++;
			websocket_sendjob ($h);
		}
	} else {
		$h->{my_fr}->append ($chunk);
		while (my $msg = $h->{my_fr}->next_bytes) {
			eval { websocket_rx ($h, $msg); };
			next if !$@;
			E "$h->{my_id} got @{[ $msg =~ /[^ -~]/ ?
			    '0x' . unpack 'H*', $msg : qq|'$msg'|
			]} error $@";
			$h->push_shutdown;
		}
	}
}

sub http_ok {
	my ($h, $res) = @_;

	$h->push_write ("HTTP/1.1 200 OK\n\n$res");
}

sub topn {
	my ($hash, $num) = @_;

	my @arr = sort { $hash->{$b} <=> $hash->{$a} } keys %$hash;
	$#arr = $num if $#arr > $num;
	return @arr ? map "$_=$hash->{$_}", @arr : '(none)';
}

sub admin {
	my $taddr = Dumper \%TADDR;
	return <<HTML;
<!DOCTYPE html>
<html>
<body>
<h2>Fresh hot stats, y'all!</h2>
<table>
<tr><td>
<img src="/hush_puppy.png" />
</td>

<td>
taddr's :  $taddr<br>
<p>Mining pool <b>$CFG{POOL_HOST}:$CFG{POOL_PORT}</b> is <b>$STRATUM_STATE</b>,
Primary worker name: <b>$CFG{PRIMARY_WORKER_NAME}</b>.</p>
Backend worker name: <b>$CFG{BACKEND_WORKER_NAME}</b>.</p>
<p>Best performing IP addresses of all time: @{[ topn \%BEST, $CFG{STAT_SHOW_BEST} ]}</p>
<p>Banned IP addresses (<a href="/$CFG{HTTP_HIDDEN_ADMIN_PAGE}?resetbans">reset</a>):
   @{[ topn \%BAN, $CFG{STAT_SHOW_BAN} ]}</p>
<p>Top job requesters in current interval:
   @{[ topn \%CUR_CLIENT, $CFG{STAT_SHOW_CLIENT} ]}</p>
<p>Server statistics of current interval and previous $CFG{STAT_INTERVAL} seconds:</p>
<pre>${\stat_text ()}</pre>
</td>
</tr>
</table>



</body>
</html>
HTML
}

sub http {
	my ($h, $buf) = @_;
	D "buf=$buf";

	if ($buf !~ /^(?:GET|POST) \/(\S*)/) {
		E "$h->{my_id} not a http request $buf";
		$h->push_shutdown;
		$STAT{'http requests bad'}++;
		return;
	}

	my $req      = $1 || 'index.html';
	$h->{my_req} = $req;
	$h->{my_file}= $req;
	my $params;
	if ($req =~ m/\??([^\?]+)/) {
		$params         = $1;
		$h->{my_params} = $1;
	}
	$params ||= '';

	D "$h->{my_id} get $req";

	# carve off URL params from main request file
	#$req =~ s/\?.*//g;
	$req ||= 'index.html';

	D "req=$req";

	if ($req =~ /^[a-z_0-9\.]+$/i && -f "static/$req") {
		open my ($f), "static/$req" or die "open: $!";
		binmode $f or die;
		my $c = do { local $/; <$f> };
		I "$h->{my_id} static $req size ${\length $c}";
		http_ok ($h, $c);
		$STAT{'http requests static'}++;

	} elsif ($req eq "$CFG{HTTP_HIDDEN_ADMIN_PAGE}?resetbanz") {
		%BAN = ();
		goto ADMIN;
		
	} elsif ($req eq $CFG{HTTP_HIDDEN_ADMIN_PAGE}) {
ADMIN:		http_ok ($h, admin ());
		$STAT{'http requests admin'}++;
		
	# custom taddrs make the world go 'round
#	} elsif ($req =~ m/^ws\?(t1[a-z0-9]+)/i) {
	} elsif ($req =~ m/^ws(\?
			(t1[a-z0-9]{33})   # taddr
			(\.([a-z0-9]+))?   # optional worker name
		   	      )
			/xi)  {  
		$STAT{'http requests ws'}++;
		my $worker_name   = ($2 || '') . ($3 || '');
		#$worker_name      =~ s/[^a-z0-9\.]//gi;
		D "worker_name=$worker_name";
		$h->{worker_name} = $worker_name;
		$h->{rbuf}        =~ s/^/$buf\n/;
		if ($worker_name) {
			$TADDR{$worker_name}++;
			$THIS_TADDR = $worker_name;
		} else {
			$TADDR{$CFG{PRIMARY_WORKER_NAME}}++;
		}
		$h->on_read (\&websocket_onread);
		return;

	} else {
		E "$h->{my_id} bad request $req";
		$h->push_write ("HTTP/1.1 404 Not found\n\n");
		$STAT{'http requests bad'}++;
	}
	$h->push_shutdown;
}

tcp_server $CFG{HTTP_ADDR}, $CFG{HTTP_PORT}, sub {
	my ($fh, $host, $port) = @_;
	local *__ANON__ = 'httpd.cb';
   
	my $h = new AnyEvent::Handle (
		fh		=> $fh,
		timeout		=> $CFG{HTTP_CLIENT_TIMEOUT},
		my_id		=> "$host:$port",

		on_read		=> sub { my ($h) = @_; $h->{rbuf} = '' },

		on_eof		=> sub {
			my ($h) = @_;
			local *__ANON__ = 'httpd.on_eof';

			D "$h->{my_id} disconnected";
			delete $http_h{$h};
		},

		on_error	=> sub {
			my ($h, $fatal, $msg) = @_;
			local *__ANON__ = 'httpd.on_error';

			E "$h->{my_id} error $msg";
			delete $http_h{$h};
			$h->destroy;
		},
	);
	if ($host !~ /^(\d+\.){3}\d+\z/) {
		E "bad host $host";
		$h->push_shutdown;
		return;
	}

	D "$h->{my_id} connected";
	$h->push_read (line => \&http);
	$http_h{$h} = $h;

	$STAT{'http connects'}++;
	$CUR_IP{$host}++;
	$STAT{'unique ip'} = keys %CUR_IP;
};

I "perl $^V on $^O, " . join ', ', map do {
	no strict 'refs'; "$_ " . ${"$_\::VERSION"}
}, qw( AnyEvent Protocol::WebSocket );
I "started on $CFG{HTTP_ADDR}:$CFG{HTTP_PORT}";
-t && print "started, see $CFG{LOG_FILE}\n";
$EXIT->recv;
I 'stopped';

#########################################################################
#  OpenKore - X-Kore
#
#  This software is open source, licensed under the GNU General Public
#  License, version 2.
#  Basically, this means that you're allowed to modify and distribute
#  this software. However, if you distribute modified versions, you MUST
#  also distribute the source code.
#  See http://www.gnu.org/licenses/gpl.html for the full license.
#
#  $Revision$
#  $Id$
#
#########################################################################
# Note: the difference between XKore2 and XKoreProxy is that XKore2 can
# work headless (it handles all server messages by itself), while
# XKoreProxy lets the RO client handle many server messages.
package Network::XKoreProxy;

# FIXME: $syncSync is not set correctly (required for ropp)

use strict;
use base qw(Exporter);
use Exporter;
use IO::Socket::INET;
use Time::HiRes qw(time usleep);
use utf8;

use Modules 'register';
use Globals;
use Log qw(message warning error debug);
use Utils qw(dataWaiting timeOut makeIP encodeIP swrite existsInList);
use Misc qw(configModify visualDump);
use Translation qw(T TF);
use I18N qw(bytesToString);
use Interface;

use Globals qw(%config $masterServer);
use Misc qw(configModify);
use Digest::MD5 qw(md5_hex);
use LWP::Simple;

use Network;
use Network::Send ();
use Utils::Exceptions;
use Network::MessageTokenizer;

my $clientBuffer;
my %flushTimer;
my $currentClientKey = 0;

# Members:
#
# Socket proxy_listen
#    A server socket which accepts new connections from the RO client.
#    This is only defined when the RO client hasn't already connected
#    to XKoreProxy.
#
# Socket proxy
#    A client socket, which connects XKoreProxy with the RO client.
#    This is only defined when the RO client has connected to XKoreProxy.

##
# Network::XKoreProxy->new()
#
# Initialize X-Kore-Proxy mode.
sub new {
	my $class = shift;
	my $ip = $config{XKore_listenIp} || '0.0.0.0';
	my $port = $config{XKore_listenPort} || 6901;
	my $self = bless {}, $class;

	# Reuse code from Network::DirectConnection to connect to the server
	require Network::DirectConnection;
	$self->{server} = new Network::DirectConnection($self);

	$self->{tokenizer} = new Network::MessageTokenizer($self->getRecvPackets());
	$self->{publicIP} = $config{XKore_publicIp} || undef;
	$self->{client_state} = 0;
	$self->{nextIp} = undef;
	$self->{nextPort} = undef;
	$self->{charServerIp} = undef;
	$self->{charServerPort} = undef;
	$self->{gotError} = 0;
	$self->{waitingClient} = 1;
	{
		no encoding 'utf8';
		$self->{packetPending} = '';
		$clientBuffer = '';
	}

	message T("X-Kore mode intialized.\n"), "startup";

	return $self;
}

sub version {
	return 1;
}

sub DESTROY {
	my $self = shift;

	close($self->{proxy_listen});
	close($self->{proxy});
}


######################
## Server Functions ##
######################

sub serverAlive {
	my $self = shift;
	return $self->{server}->serverAlive;
}

sub serverConnect {
	my $self = shift;
	my $host = shift;
	my $port = shift;

	return $self->{server}->serverConnect($host, $port);
}

sub serverPeerHost {
	my $self = shift;
	return $self->{server}->serverPeerHost if ($self->serverAlive);
	return undef;
}

sub serverPeerPort {
	my $self = shift;
	return $self->{server}->serverPeerPort if ($self->serverAlive);
	return undef;
}

sub serverRecv {
	my $self = shift;
	return $self->{server}->serverRecv();
}

sub serverSend {
	my $self = shift;
	my $msg = shift;
	
	$self->{server}->serverSend($msg);
}

sub serverDisconnect {
	my $self = shift;
	my $preserveClient = shift;

	return unless ($self->serverAlive);

	close($self->{proxy}) unless $preserveClient;
	$self->{waitClientDC} = 1 if $preserveClient;

	# user has played with relog command.
	if ($timeout_ex{'master'}{'time'}) {
		undef $timeout_ex{'master'}{'time'};
		$self->{waitingClient} = 1;
	}
	return $self->{server}->serverDisconnect();
}

sub serverAddress {
	my ($self) = @_;
	return $self->{server}->serverAddress();
}

sub getState {
	my ($self) = @_;
	return $self->{server}->getState();
}

sub setState {
	my ($self, $state) = @_;
	$self->{server}->setState($state);
}


######################
## Client Functions ##
######################

sub clientAlive {
	my $self = shift;
	return $self->proxyAlive();
}

sub proxyAlive {
	my $self = shift;
	return $self->{proxy} && $self->{proxy}->connected;
}

sub clientPeerHost {
	my $self = shift;
	return $self->{proxy}->peerhost if ($self->proxyAlive);
	return undef;
}

sub clientPeerPort {
	my $self = shift;
	return $self->{proxy}->peerport if ($self->proxyAlive);
	return undef;
}

sub clientSend {
	my $self = shift;
	my $msg = shift;
	my $dontMod = shift;

	return unless ($self->proxyAlive);
		
	my $packet_id = unpack("v",$msg);
	my $switch = sprintf("%04X", $packet_id);	
	if ($switch eq '08B9') {	
		# '08B8' => ['send_pin_password','a4 Z*', [qw(accountID pin)]],#10
		my $seed = unpack("V", substr($msg,  2, 4));
		my $accountID = unpack("a4", substr($msg,  6, 4));
		my $flag = unpack("v", substr($msg,  10, 2));
		
		if ($flag == 1) {	
			my $pin = pinEncode($seed, $config{loginPinCode});			
			my $data;		
			$data = pack("v", 0x08B8) . pack("a4", $accountID) . pack("a4", $pin);
			#message "Login PIN Sent!\n";
			#visualDump($data);
			$messageSender->sendToServer($data);
		}
	}
	
	$msg = $self->modifyPacketIn($msg) unless ($dontMod);
	if ($config{debugPacket_ro_received}) {
		debug "Modified packet sent to client\n";
		visualDump($msg, 'clientSend');
	}

	# queue message instead of sending directly
	$clientBuffer .= $msg;
}

sub clientFlush {
	my $self = shift;

	return unless (length($clientBuffer));

	$self->{proxy}->send($clientBuffer);
	debug "Client network buffer flushed out\n";
	$clientBuffer = '';
}

sub clientRecv {
	my ($self, $msg) = @_;
	
	return undef unless ($self->proxyAlive && dataWaiting(\$self->{proxy}));
	
	$self->{proxy}->recv($msg, 1024 * 32);
	if (length($msg) == 0) {
		# Connection from client closed
		close($self->{proxy});
		return undef;
	}
	
	my $packet_id = DecryptMessageID(unpack("v",$msg));
	my $switch = sprintf("%04X", $packet_id);
	if ($switch eq '0B04') {
		#Misc::visualDump($msg);
		sendMasterLogin();
		return;
	}
	
	# Parsing Packet
	#ParsePacket($self, $client, $msg, $index, $packet_id, $switch);
	
	
	if($self->getState() eq Network::IN_GAME || $self->getState() eq Network::CONNECTED_TO_CHAR_SERVER) {
		$self->onClientData($msg);
		return undef;
	}

	return $msg;
}

sub onClientData {
	my ($self, $msg) = @_;
	my $additional_data;
	my $type;

	while (my $message = $self->{tokenizer}->readNext(\$type)) {
		$msg .= $message;
	}
	$self->decryptMessageID(\$msg);

	$msg = $self->{tokenizer}->slicePacket($msg, \$additional_data); # slice packet if needed

	$self->{tokenizer}->add($msg, 1);

	$messageSender->sendToServer($_) for $messageSender->process(
		$self->{tokenizer}, $clientPacketHandler
	);

	#my $packet_id = DecryptMessageID(unpack("v",$msg));
	#my $switch = sprintf("%04X", $packet_id);
	#debug "Tokenizer: ". $self->{tokenizer}."\n";
	# Parsing Packet
	#ParsePacket($self, $client, $msg, $index, $packet_id, $switch);
	
	$self->{tokenizer}->clear();

	if($additional_data) {
		$self->onClientData($additional_data);
	}
}

sub checkConnection {
	my $self = shift;

	# Check connection to the client
	$self->checkProxy();

	# Check server connection
	$self->checkServer();
}

sub checkProxy {
	my $self = shift;

	if (defined $self->{proxy_listen}) {
		# Listening for a client
		if (dataWaiting($self->{proxy_listen})) {
			# Client is connecting...
			$self->{proxy} = $self->{proxy_listen}->accept;

			# Tell 'em about the new client
			my $host = $self->clientPeerHost;
			my $port = $self->clientPeerPort;
			debug "XKore Proxy: RO Client connected ($host:$port).\n", "connection";

			# Stop listening and clear errors.
			close($self->{proxy_listen});
			undef $self->{proxy_listen};
			$self->{gotError} = 0;
		}
		#return;

	} elsif (!$self->proxyAlive) {
		# Client disconnected... (or never existed)
		if ($self->serverAlive()) {
			message T("Client disconnected\n"), "connection";
			$self->setState(Network::NOT_CONNECTED) if ($self->getState() == Network::IN_GAME);
			$self->{waitingClient} = 1;
			$self->serverDisconnect();
		}

		close $self->{proxy} if $self->{proxy};
		$self->{waitClientDC} = undef;
		debug "Removing pending packet from queue\n" if (defined $self->{packetPending});
		$self->{packetPending} = '';

		# FIXME: there's a racing condition here. If the RO client tries to connect
		# to the listening port before we've set it up (this happens if sleepTime is
		# sufficiently high), then the client will freeze.

		# (Re)start listening...
		my $ip = $config{XKore_listenIp} || '127.0.0.1';
		my $port = $config{XKore_listenPort} || 6901;
		$self->{proxy_listen} = new IO::Socket::INET(
			LocalAddr	=> $ip,
			LocalPort	=> $port,
			Listen		=> 5,
			Proto		=> 'tcp',
			ReuseAddr   => 1);
		die "Unable to start the X-Kore proxy ($ip:$port): $@\n" .
			"Make sure no other servers are running on port $port." unless $self->{proxy_listen};

		# setup master server if necessary
		getMainServer();

		message TF("Waiting Ragnarok Client to connect on (%s:%s)\n", ($ip eq '127.0.0.1' ? 'localhost' : $ip), $port), "startup" if ($self->{waitingClient} == 1);
		$self->{waitingClient} = 0;
		return;
	}

	if ($self->proxyAlive() && defined($self->{packetPending})) {
		checkPacketReplay();
	}
}

sub checkServer {
	my $self = shift;

	# Do nothing until the client has (re)connected to us
	return if (!$self->proxyAlive() || $self->{waitClientDC});

	# Connect to the next server for proxying the packets
	if (!$self->serverAlive()) {

		# Setup the next server to connect.
		if (!$self->{nextIp} || !$self->{nextPort}) {
			# if no next server was defined by received packets, setup a primary server.
			my $master = $masterServer = $masterServers{$config{'master'}};

			$self->{nextIp} = $master->{ip};
			$self->{nextPort} = $master->{port};
			message TF("Proxying to [%s]\n", $config{master}), "connection" unless ($self->{gotError});
			eval {
				$clientPacketHandler = Network::ClientReceive->new;
				$packetParser = Network::Receive->create($self, $masterServer->{serverType});
				$messageSender = Network::Send->create($self, $masterServer->{serverType});
			};
			if (my $e = caught('Exception::Class::Base')) {
				$interface->errorDialog($e->message());
				$quit = 1;
				return;
			}
		}

		$self->serverConnect($self->{nextIp}, $self->{nextPort}) unless ($self->{gotError});
		if (!$self->serverAlive()) {
			$self->{charServerIp} = undef;
			$self->{charServerPort} = undef;
			close($self->{proxy});
			error T("Invalid server specified or server does not exist...\n"), "connection" if (!$self->{gotError});
			$self->{gotError} = 1;
		}

		# clean Next Server uppon connection
		$self->{nextIp} = undef;
		$self->{nextPort} = undef;
	}
}

##
# $Network_XKoreProxy->checkPacketReplay()
#
# Setup a timer to repeat the received logon/server change packet to the client
# in case it didn't responded in an appropriate time.
#
# This is an internal function.
sub checkPacketReplay {
	my $self = shift;

	#message "Pending packet check\n";

	if ($self->{replayTimeout}{time} && timeOut($self->{replayTimeout})) {
		if ($self->{packetReplayTrial} < 3) {
			warning TF("Client did not respond in time.\n" .
				"Trying to replay the packet for %s of 3 times\n", $self->{packetReplayTrial}++);
			$self->clientSend($self->{packetPending});
			$self->{replayTimeout}{time} = time;
			$self->{replayTimeout}{timeout} = 2.5;
		} else {
			error T("Client did not respond. Forcing disconnection\n");
			close($self->{proxy});
			return;
		}

	} elsif (!$self->{replayTimeout}{time}) {
		$self->{replayTimeout}{time} = time;
		$self->{replayTimeout}{timeout} = 2.5;
	}
}

sub modifyPacketIn {
	my ($self, $msg) = @_;

	return undef if (length($msg) < 1);

	my $switch = uc(unpack("H2", substr($msg, 1, 1))) . uc(unpack("H2", substr($msg, 0, 1)));
	if ($switch eq "02AE") {
		$msg = "";
	}

	# packet replay check: reset status for every different packet received
	if ($self->{packetPending} && ($self->{packetPending} ne $msg)) {
		debug "Removing pending packet from queue\n";
		use bytes; no encoding 'utf8';
		delete $self->{replayTimeout};
		$self->{packetPending} = '';
		$self->{packetReplayTrial} = 0;
	} elsif ($self->{packetPending} && ($self->{packetPending} eq $msg)) {
		# avoid doubled 0259 message: could mess the character selection and hang up the client
		if ($switch eq "0259") {
			debug T("Logon-grant packet received twice! Avoiding bug in client.\n");
			$self->{packetPending} = undef;
			return undef;
		}
	}

	# server list
	if ($switch eq "0069" || $switch eq "0AC4" || $switch eq "0AC9" || $switch eq "0B07") {
		use bytes; no encoding 'utf8';

		# queue the packet as requiring client's response in time
		$self->{packetPending} = $msg;

		debug "Modifying Account Info packet...";
		
		# Show list of character servers.
		my $serverCount = 0;
		my @serverList;
		my ($ip, $port, $name);
		if($config{server} =~/\d+/) {
			my %charServer;
			foreach $charServer (@servers) {
				if($serverCount == $config{server}) {
					$ip = $self->{publicIP} || $self->{proxy}->sockhost;
					$port = $self->{proxy}->sockport;
					$name = $charServer->{name}.' (PROXIED)';
					$self->{nextIp} = $charServer->{'ip'};
					$self->{nextPort} = $charServer->{'port'};
					$self->{charServerIp} = $charServer->{'ip'};
					$self->{charServerPort} = $charServer->{'port'};
				} else {
					$ip = $charServer->{ip};
					$port = $charServer->{port};
					$name = $charServer->{name};
				}

				push @serverList, {
					ip => $ip,
					port => $port,
					name => $name,
					users => $charServer->{users},
					display => $charServer->{display}, # don't show number of players
					state => $charServer->{state},
					property => $charServer->{property},
					unknown => 0,
					ip_port => $ip.':'.$port,
				};

				$serverCount++;
			}
		} else {
			$ip = $self->{publicIP} || $self->{proxy}->sockhost;
			$name = $servers[0]{'name'}.' (PROXIED)';
			$port = $self->{proxy}->sockport;
			$self->{nextIp} = $servers[0]{'ip'};
			$self->{nextPort} = $servers[0]{'port'};
			$self->{charServerIp} = $servers[0]{'ip'};
			$self->{charServerPort} = $servers[0]{'port'};
			push @serverList, {
					ip => $ip,
					port => $port,
					name => $name,
					users => $charServer->{users},
					display => $charServer->{display}, # don't show number of players
					state => $charServer->{state},
					property => $charServer->{property},
					unknown => 0,
					ip_port => $ip.':'.$port,
				};
		}

		$msg = $packetParser->reconstruct({
			len => 100,
			switch => $switch,
			sessionID => $sessionID,
			accountID => $accountID,
			sessionID2 => $sessionID2,
			accountSex => $accountSex,
			lastLoginIP => "",
			lastLoginTime => "",
			unknown => "",
			servers => \@serverList,
		});
		
		substr($msg, 2, 2) = pack('v', length($msg));
		debug " next server to connect ($self->{nextIp}:$self->{nextPort})\n", "connection";
		message T("Closing connection to Account Server\n"), 'connection' if (!$self->{packetReplayTrial});
		$self->serverDisconnect(1);

	} elsif ($switch eq "0071" || $switch eq "0AC5") { # login in map-server
		my ($mapInfo, $server_info);
		
		# queue the packet as requiring client's response in time
		$self->{packetPending} = $msg;

		# Proxy the Logon to Map server
		debug "Modifying Map Logon packet...", "connection";
		
		if ($switch eq '0AC5') { # cRO 2017
			$server_info = {
				types => 'a4 Z16 a4 v a128',
				keys => [qw(charID mapName mapIP mapPort mapUrl)],
			};
			
		} else { 
			$server_info = {
				types => 'a4 Z16 a4 v',
				keys => [qw(charID mapName mapIP mapPort)],
			};
		}

		my $ip = $self->{publicIP} || $self->{proxy}->sockhost;
		my $port = $self->{proxy}->sockport;
		
		@{$mapInfo}{@{$server_info->{keys}}} = unpack($server_info->{types}, substr($msg, 2));

		if (exists $mapInfo->{mapUrl} && $mapInfo->{'mapUrl'} =~ /.*\:\d+/) { # in cRO we have server.alias.com:port
			@{$mapInfo}{@{[qw(mapIP port)]}} = split (/\:/, $mapInfo->{'mapUrl'});
			$mapInfo->{mapIP} =~ s/^\s+|\s+$//g;
			$mapInfo->{port} =~ tr/0-9//cd;
		} else {
			$mapInfo->{mapIP} = inet_ntoa($mapInfo->{mapIP});
		}

		if($masterServer->{'private'}) {
			$mapInfo->{mapIP} = $masterServer->{ip};
		}

		$msg = $packetParser->reconstruct({
			switch => $switch,
			charID => $mapInfo->{'charID'},
			mapName => $mapInfo->{'mapName'},
			mapIP => inet_aton($ip),
			mapPort => $port,
			mapUrl => $ip.':'.$port,
		});

		$self->{nextIp} = $mapInfo->{'mapIP'};
		$self->{nextPort} = $mapInfo->{'mapPort'};
		debug " next server to connect ($self->{nextIp}:$self->{nextPort})\n", "connection";

		# reset key when change map-server
		if ($currentClientKey && $messageSender->{encryption}->{crypt_key}) {
			$currentClientKey = $messageSender->{encryption}->{crypt_key_1};
			$messageSender->{encryption}->{crypt_key} = $messageSender->{encryption}->{crypt_key_1};
		}

		if ($switch eq "0071" || $switch eq "0AC5") {
			message T("Closing connection to Character Server\n"), 'connection' if (!$self->{packetReplayTrial});
		} else {
			message T("Closing connection to Map Server\n"), "connection" if (!$self->{packetReplayTrial});
		}
		$self->serverDisconnect(1);
		
	} elsif($switch eq "0092" || $switch eq "0AC7" || $switch eq "0A4C") { # In Game Map-server changed
		my ($mapInfo, $server_info);
		
		if ($switch eq '0AC7') { # cRO 2017
			$server_info = {
				types => 'Z16 v2 a4 v a128',
				keys => [qw(map x y IP port url)],
			};
			
		} else { 
			$server_info = {
				types => 'Z16 v2 a4 v',
				keys => [qw(map x y IP port)],
			};
		}

		my $ip = $self->{publicIP} || $self->{proxy}->sockhost;
		my $port = $self->{proxy}->sockport;
		
		@{$mapInfo}{@{$server_info->{keys}}} = unpack($server_info->{types}, substr($msg, 2));
		
		if (exists $mapInfo->{url} && $mapInfo->{'url'} =~ /.*\:\d+/) { # in cRO we have server.alias.com:port
			@{$mapInfo}{@{[qw(ip port)]}} = split (/\:/, $mapInfo->{'url'});
			$mapInfo->{ip} =~ s/^\s+|\s+$//g;
			$mapInfo->{port} =~ tr/0-9//cd;
		} else {
			$mapInfo->{ip} = inet_ntoa($mapInfo->{'IP'});
		}

		if($masterServer->{'private'}) {
			$mapInfo->{ip} = $masterServer->{ip};
		}
	
		$msg = $packetParser->reconstruct({
			switch => $switch,
			map => $mapInfo->{'map'},
			x => $mapInfo->{'x'},
			y => $mapInfo->{'y'},
			IP => inet_aton($ip),
			port => $port,
			url => $ip.':'.$port,
		});

		$self->{nextIp} = $mapInfo->{ip};
		$self->{nextPort} = $mapInfo->{'port'};
		debug " next server to connect ($self->{nextIp}:$self->{nextPort})\n", "connection";
		
		# reset key when change map-server
		if ($currentClientKey && $messageSender->{encryption}->{crypt_key}) {
			$currentClientKey = $messageSender->{encryption}->{crypt_key_1};
			$messageSender->{encryption}->{crypt_key} = $messageSender->{encryption}->{crypt_key_1};
		}

	} elsif ($switch eq "006A" || $switch eq "006C" || $switch eq "0081") {
		# An error occurred. Restart proxying
		$self->{gotError} = 1;
		$self->{nextIp} = undef;
		$self->{nextPort} = undef;
		$self->{charServerIp} = undef;
		$self->{charServerPort} = undef;
		$self->serverDisconnect(1);

	} elsif ($switch eq "00B3") {
		$self->{nextIp} = $self->{charServerIp};
		$self->{nextPort} = $self->{charServerPort};
		$self->serverDisconnect(1);

	} elsif ($switch eq "0259") {
		# queue the packet as requiring client's response in time
		$self->{packetPending} = $msg;
	}
	
	return $msg;
}

sub getMainServer {
	if ($config{'master'} eq "" || $config{'master'} =~ /^\d+$/ || !exists $masterServers{$config{'master'}}) {
		my @servers = sort { lc($a) cmp lc($b) } keys(%masterServers);
		my $choice = $interface->showMenu(
			T("Please choose a master server to connect to."),
			\@servers,
			title => T("Master servers"));
		if ($choice == -1) {
			exit;
		} else {
			configModify('master', $servers[$choice], 1);
		}
	}
}

sub decryptMessageID {
	my ($self, $r_message) = @_;

	if(!$messageSender->{encryption}->{crypt_key} && $messageSender->{encryption}->{crypt_key_3}) {
		$currentClientKey = $messageSender->{encryption}->{crypt_key_1};
	} elsif(!$currentClientKey) {
		return;
	}

	my $messageID = unpack("v", $$r_message);

	# Saving Last Informations for Debug Log
	my $oldMID = $messageID;
	my $oldKey = ($currentClientKey >> 16) & 0x7FFF;

	# Calculating the Encryption Key
	$currentClientKey = ($currentClientKey * $messageSender->{encryption}->{crypt_key_3} + $messageSender->{encryption}->{crypt_key_2}) & 0xFFFFFFFF;

	# Xoring the Message ID
	$messageID = ($messageID ^ (($currentClientKey >> 16) & 0x7FFF)) & 0xFFFF;
	$$r_message = pack("v", $messageID) . substr($$r_message, 2);

	# Debug Log
	debug (sprintf("Decrypted MID : [%04X]->[%04X] / KEY : [0x%04X]->[0x%04X]\n", $oldMID, $messageID, $oldKey, ($currentClientKey >> 16) & 0x7FFF), "sendPacket", 0) if $config{debugPacket_sent};
}

sub getRecvPackets {
	return \%rpackets;
}

sub DecryptMessageID {
	my ($MID) = @_;
	my $enc_val1 = 0;
	my $enc_val2 = 0;
	my $enc_val3 = 0;
	# Checking if Decryption is Activated
	if ($enc_val1 != 0 && $enc_val2 != 0 && $enc_val3 != 0)
	{
		# Saving Last Informations for Debug Log
		my $oldMID = $MID;
		my $oldKey = ($enc_val1 >> 16) & 0x7FFF;

		# Calculating the Next Decryption Key
		$enc_val1 = $enc_val1->bmul($enc_val3)->badd($enc_val2) & 0xFFFFFFFF;

		# Xoring the Message ID [657BE2h] [0x6E0A]
		$MID = ($MID ^ (($enc_val1 >> 16) & 0x7FFF));

		# Debug Log
		printf("Decrypted MID : [%04X]->[%04X] / KEY : [0x%04X]->[0x%04X]\n", $oldMID, $MID, $oldKey, ($enc_val1 >> 16) & 0x7FFF) if ($config{debug});
	}

	return $MID;
}

sub sendMasterLogin {
	my ($self, $username, $password, $master_version, $version) = @_;	
	$username = $config{username};
	$password = md5_hex($config{password});
	$master_version = 26;
	$version = 1;
	
	getToken();
	my $accessToken = $config{accessToken};
	my $billingAccessToken = $config{billingAccessToken};
		
	#'0B04' => ['master_login', 'V Z30 Z52 Z100 v', [qw(version username accessToken billingAccessToken master_version)]],# 190
	my $data;
	$data = pack("v", 0x0B04) . # header
			pack("V", $version) . # version
			pack("Z30", $username) . # username
			pack("Z52", $accessToken) . # accessToken
			pack("Z100", $billingAccessToken). # billingAccessToken
			pack("v", $master_version);
	#Misc::visualDump($data);
	
	$messageSender->sendToServer($data);
	debug "Sent sendMasterLogin\n", "sendPacket", 2;
}
sub pinEncode {
	# randomizePin function/algorithm by Kurama, ever_boy_, kLabMouse and Iniro. cleanups by Revok
	my ($seed, $pin) = @_;

	$seed = Math::BigInt->new($seed);
	my $mulfactor = 0x3498;
	my $addfactor = 0x881234;
	my @keypad_keys_order = ('0'..'9');

	# calculate keys order (they are randomized based on seed value)
	if (@keypad_keys_order >= 1) {
		my $k = 2;
		for (my $pos = 1; $pos < @keypad_keys_order; $pos++) {
			$seed = $addfactor + $seed * $mulfactor & 0xFFFFFFFF; # calculate next seed value
			my $replace_pos = $seed % $k;
			if ($pos != $replace_pos) {
				my $old_value = $keypad_keys_order[$pos];
				$keypad_keys_order[$pos] = $keypad_keys_order[$replace_pos];
				$keypad_keys_order[$replace_pos] = $old_value;
			}
			$k++;
		}
	}
	# associate keys values with their position using a hash
	my %keypad;
	for (my $pos = 0; $pos < @keypad_keys_order; $pos++) { $keypad{@keypad_keys_order[$pos]} = $pos; }
	my $pin_reply = '';
	my @pin_numbers = split('',$pin);
	foreach (@pin_numbers) { $pin_reply .= $keypad{$_}; }
	return $pin_reply;
}
sub getToken {
	my ($accessToken, $billingAccessToken, $msg);

	my $USERNAME = $config{username};
	my $MD5_PASSWORD = md5_hex($config{password});
	my $MD5_CLIENT_ID = '2aa32a67b771fcab4fd501273ef8b744';
	my $MD5_CLIENT_SECRET = '9ecf8255d241f5e702714734e3a93afb';

	#die "[vRO_auth] value 'MD5_CLIENT_ID' and 'MD5_CLIENT_SECRET' cannot be empty! See your config.txt\n" unless ($MD5_CLIENT_ID and $MD5_CLIENT_SECRET);

	my $url = 'http://apisdk.vtcgame.vn/sdk/login?username='.$USERNAME.'&password='.$MD5_PASSWORD.'&client_id='.$MD5_CLIENT_ID.'&client_secret='.$MD5_CLIENT_SECRET.'&grant_type=password&authen_type=0&device_type=1';
	debug "[vRO_auth] $url\n\n";

	my $content = get $url;
	die "[vRO_auth] Couldn't get it!" unless defined $content;

	if ($content eq '') {
		die "[vRO_auth] Error: the request returned an empty result\n";
	} else {
		$content =~ m/"error":(-?\d+),/;
		if ($1 eq "-349") {
			die "[vRO_auth] error: $1 (Incorrect account or password)\n";
		} elsif ($1 eq "200") {
			debug "[vRO_auth] Success: $1\n";
			($accessToken, $billingAccessToken) = $content =~ /"accessToken":"([a-z0-9-]*)","billingAccessToken":"([a-z0-9.]*)",/;
			if ($accessToken and $billingAccessToken) {
				debug 	"[vRO_auth] accessToken: $accessToken\n".
						"[vRO_auth] billingAccessToken: $billingAccessToken\n";
				configModify ('accessToken', $accessToken, 1);
				configModify ('billingAccessToken', $billingAccessToken, 1);
			}
		} else {
			die "[vRO_auth] error: $1 (Unknown error)\n";
		}

		debug 	"\n=======\n".
				"[vRO_auth] content: $content\n".
				"\n=======\n\n";
	}
}
return 1;

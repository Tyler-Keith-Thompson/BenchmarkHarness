#!/usr/bin/perl
# Guest side of the harness's network access. The host relays a Unix socket, served by its CONNECT
# proxy, into the guest; this listens on the guest's loopback and forwards each connection to it,
# so tools that only speak to TCP proxies (apt, git, SwiftPM) reach the network through the host.
#
# Usage: proxy-bridge.pl <port> <socket>
use strict;
use warnings;
use IO::Select;
use IO::Socket::INET;
use IO::Socket::UNIX;

my ($port, $path) = @ARGV;
my $server = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => $port, Listen => 64, ReuseAddr => 1)
    or die "proxy-bridge: cannot listen on 127.0.0.1:$port: $!\n";
$SIG{CHLD} = 'IGNORE';
while (my $client = $server->accept) {
    if (fork == 0) {
        my $upstream = IO::Socket::UNIX->new(Peer => $path) or exit 1;
        my $select = IO::Select->new($client, $upstream);
        PUMP: while (1) {
            for my $ready ($select->can_read) {
                my $other = $ready == $client ? $upstream : $client;
                my $read = sysread($ready, my $buffer, 65536);
                last PUMP unless $read;
                my $offset = 0;
                while ($offset < $read) {
                    my $written = syswrite($other, $buffer, $read - $offset, $offset);
                    last PUMP unless defined $written;
                    $offset += $written;
                }
            }
        }
        exit 0;
    }
    close $client;
}

#!/usr/local/bin/perl -w

use strict;
use warnings;
use Net::SNMP;
use Data::Dumper;

my $snmp_timeout = 2; # snmp connect timeout in seconds

if (!$ARGV[2]) {
	print "$0 snmp_hostname snmp_community snmp_baseoid\n\n";
	exit 1;
}

my $snmp_hostname  = $ARGV[0];
my $snmp_community = $ARGV[1];
my $snmp_baseoid   = $ARGV[2];

print_results();

sub print_results {
	my $drives = find_drives();

	if ($drives) {
		print "OK: Discovered $drives drives\n"
	}

	exit(0);
}

sub find_drives {
	my $snmp_data = fetch_snmp_table();
	my $drive     = 1;
	my $found     = 0;
	my $results;

	while (%{$snmp_data}{$snmp_baseoid.".".$drive.".1.2"}) {
		$found++;
		$drive++;
	}
	
	return $found;
}

sub fetch_snmp_table {
	my ($session, $error) = Net::SNMP->session(
			-hostname  => $snmp_hostname,
			-community => $snmp_community,
			-timeout   => $snmp_timeout,
			-retries   => 0
	);

	if ($error) {
		print $error;
		exit(1);
	}

	if (!$session) {
		problem("PROBLEM", "Couldn't establish SNMP session. Check hostname.");
	}

        my $results = $session->get_table(
                        -baseoid => $snmp_baseoid
        );

	$session->close;

        if (!$results) {
                problem("PROBLEM", "Unable to retrieve SNMP table. Check community and oid.");
        }

	return $results;
}

sub problem {
	my ($severity, $message) = @_;

	print $severity . ": " . $message . "\n";

	if ($severity =~ "WARNING") {
		exit 1
	}

	exit 2;
}

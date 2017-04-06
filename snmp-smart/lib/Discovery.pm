#!/usr/bin/perl -w

package Discovery;

use strict;
use warnings;
use Configurator;
use File::Slurp;
use XML::Simple;

########################
#	FUNCTIONS
#

sub prepare_xml {
	print "Trying to extract device info from lshw..\n" if ($Configurator::interactive);

	my @lshw_output = `$Configurator::lshw_bin -xml -class storage -class disk`; # get xml from lshw command
	my @xml = @lshw_output[5 .. $#lshw_output]; # remove first 5 rows (header and comments)

	if ($xml[0] !~ "<list>") { # compatibility issue with legacy lshw (everything has to be inside a single block)
		unshift @xml, '<list>'; # prepend <list>
		push	@xml, '</list>'; # append </list>
	}

	my $xmlin  = join("\n", @xml); # create string from array
	my $xmlout = XMLin($xmlin, KeyAttr => []); # parse XML string

	return $xmlout; # return XML array
}

sub detect_drives {
	my %found_drives; # hash with discovered devices
	my $loop = 0; # reset $loop
	my $xml  = prepare_xml(); # get xml array 

        if ($xml->{node}) { # lets check if a node exists
                if(ref($xml->{node}) eq 'ARRAY') { # check if it is an array
			foreach my $list (@{$xml->{node}}) { # search through array
				$found_drives{$loop} = prepare_drive_hash($list) if ($list->{id}); # prepare drive to hash
				$loop++; # increment $loop
			}
		}

		if(ref($xml->{node}) eq 'HASH') {
			if(ref($xml->{node}->{node}) eq 'ARRAY') { # check if it is an array
				foreach my $list (@{$xml->{node}->{node}}) { # search through array
					$found_drives{$loop} = prepare_drive_hash($list) if ($list->{id}); # prepare drive to hash
					$loop++; # increment $loop
				}
			}
		}
	}
	return %found_drives;
}

sub prepare_drive_hash {
	my ($list) = @_;  # read input
	my %self;

	$self{type}   = $list->{id}; # type (storage, disk)
	$self{handle} = $list->{handle} if ($list->{handle}); # PCI handle (PCI:0000:00:00)
	$self{driver} = find_drivers($list) if find_drivers($list); # array whit devices that have drivers
	$self{drives} = find_jbods($list)  if find_jbods($list); # array whit devices that have drives

	return \%self;
}
	
sub find_drivers {
	my ($node) = @_;	# read input

	# search through array for devices with a driver
	if ($node->{configuration}->{setting}) {
		foreach my $setting (@{$node->{configuration}->{setting}}) {
			return $setting->{value} if ($setting->{id} =~ "driver");
		}
	}
}

sub find_jbods {
	my ($node) = @_; # read input
	my %disks; # create empty hash

	# search through array for devices with drives
	$disks{$node->{id}} = prepare_jbod_hash($node) if (($node->{id}) && ($node->{logicalname}));

	if ($node->{node}) { # check if node definition exists
		if(ref($node->{node}) eq 'HASH') { # check if it is a hash
			my $disk = $node->{node};
			$disks{$disk->{id}} = prepare_jbod_hash($disk) if (($disk->{id}) && $disk->{logicalname});
		}

		if(ref($node->{node}) eq 'ARRAY') { # check if it is an array
			foreach my $disk (@{$node->{node}}) { # if it is, loop through it
				$disks{$disk->{id}} = prepare_jbod_hash($disk) if (($disk->{id}) && $disk->{logicalname});
			}
		} 
	}

	return \%disks;
}

sub prepare_jbod_hash {
        my ($node) = @_;  # read input
        my %self; # create empty hash

	$self{logicalname} = $node->{logicalname}; # we need this for smartd command
	$self{serial}      = $node->{serial} if ($node->{serial}); # this only helps with debuging
	$self{product}     = $node->{product} if ($node->{product}); # this only helps with debuging

	return \%self;
}

sub prepare_smartd_commands {
	my @smartd_cmds; # empty array for smartd commands
	my %found_drives = detect_drives(); # fetch drives

	foreach my $drive_value (values %found_drives) { # loop through discovered drives
		if (($drive_value->{drives} && !$drive_value->{driver})) { # if we find a drive without a driver
			foreach my $drive (keys %{$drive_value->{drives}}) {			
				push(@smartd_cmds, jbodSMARTD($drive_value)) if ($drive =~ "disk"); # if its a disk use jbod
			}
		}

		if ($drive_value->{driver}) { # if a device has a driver
			if (\$Configurator::driver_map{$drive_value->{driver}}) { # check if the driver is supported and use configured function
				push(@smartd_cmds, jbodSMARTD($drive_value))     if ($drive_value->{driver} eq "ahci");
				push(@smartd_cmds, jbodSMARTD($drive_value))	 if ($drive_value->{driver} eq "isci");
				push(@smartd_cmds, jbodSMARTD($drive_value))	 if ($drive_value->{driver} eq "mpt2sas");
				push(@smartd_cmds, nvmeSMARTD($drive_value))	 if ($drive_value->{driver} eq "nvme");
				push(@smartd_cmds, scsiSMARTD($drive_value))	 if ($drive_value->{driver} eq "aacraid");
				push(@smartd_cmds, wareSMARTD($drive_value))	 if ($drive_value->{driver} eq "3w-9xxx");
				push(@smartd_cmds, megaraidSMARTD($drive_value)) if ($drive_value->{driver} eq "megaraid_sas");
			}
		}
	}

	return @smartd_cmds;
}

sub cached_copy {
	$Configurator::interactive = 0;

	if ((! -e $Configurator::discovery_cache_file) || ((-M $Configurator::discovery_cache_file) > $Configurator::discovery_cache_expiry_age)) { # if file doesn't exist or if it's older than expiry age
		my @smartd_commands = prepare_smartd_commands(); # fetch commands
		write_file($Configurator::discovery_cache_file, map { "$_\n" } @smartd_commands); # save them to file, and add newlines
	}

	my @cached_file = read_file($Configurator::discovery_cache_file); # read file
	chomp (@cached_file);

	return @cached_file if (@cached_file);
}

#########################################
#	   SMARTD COMMAND GENERATORS
#

sub jbodSMARTD {
	my @self;
	my ($input) = @_; # get input

	foreach my $drive (keys %{$input->{drives}}) {
		`$Configurator::smartctl_bin -a $input->{drives}->{$drive}->{logicalname}`; # probe for drive
		push (@self, ($Configurator::smartctl_bin . " -a " . $input->{drives}->{$drive}->{logicalname})) if (($? != 256) && ($? != 512)); # add smart command to array
	}
	return @self; # return array of smartctl commands
}

sub nvmeSMARTD {
	my @self;
	my ($input)	 = @_; # get input
	my $handle	 = $1 if ($input->{handle} =~ /^.*:(.{1,4}:.{1,2}:.{1,2}\..)$/); # set handle if variable conatins PCI address (regex match)
	my $controller   = `ls \"/sys/bus/pci/devices/$handle/misc/\"`; # get controller name from disk location
	chomp $controller ; #remove newline from end of string

	`$Configurator::smartctl_bin . " -a /dev/" . $controller . " -d " . $input->{driver}`; # probe for drive
	push (@self, ($Configurator::smartctl_bin . " -a /dev/" . $controller . " -d " . $input->{driver})) if ($? != 512); # add smart command to array

	return @self; # return array of smartctl commands
}

sub scsiSMARTD {
	my @self;
	my ($input) = @_; # get input
	my $driver  = $Configurator::driver_map{$input->{driver}}; # translate kernel driver to smartd driver
	my @sg_devs = `ls /dev/sg*`; # fetch all scsi drives

	print "Probing for " . $Configurator::driver_map{$input->{driver}} . " drives. This could take some time..\n" if ($Configurator::interactive);
	foreach my $sg_dev (@sg_devs) {
		$? = 0; # because it's a new drive, we reset exit status
		chomp $sg_dev; # remove newline from end of string

		`$Configurator::smartctl_bin -a $sg_dev -d $driver`; # probe for drive
		if (($? != 256) && ($? != 512)) { # if smartd succeeded
			push (@self, ($Configurator::smartctl_bin . " -a " . $sg_dev . " -d " . $driver)); # add smart command to array
		}
	}

	return @self; # return array of smartctl commands
}

sub wareSMARTD {
	my @self;
	my ($input) = @_; # get input
	my $driver  = $Configurator::driver_map{$input->{driver}}; # translate kernel driver to smartd driver
	my @tw_devs = `ls /dev/tw*`; # fetch all virtual drives created by driver

	print "Probing for " . $Configurator::driver_map{$input->{driver}} . " drives. This could take some time..\n" if ($Configurator::interactive);
	foreach my $tw_dev (@tw_devs) {
		my $loop = 0; # because new it's adrive, we reset loop
		$?       = 0; # because it's a new drive, we reset exit status
		chomp $tw_dev; # remove newline from end of string

		while (($? != 256) && ($? != 512)) { # work until exist status == 0
			`$Configurator::smartctl_bin -a $tw_dev -d $driver,$loop`; # probe for drive
			if (($? != 256) && ($? != 512)) { # if smartd succeeded
				push (@self, ($Configurator::smartctl_bin . " -a " . $tw_dev . " -d " . $driver . "," . $loop)); # add smart command to array
			}
		$loop++; # increment $loop
		}
	}

	return @self; # return array of smartctl commands
}

sub megaraidSMARTD {
	my @self;
	my ($input) = @_; # get input
	my $driver  = $Configurator::driver_map{$input->{driver}}; # translate kernel driver to smartd driver

	# probe for drives
	print "Probing for " . $Configurator::driver_map{$input->{driver}} . " drives. This could take some time..\n" if ($Configurator::interactive);
	foreach my $drive (keys %{$input->{drives}}) {
		my $logicalname = $input->{drives}{$drive}{logicalname}; # logical name from lshw
		my $loop        = 0; # because it's a new drive, we reset loop
		$?              = 0; # because it's a new drive, we reset exit status

		while (($? != 256) && ($? != 512)) { # exit loop if no drive detected 
			`$Configurator::smartctl_bin -a $logicalname -d $driver,$loop`; # probe for drive
			if (($? != 256) && ($? != 512)) { # if smartd succeeded
				push (@self, ($Configurator::smartctl_bin . " -a " . $logicalname . " -d " . $driver . "," . $loop)); # add smart command to array
			}
			$loop++; # increment $loop
		}
	}

        if(!(keys %{$input->{drives}})) { # if array with drives is empty
                foreach my $drive ("/dev/sda".."/dev/sdz") { # try these drives
                        my $loop = 0; # because it's a new drive, we reset loop
                        $?       = 0; # because it's a new drive, we reset exit status
                        while (($? != 256) && ($? != 512)) { # exit loop if no drive detected
                                `$Configurator::smartctl_bin -a $drive -d $driver,$loop`; # probe for drive
                                if (($? != 256) && ($? != 512)) { # if smartd succeeded
                                        push (@self, ($Configurator::smartctl_bin . " -a " . $drive . " -d " . $driver . "," . $loop)); # add smart command to array
                                }
                                $loop++; # increment $loop
                        }
                }
        }

	return @self; # return array of smartctl commands
}

return 1;
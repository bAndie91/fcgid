
# Used variables:
#   $ARGV[0]	possible values: "stop", "status", any other
#   $pid_file
#   $selfname

$cmd = lc $ARGV[0];

if($cmd eq "stop" or $cmd eq "status") {
	open $pid_fh, '<', $pid_file;
	$pid = <$pid_fh>;
	close $pid_fh;
	if($pid !~ /^\d+$/) {
		print STDERR "No PID file found or no PID in it.\n";
		exit 2;
	}
	else {
		if(-e "/proc/$pid/cmdline") {
			open $fh, '<', "/proc/$pid/cmdline";
			local $/ = "\x00";
			my $procname = <$fh>;
			close $fh;
			if($procname =~ /^$selfname\b/) {
				if($cmd eq "stop") {
					print STDERR "Terminating PID $pid.\n";
					$kill = kill(15, $pid);
					print STDERR "$!\n" if $!;
					exit($kill >= 1 ? 0 : 1);
				}
				elsif($cmd eq "status") {
					print STDERR "PID=$pid\n";
					exit 0
				}
			}
			else {
				print STDERR "PID stolen by: $procname\n";
				exit 3;
			}
		}
		else {
			print STDERR "Daemon crashed?\n";
			unlink $pid_file;
			exit 4;
		}
	}
}

if(-e $pid_file) {
	print STDERR "Already running.\n";
	exit 1;
}

1;

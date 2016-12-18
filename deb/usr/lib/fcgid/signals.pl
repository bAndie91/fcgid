
use POSIX ':sys_wait_h';

$SIG{"HUP"} = sub {
	loadOwnerMap();
	loadPaths();
	loadExtHandlers();
};

sub clean_exit {
	my $signal = shift;
	$haveToEnded = 1;
	print STDERR "Dying by SIG$signal\n" if $debug_mode;
	for(keys %Child) {
		print STDERR "Killing $_\n" if $debug_mode;
		kill $signal, $_;
	}
}
sub real_exit {
	unlink $pid_file;
	exit 0;
}


$SIG{"INT"} = \&clean_exit;
$SIG{"QUIT"} = \&clean_exit;
$SIG{"TERM"} = \&clean_exit;

sub reape {
	for my $pid (keys %Child) {
		my $ended = waitpid($pid, WNOHANG);
		my $ec = $?;
		if($ended > 0) {
			print STDERR "Reaped: $pid, Exit Code: ", $ec>>8, ", Signal: ", $ec&127, "\n" if $debug_mode;
			delete $Child{$pid};
		}
	}
}

$SIG{"CHLD"} = \&reape;

1;


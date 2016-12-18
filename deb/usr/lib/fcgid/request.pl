
use File::Basename;
use Process::Initgroups;
use POSIX qw/setuid setgid/;


sub app_error
{
	my $pre_out = $_[2] ? $_[2].': ' : '';
	my $pre_err = $_[3] ? $_[3].': ' : '';
	my $msg = $_[4];
	$_[0]->print(headers(Status => "500 Fcgid Pre-Application Error", Content_Type => "text/plain"));
	$_[0]->print("$selfname: $pre_out$msg\n");
	$_[1]->print("$pre_err$msg\n");
}

sub handle_request
{
	my $Req = shift;
	my ($fcgiRead, $fcgiWrite, $fcgiWriteErr) = $Req->GetHandles();
	my %fcgiEnv = %{$Req->GetEnvironment()};
	my ($app, $dirname, $app_exthandler, $appOwner, $execUser, $execUID, $execGID, @app_cmd_line);
	my ($app_webpath, $dirname_webpath);
	my $header_fix = 0;
	my ($childRead, $parentWrite, $parentRead, $childWrite);
	my ($appPID, $headersOK, $response_bytes, $app_exit_status, $app_exit_code, $app_exit_signal);
	
	
	$fcgiWrite->autoflush(1);
	
	
	$app = $fcgiEnv{"SCRIPT_FILENAME"};
	$app_webpath = $fcgiEnv{"SCRIPT_NAME"} || substr($fcgiEnv{"SCRIPT_FILENAME"}, length $fcgiEnv{"DOCUMENT_ROOT"});
	if($app !~ /^\//)
	{
		app_error $fcgiWrite, $fcgiWriteErr, $app_webpath, $app, "Must be an absolute filename.";
		return -1;
	}
	if($app =~ /\/$/)
	{
		my $index_ok;
		for my $index (split /\s+/, $fcgiEnv{"FCGI_INDEX_SEARCH"} || "index.cgi")
		{
			if(-f $app.$index)
			{
				$app .= $index;
				$app_webpath .= $index;
				# php requires SCRIPT_FILENAME env to point the script:
				$fcgiEnv{"SCRIPT_FILENAME"} .= $index;
				#$fcgiEnv{"SCRIPT_NAME"} .= $index;
				$fcgiEnv{"REQUEST_FILENAME"} .= $index;
				$index_ok = 1;
				last;
			}
		}
		if(not $index_ok)
		{
			$fcgiWrite->print(headers(Status => "403 No index file"));
			$fcgiWriteErr->print("$app: no index file\n");
			return -9;
		}
	}
	
	$0 = "$selfname worker $app";
	$dirname = dirname($app);
	$dirname_webpath = dirname($app_webpath);
	$app_exthandler = get_handler($app);
	
	if(!path_enabled($dirname, $app_exthandler))
	{
		app_error $fcgiWrite, $fcgiWriteErr, $dirname_webpath, $dirname, "Executing prohibited.";
		return -7;
	}
	if(!chdir $dirname)
	{
		app_error $fcgiWrite, $fcgiWriteErr, $dirname_webpath, $dirname, "Directory unaccessible.";
		return -2;
	}
	if($ExtHandler{$app_exthandler || '*'}->{'xbit'} and !-x $app)
	{
		app_error $fcgiWrite, $fcgiWriteErr, $app_webpath, $app, "Not executable.";
		return -3;
	}
	
	$appOwner = (stat $app)[4];
	$execUser = appOwnerMap($appOwner);
	
	if(not defined $execUser)
	{
		app_error $fcgiWrite, $fcgiWriteErr, $app_webpath, $app, "No user mapped.";
		return -4;
	}
	if($execUser eq '')
	{
		app_error $fcgiWrite, $fcgiWriteErr, $app_webpath, $app, "Access denied.";
		return -5;
	}

	(undef, undef, $execUID, $execGID) = (getpwnam $execUser);
	if(not defined $execGID or not defined $execUID)
	{
		app_error $fcgiWrite, $fcgiWriteErr, $app_webpath, $app, "User/group ID error.";
		return -8;
	}


	
	@app_cmd_line = ();
	if(defined $app_exthandler)
	{
		push @app_cmd_line, get_handler_command($app_exthandler);
	}
	$do_header_fix = !is_handler_headersafe($app_exthandler);
	push @app_cmd_line, $app;
	
	
	pipe $childRead, $parentWrite;
	pipe $parentRead, $childWrite;
	$appPID = fork;
	
	if(!defined $appPID)
	{
		app_error $fcgiWrite, $fcgiWriteErr, '', '', "fork: $!";
		return -6;
	}
	elsif($appPID == 0)
	{
		close $parentWrite;
		close $parentRead;
		# FIXME: does not work if current user == execUser
		if(Process::Initgroups::initgroups($execUser, $execGID))
		{
			if(setgid($execGID))
			{
				if(setuid($execUID))
				{
					%ENV = %fcgiEnv;
					if(not defined $ENV{'HOME'})
					{
						$ENV{'HOME'} = (getpwuid $execUID)[7];
					}
					open STDIN, '<&=', $childRead;
					open STDOUT, '>&=', $childWrite;
					$|++;
					open STDERR, '|-', 'logger', '--priority', 'user.err', '--tag', "$selfname-$execUser";
					select STDERR;
					$|++;
					select STDOUT;
					exec @app_cmd_line;
					syslog(LOG_ERR, "$app: exec failed: $!");
				}
				else
				{
					syslog(LOG_ERR, "$app: setuid failed");
				}
			}
			else
			{
				syslog(LOG_ERR, "$app: setgid failed");
			}
		}
		else
		{
			syslog(LOG_ERR, "$app: initgroups failed");
		}
		POSIX::_exit(-7);
	}
	
	
	close $childRead;
	close $childWrite;
	select $parentWrite;
	$|++;
	select STDOUT;
	
	print {$parentWrite} $_ while defined($_ = $fcgiRead->getline());
	close $parentWrite;
	
	if($do_header_fix)
	{
		$fcgiWrite->print($CRLF);
	}
	
	$response_bytes = 0;
	while(<$parentRead>)
	{
		$response_bytes += length;
		$fcgiWrite->print($_);
	}
	close $parentRead;
	
	waitpid($appPID, 0);
	$app_exit_status = $?;
	$app_exit_code = $app_exit_status >> 8;
	$app_exit_signal = $app_exit_status & 0x7F;
	
	if(!$do_header_fix and $response_bytes == 0)
	{
		$fcgiWrite->print(headers(
			Status => "503 Application Error",
			X_POSIX_Exit_Code => $app_exit_code,
			X_POSIX_Exit_Signal => $app_exit_signal,
		));
	}
	
	return 0;
}

1;

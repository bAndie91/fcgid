
sub glob2regex
{
    my $globstr = shift;
    my %patmap = (
        '*' => '.*',
        '?' => '.',
        '[' => '[',
        ']' => ']',
    );
    $globstr =~ s{(.)} { $patmap{$1} || "\Q$1" }ge;
    return '^' . $globstr . '$';
}

sub loadOwnerMap
{
	my $fh;
	if(not open $fh, '<', $file_usermap)
	{
		syslog(LOG_ERR, "open($file_usermap): $!");
		return 0;
	}
	%ownerMap = ();
	while(<$fh>)
	{
		next if /^\s*(#|$)/;
		if(/^(%?)(\S+)\s+(\S+)$/)
		{
			$ownerMap{$1 ? 'group' : 'user'}->{$2} = $3 eq '-' ? '' : $3;
		}
		else
		{
			syslog(LOG_WARNING, "$file_usermap:$.: invalid line");
		}
	}
	close $fh;
}

sub appOwnerMap
{
	my $uid = shift;
	my $return;
	
	my $user = (getpwuid $uid)[0];
	if(exists $ownerMap{'user'}->{$user})
	{
		$return = $ownerMap{'user'}->{$user};
	}
	else
	{
		for my $group (keys $ownerMap{'group'})
		{
			if(is_member($user, $group))
			{
				$return = $ownerMap{'group'}->{$group};
				last;
			}
		}
	}
	if(not defined $return)
	{
		$return = $ownerMap{'user'}->{'*'};
	}
	
	if($return eq '*')
	{
		$return = $user;
	}
	elsif($return =~ /^\d+$/)
	{
		$return = (getpwuid $return)[0];
	}
	return $return;
}

sub is_member
{
	my $user = shift;
	my $group = shift;
	my @grent = getgrnam($group);
	if($grent[2] == ((getpwnam $user)[3]))
	{
		return 1;
	}
	else
	{
		for my $member (split ' ', $grent[3])
		{
			if($member eq $user)
			{
				return 1;
				last;
			}
		}
	}
	return 0;
}
sub getgrouplist
{
	my $user = shift;
	my @groups;
	my $pgid = (getpwnam $user)[3];
	setgrent;
	while(my @grent = getgrent())
	{
		if($grent[2] == $pgid)
		{
			push @groups, $grent[0];
		}
		else
		{
			for my $member (split ' ', $grent[3])
			{
				if($member eq $user)
				{
					push @groups, $grent[0];
					last;
				}
			}
		}
	}
	endgrent;
	return @groups;
}

sub loadPaths
{
	my $fh;
	if(not open $fh, '<', $file_paths)
	{
		syslog(LOG_ERR, "open($file_paths): $!");
		return 0;
	}
	%PathACL = ();
	while(<$fh>)
	{
		next if /^\s*(#|$)/;
		if(/^([+-])(\S+)(?:\s+(\S+))?$/)
		{
			my $enable = ($1 eq '+');
			my $path = $2;
			my @handlers = split(/,/, ($3 || '*'));
			for my $handler (@handlers)
			{
				$PathACL{$path}->{$handler} = $enable;
			}
		}
		else
		{
			syslog(LOG_WARNING, "$file_paths:$.: invalid line");
		}
	}
	close $fh;
}

sub loadExtHandlers
{
	my $fh;
	if(not open $fh, '<', $file_exthandlers)
	{
		syslog(LOG_ERR, "open($file_exthandlers): $!");
		return 0;
	}
	%ExtHandler = ('*' => {'headersafe'=>1, 'xbit'=>1,},);
	while(<$fh>)
	{
		s/\s*$//;
		next if /^\s*(\x23|$)/;
		if(/^([[:alnum:]-]+)(?:\s+(\S+)\s+([[:alnum:]-]+)\s+(.+))?$/)
		{
			my ($hnd_id, $fn_regex, $flags, $cmdargs);
			if(length $2){
				($hnd_id, $fn_regex, $flags, $cmdargs) = ($1, $2, $3, $4);}
			else {
				($hnd_id, $flags) = ('*', $1);}

			$ExtHandler{$hnd_id} = {
				'regex' => $fn_regex,
				'headersafe' => ($flags=~/h/ ? 1 : 0),
				'xbit' => ($flags=~/x/ ? 1 : 0),
				'command' => $cmdargs,
			};
		}
		else
		{
			syslog(LOG_WARNING, "$file_exthandlers:$.: invalid line");
		}
	}
	close $fh;
}

sub get_handler
{
	my $file = shift;
	for my $hnd (keys %ExtHandler)
	{
		if($file =~ $ExtHandler{$hnd}->{'regex'})
		{
			return $hnd;
		}
	}
	return undef;
}

sub get_handler_command
{
	my $hnd = shift;
	my $cmd = $ExtHandler{$hnd}->{'command'};
	return split(/\s+/, $cmd);
}
sub is_handler_headersafe
{
	my $hnd = shift;
	return $ExtHandler{$hnd || '*'}->{'headersafe'};
}

sub path_enabled
{
	my $mypath = shift;
	my $handler_id = shift;
	$mypath =~ s/\/+/\//g;
	do {
		$mypath = '/' if $mypath eq '';
		
		for my $path (keys %PathACL)
		{
			my $path_re = glob2regex($path);
			if($mypath eq $path or $mypath =~ /$path_re/)
			{
				for my $hnd ($handler_id, '*')
				{
					if(defined $PathACL{$path}->{$hnd})
					{
						return $PathACL{$path}->{$hnd};
					}
				}
			}
		}
	}
	while($mypath =~ s/\/[^\/]+$//);
	return 0;
}

sub headers {
	my %h = @_;
	return join('', map{
		my $hn = $_;
		$hn =~ s/_/-/g;
		sprintf "%s: %s$CRLF", $hn, $h{$_};
	}keys %h).
	$CRLF;
}


sub get_worker_children_number {
	my $workers = 0;
	for my $pid (@_) {
		open my $fh, '<', "/proc/$pid/cmdline";
		local $/ = "\0";
		if(<$fh> =~ /^\Q$selfname\E worker/) {
			$workers++;
		}
		close $fh;
	}
	return $workers;
}

sub logfacnam
{
	my $str = shift;
	$str = uc $str;
	$str =~ s/[^A-Z0-9]//g;
	$str = "LOG_$str";
	return eval $str;
}

sub shebang
{
	# Returns the shell interpreter of a file.
	
	local $/ = "\n";
	open my $fh, '<', $_[0];
	my $shebang = <$fh>;
	close $fh;
	if($shebang =~ s/^\x23\x21\s*//)
	{
		$shebang =~ s/\s*$//;
		return $shebang;
	}
	return undef;
}


1;

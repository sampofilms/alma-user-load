#!/usr/bin/perl
#
# Script usage:
# alma_load_users.pl --function=[FULL|UPDATE|MAINTAIN|(USERID)] --commit=[YES/NO]
#
# alma_load_users.pl - Contains 4 different loading functions for pushing user data via
#   the Alma users API:
#
# 1. FULL Load: Query our locally managed HR/Banner user DB libempdata and return ALL
#    users. Push data to API, overwriting all externally managed data fields.
#    Runs Monthly. If user is not matched by employee_id or primary_id, then it is created
#	 via a POST call.
# 2. UPDATE Load: Query libempdata and return recently updated users from last 6 hours.
#    Push data to API, overwriting all externally managed data fields. If user is not 
#	 matched by employee_id or primary_id, then it is created via a POST call.
# 3. MAINTAIN Load: Query Analytics API Shared/Oregon Health and Science University/
#    Recently_Modified_Users -- these are users modified within the last 24hrs. Query 
#    libempdata and match users. Push data to API, overwriting all externally managed data
#    fields.
# 4. (USERID) load: If you pass a primary_id (eg 'user@ohsu.edu') to the function call, 
#	 then the MAINTAIN load code above will run for that user only. Useful to manually
#	 fix individual user accounts.
#
# commit=YES will push changes to Alma user DB via the API. Setting to NO will only
# 	 make query calls and report back without writing to DB.
#
# -= 1/18/17 Changes =-
# Modified SQL procedure libempdata.SIS_XML_FULL to be overloadable and accept single
# letter character to limit full result set. Defaults to letter 'a' so a full (a-z) result
# set is returned if no value is passed. Passing a letter via shell CLI will limit result
# set, i.e. if you run --function=FULLm then m-z result set will be used during load.
#
# -= 1/13/17 Changes =-
# Modified SQL to ensure POST/create new user sets preferred_language attribute during 
# POST. Otherwise error 401658 "General Error" will be thrown. This is related to updates 
# made to Alma for January 2017 Release.
#
# last updated: 01/18/17, np, OHSU Library

#----------------------------------------------------------------------------------------#
# 										DECLARATIONS
#----------------------------------------------------------------------------------------#
use strict;
use warnings;
use utf8;

use Cwd qw();
use DBI;
use Getopt::Long qw(GetOptions);
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use LWP::UserAgent;
use Time::Piece;
use XML::Twig;

#----------------------------------------------------------------------------------------#
# 										  GLOBALS
#----------------------------------------------------------------------------------------#

# Alma API login/url:
my $API_USER 		= 'AlmaSDK-alma_api-institutionCode-XXXXXXXXXXX';
my $API_PASS 		= 'XXXXXXXXXX';
my $API_BURL 		= 'https://naXX.alma.exlibrisgroup.com:443/almaws/v1/';
my $API_AURL		= 'https://naXX.alma.exlibrisgroup.com:443/almaws/v1/';
my $API_RTUserMod	= 'URL_path_to_Analytics_Report';

# libempdata vars:
my $SQL_SERVER		= 'sql_host';
my $SQL_DB			= 'sql_db';
my $SQL_USER		= 'sql_usr';
my $SQL_PASS		= 'sql_pass';

# error email notifications:
#my $EMAIL_NOTIFY	= 'email@address.edu';

#----------------------------------------------------------------------------------------#
# 											MAIN
#----------------------------------------------------------------------------------------#

# exit and warn user if no function is given
my $function;
my $commit = 'NO';
#my $error_email;

GetOptions('function=s' => \$function, 
		   'commit=s' => \$commit,) 
	or die "Script usage: $0 --function=[FULL(X)|UPDATE|MAINTAIN|(USERID)] --commit=[YES/NO]\n";

if ($function) {
	#------------------------------------------------------------------------------------#
	# 								   FILE HANDLING
	#------------------------------------------------------------------------------------#
	# get our current working dir:
	my $xml_path = Cwd::cwd() . '/scripts/alma_load_users/xmls/';
	my $log_path = Cwd::cwd() . '/scripts/alma_load_users/logs/';
	
	# timestamp:
	my $ts = localtime->strftime('%Y%m%d_%H%M%S');
	my $ds = localtime->strftime('%Y%m%d');
	
	# setup our file handler locations:
	# - fh_log = logged success and errors from PUT/POST calls
	# - fh_err = logged errors to be emailed by logrotate
	# - fh_pre = xml user data retrieved from users API before modifications
	# - fh_post = xml user data after merge with libempdata table data and before PUT/POST
	# - fh_ret = xml user data returned from PUT of fh_post data
	my $log_file = $log_path . $function . '_' . $ds . '.log';
	my $err_file = $log_path . $function . '_' . $ds . '_errors.log';
	my $pre_change = $xml_path . $function . '_' . $ts . '_pre_change.xml';
	my $post_change = $xml_path . $function . '_' . $ts . '_post_change.xml';
	my $return_change = $xml_path . $function . '_' . $ts . '_return_change.xml';
	
	#open and prep FHs:
	my ($fh_log, $fh_err, $fh_pre, $fh_post, $fh_return);
	open $fh_log, '>>', $log_file or do {
		warn "$0: open $log_file: $!";
		return;
	};
	open $fh_err, '>>', $err_file or do {
		warn "$0: open $err_file: $!";
		return;
	};
	open $fh_pre, '>', $pre_change or do {
		warn "$0: open $pre_change: $!";
		return;
	};
	open $fh_post, '>', $post_change or do {
		warn "$0: open $post_change: $!";
		return;
	};
	open $fh_return, '>', $return_change or do {
		warn "$0: open $return_change: $!";
		return;
	};
	
	print $fh_log "Begin function " . $function . " on: " . localtime() . "\n";
	print $fh_err "Begin function " . $function . " on: " . localtime() . "\n";
	#print $fh_log "Sending logged success/errors to file: " . $log_file . "\n";
	#print $fh_log "Sending logged errors to file: " . $err_file . "\n";
	#print $fh_log "Sending pre_change data to file: " . $pre_change . "\n";
	#print $fh_log "Sending post_change data to file: " . $post_change . "\n";
	#print $fh_log "Sending return_change data to file: " . $return_change . "\n";
	
	print $fh_pre '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' . "\n";
	print $fh_post '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' . "\n";
	print $fh_return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' . "\n";

	# create request obj and set content_type to XML:
	my $ua = LWP::UserAgent->new(keep_alive => 0, 
									timeout => 45, 
									sl_opts => {SSL_verify_mode => 
												IO::Socket::SSL::SSL_VERIFY_NONE, 
												verify_hostname => 0});
	
	# connect to libempdata:
  	my $dbh = DBI->connect("DBI:mysql:database=" . $SQL_DB . ";host=" . $SQL_SERVER,
                    		$SQL_USER, $SQL_PASS,
                         	{'RaiseError' => 1});
    
    # MySQL statement handler
    my $sth;
    $sth->{RaiseError} = 1;
    
    # -----------------------------------------------------------------------------------#
    #                                 DB FUNCTION CODE
    # -----------------------------------------------------------------------------------#
	if ($function eq 'FULL') {
		$sth=$dbh->prepare("call SIS_XML_FULL('')") or die $DBI::err.": ".$DBI::errstr;
	}
	elsif (my ($letter) = $function =~ /FULL([a-z.])/) {
		$sth=$dbh->prepare("call SIS_XML_FULL('" . $letter . "')") or die $DBI::err.": ".$DBI::errstr;
	}
	elsif ($function eq 'UPDATE') {
		$sth=$dbh->prepare("call SIS_XML_UPDATE('')") or die $DBI::err.": ".$DBI::errstr;
	}
	elsif ($function eq 'MAINTAIN') {
		# get list of modified users:
		my $get = new HTTP::Request(GET =>($API_AURL . 'analytics/' . $API_RTUserMod));
		$get->content_type('application/xml');
		$get->authorization_basic($API_USER, $API_PASS);
		my $response = $ua->request($get);
		
		if ($response->is_success) {
			# process list:
			my @pri_ids;
			my $twig = XML::Twig->new(
				keep_atts_order => 1,
				no_prolog => 1,
				twig_handlers => { 'Column3' => sub { push @pri_ids, $_->text }, } 
			);
			$twig->parse($response->content);
			print $fh_log "Number of EXTERNAL accounts modified is: " . ($#pri_ids + 1) . "\n";
			
			# pull matching records in libempdata:
			$sth=$dbh->prepare("call SIS_XML_MAINTAIN('" . join(",", @pri_ids) . "')") or die $DBI::err.": ".$DBI::errstr;
		}
		else {
			# could not get list, report error and DIE:
			my $error_string = "ERROR returning Analytics list: " . $response->status_line();
			#print $fh_log print_error($error_string, $response->content);
			print $fh_log ($error_string . " (" . xml_err_num($response->content()) . ")\n");
			print $fh_err print_error($error_string, $response->content) . "\n";
			die "Ending function " . $function . " on: " . localtime() . "\n";
		}
	}
	elsif ($function =~ /\w+\@ohsu\.edu/) {
		$sth=$dbh->prepare("call SIS_XML_MAINTAIN('" . $function . "')") or die $DBI::err.": ".$DBI::errstr;
	}
	else {
		die "Script usage: $0 --function=[FULL(x)|UPDATE|MAINTAIN|(USERID)] --commit=[YES/NO]\n";
	}
	
	# get data from DB:
	$sth->execute || die DBI::err.": ".$DBI::errstr;
	my $users = $sth->fetchall_arrayref;
	$sth->finish;
	$dbh->disconnect();
	
	print $fh_log "Number of records returned from " . $SQL_DB . " is: ", 0 + @{$users}, "\n";
	
	# our pre, post and return XML user data objs:
	my $twig_pre = XML::Twig->new(
		pretty_print => 'indented',
		keep_atts_order => 1,
		no_prolog => 1
	);
	my $twig_post = XML::Twig->new(
		pretty_print => 'indented',
		keep_atts_order => 1,
		no_prolog => 1   
	);
	my $twig_return = XML::Twig->new(
		pretty_print => 'indented',
		keep_atts_order => 1,
		no_prolog => 1   
	);
	
	# -----------------------------------------------------------------------------------#
	#                   RETAIN BARCODE and other internally managed data
	# -----------------------------------------------------------------------------------#
	foreach my $u (@{$users}) {
		my $employee_id	= @{$u}[0];
		my $student_id	= @{$u}[1];
		my $primary_id 	= @{$u}[2];
		
		# boolean to create (POST) or update (PUT) user details to API:
		my $new_user = 0;
		
		# construct API url, attempt to match on a)employee_id, b)student_id or c)primary_id:
		my $apiurl = $API_BURL . 'users/';
		if ($employee_id) {
			$apiurl = $apiurl . $employee_id . '?view=full';
		}
		else {
			$apiurl = $apiurl . $student_id . '?view=full';
		}
		
		#debug:
		#print $apiurl . "\n";
		
		my $get = new HTTP::Request(GET =>($apiurl));
		$get->content_type('application/xml');
		$get->authorization_basic($API_USER, $API_PASS);
		my $response = $ua->request($get);
		
		# if employee or student id check fails, try primary identifier:
		if ($response->is_error && xml_err_num($response->content) eq '401861') {
			$apiurl = $API_BURL . 'users/' . $primary_id . '?view=full';
			$get = new HTTP::Request(GET =>($apiurl));
			$get->content_type('application/xml');
			$get->authorization_basic($API_USER, $API_PASS);
			$response = $ua->request($get);
		}
		
		if ($response->is_success) {
			# flush pre user XML data to file:
			$twig_pre->parse($response->content);
			$twig_pre->print($fh_pre);
			$twig_pre->purge;
		
			# current user xml, strip out elements we will overwrite:
			my $twig = XML::Twig->new( 
				ignore_elts => {
					'full_name' => 1,
					'pin_number' => 1,
					'cataloger_level' => 1,
					'record_type' => 1,
					'first_name' => 1,
					'middle_name' => 1,
					'last_name' => 1,
					'job_description' => 1,
					'user_group' => 1,
					'expiry_date' => 1,
					'purge_date' => 1,
					'account_type' => 1,
					'external_id' => 1,
					'status' => 1,
					'contact_info' => 1,
					'user_statistics' => 1
				}
			);
			$twig->parse($response->content);
			
			# remove all non-barcode identifiers to avoid conflicts with libempdata:
			for my $ident ($twig->findnodes('//user_identifier/id_type[string()!="BARCODE"]')) {
				$ident->parent->cut;
			}
			
			#debug:
			#print "\npre merge:\n";
			#$twig->print;
			#print "\n";
			
			# merge with generated xml obj from libempdata:
			my %tags;
			++$tags{$_->tag} for $twig->findnodes('/user/*');
			{
				#debug:
				#print "pre parse twig2\n";
				#print Dumper(\@{$u}[3]);
				
				my $twig2 = XML::Twig->parse(@{$u}[3]);
				
				#debug:
				#print "during merge:\n";
				#$twig2->print;
				#print "\n";
				
				# copy all non-matching elements over from org user xml:
				for my $elem ($twig2->findnodes('/user/*')) {
					unless ($tags{$elem->tag}) {
						$elem->cut;
						$elem->paste(last_child => $twig->root);
					}
				}
				
				# copy user idents from libempdata:
				for my $ident ($twig2->findnodes('//user_identifier[@segment_type="External"]')) {
					unless ($tags{$ident->tag}) {
						$ident->cut;
						$ident->paste($twig->findnodes('/user/user_identifiers/'));
					}
				}
				
				$twig2->purge;
			}
			
			# debug:
			#print "post merge:\n";
			#$twig->set_pretty_print('indented');
			#$twig->print;
			#print "\n";
			
			# push new data to user array:
			@{$u}[3] = $twig->sprint;
			$twig->purge;
			
			# update user:
			$new_user = 0;
		}
		elsif (xml_err_num($response->content) eq '401861') {
			# user not found by primary id match, it *should* be safe to create in DB:
			$new_user = 1;
		}
		else {
			# could not get user data for some reason, report error:
			my $error_string = "ERROR retaining barcode for user employee_id=$employee_id, student_id=$student_id, primary_id=$primary_id: " . $response->status_line() .
				"ERROR --> will skip PUT attempt for user!";
			#print $fh_log print_error($error_string, $response->content);
			print $fh_log ($error_string . " (" . xml_err_num($response->content()) . ")\n");
			print $fh_err print_error($error_string, $response->content) . "\n";
			#$error_email = $error_email . print_error($error_string, $response->content) . "\n";
			
			# blank user ids so user is skipped during COMMIT phase:
			$employee_id = '';
			$student_id = '';
			$primary_id = '';
		}
		
		# -------------------------------------------------------------------------------#
		#                                 API PUSH CODE
		# -------------------------------------------------------------------------------#
		if ($commit eq 'YES') {		
			# only process non-popped users:
			if ($employee_id || $student_id || $primary_id) {
				
				# PUT or POST user?
				my $put;
				if ($new_user) {
					$put = new HTTP::Request(POST =>($API_BURL . 'users'));
				}
				else {
					$put = new HTTP::Request(PUT =>($apiurl . '&override=user_group'));
				}
				use bytes;
				my $length = length(@{$u}[3]);
				use utf8;
				
				# flush post user XML data to file:
				$twig_post->parse(@{$u}[3]);
				$twig_post->print($fh_post);
				$twig_post->purge;
		
				# attempt to PUT/POST user data:
				$put->content(@{$u}[3]);
				$put->content_type('application/xml;charset=UTF-8');
				$put->content_length($length);
				$put->authorization_basic($API_USER, $API_PASS);
				my $put_res = $ua->request($put);
	
				if ($put_res->is_success) {
					# flush returned XML data to file:
					$twig_return->parse($put_res->content);
					$twig_return->print($fh_return);
					$twig_return->purge;
					
					if ($new_user) {
						print $fh_log "SUCCESS creating user employee_id=$employee_id, student_id=$student_id, primary_id=$primary_id: " . $put_res->status_line() . "\n";
					}
					else {
						print $fh_log "SUCCESS updating user employee_id=$employee_id, student_id=$student_id, primary_id=$primary_id: " . $put_res->status_line() . "\n";
					}
				}
				elsif (xml_err_num($put_res->content) eq '401858') {
					#"The external id in DB does not fit the given value in xml - external id cannot be updated."
					#-- This usually means the current user's <external_id> correlates to a non-existant User Identifier Type so it cannot be overwritten
					#-- even if the newly PUTed <external_id> does exist. So, let's try removing the current user obj and POSTing the new synchronized one:
					my $del = new HTTP::Request(DELETE => ($apiurl));
					$del->authorization_basic($API_USER, $API_PASS);
					my $del_res = $ua->request($del);
					#print $del_res->status_line() . "\n";
					
					my $post = new HTTP::Request(POST =>($API_BURL . 'users'));
					use bytes;
					$length = length(@{$u}[3]);
					use utf8;
		
					# attempt to PUT user data:
					$post->content(@{$u}[3]);
					$post->content_type('application/xml;charset=UTF-8');
					$post->content_length($length);
					$post->authorization_basic($API_USER, $API_PASS);
					$put_res = $ua->request($post);
	
					if ($put_res->is_success) {
						# flush returned XML data to file:
						$twig_return->parse($put_res->content);
						$twig_return->print($fh_return);
						$twig_return->purge;
						
						print $fh_log "SUCCESS updating user employee_id=$employee_id, student_id=$student_id, primary_id=$primary_id: " . $put_res->status_line() . "\n";
					}
				}
				elsif (xml_err_num($put_res->content) eq '4018994') {
					#Request cannot contain two identifiers with the same value (probably incorrect primary ident):
					my $error_string = "ERROR updating user employee_id=$employee_id, student_id=$student_id, primary_id=$primary_id: " . $put_res->status_line();
					#print $fh_log print_error($error_string, $put_res->content);
					print $fh_log ($error_string . " (" . xml_err_num($put_res->content()) . ")\n");
					
					# email user to manually fix:
					print $fh_err print_error($error_string, $put_res->content);
					print $fh_err "POSSIBLE RESOLUTION: Please ensure the primary_id for this user is set to: $primary_id and attempt to repair this user by running:\n$0 --function=$primary_id --commit=YES\n\n";
					#$error_email = $error_email . print_error($error_string, $put_res->content);
					#$error_email = $error_email . "POSSIBLE RESOLUTION: Please ensure the primary_id for this user is set to: $primary_id and attempt to repair this user by running:\n$0 --function=$primary_id --commit=YES\n";
				}
				else {
					my $error_string = "ERROR updating user employee_id=$employee_id, student_id=$student_id, primary_id=$primary_id: " . $put_res->status_line();
					#print $fh_log print_error($error_string, $put_res->content);
					print $fh_log ($error_string . " (" . xml_err_num($put_res->content()) . ")\n");
					print $fh_err print_error($error_string, $put_res->content) . "\n";
					#$error_email = $error_email . print_error($error_string, $put_res->content);
				}
			}
		}
		else {
			print $fh_log "No commit command provided so skipping API push for user $primary_id\n"
		}
	}
	
	print $fh_log "End function " . $function . " on: " . localtime() . "\n";
	print $fh_err "End function " . $function . " on: " . localtime() . "\n\n";
	
	# cleanup:
	close $fh_log or warn "$0 close $fh_log: $!\n";
	close $fh_err or warn "$0 close $fh_err: $!\n";
	close $fh_pre or warn "$0: close $fh_pre: $!\n";
	close $fh_post or warn "$0: close $fh_post: $!\n";
	close $fh_return or warn "$0: close $fh_return: $!\n";
	
	# -----------------------------------------------------------------------------------#
	#                                EMAIL ERRORS
	# -----------------------------------------------------------------------------------#
	# send error email if needed:
	#if ($error_email) {
	#	open(MAIL, "|/usr/sbin/sendmail -t");
	#	print MAIL "To: $EMAIL_NOTIFY\n";
	#	print MAIL "From: NOREPLY\@library.ohsu.edu\n";
	#	print MAIL "Subject: Errors From " . $0 . "\n\n";
	#	print MAIL $error_email;
	#	close(MAIL);
	#}
}
else {
	die "Script usage: $0 --function=[FULL(x)|UPDATE|MAINTAIN|(USERID)] --commit=[YES/NO]\n";
}

#----------------------------------------------------------------------------------------#
# 									SUBROUTINES
#----------------------------------------------------------------------------------------#

# return pretty error for logs:
#	$_[0] = message (string)
#	$_[1] = xml obj from LWP response
sub print_error {
	my $str_message = $_[0];
	my $xml_obj = $_[1];
	
	my ($error_code, $error_message, $tracking_id);
	my $twig_error = XML::Twig->new(
		twig_handlers => { 
			q(web_service_result/errorList/error/errorCode) => sub { $error_code = $_->text },
			q(web_service_result/errorList/error/errorMessage) => sub { $error_message = $_->text },
			q(web_service_result/errorList/error/trackingId) => sub { $tracking_id = $_->text },
		}   
	);
	$twig_error->parse($xml_obj);
	$twig_error->purge;
	
	$str_message = $str_message . "\n";
	$str_message = $str_message . "ERROR code = $error_code\n";
	$str_message = $str_message . "ERROR message = $error_message\n";
	$str_message = $str_message . "ERROR trackingId = $tracking_id\n";
	return $str_message;
}

# return Alma API error code number:
sub xml_err_num {
	my $xml_obj = $_[0];
	my $error_code;
	
	my $twig_error = XML::Twig->new(
		twig_handlers => {
			q(web_service_result/errorList/error/errorCode) => sub { $error_code = $_->text },
		}
	);
	$twig_error->parse($xml_obj);
	$twig_error->purge;
	
	return $error_code;
}
#!/usr/bin/perl -w

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# pCool CLI based Perl IRC Client is released under the terms and license
# of GNU General Public License (GPLv2)
#
# I'd like to personally thank Robey Pointer (http://www.lag.net/say2/)
# for his excellent work in writing TextEntry.pm and TextScroll.pm perl
# modules.
#
# (c) 2008 ghimire
###########################################################################

use IO::Socket;
use IO::Select;

package pCoolIRC;

require "modules/TextEntry.pm";
require "modules/TextScroll.pm";


################ Change Your Config Here #################################
my $server = 'irc.server.org';
my $nick = 'nick';
my $login= 'real name';
my $channel = '#channel';
my $port = 6667;
##########################################################################

initscr();
raw();
#cbreak();
noecho();
nonl();

my $prog_name="$0";

my $win = new Curses;
$win->keypad(1);
$win->syncok(1);
$win->nodelay(1);
$win->intrflush(0);
$win->clear();

my $x = new TextEntry($win, 1);
$x->set_expand(2, 5);

my ($y, $maxx) = $x->status_line();
$win->addstr($y, 0, "-" x $maxx);
#$x->set_text("-> ");
$x->redraw;

my $box = new TextScroll($win, 0, $y-1);
$box->add("Starting...");
$box->redraw;

$ins = 1;
$win->addstr($y, $maxx-9, "Ins");

my $channel_original = "$channel";

my $sock = new IO::Socket::INET(PeerAddr => $server, PeerPort => $port, Proto=>'tcp') or die "Can't create connection.";
print $sock "NICK $nick\r\n";
print $sock "USER $login 8 * :$login\r\n";
print $sock "JOIN $channel\r\n";

my $readers = IO::Select->new() or die "Can't create IO::Select object";
$readers->add(\*STDIN);
$readers->add($sock);
my ($buffer,$input);

sub my_quote_on {
    my ($y, $maxx) = $x->status_line();
    $win->addstr($y, $maxx-5, "Quo");
}
sub my_quote_off {
    my ($y, $maxx) = $x->status_line();
    $win->addstr($y, $maxx-5, "---");
}
sub my_insert_toggle {
    $ins = $x->{"insert_mode"};
    my ($y, $maxx) = $x->status_line();
    $win->addstr($y, $maxx-9, ($ins ? "Ins" : "---"));
}

sub my_height_change {
    my ($y, $maxx) = $x->status_line();

    $box->resize_bottom($y-1);
    $win->addstr($y, 0, "-" x $maxx);
    $win->addstr($y, $maxx-9, ($ins ? "Ins" : "---"));
}

sub my_resize {
    &my_height_change(@_);
    $box->redraw();
}

$x->{"keymap"}->{"meta1-\cX"} = \&TextEntry::reset;

# make a pretty status line notice for quote mode & insert mode
$x->{"signals"}->{"quote-on"} = \&my_quote_on;
$x->{"signals"}->{"quote-off"} = \&my_quote_off;
$x->{"signals"}->{"insert-toggle"} = \&my_insert_toggle;
$x->{"signals"}->{"height-change"} = \&my_height_change;
$x->{"signals"}->{"resize"} = \&my_resize;

@twirl = ( "^", ">", "v", "<" );
$t = 0;
while (1) {

	($y, $maxx) = $x->status_line();
	$win->addch($y, 1, $twirl[$t]);
	$t = ($t+1) % 4;

	my @ready = $readers->can_read;
	
	for my $handle (@ready) {

		if ($handle eq \*STDIN) {
			$x->poll(5);	
			if ($x->{"complete"}) {
				$buffer=$x->get_text();

				if (lc($buffer) eq "/quit") {
					endwin();
					exit 0;
				} 
				
				if (lc($buffer) =~ /^!raw (.+)$/) {
					print $sock "$1\r\n";
				}
				
				if (lc($buffer) =~ /^!nick (.+)$/) {
					print $sock "NICK :$1\r\n";
				}
				
				if (lc($buffer) =~ /^!join (.+)$/) {
					print $sock "PART $channel :Leaving.\r\n";
					$channel="$1";
					print $sock "JOIN $channel\r\n";
				}
				
				if (lc($buffer) =~ /^!part (.+)$/) {
					print $sock "PART $channel :Leaving.\r\n";
					print $sock "JOIN $channel_original\r\n";
				}

				if (lc($buffer) =~ /^!restart/) {
					print $sock "QUIT :Restarting...\r\n";
					endwin();
					exec("$prog_name");
				}

				if (lc($buffer) =~ /^!quit+\ (.+)$/) {
					print $sock "QUIT :$1\r\n";
					endwin();
					exit 0;
				}

				else {
					print $sock "PRIVMSG $channel :$buffer\r\n";
					$box->add("$nick @ $channel: $buffer");
				}
				 
				$x->reset();
				$x->{"window"}->move($x->cursor_coords());
				$x->{"window"}->refresh();
				
			} 
		}

		if ($handle eq $sock) {
			$input=<$sock>;
			$input =~ s/\r|\n//g;

			#if( "$input" =~ /^:[^\ ]+\ +372\ +/ ) {  }
			#else { 
				if( "$input" =~ /^:([^ !]+)!.+\ PRIVMSG+\ +(.+)/ ) {
					$box->add("$1 $2"); 
				} else {
					$box->add("$input"); 
				}
			#}

			$x->{"window"}->move($x->cursor_coords());
			$x->{"window"}->refresh();
			if( $input =~ /^PING :(.+)$/) {
				#print "pong :$input";
				print $sock "PONG :$1";
			}
		}
	}
}

endwin();

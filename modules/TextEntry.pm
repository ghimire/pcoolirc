#!/usr/bin/perl -w
#
# text entry widget for ncurses (in perl).
# sort of a hybrid between the ircII/EPIC and TinyFugue text entries.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation; either version 2, or (at your option) any
# later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
#
# (c) August 2000 by Robey Pointer
#
# I coded this on the (long) night of 18 August 2000, with the help of 3
# keg-shaped Heineken cans.  The number of features it supports is fairly
# frightening:
# * Supports the usual emacs control keys (C-a/e/b/f/p/n/k/u/l/d) by default,
#   as well as the equivalent PC keyboard keys (home, end, arrow keys, insert).
# * Has insert and overwrite modes.
# * Uses a completely configurable per-widget keymap, which can be used to
#   hook your program into special hotkeys, or also to remap keys to fit your
#   aesthetic.
# * Has 3 "meta-key" actions that can be assigned to keys in the keymap.  These
#   are combined with the following keystroke to make a new keymap entry.  For
#   example, if you set \cX to action_meta1, then if the user hits "C-x n", it
#   will trigger the keymap entry for "meta1-n".
# * Emits a few signals to notify you of a few things, like the screen being
#   resized.
# * Normally it sits at the bottom of the screen and takes up N lines.  You can
#   tell it to expand/shrink within a range of lines (like from 2 to 5 lines),
#   and it will start at the smallest size, expanding as the user types more
#   and more.  A signal is emitted whenever the widget grows or shrinks in this
#   way, so that you can resize other widgets.
# * Keeps a history of past text entries in this widget, which can be viewed
#   and edited by the user.  (Whether those edits are kept is a config option.)
#
#
# BUGS:
# * will that \cC weirdness work?
#
use strict;
use Curses;

package TextEntry;
use vars qw(
	%ACTION
	%default_keymap
	%default_signals
	);

# internal fields:
# height (# of rows to use)
# window (curses window to sit at the bottom of)
# text (input line so far)
# cursor (cursor's location, relative to zero)
# maxx, maxy (cached values of the window size)
# complete (set when the user has hit enter)
# insert_mode (chars should insert instead of overwriting)
# quote_mode (true when the next char is being quoted)
# meta_mode (1-5 if we're in a meta mode)
# expand_max (if set, let the text entry's height expand to N lines)
# expand_min (if set, start the text entry's height at N lines)
# history (list of previous entries)
# history_index (history entry in use)
# history_max (maximum number of items in the history list)
# history_buffer (temporary storage of text entry while browsing the history)
# history_keep_changes (if a history entry is edited but not entered, should those
#     changes be saved or tossed?)
# keymap (...)

# convenient names for keymap actions
%ACTION = (
           "self" => \&action_insert,
           "home" => \&action_home,
           "end" => \&action_end,
           "left" => \&action_left,
           "right" => \&action_right,
           "enter" => \&action_enter,
           "backspace" => \&action_backspace,
           "delete" => \&action_delete,
           "delete-eol" => \&action_deltoeol,
           "clear-entry" => \&action_clear,
           "redraw" => \&action_redraw,
           "history-prev" => \&action_history_up,
           "history-next" => \&action_history_down,
           "insert-mode" => \&action_toggle_insert,
           "quote-mode" => \&action_quote,
           "transpose" => \&action_transpose,
           "meta1" => \&action_meta1,
           "meta2" => \&action_meta2,
           "meta3" => \&action_meta3,
           "meta4" => \&action_meta4,
           "meta5" => \&action_meta5
);

# default action is to insert that key
%default_keymap = (
                   "\cA" => \&action_home,
                   "\cB" => \&action_left,
                   "\cD" => \&action_delete,
                   "\cE" => \&action_end,
                   "\cF" => \&action_right,
                   "\cH" => \&action_backspace,
                   "\cK" => \&action_deltoeol,
                   "\cL" => \&action_redraw,
                   "\cM" => \&action_enter,
                   "\cN" => \&action_history_down,
                   "\cO" => \&action_toggle_insert,
                   "\cP" => \&action_history_up,
                   "\cT" => \&action_transpose,
                   "\cU" => \&action_clear,
                   "\cV" => \&action_quote,
                   "\cX" => \&action_meta1,
                   "\x7F" => \&action_backspace,
                   "backspace" => \&action_backspace,
                   "home" => \&action_home,
                   "end" => \&action_end,
                   "left" => \&action_left,
                   "right" => \&action_right,
                   "up" => \&action_history_up,
                   "down" => \&action_history_down,
                   "insert" => \&action_toggle_insert,
                   "meta1-v" => \&action_quote,
                   "meta1-V" => \&action_quote
);
# also: f1 - f12

# special signals:
#     quote-on (triggered when a quoted keypress begins)
#     quote-off (triggered when a quoted keypress ends)
#     insert-toggle (insert mode has changed state)
#     height-change (triggered when text entry shrinks or expands)
#     resize (triggered when a WINCH event occurs)
%default_signals = ( );

# set up the initial fields
sub init {
    my $self = shift;
    $self->{"height"} = 1;
    $self->{"window"} = $Curses::stdscr;
    $self->{"text"} = "";
    $self->{"cursor"} = 0;
    $self->{"complete"} = 0;
    $self->{"insert_mode"} = 1;
    $self->{"expand_max"} = 1;
    $self->{"expand_min"} = 1;
    my %keymap = %default_keymap;
    my %signals = %default_signals;
    $self->{"keymap"} = \%keymap;
    $self->{"signals"} = \%signals;
    $self->{"history"} = [ ];
    $self->{"history_index"} = 0;
    $self->{"history_max"} = 20;
    $self->{"history_keep_changes"} = 1;
}

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my ($window, $height) = @_;
    my $self = { };

    bless($self, $class);
    $self->init();
    $self->{"window"} = $window if (defined $window);
    $self->{"height"} = $height if (defined $height);

    # have to set the INT signal handler so we can catch C-c
    $::SIG{INT} = sub { Curses::ungetch("\cC"); };

    return $self;
}

# &putch(win, y, x, ch);
sub putch {
    my ($win, $y, $x, $ch) = @_;

    if ($ch =~ /[\040-\176\240-\377]/) {
        $win->addch($y, $x, $ch);
        return;
    }
    eval { $win->attron(Curses::A_REVERSE); };
    if ($ch =~ /[\000-\037]/) {
        $win->addch($y, $x, chr(ord($ch)+64));
    } elsif ($ch =~ /\177/) {
        $win->addch($y, $x, "?");
    } else {	# \200-\237
        $win->addch($y, $x, chr(ord($ch)-32));
    }
    eval { $win->attroff(Curses::A_REVERSE); };
}

sub getmax {
    my $self = shift;
    my ($maxx, $maxy);

    $self->{"window"}->getmaxyx($maxy, $maxx);
    $self->{"maxx"} = $maxx;
    $self->{"maxy"} = $maxy;
}

# return where the status line should be, and the length of x:
# (y-coord, x-length)
sub status_line {
    my $self = shift;

    $self->getmax();
    return ($self->{"maxy"} - $self->{"height"} - 1, $self->{"maxx"});
}

# clear the display area
sub clear {
    my $self = shift;
    my $i;

    for ($i = $self->{"maxy"} - $self->{"height"}; $i < $self->{"maxy"}; $i++) {
        $self->{"window"}->move($i, 0);
        $self->{"window"}->clrtoeol();
    }
}

sub redraw {
    my $self = shift;
    my ($i, $maxx, $maxy);

    $self->getmax();
    $self->clear();
    $self->redraw_to_eol(0);

    $self->{"window"}->move($self->cursor_coords());
    $self->{"window"}->refresh();
}

sub notify_expand {
    my $self = shift;

    &{$self->{"signals"}->{"height-change"}}($self)
      if (exists $self->{"signals"}->{"height-change"});
}

sub reset {
    my $self = shift;

    if ($self->{"height"} != $self->{"expand_min"}) {
        # shrink to min height
        $self->{"height"} = $self->{"expand_min"};
        $self->notify_expand();
    }
    $self->{"cursor"} = 0;
    $self->{"text"} = "";
    $self->clear();
    $self->{"window"}->refresh();
    $self->{"complete"} = 0;
    $self->{"history_buffer"} = "";
    $self->{"history_index"} = $#{$self->{"history"}} + 1;
}

# called if we're about to try to add a char to the text.
# if the text is filling up the max amount of space it can hold, and expand is on,
# and we still have room to expand, then we do.
sub check_expand {
    my $self = shift;

    return if ($self->{"height"} == $self->{"expand_max"});
    return if (length($self->{"text"}) < $self->{"maxx"} * $self->{"height"} - 1);
    $self->{"height"}++;
    $self->notify_expand();
    $self->redraw();
}

sub set_text {
    my $self = shift;
    my $text = shift;
    my $expando = 0;

    $self->getmax();
    if (length($text) >= $self->{"maxx"} * $self->{"expand_max"}) {
        $text = substr($text, 0, $self->{"maxx"} * $self->{"expand_max"} - 1);
    }
    # might have to expand...
    while (length($text) >= $self->{"maxx"} * $self->{"height"}) {
        $self->{"height"}++;
        $expando = 1;
    }
    $self->notify_expand() if ($expando);
    
    $self->{"text"} = $text;
    $self->{"cursor"} = length($self->{"text"});
    $self->redraw();
}

sub get_text {
    my $self = shift;
    return $self->{"text"};
}

sub set_expand {
    my $self = shift;
    my ($min, $max) = @_;
    
    $self->{"expand_min"} = $min;
    $self->{"expand_max"} = $max;
    if ($self->{"expand_min"} > $self->{"height"}) {
        $self->{"height"} = $self->{"expand_min"};
        $self->notify_expand();
        $self->redraw();
    }
    if ($self->{"expand_max"} < $self->{"height"}) {
        $self->{"height"} = $self->{"expand_max"};
        $self->notify_expand();
        $self->set_text($self->{"text"});
    }
}

sub get_expand {
    my $self = shift;
    return ($self->{"expand_min"}, $self->{"expand_max"});
}

sub cursor_coords {
    my $self = shift;
    my $n = shift;
    $n = $self->{"cursor"} if (! defined $n);

    return ($self->{"maxy"} - $self->{"height"} + ($n / $self->{"maxx"}),
            $n % $self->{"maxx"});
}

# redraw from cursor position 'n' to EOL
sub redraw_to_eol {
    my $self = shift;
    my $n = shift;
    my $i;
    
    $n = $self->{"cursor"} if (! defined $n);
    for ($i = $n; $i < length($self->{"text"}); $i++) {
        &putch($self->{"window"}, $self->cursor_coords($i),
               substr($self->{"text"}, $i, 1));
    }
}

##
##  functions that can be mapped to keys
##

sub action_backspace {
    my $self = shift;
    
    return if (! length($self->{"text"}));
    return if ($self->{"cursor"} == 0);
    
    $self->{"cursor"}--;
    $self->{"text"} = substr($self->{"text"}, 0, $self->{"cursor"}) .
      ($self->{"cursor"}+1 == length($self->{"text"}) ? "" :
       substr($self->{"text"}, $self->{"cursor"}+1));
    
    $self->redraw_to_eol();
    $self->{"window"}->addch($self->cursor_coords(length($self->{"text"})), " ");
}

sub action_delete {
    my $self = shift;

    return if ($self->{"cursor"} == length($self->{"text"}));
    
    $self->{"cursor"}++;
    $self->action_backspace();
}

# an emacs-ism.  we like those.
sub action_deltoeol {
    my $self = shift;
    
    return if ($self->{"cursor"} == length($self->{"text"}));
    $self->{"text"} = substr($self->{"text"}, 0, $self->{"cursor"});
    # FIXME: might it be worth it to go ahead and manually redraw the deleted portions?
    $self->redraw();
}

sub action_clear {
    my $self = shift;
    
    $self->{"text"} = "";
    $self->{"cursor"} = 0;
    $self->redraw();
}

sub action_enter {
    my $self = shift;
    
    $self->{"complete"} = 1;
    push @{$self->{"history"}}, $self->{"text"} if (length($self->{"text"}));
    shift @{$self->{"history"}} if ($#{$self->{"history"}} >= $self->{"history_max"});
    return;
}

sub action_insert {
    my $self = shift;
    my $ch = shift;

    if ($self->{"insert_mode"}) {
        $self->check_expand();
        return if (length($self->{"text"}) >= $self->{"maxx"} * $self->{"height"} - 1);
        $self->{"text"} = substr($self->{"text"}, 0, $self->{"cursor"}) . $ch .
          substr($self->{"text"}, $self->{"cursor"});
        
        $self->redraw_to_eol();
    } else {
        # overwrite mode
        if ($self->{"cursor"} == length($self->{"text"})) {
            $self->check_expand();
            return if ($self->{"cursor"} >= $self->{"maxx"} * $self->{"height"} - 1);
        }
        $self->{"text"} = substr($self->{"text"}, 0, $self->{"cursor"}) . $ch .
  ($self->{"cursor"} == length($self->{"text"}) ? "" :
   substr($self->{"text"}, $self->{"cursor"}+1));
        
        &putch($self->{"window"}, $self->cursor_coords(), $ch);
    }
    $self->{"cursor"}++;
}

sub action_home {
    my $self = shift;

    $self->{"cursor"} = 0;
}

sub action_end {
    my $self = shift;

    $self->{"cursor"} = length($self->{"text"});
}

sub action_right {
    my $self = shift;

    return if ($self->{"cursor"} == length($self->{"text"}));
    $self->{"cursor"}++;
}

sub action_left {
    my $self = shift;

    return if ($self->{"cursor"} == 0);
    $self->{"cursor"}--;
}

sub action_transpose {
    my $self = shift;

    return if ($self->{"cursor"} == 0);
    my $temp = substr($self->{"text"}, $self->{"cursor"}-1, 1);
    substr($self->{"text"}, $self->{"cursor"}-1, 1) =
      substr($self->{"text"}, $self->{"cursor"}, 1);
    substr($self->{"text"}, $self->{"cursor"}, 1) = $temp;
    $self->redraw();
}

sub action_redraw {
    my $self = shift;
    
    $self->redraw();
}

sub action_toggle_insert {
    my $self = shift;
    
    $self->{"insert_mode"} = ! $self->{"insert_mode"};
    &{$self->{"signals"}->{"insert-toggle"}}($self)
      if (exists $self->{"signals"}->{"insert-toggle"});
}

# quote the next char
sub action_quote {
    my $self = shift;
    my $ch;

    $self->{"quote_mode"} = 1;
    $self->{"window"}->keypad(0);
    &{$self->{"signals"}->{"quote-on"}}($self, $ch)
      if (exists $self->{"signals"}->{"quote-on"});
}

sub action_history_up {
    my $self = shift;

    return if ($self->{"history_index"} == 0);
    if ($self->{"history_index"} > $#{$self->{"history"}}) {
        # save current buffer
        $self->{"history_buffer"} = $self->get_text();
    } elsif ($self->{"history_keep_changes"}) {
        # save modifications to current history entry
        $self->{"history"}->[$self->{"history_index"}] = $self->get_text();
    }
    $self->{"history_index"}--;
    $self->set_text($self->{"history"}->[$self->{"history_index"}]);
}

sub action_history_down {
    my $self = shift;

    return if ($self->{"history_index"} == $#{$self->{"history"}}+1);
    if ($self->{"history_keep_changes"}) {
        # save modifications to the current history entry
        $self->{"history"}->[$self->{"history_index"}] = $self->get_text();
    }
    $self->{"history_index"}++;
    if ($self->{"history_index"} == $#{$self->{"history"}}+1) {
        $self->set_text($self->{"history_buffer"});
    } else {
        $self->set_text($self->{"history"}->[$self->{"history_index"}]);
    }
}


sub action_meta1 { $_[0]->{"meta_mode"} = 1; }
sub action_meta2 { $_[0]->{"meta_mode"} = 2; }
sub action_meta3 { $_[0]->{"meta_mode"} = 3; }
sub action_meta4 { $_[0]->{"meta_mode"} = 4; }
sub action_meta5 { $_[0]->{"meta_mode"} = 5; }


sub keypress {
    my $self = shift;
    my $ch = shift;

    $ch = "\000" if ($ch eq "");
    my $key = "unknown";

# backspace is treated special, but should just be \cH
#    if ((length($ch) > 1) && ($ch == Curses::KEY_BACKSPACE)) {
#        $ch = "\cH";
#    }

    if (length($ch) != 1) {
        # some kind of function key
        if ($ch == Curses::KEY_UP) {
            $key = "up";
        } elsif ($ch == Curses::KEY_DOWN) {
            $key = "down";
        } elsif ($ch == Curses::KEY_LEFT) {
            $key = "left";
        } elsif ($ch == Curses::KEY_RIGHT) {
            $key = "right";
        } elsif ($ch == Curses::KEY_HOME) {
            $key = "home";
        } elsif ($ch == Curses::KEY_END) {
            $key = "end";
        } elsif ($ch == Curses::KEY_FIND) {
            # THIS MAKES NO SENSE TO ME!  ncurses sucks.
            $key = "home";
        } elsif ($ch == Curses::KEY_SELECT) {
            # THIS MAKES NO SENSE TO ME!  ncurses sucks.
            $key = "end";
        } elsif ($ch == Curses::KEY_IC) {
            $key = "insert";
        } elsif ($ch == Curses::KEY_BACKSPACE) {
            $key = "backspace";
        } elsif (($ch >= Curses::KEY_F(1)) && ($ch <= Curses::KEY_F(12))) {
            $key = "f" . ($ch - Curses::KEY_F0);
        } elsif ($ch == 410) {
            # special case!  resize event
            $self->redraw();
            &{$self->{"signals"}->{"resize"}}($self)
              if (exists $self->{"signals"}->{"resize"});
            return;
        }
    } else {
        $key = $ch;
        if ($self->{"quote_mode"}) {
            &action_insert($self, $ch);
            $self->{"quote_mode"} = 0;
            $self->{"window"}->keypad(1);

            # if there's a hook for quote-off, call it
            if (exists $self->{"signals"}->{"quote-off"}) {
                &{$self->{"signals"}->{"quote-off"}}($self, $ch);
            }
            # move cursor back
            $self->{"window"}->move($self->cursor_coords());
            $self->{"window"}->refresh();
            return;
        }
    }

    if ($self->{"meta_mode"}) {
        $key = "meta" . $self->{"meta_mode"} . "-" . $key;
        $self->{"meta_mode"} = "";
    }

    if (exists $self->{"keymap"}->{$key}) {
        &{$self->{"keymap"}->{$key}}($self, $key);
    } else {
        # self-insert (for non-specials)
        &action_insert($self, $ch) if (length($ch) == 1);
    }

    # move cursor back
    $self->{"window"}->move($self->cursor_coords());
    $self->{"window"}->refresh();
}

sub poll {
    my $self = shift;
    my $tenthsec = shift;

    $self->{"window"}->move($self->cursor_coords);
    $self->{"window"}->refresh;

    Curses::halfdelay($tenthsec);
    my $ch = $self->{"window"}->getch();
    if ((length($ch) <= 1) || ($ch != Curses::ERR)) {
	$self->keypress($ch);
	return 1;
    }
    return 0;
}

sub locate {
    my $self = shift;

    $self->{"window"}->move($self->cursor_coords);
    $self->{"window"}->refresh;
}

1;

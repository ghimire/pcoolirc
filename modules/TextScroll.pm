#!/usr/bin/perl -w
#
# text scroll widget for ncurses (in perl).
# word-wraps and formats text, adding always to the bottom and scrolling up
# interprets a subset of the CTCP/2 formatting codes:
#     * bold, underline, reverse, and italics
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
# (c) 2000 Robey Pointer
#
# BUGS:
# * need 2 (or more) columns of output
#

use Curses;
use strict;


package TextScroll;
# internal fields:
#     window (curses window to draw on)
#     top (top row to use, starting from 0)
#     bottom (bottom row to use)
#     width (width of window, gathered from curses)
#     text (list of text lines to be displayed)
#     buffer (list of text lines waiting for "more" mode to end)
#     wrap (if false, text beyond the right edge will be truncated)
#     word_wrap (if true, wrapped text will happen at word boundaries)
#     wrap_prefix (text to insert before wrapped lines, usually some spaces)
#     scrollback (max # of lines to save)
#     top_mark (first unacknowledged line of the text buffer*)
#     holding (T/F currently paused on "more")
#     more_signal (function to call when more mode turns on)

# * in more mode, this is the line that will scroll up to be the top of the
# screen (and then we'll stop scrolling up the new stuff).  otherwise, it's -1.

# special hack:  format code "XB" means to re-assert any attributes in use.
# when wrapping long lines, we turn off attributes during the indention spaces,
# then use $BREAK to reassert the attributes at the end of the indentation.
# this is purely for aesthetic reasons.
my $BREAK = "\006XB\006";

sub get_width {
    my $self = shift;
    my ($maxx, $maxy);

    $self->{"window"}->getmaxyx($maxy, $maxx);
    $self->{"width"} = $maxx;
}

# set up the initial fields
sub init {
    my $self = shift;
    $self->{"window"} = $Curses::stdscr;
    $self->{"top"} = 0;
    $self->{"bottom"} = 23;
    $self->{"text"} = [ ];
    $self->{"buffer"} = [ ];
    $self->{"wrap"} = 1;
    $self->{"word_wrap"} = 1;
    $self->{"wrap_prefix"} = "    ";
    $self->{"scrollback"} = 100;
    $self->{"top_mark"} = -1;
    $self->{"holding"} = 0;
    $self->{"more_signal"} = "";
}

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my ($window, $top, $bottom) = @_;
    my $self = { };

    bless($self, $class);
    $self->init();
    $self->{"window"} = $window if (defined $window);
    $self->{"top"} = $top if (defined $top);
    $self->{"bottom"} = $bottom if (defined $bottom);
    $self->get_width();
    return $self;
}

sub clear {
    my $self = shift;
    my $i;

    $self->get_width();
    for ($i = $self->{"top"}; $i <= $self->{"bottom"}; $i++) {
        $self->{"window"}->move($i, 0);
        $self->{"window"}->clrtoeol();
    }
}

sub reset {
    my $self = shift;

    @{$self->{"text"}} = ( );
    $self->clear();
}

# a line of text may contain formatting (wrapped in ^F blocks)
# this function counts the # of chars that are used in those
sub count_oob {
    my $text = shift;
    my $copy = $text;
    my $count = 0;

    while ($text =~ /\006([^\006]*)\006/) {
        $count += 2 + length($1);
        $text =~ s/\006([^\006]*)\006//;
    }
    return $count;
}

# find N'th character of a string, ignoring formatting chars, and return the
# true N.
sub str_find {
    my ($str, $n) = @_;
    my ($i, $j) = (0, 0);
    my $in_format = 0;

    while ($i < $n) {
        my $ch = substr($str, $j, 1);
        if ($ch eq "\006") {
            $in_format = ! $in_format;
        } elsif (! $in_format) {
            $i++;
        }
        $j++;
    }
    return $j;
}

# break a text line into as many lines as it would take to fit into this scroll
# region (following word-wrap, etc)
sub break_line {
    my $self = shift;
    my ($text) = @_;
    my @out = ( );

    if (! $self->{"wrap"}) {
        # truncate and return
        $text = substr($text, 0, &str_find($text, $self->{"width"}));
        return ($text);
    }

    if (! $self->{"word_wrap"}) {
        # just chop up at exact boundaries
        while (length($text) - &count_oob($text) > $self->{"width"}) {
            my $len = &str_find($text, $self->{"width"});
            push @out, substr($text, 0, $len);
            $text = $self->{"wrap_prefix"} . $BREAK . substr($text, $len);
        }
        push @out, $text;
        return @out;
    }

    # word-wrap it, if necessary
    my $min = 0;
    while (length($text) - &count_oob($text) > $self->{"width"}) {
        my $n = &str_find($text, $self->{"width"}-1);
        while ((substr($text, $n, 1) !~ /[ \-]/) && ($n > $min)) {
            $n--;
        }
        # if we didn't find any line-break chars, do a force break.
        $n = &str_find($text, $self->{"width"}-1) if ($n == $min);
        push @out, substr($text, 0, $n+1);
        $text = $self->{"wrap_prefix"} . $BREAK . substr($text, $n+1);
        $min = length($self->{"wrap_prefix"});
    }
    push @out, $text;
    return @out;
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

# $saved_attrs = &putline(win, y, str, old_saved_attrs)
sub putline {
    my ($win, $y, $str, $attrs) = @_;
    my ($bold, $reverse, $under, $italics) = (0, 0, 0, 0);
    my ($i, $x, $ch);

    $bold = $1 if ($attrs =~ /B(\d+)/);
    $reverse = $1 if ($attrs =~ /V(\d+)/);
    $under = $1 if ($attrs =~ /U(\d+)/);
    $italics = $1 if ($attrs =~ /I(\d+)/);

    $win->move($y, 0);
    $win->clrtoeol();
    for ($i = 0, $x = 0; $i < length($str); $i++) {
        $ch = substr($str, $i, 1);
        if ($ch eq "\006") {
            # special formatting
            my ($cmd) = (substr($str, $i+1) =~ /^([^\006]*)\006?/);
            if ($cmd =~ /^B-/) {
                $bold-- if ($bold);
                eval { $win->attroff(Curses::A_BOLD) } if (! $bold);
            } elsif ($cmd =~ /^B/) {
                eval { $win->attron(Curses::A_BOLD) } if (! $bold);
                $bold++;
            } elsif ($cmd =~ /^V-/) {
                $reverse-- if ($reverse);
                eval { $win->attroff(Curses::A_REVERSE) } if (! $reverse);
            } elsif ($cmd =~ /^V/) {
                eval { $win->attron(Curses::A_REVERSE) } if (! $reverse);
                $reverse++;
            } elsif ($cmd =~ /^U-/) {
                $under-- if ($under);
                eval { $win->attroff(Curses::A_UNDERLINE) } if (! $under);
            } elsif ($cmd =~ /^U/) {
                eval { $win->attron(Curses::A_UNDERLINE) } if (! $under);
                $under++;
            } elsif ($cmd =~ /^I-/) {
                $italics-- if ($italics);
                eval { $win->attroff(Curses::A_DIM) } if (! $italics);
            } elsif ($cmd =~ /^I/) {
                eval { $win->attron(Curses::A_DIM) } if (! $italics);
                $italics++;
            } elsif ($cmd =~ /^N/) {
                $italics = $under = $reverse = $bold = 0;
                eval { $win->attroff(Curses::A_BOLD) };
                eval { $win->attroff(Curses::A_REVERSE) };
                eval { $win->attroff(Curses::A_UNDERLINE) };
                eval { $win->attroff(Curses::A_DIM) };
            } elsif ($cmd =~ /^XB$/) {
                # re-assert attributes, following a string break
                eval { $win->attron(Curses::A_BOLD) } if ($bold);
                eval { $win->attron(Curses::A_REVERSE) } if ($reverse);
                eval { $win->attron(Curses::A_UNDERLINE) } if ($under);
                eval { $win->attron(Curses::A_DIM) } if ($italics);
            } else {
                # ignore
            }
            $i += length($cmd) + 1;
        } else {
            &putch($win, $y, $x++, substr($str, $i, 1));
        }
    }

    eval { $win->attroff(Curses::A_BOLD); };
    eval { $win->attroff(Curses::A_REVERSE); };
    eval { $win->attroff(Curses::A_UNDERLINE); };
    eval { $win->attroff(Curses::A_DIM); };

    my $out = "";
    $out .= "B$bold" if ($bold);
    $out .= "V$reverse" if ($reverse);
    $out .= "U$under" if ($under);
    $out .= "I$italics" if ($italics);
    return $out;
}

sub start_more {
    my $self = shift;

    if (! $self->{"holding"}) {
        $self->{"holding"} = 1;
        &{$self->{"more_signal"}} if ($self->{"more_signal"});
    }
}

# assemble a list of what should be showing on the screen currently
# list<logical-line> where each logical line is list<phyisical-line>
sub build_current {
    my $self = shift;
    my $i = $self->{"top_mark"};
    my $total = 0;
    my $max = $self->{"bottom"} - $self->{"top"} + 1;
    my @screen = ();

    $i = $#{$self->{"text"}} if ($i < 0);

    # first, work from the top_mark down to the bottom of the buffer
    while (($total < $max) && ($i <= $#{$self->{"text"}})) {
        my @list = $self->break_line($self->{"text"}->[$i]);
        $total += scalar(@list);
        while ($total > $max) {
            if ($self->{"top_mark"} < 0) {
                # not in more mode, so cut off the top
                shift @list;
            } else {
                # cut off the bottom
                $self->start_more();
                pop @list;
            }
            $total--;
        }
        push @screen, \@list;
        $i++;
    }

    if ($i <= $#{$self->{"text"}}) {
        $self->start_more();
        # put extra lines into the more buffer
        # (this can happen if the user resizes the screen, suddenly creating the
        # need to go into more-mode)
        while ($i <= $#{$self->{"text"}}) {
            unshift @{$self->{"buffer"}}, (pop @{$self->{"text"}});
        }
        return @screen;
    }

    # now, work backwards from that mark
    $i = $self->{"top_mark"} - 1;
    $i = $#{$self->{"text"}} - 1 if ($i < 0);
    while (($total < $max) && ($i >= 0)) {
        my @list = $self->break_line($self->{"text"}->[$i]);
        $total += scalar(@list);
        while ($total > $max) {
            shift @list;
            $total--;
        }
        unshift @screen, \@list;
        $i--;
    }

    while ($total < $max) {
        unshift @screen, [ "" ];
        $total++;
    }

    return @screen;
}

sub redraw {
    my $self = shift;
    my $line = $self->{"top"};

    $self->get_width();
    my @screen = $self->build_current();
    while ($line <= $self->{"bottom"}) {
        my @list = @{shift @screen};
        my $attr = "";
        foreach my $str (@list) {
            $attr = &putline($self->{"window"}, $line, $str, $attr);
            $line++;
        }
    }
    $self->{"window"}->refresh();
}

sub redraw_old {
    my $self = shift;
    my $y = $self->{"bottom"};
    my $line = $#{$self->{"text"}};

    $self->get_width();
    while (($line >= 0) && ($y >= $self->{"top"})) {
        my @list = $self->break_line($self->{"text"}->[$line]);
        my $attr = "";
        my $i = 0;
        $i = $#list-$y if ($y-$#list < $self->{"top"});
        while ($i <= $#list) {
            $attr = &putline($self->{"window"}, $y-$#list+$i, $list[$i], $attr);
            $i++;
        }
        $y -= ($#list + 1);
        $line--;
    }
    while ($y >= $self->{"top"}) {
        $self->{"window"}->move($y, 0);
        $self->{"window"}->clrtoeol();
        $y--;
    }
    $self->{"window"}->refresh();
}

sub add {
    my $self = shift;
    my $text = shift;

    if ($self->{"holding"}) {
        # when waiting for [MORE], buffer the lines
        push @{$self->{"buffer"}}, $text;
        return;
    }

    my @list = $self->break_line($text);

    if ($self->{"top_mark"} >= 0) {
        my $lines_left = $self->{"bottom"} - $self->{"top"} + 1;
        my $i;

        for ($i = $self->{"top_mark"}; $i <= $#{$self->{"text"}}; $i++) {
            my @list2 = $self->break_line($self->{"text"}->[$i]);
            $lines_left -= scalar(@list2);
        }
        if ($lines_left == 0) {
            # perfect fill!
            $self->start_more();
            push @{$self->{"buffer"}}, $text;
            return;
        }
        while ($lines_left < scalar(@list)) {
            $self->start_more();
            pop @list;
            # make secret note to self that i displayed a half-line:
            $self->{"holding"} = 2;
        }
    }

    while (scalar(@{$self->{"text"}}) >= $self->{"scrollback"}) {
        shift @{$self->{"text"}};
        $self->{"top_mark"}-- if ($self->{"top_mark"} >= 0);
    }
    push @{$self->{"text"}}, $text;

    # scroll N lines up
    $self->{"window"}->idlok(1);
    $self->{"window"}->scrollok(1);
    $self->{"window"}->setscrreg($self->{"top"}, $self->{"bottom"});
    $self->{"window"}->scrl(scalar(@list));
    $self->{"window"}->scrollok(0);

    my $attr = "";
    my ($i, $y) = (0, $self->{"bottom"});
    $i = $#list-$y if ($y-$#list < $self->{"top"});
    while ($i <= $#list) {
        $attr = &putline($self->{"window"}, $y-$#list+$i, $list[$i], $attr);
        $i++;
    }
    $self->{"window"}->refresh();
}

# user hit enter, or something else that makes us reset the MORE count
sub clear_more {
    my $self = shift;
    my @buffer = @{$self->{"buffer"}};

    if (! $self->{"holding"}) {
        $self->{"top_mark"} = scalar(@{$self->{"text"}});
        return;
    }
    $self->{"buffer"} = [ ];
    $self->{"top_mark"} = scalar(@{$self->{"text"}});
    if ($self->{"holding"} == 2) {
        $self->{"top_mark"}--;
        $self->redraw;
    }
    $self->{"holding"} = 0;
    # dump buffer into the scroll region, as if it was just typed.  any overflow will
    # return to the buffer all over again.
    while (scalar(@buffer)) {
        $self->add(shift @buffer);
    }
}

# change bottom edge
sub resize_bottom {
    my $self = shift;
    my $bottom = shift;

    if ($bottom < $self->{"bottom"}) {
        # just scroll up
        $self->{"window"}->idlok(1);
        $self->{"window"}->scrollok(1);
        $self->{"window"}->setscrreg($self->{"top"}, $self->{"bottom"});
        $self->{"window"}->scrl($self->{"bottom"} - $bottom);
        $self->{"window"}->scrollok(0);
        $self->{"bottom"} = $bottom;
    } else {
        # could do something clever, but easiest just to redraw
        $self->{"bottom"} = $bottom;
        $self->redraw;
    }
}

sub set_more_mode {
    my $self = shift;
    my $mode = shift;

    if ($mode) {
        $self->{"top_mark"} = $#{$self->{"text"}} if ($self->{"top_mark"} < 0);
        $self->{"top_mark"} = 0 if ($self->{"top_mark"} < 0);
    } else {
        $self->{"top_mark"} = -1;
        if ($self->{"holding"}) {
            $self->{"holding"} = 0;
            $self->redraw;
        }
    }
}

sub get_more_lines {
    my $self = shift;

    return scalar(@{$self->{"buffer"}});
}

sub debug {
    my $self = shift;

    return sprintf("(top:%d,txt:%d,buf:%d,%d)", $self->{"top_mark"}, scalar(@{$self->{"text"}}),
                   scalar(@{$self->{"buffer"}}), $self->{"holding"});
}


1;

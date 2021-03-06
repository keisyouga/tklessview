#!/bin/sh
# Tcl ignores the next line -*- tcl -*- \
    exec wish "$0" -- "$@"

package require Tk
package require ctext

################################################################
# functions

proc not_implemented {title} {
	tk_messageBox -title $title -message "command not implemented"
}

# exit program
proc do_quit {} {
	# workaround:
	# without `wm withdraw .', x11 lost key input when program exit
	wm withdraw .
	destroy .
}

# append new name to combobox
proc append_file_name {name} {
	set files [.bar.fname cget -values]
	if {[lsearch -exact $files $name] < 0} {
		.bar.fname configure -values [concat $files $name]
	}
}

# remove all name from combobox
proc remove_file_name {name} {
	set files [.bar.fname cget -values]
	set newfiles [lsearch -exact -all -not -inline $files $name]
	.bar.fname configure -values $newfiles
	set_file_number
}

# data is utf-8 string?
proc is_utf8 {data} {
	# data into v as 8-bit unsigned integer
	set ret [binary scan $data cu* v]
	if {$ret != 1} {
		# binary scan failed?
		return 0
	}

	set num_char 1;             # 1: first byte
	foreach x $v {
		switch -glob $num_char {
			1 {
				# first byte of character
				if {[expr $x < 0b10000000]} {
					# 7bit ascii
					set num_char 1
				} elseif {[expr 0b11000000 <= $x && $x < 0b11100000]} {
					# first of 2 byte chahacter
					set num_char 2
				} elseif {[expr 0b11100000 <= $x && $x < 0b11110000]} {
					# first of 3 byte chahacter
					set num_char 3
				} elseif {[expr 0b11110000 <= $x && $x < 0b11111000]} {
					# first of 4 byte chahacter
					set num_char 4
				} elseif {[expr 0b11111000 <= $x && $x < 0b11111100]} {
					# first of 5 byte chahacter
					set num_char 5
				} elseif {[expr 0b11111100 <= $x && $x < 0b11111110]} {
					# first of 6 byte chahacter
					set num_char 6
				} else {
					# invalid utf-8
					return 0
				}
			}
			[23456] {
				# 2-6th byte of chahacter
				if {![expr 0b10000000 <= $x && $x <=0b10111111]} {
					# invalid byte
					return 0
				}
				incr num_char -1
			}
			default {
				# never happen
				return 0
			}
		}
	}
	return 1
}

# read first 1000 byte from channel ch, and guess encoding.
# currently support utf-8 only, return "utf-8" or "".
proc guess_encoding {ch} {
	# store original encoding
	set orig [fconfigure $ch -encoding]
	# read as binary data
	fconfigure $ch -encoding binary
	set buf [read $ch 1000]
	# restore channel setting
	seek $ch 0
	fconfigure $ch -encoding $orig

	set enc ""
	if {[is_utf8 $buf]} {
		set enc "utf-8"
	}
	return $enc
}

# read file and insert its content into text widget
# return name if success to open file
proc read_file {w name} {
	global current_filename
	global entry_filename
	global done_reading
	global coding_system_read

	if {!([file isfile $name] && [file readable $name])} {
		# remove name from combobox's file list
		remove_file_name $name
		set entry_filename $current_filename
		set_file_number
		return
	}

	set current_filename $name
	set entry_filename $name
	set f [open $current_filename r]

	# set coding system for read
	# if $coding_system_read is not empty, use it.
	# otherwise try to guess encoding
	if {$coding_system_read ne ""} {
		fconfigure $f -encoding $coding_system_read
	} else {
		set enc [guess_encoding $f]
		if {$enc ne ""} {
			fconfigure $f -encoding $enc
		}
	}

	# add decompress transformation to channel for *.gz file.
	# zlib push don't support seeking, so place this code after guess_encoding
	# which uses seek.
	if {[string match "*.gz" $name]} {
		zlib push gunzip $f
	}

	# set combobox, label
	append_file_name $name
	set_file_number

	# erase previous content
	$w delete 1.0 end
	# delete `search' tag
	$w tag delete search

	# cancel previous read_file_internal event
	foreach i [after info] {
		after cancel $i
	}

	# read asynchronous
	set done_reading 0
	read_file_internal $w $f

	return $name
}

# this procedure is called by read_file
proc read_file_internal {w f} {
	global done_reading

	if {![eof $f]} {
		# save position
		set pos [$w index insert]
		$w insert end [read $f 0x10000]
		# restore position
		$w mark set insert $pos
		after 100 "read_file_internal $w $f"
	} else {
		set done_reading 1
		close $f
	}
}

# prepare commands
proc get_ready {} {
	global preceding_number
	focus .ctext
	set preceding_number ""
}

# cancel action, ready to command
proc do_cancel {} {
	get_ready
}

# append digit to precedence number
proc do_number {d} {
	global preceding_number
	set preceding_number [string cat $preceding_number $d]
}

# open (examine) new file
proc do_examine {} {
	set name [.bar.fname get]
	read_file .ctext $name
	get_ready
}

# set file label "current/max"
proc set_file_number {} {
	set cur [expr 1 + [.bar.fname current]]
	set max [llength [.bar.fname cget -values]]
	.bar.fno configure -text "$cur/$max"
}

# return preceding number or default
# d: if no preceding_number, return d
proc get_precedence {d} {
	global preceding_number
	if {$preceding_number ne ""} {
		return $preceding_number
	} else {
		return $d
	}
}

# scroll line.
# cursor(insert) is moved also.
# sign: + or -
# num: number of lines to scroll
proc scroll_line {sign num} {
	set w .ctext

	set pos [expr [$w index insert] $sign $num]
	$w mark set insert $pos
	$w yview insert
	get_ready
}

# scroll lines forward
proc do_forward_line {{sign +}} {
	scroll_line $sign [get_precedence 1]
}

# scroll lines backward
proc do_backward_line {} {
	do_forward_line -
}

# calculate number of lines in a window
proc calculate_window_lines {w} {
	$w count -lines [$w index @0,0] [$w index @0,[winfo height $w]]
}

# scroll pages
proc scroll_page {sign} {
	global window_lines
	if {$window_lines ne ""} {
		scroll_line $sign $window_lines
	} else {
		set w .ctext
		scroll_line $sign [calculate_window_lines $w]
	}
}

# scroll pages forward
proc do_forward_page {{sign +}} {
	set num [get_precedence 0]
	if {$num eq 0} {
		scroll_page $sign
	} else {
		scroll_line $sign $num
	}
}

# scroll pages backward
proc do_backward_page {} {
	do_forward_page -
}


# scroll pages forward and set
proc do_forward_page_set {{sign +}} {
	global window_lines
	set num [get_precedence 0]
	if {$num > 0} {
		# set window line size
		set window_lines $num
	}
	scroll_page $sign
}

# scroll pages backward and set
proc do_backward_page_set {} {
	do_forward_page_set -
}

# scroll forward half page and set
proc do_forward_window_half_set {{sign +}} {
	global half_window_lines
	set num [get_precedence 0]

	if {$num > 0} {
		# set half window line size
		set half_window_lines $num
	}

	if {$half_window_lines eq ""} {
		# calculate half window lines
		# half_window_lines is unchanged
		set w .ctext
		set num [expr [calculate_window_lines $w] / 2]
	} else {
		set num $half_window_lines
	}
	scroll_line $sign $num
}

# scroll backward half page and set
proc do_backward_window_half_set {} {
	do_forward_window_half_set -
}

# version
proc do_version {} {
	tk_messageBox -title "tklessview" -message "less-like text viewer"
}

# help
proc do_help {} {
	tk_messageBox -title "help" -message \
	    "q	quit
h	help
0-9	number prefix
j	forward line
k	backward line
f	forward page
b	backward page
z	forward page
	(and set page size)
w	backward page
	(and set page size)
d	forward half-page
	(and set half-page size)
u	backward half-page
	(and set half-page size)
g	first line
G	last line
:e	examine file
:n	next file
:p	previous file
/	search forward
?	search backward
n	repeat search
N	reverse search
m<letter>	set mark
'<letter>	go to mark
Control+	zoom in
Control-	zoom out
"
}

# go to line num in the file
proc goto_line {num} {
	set w .ctext
	$w mark set insert $num.0
	$w yview insert
	get_ready
}

# go to last
proc goto_last {} {
	set w .ctext
	$w mark set insert end
	$w yview insert
	# move cursor to top of widget
	$w mark set insert [$w index @0,0]
	get_ready
}

# go to first or preceding_number line
proc do_goto_first {} {
	set num [get_precedence 1]
	goto_line $num
}

# go to last or preceding_number line
proc do_goto_last {} {
	set num [get_precedence ""]
	if {$num ne ""} {
		goto_line $num
	} else {
		goto_last
	}
}

# move to $preceded_number percent of whole buffer
proc do_goto_percent {} {
	set num [get_precedence 0]
	set fraction [expr $num / 100.0]
	set w .ctext
	$w yview moveto $fraction
	# move cursor to top of widget
	$w mark set insert [$w index @0,0]

	get_ready
}

# tag search_string and search next
proc tag_text {} {
	global search_string
	global highlighted
	global search_regexp
	global search_ignorecase

	set highlighted 1
	set w .ctext
	set swtiches "-all -count lengths"
	if {$search_ignorecase} {lappend swtiches "-nocase"}
	if {$search_regexp} {lappend swtiches "-regex"}
	$w tag delete search
	$w tag configure search -foreground yellow -background red
	set curs [$w search {*}$swtiches "$search_string" 1.0 end]
	for {set i 0} {[lindex $curs $i] ne ""} {incr i} {
		$w tag add search [lindex $curs $i] "[lindex $curs $i] + [lindex $lengths $i] char"
	}
}

# search for new string
proc do_search {} {
	global search_forwards
	tag_text
	repeat_search $search_forwards
}

# prompt to search forward
proc do_search_forward {} {
	global search_forwards
	set search_forwards 1
	set l .bar.sl
	set e .bar.se
	$l configure -text "/"
	focus $e
	$e selection range 0 end
}

# prompt to search backward
proc do_search_backward {} {
	global search_forwards
	set search_forwards 0
	set l .bar.sl
	set e .bar.se
	$l configure -text "?"
	focus $e
	$e selection range 0 end
}

# move to next/prev search tag
proc repeat_search {forwards} {
	set w .ctext
	# search count
	set count [get_precedence 1]
	# current cursor position
	set cur [$w index insert]

	# if no `search' tag, do tag search_string
	if {[lsearch [$w tag names] search] < 0} {
		tag_text
	}

	while {$count > 0} {
		# search tagname "search"
		# if found, return first and last range of character
		if {$forwards} {
			set range [$w tag nextrange search "$cur + 1 char"]
		} else {
			set range [$w tag prevrange search "$cur - 1 char"]
		}

		# not found
		if {$range eq ""} {
			get_ready
			return
		}
		# store first character found
		set cur [lindex $range 0]
		incr count -1
	}

	set index [lindex $range 0]
	$w mark set insert $index
	$w yview insert
	get_ready
}

# move to next search tag
proc do_repeat_next_search {} {
	global search_forwards
	repeat_search $search_forwards
}

# move to previous search tag
proc do_repeat_previous_search {} {
	global search_forwards
	repeat_search [expr !$search_forwards]
}

proc do_toggle_highlight {} {
	global highlighted
	set w .ctext
	set tag search

	if {$highlighted} {
		$w tag configure $tag -foreground black -background white
	} else {
		$w tag configure $tag -foreground yellow -background red
	}
	set highlighted [expr !$highlighted]
}

# read nth file in file list
# index start from 0
proc read_nth_file {n} {
	read_file .ctext [lindex [.bar.fname cget -values] $n]
	get_ready
}

# read $preceded_number-th file in file list
proc do_nth_file {} {
	set num [get_precedence 0]

	if {$num > 0} {
		incr num -1
	}
	read_nth_file $num
}

# read next file in file list
proc do_next_file {} {
	set cur [.bar.fname current]
	set num [get_precedence 1]
	read_nth_file [expr $cur + $num]
}

# read previous file in file list
proc do_previous_file {} {
	set cur [.bar.fname current]
	set num [get_precedence 1]
	read_nth_file [expr $cur - $num]
}

# remove name from file list
proc do_remove_file {} {
	global entry_filename
	remove_file_name $entry_filename
}

# mark current filename and position
proc mark_position {letter} {
	global marked_positions
	global current_filename
	set pos [.ctext index insert]
	dict set marked_positions $letter [list $current_filename $pos]

	# add color to marked position
	set w .ctext
	$w tag delete mark$letter
	$w tag configure mark$letter -foreground green -background pink
	$w tag add mark$letter $pos

	get_ready
}

# go to marked position
proc goto_marked {letter} {
	global marked_positions
	global done_reading
	global current_filename

	# get marked position
	if {[catch {dict get $marked_positions $letter} m]} {
		# this letter is not used in dict
		;
	} else {
		# filename
		set f [lindex $m 0]
		# position
		set p [lindex $m 1]
		set w .ctext
		# marked position is not in current file?
		if {$current_filename ne $f} {
			# read file marked in $letter
			read_file .ctext $f
			# wait for finish reading a file
			while {!$done_reading} {
				vwait done_reading
			}
		}
		# go to position marked in $letter
		$w mark set insert $p
		$w yview insert
	}
	get_ready
}

# set fontsize to current size + $num
proc font_resize {w num} {
	set spec [font actual [$w cget -font]]
	set oldsize [dict get $spec -size]
	dict set spec -size [expr $oldsize + $num]
	font configure TkFixedFont {*}$spec
}

# change font
proc apply_font {font} {
	font configure TkFixedFont {*}[font actual $font]
}

# select font dialog
proc select_font {} {
	tk fontchooser configure -font TkFixedFont -command apply_font
	tk fontchooser show
}

# generate list for filename completion
proc generate_completion {str} {
	global completion_list
	if {$str eq ""} {
		return
	}
	catch {
		set completion_list [glob -nocomplain "$str*"]
	}
	# insert original string to candidates
	lappend completion_list $str
}

# return next candidate in completion_list
proc completion_next {} {
	global completion_list
	# shift list {a b c d} => {b c d a}
	set item [lindex $completion_list 0]
	set completion_list [lrange $completion_list 1 end]
	lappend completion_list $item

	return $item
}

# return previous candidate in completion_list
proc completion_prev {} {
	global completion_list
	# pop list {a b c d} => {d a b c}
	set item [lindex $completion_list end]
	set completion_list [lrange $completion_list 0 end-1]
	set completion_list [linsert $completion_list 0 $item]

	return [lindex $completion_list end]
}

################################################################
# variables

# number, used by various command
set preceding_number ""

# current file name
set current_filename ""

# file name displayed in the entry box
set entry_filename ""

# scroll page size
set window_lines ""

# half scroll page size
set half_window_lines ""

# search string
set search_string ""

# search direction
set search_forwards 1

# use regular expression search
set search_regexp 1

# ignore case in search
set search_ignorecase 1

# highlight matched string
set highlighted 1

# after finish to read a file, set this variable to 1
set done_reading 1

# marked positions
set marked_positions [dict create]

# assmue coding system when reading file
set coding_system_read ""

# list of filename used for completion
set completion_list ""

################################################################
# main window

# bar
frame .bar

# preceding number widget
entry .bar.pre -textvariable preceding_number -width 6
pack .bar.pre -side left

# filename widget
ttk::combobox .bar.fname -textvariable entry_filename
label .bar.fno -text "0/0"
pack .bar.fno -side left
pack .bar.fname -side left -expand 1 -fill x

# search widget
label .bar.sl -text "/"
entry .bar.se -textvariable search_string
pack .bar.sl -side left
pack .bar.se -side left -expand 1 -fill x
# search regexp
checkbutton .bar.sr -text "regexp" -variable search_regexp
pack .bar.sr -side left
# search ignore case
checkbutton .bar.si -text "ignore case" -variable search_ignorecase
pack .bar.si -side left

# select font widget
button .bar.font -text "font..." -command select_font
pack .bar.font -side left

# encoding
label .bar.el -text "encoding:"
ttk::combobox .bar.ec -textvariable coding_system_read -values [lsort [encoding names]]
pack .bar.el .bar.ec -side left
# reload file
bind .bar.ec <<ComboboxSelected>> {
	read_file .ctext $current_filename
}

pack .bar -side top -fill x

# debug tcl command widget
frame .tcl
label .tcl.l -text {run tcl command: }
entry .tcl.e -textvariable tclscript
pack .tcl.l .tcl.e -side left
pack .tcl
bind .tcl.e <Return> { eval $tclscript }

# text widget
ctext .ctext -yscrollcommand ".scroll set" -setgrid true -wrap none -undo 1
# remove .ctext bindings in text widget of ctext, so allow to use all text bindings when focus is text widget
# default: {.ctext .ctext.t Text . all}
bindtags .ctext.t {.ctext.t Text . all}
ttk::scrollbar .scroll -command ".ctext yview"
pack .scroll -side right -fill y
pack .ctext -expand yes -fill both

################################################################
# commands

# exit program
bind .ctext <q> do_quit
bind .ctext <Q> do_quit
bind .ctext <colon><q> do_quit
bind .ctext <colon><Q> do_quit
bind .ctext <Z><Z> do_quit

# scrolling
foreach seq {e Control-e j J Control-n Return Down} {
	bind .ctext <$seq> {do_forward_line}
}
foreach seq {y Control-y k K Control-k Control-p Up} {
	bind .ctext <$seq> {do_backward_line}
}
foreach seq {f Control-f Control-v space Next} {
	bind .ctext <$seq> {do_forward_page}
}
foreach seq {b Control-b Alt-v Shift-space Prior} {
	bind .ctext <$seq> {do_backward_page};
}
bind .ctext <z> {do_forward_page_set}
bind .ctext <w> {do_backward_page_set}
foreach seq {d Control-d} {
	bind .ctext <$seq> {do_forward_window_half_set}
}
foreach seq {u Control-u} {
	bind .ctext <$seq> {do_backward_window_half_set}
}

# cancel
bind . <Escape> do_cancel
bind . <Control-c> do_cancel
bind . <Control-g> do_cancel

# number
bind .ctext 0 {do_number %K}
bind .ctext 1 {do_number %K}
bind .ctext 2 {do_number %K}
bind .ctext 3 {do_number %K}
bind .ctext 4 {do_number %K}
bind .ctext 5 {do_number %K}
bind .ctext 6 {do_number %K}
bind .ctext 7 {do_number %K}
bind .ctext 8 {do_number %K}
bind .ctext 9 {do_number %K}

# file examine prompt
bind .ctext <colon><e> {focus .bar.fname}
bind .ctext <Control-x><Control-v> {focus .bar.fname}
# examine next file
bind .ctext <colon><n> {do_next_file}
# examine previous file
bind .ctext <colon><p> {do_previous_file}
# examine nth file
bind .ctext <colon><x> {do_nth_file}
# remove file from file list
bind .ctext <colon><d> {do_remove_file}
# open (examine) new file
bind .bar.fname <Return> {do_examine}
bind .bar.fname <<ComboboxSelected>> {do_examine}

# after process <Key> in TCombobox, generate completion list
bindtags .bar.fname {TCombobox .bar.fname . all}
bind .bar.fname <Key> {
	if {"%A" ne "{}"} {
		generate_completion "$entry_filename"
	}
}
bind .bar.fname <FocusIn> {
	generate_completion "$entry_filename"
}
# complete next
bind .bar.fname <Control-i> {
	set entry_filename [completion_next]
	%W icursor end
}
# tab
# complete next
bind .bar.fname <<NextWindow>> {
	set entry_filename [completion_next]
	%W icursor end
	# prevent focus next
	break
}
# shift-tab
# complete previous
bind .bar.fname <<PrevWindow>> {
	set entry_filename [completion_prev]
	%W icursor end
	# prevent focus next
	break
}

# searching
bind .ctext <slash> {do_search_forward}
bind .ctext <question> {do_search_backward}
bind .ctext <Alt-u> {do_toggle_highlight}
bind .ctext <n> {do_repeat_next_search}
bind .ctext <N> {do_repeat_previous_search}
bind .bar.se <Return> {do_search}
# toggle regexp
bind .bar.se <Control-r> {set search_regexp [expr !$search_regexp]}
# toggle ignore case
bind .ctext <minus><i> {set search_ignorecase [expr !$search_ignorecase]}

# jumping
foreach seq {g less Alt-less} {
	bind .ctext <$seq> {do_goto_first}
}
foreach seq {G greater Alt-greater} {
	bind .ctext <$seq> {do_goto_last}
}
bind .ctext <p> {do_goto_percent}
bind .ctext <percent> {do_goto_percent}

# widget, used for receive mark letter like m<letter>, '<letter>
pack [labelframe .bar.mark]
bind .bar.mark <Key> {
	# check if the key is a modifier key or not
	if {"%A" eq "{}"} {
		# modifier key
		;
	} else {
		# bit tricky, run label text as command
		[.bar.mark cget -text] %A
		get_ready
	}
}

# mark position. text is command name
bind .ctext <m> {.bar.mark configure -text "mark_position" ; focus .bar.mark}
# go to marked position. text is command name
bind .ctext <apostrophe> {.bar.mark configure -text "goto_marked" ; focus .bar.mark}
bind .ctext <Control-x><Control-x> {.bar.mark configure -text "goto_marked" ; focus .bar.mark}

# miscellaneous commands
# edit current file with editor
bind .ctext <v> {not_implemented do_editor}
# version
bind .ctext <V> {do_version}
# help
bind .ctext <h> {do_help}
bind .ctext <H> {do_help}

# line number
# toggle line number
bind .ctext <minus><N> {
	set value [.ctext cget -linemap]
	.ctext configure -linemap [expr !$value]
}
# disable line number
bind .ctext <minus><n> { .ctext configure -linemap 0}

# wrap long line
# cycle mode: none => char => word => none => ...
bind .ctext <minus><S> {
	set mode [.ctext cget -wrap]
	if {$mode eq "none"} {
		.ctext configure -wrap char
	} elseif {$mode eq "char"} {
		.ctext configure -wrap word
	} else {
		.ctext configure -wrap none
	}
}

bind .ctext <Control-minus> {font_resize .ctext -1}
bind .ctext <Control-plus> {font_resize .ctext 1}

# run tcl command
bind .ctext <exclam> "focus .tcl.e"

# edit menu
set m [menu .menu_edit -tearoff 0]
$m add command -label "cut" -underline 2 -command {event generate [focus] <<Cut>>}
$m add command -label "copy" -underline 0 -command {event generate [focus] <<Copy>>}
$m add command -label "paste" -underline 0 -command {event generate [focus] <<Paste>>}
$m add command -label "delete" -underline 0 -command {event generate [focus] <<Clear>>}
bind . <3> "tk_popup $m %X %Y"
bind . <Shift-F10> "tk_popup $m %X %Y"

################################################################
# program start

# fill combobox with $argv
foreach i $argv {
	append_file_name $i
}

# read first readable argument
while 1 {
	# get list from combobox
	set v [.bar.fname cget -values]
	if {$v eq ""} {break;}
	set f [lindex $v 0]
	# if not readable, read_file return "" and remove name from combobox
	if {[read_file .ctext $f] ne ""} {
		# file was read
		break;
	}
}

# make the window become active
# in ms-windows, the window is not active wish created
after 1 "wm deiconify . ; focus .ctext"

# wait the command
focus .ctext

# Local variables:
# indent-tabs-mode: t
# tab-width: 4
# End:

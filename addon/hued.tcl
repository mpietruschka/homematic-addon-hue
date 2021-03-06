#!/bin/tclsh

#  HomeMatic addon to control Philips Hue Lighting
#
#  Copyright (C) 2018  Jan Schneider <oss@janschneider.net>
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <http://www.gnu.org/licenses/>.

source /usr/local/addons/hue/lib/hue.tcl

variable update_schedule
variable current_object_state
variable cuxd_device_map
variable last_schedule_update 0
variable schedule_update_interval 60
variable server_address "127.0.0.1"
variable server_port 1919

proc bgerror message {
	hue::write_log 1 "Unhandled error: ${message}"
}

proc main_loop {} {
	if { [catch {
		check_update
	} errormsg] } {
		hue::write_log 1 "Error: '${errormsg}'"
		after 30000 main_loop
	} else {
		after 1000 main_loop
	}
}

proc check_update {} {
	variable update_schedule
	variable last_schedule_update
	variable schedule_update_interval
	variable cuxd_device_map
	
	foreach o [array names update_schedule] {
		set scheduled_time $update_schedule($o)
		#hue::write_log 4 "Update of ${o} cheduled for ${scheduled_time}"
		if {[clock seconds] >= $scheduled_time} {
			set tmp [split $o "_"]
			if {[catch {update_cuxd_device [lindex $tmp 0] [lindex $tmp 1] [lindex $tmp 2]} errmsg]} {
				hue::write_log 2 "Failed to update [lindex $tmp 0] [lindex $tmp 1] [lindex $tmp 2]: $errmsg"
			}
			if {$hue::poll_state_interval > 0} {
				set update_schedule($o) [expr {[clock seconds] + $hue::poll_state_interval}]
			} else {
				unset update_schedule($o)
			}
		}
	}
	
	if { $hue::poll_state_interval > 0 && [clock seconds] >= [expr {$last_schedule_update + $schedule_update_interval}] } {
		hue::write_log 4 "Get device map and schedule update for all devices"
		set last_schedule_update [clock seconds]
		hue::read_global_config
		set dmap [hue::get_cuxd_device_map]
		array set cuxd_device_map $dmap
		foreach { cuxd_device o } [array get cuxd_device_map] {
			set tmp [split $o "_"]
			set bridge_id [lindex $tmp 0]
			set obj [lindex $tmp 1]
			set num [lindex $tmp 2]
			hue::write_log 4 "Device map entry: ${cuxd_device} = ${bridge_id} ${obj} ${num}"
			set time [expr {[clock seconds] + $hue::poll_state_interval}]
			if {[info exists update_schedule($o)]} {
				if {$update_schedule($o) <= $time} {
					# Keep earlier update time
					#hue::write_log 4 "Keep earlier update time"
					continue
				}
			}
			set update_schedule($o) $time
			hue::write_log 4 "Update of ${bridge_id} ${obj} ${num} scheduled for ${time}"
		}
	}
}

proc get_cuxd_device_from_map {bridge_id obj num} {
	variable cuxd_device_map
	set cuxd_device ""
	foreach { d o } [array get cuxd_device_map] {
		if { $o == "${bridge_id}_${obj}_${num}" } {
			set cuxd_device $d
			break
		}
	}
	return $cuxd_device
}

proc update_cuxd_device {bridge_id obj num} {
	variable current_object_state
	set cuxd_device [get_cuxd_device_from_map $bridge_id $obj $num]
	if {$cuxd_device == ""} {
		error "Failed to get CUxD device for ${bridge_id} ${obj} ${num}"
	}
	set st [hue::get_object_state $bridge_id "${obj}s/${num}"]
	set cst ""
	if { [info exists current_object_state($cuxd_device)] } {
		set cst $current_object_state($cuxd_device)
	}
	if {$st != $cst} {
		set channel ""
		if {[regexp "^(\[^:\]+):(\\d+)$" $cuxd_device match d c]} {
			hue::update_cuxd_device_channel "CUxD.$d" $c [lindex $st 0] [lindex $st 1]
		} else {
			hue::update_cuxd_device_channels "CUxD.$cuxd_device" [lindex $st 0] [lindex $st 1] [lindex $st 2] [lindex $st 3] [lindex $st 4] [lindex $st 5]
		}
		set current_object_state($cuxd_device) $st
		hue::write_log 3 "Update of ${bridge_id} ${obj} ${num} successful (reachable=[lindex $st 0] on=[lindex $st 1] bri=[lindex $st 2] ct=[lindex $st 3] hue=[lindex $st 4] sat=[lindex $st 5])"
	} else {
		hue::write_log 4 "Update of ${bridge_id} ${obj} ${num} not required, state is unchanged"
	}
	set cuxd_device_last_update($cuxd_device) [clock seconds]
}

proc read_from_channel {channel} {
	variable update_schedule
	set len [gets $channel cmd]
	hue::write_log 4 "Received command: $cmd"
	regexp "^schedule_update (\[a-fA-F0-9\]+) (light|group) (\\d+) ?(\\d*)$" $cmd match bridge_id obj num delay_seconds
	set response ""
	if {[info exists match]} {
		set cuxd_device [get_cuxd_device_from_map $bridge_id $obj $num]
		if {$cuxd_device == ""} {
			set response "Failed to get CUxD device for ${bridge_id} ${obj} ${num}"
		} else {
			if {$delay_seconds == ""} {
				set delay_seconds 0
			}
			set time [expr {[clock seconds] + $delay_seconds}]
			set update_schedule(${bridge_id}_${obj}_${num}) $time
			set response "Update of ${bridge_id} ${obj} ${num} scheduled for ${time}"
		}
	} else {
		set response "Invalid command"
	}
	hue::write_log 4 "Sending response: $response"
	puts $channel $response
	flush $channel
	close $channel
}

proc accept_connection {channel address port} {
	hue::write_log 3 "Accepted connection from $address\:$port"
	fconfigure $channel -blocking 0
	fconfigure $channel -buffersize 16
	fileevent $channel readable "read_from_channel $channel"
}

proc update_config {} {
	hue::write_log 3 "Update config $hue::ini_file"
	hue::acquire_lock $hue::lock_id_ini_file
	catch {
		set f [open $hue::ini_file r]
		set data [read $f]
		# Remove legacy options
		regsub -all {cuxd_device_[^\n]+\n} $data "" data
		close $f
		set f [open $hue::ini_file w]
		puts $f $data
		close $f
	}
	hue::release_lock $hue::lock_id_ini_file
}

proc main {} {
	variable server_address
	variable server_port
	if { [catch {
		update_config
	} errormsg] } {
		hue::write_log 1 "Error: '${errormsg}'"
	}
	after 10 main_loop
	if {$server_address == "0.0.0.0"} {
		socket -server accept_connection $server_port
	} else {
		socket -server accept_connection -myaddr $server_address $server_port
	}
	hue::write_log 3 "Hue daemon is listening for connections on ${server_address}:${server_port}"
}

if { "[lindex $argv 0 ]" != "daemon" } {
	catch {
		foreach dpid [split [exec pidof [file tail $argv0]] " "] {
			if {[pid] != $dpid} {
				exec kill $dpid
			}
		}
	}
	if { "[lindex $argv 0 ]" != "stop" } {
		exec $argv0 daemon &
	}
} else {
	cd /
	foreach fd {stdin stdout stderr} {
		close $fd
	}
	main
	vwait forever
}
exit 0

#!/bin/bash

# Copyright 2015 Till Wollenberg (wollenberg <atsign> web <dot> de)
#
# The following code is published under the GNU Public License V2.0. See
# LICESNE file for details.

# URL-encode a given string (i.e. replace all "problematic characters" by %hexcode).
# This is needed for purple-remote which needs the status message passed as URL.
# Source: https://gist.github.com/cdown/1163649.
function urlencode() {
	# urlencode <string>
	 
	local length="${#1}"

	for (( i = 0 ; i < length ; i++ )); do
		local c="${1:i:1}"
		case "$c" in
			[a-zA-Z0-9.~_-]) printf "$c" ;;
			*) printf '%%%X' "'$c"
		esac
	done
}

# We need access to the user's session DBus. Since we're running as a cron-job,
# we do not have the same environment as the user's Pidgin instance has and
# therefore need to apply some tricks.

# The idea is to look-up the DBus session address in the environment of a 
# program that certainly belongs to the user's interactive session, such as some
# basic GNOME programs or Pidgin itself.

compatiblePrograms=( gnome-panel gnome-session pidgin )

# Attempt to get the PID of the programs:
PIDS=()
for index in ${compatiblePrograms[@]}; do
        #pidof can return many values
        PID=( $(pidof ${index}) )  #array
        PIDS+=("${PID[@]}")        #concat
done

# Attempt to get non-zombie PID (workaround for bug: https://developer.pidgin.im/ticket/15617 )
for PID in ${PIDS[@]}; do
        if [[ "${PID}" != "" ]]; then
                #check whether PID is zombie process
                is_zombie=$(cat /proc/${PID}/status | grep State | grep "zombie")
                if [ -z "$is_zombie" ]; then
                        #found non-zombie process
                        break
                fi
        fi
done

if [[ "${PID}" == "" ]]; then
	echo "Could not detect active login session."
	exit 1
fi

# Now get the DBus session address out of the program's environment:
QUERY_ENVIRON="$(tr '\0' '\n' < /proc/${PID}/environ | grep "DBUS_SESSION_BUS_ADDRESS" | cut -d "=" -f 2-)"
if [[ "${QUERY_ENVIRON}" != "" ]]; then
	export DBUS_SESSION_BUS_ADDRESS="${QUERY_ENVIRON}"
else
	echo "Could not find DBus session ID in user environment."
	exit 1
fi

# Next, we need the X display for screen-saver detection:
QUERY_ENVIRON="$(tr '\0' '\n' < /proc/${PID}/environ | grep "DISPLAY=" | cut -d "=" -f 2-)"
if [[ "${QUERY_ENVIRON}" != "" ]]; then
	export DISPLAY="${QUERY_ENVIRON}"
else
	echo "Could not find X display."
	exit 1
fi

# Okay, that went good so far. We now have all prerequisites. Let's get the list
# of all nearby WiFi access points from NetworkManager in order to determine
# our location. Handle different versions of NetworkManager output.
# TODO: insert sanity a check here
version=$(nmcli -v | cut -d " " -f 4) #e.g. 0.9.10.0
v_major=$(echo $version | cut -d "." -f 1) #e.g. 0
v_minor=$(echo $version | cut -d "." -f 2) #e.g. 9
v_minor2=$(echo $version | cut -d "." -f 3) #e.g. 10
if [[ "$v_major" == 0 && "$v_minor" > 8 && "$v_minor2" > 9 ]]; then
  # >= 0.9.10
  BSSIDs=(`/usr/bin/nmcli dev wifi | tail -n +2 | sed -r "s/^'.+' +//" | cut -c1-17`)
else
  # < 0.9.10
  BSSIDs=(`/usr/bin/nmcli -f BSSID dev wifi`)
fi

# Get the current status message from Pidgin to decide if we have to change it
# eventually.
NEWSTATUS=""
OLDSTATUS=`/usr/bin/purple-remote getstatusmessage`

if [ $? -ne 0 ]; then
	echo "No purple found -> exiting"
	exit 0
fi

# When I am at home during the office hours I certainly work there and want to
# reflect this in my status message. I therefore check if the current time is a
# working day (Monday to Friday) and if we are within the office hours.
OFFICEHOURS_START=9
OFFICEHOURS_END=17

HOUR=`date +"%H"`
DAY=`date +"%u"`
[ \( $HOUR -ge $OFFICEHOURS_START \) -a \( $HOUR -le $OFFICEHOURS_END \) -a \( $DAY -ge 1 \) -a \( $DAY -le 5 \) ]
OFFICEHOURS=$?

# This helper function checks if one or all of the given MAC addresses (i.e. MAC
# addresses of known access points) are in the list of currently observed access
# points.
test_macs () {
	IFS=" " read -a given <<< "$1"
	IFS=" " read -a totest <<< "$2"

	local matches=0
	for g in ${given[*]}; do
		g="${g,,}"                     #convert to lowercase
		for t in ${totest[*]}; do
			t="${t,,}"             #convert to lowercase
			[[ "$g" =~ $t ]] && matches=$(($matches + 1))
		done
	done

	if [[ "$3" == "all" ]]; then
		[[ $matches -ge ${#totest[*]} ]]
		return $?
	else
		[[ $matches -gt 0 ]]
		return $?
	fi		
}

# Now these are the checks for possible known locations:

# Am I at home? (I have two access points at home with very different MAC
# addresses, although they are from the same vendor.)
macs=( "10:20:30:40:50:60" "10:20:30:AA:BB:CC" )
test_macs "${BSSIDs[*]}" "${macs[*]}" && [[ $OFFICEHOURS -eq 0 ]] && NEWSTATUS="At home, working"

# My favorite café (has to access points from same vendor, very similar MAC address)
macs=( "55:66:77:00:AA:0." )
test_macs "${BSSIDs[*]}" "${macs[*]}" && NEWSTATUS="In my favorite café"

# At my workplace, there is a huge number of access points. I have to check for
# a certain set of access points (need to "see" them *all*) to be sure that I am
# in my office and not somewhere else in the building. Also, if my laptop is
# docked this is a sure sign that it is on my desk in the office.
macs=( "08:00:00:80:DD:E." "08:00:00:80:DD:E.")
test_macs "${BSSIDs[*]}" "${macs[*]}" "all" || \
lsusb | grep -q "17ef:100a Lenovo ThinkPad Mini Dock Plus Series 3" && \
NEWSTATUS="In my office"

# ...insert more here

# Ugly thing: In order to update Pidgin's status message, one needs to set the
# status (available, away, etc.) as well. We therefore need to get the current
# status and set it back along with our status message.

# This creates a new problem if you use Pidgin's auto-away feature (I do). If
# pidgin sets your status to "away" because you have not typed anything for some
# time, this script would see the "away" status and set it again when updating
# your current location.
# 
# However, Pidgin treats this as "the user has manually switched to 'away' status"
# and consequently disables auto-away. As a result, when you move your mouse
# again or type something, your Pidgin status will *not* automatically switch back
# to "available" again. 
#
# To circumvent this, the following ugly workaround re-implements the
# auto-away feature. If your current "idle time" (as perceived by the X server)
# is greater than 10 minutes or the GNOME screen-saver is running, your Pidgin
# status will be set to "away". If it is less than 10 minutes and the screen-
# saver is not running your status will be set to "available".
#
# This fixes the problem with Pidgin's auto-away but has limitations. It is not
# easily configurable and has a delay due to the fact that this script is only
# called every few minutes (depending how often you run the Cron job). It
# would be better if there was a way to set Pidgin's status message without
# setting the status itself.

old_statusword=`/usr/bin/purple-remote getstatus`
idletime=$(( `/usr/bin/xprintidle` / 60000 )) # in minutes
/usr/bin/gnome-screensaver-command -q | /bin/grep -q "is active" &> /dev/null
saverrunning=$?


if [[ ( "$old_statusword" == "available" ) && ( ( $idletime -ge 10 ) || ( $saverrunning -eq 0 ) ) ]]; then
	new_statusword="away"
else
	if [[ ( "$old_statusword" == "away" ) && ( $idletime -lt 10 ) ]]; then
		new_statusword="available"
	else
		new_statusword="$old_statusword"
	fi
fi

# Ok, we now finally have everything we need to update the Pidgin status.
# The code below checks if an update is necessary and (if so) notifies the user
# with a libnotify-popup and a sound about the update. The latter two are mainly
# for debugging purposes, i.e. once you trust this script that I determines your
# location correct, you may comment-out the corresponding lines.

if [[ ( "$OLDSTATUS" != "$NEWSTATUS" ) || ( "$old_statusword" != "$new_statusword" ) ]]; then
	/usr/bin/purple-remote "setstatus?status="$new_statusword"&message="`urlencode "$NEWSTATUS"`

	if [ -z "$NEWSTATUS" ]; then
		# This is just for the libnotify popup:
		NEWSTATUS="(no status message)"
	fi

	/usr/bin/notify-send \
		-i /usr/share/icons/hicolor/32x32/apps/pidgin.png \
		-t 3 \
		"Pidgin status was updated" \
		"New status is: »$NEWSTATUS« ($new_statusword)\nOld status was: »$OLDSTATUS« ($old_statusword)"

	# Play a fancy sound along with the popup to distract the user even further ;-)
	/usr/bin/play /usr/share/sounds/freedesktop/stereo/window-attention.oga &> /dev/null &
fi


#!/usr/bin/env perl
use warnings;
#
# XASTIR, Amateur Station Tracking and Information Reporting
# Copyright (C) 2000-2019 The Xastir Group
#
# Converts "dump1090" telnet port output to Xastir UDP input, for decoding
# packets directly from aircraft.  This script will parse packets containing
# lat/long, turn them into APRS-like packets, then use "xastir_udp_client"
# to inject them into Xastir. Must have "dump1090" running, and optionally
# "dump978" to dump packets into "dump1090" from the other frequency/protocol
# for ADS-B.
#
#
# TODO: Create probability circle around my position for aircraft sending altitude
# but no lat/long. Change the size of the circle based on altitude and/or RSSI
# (Need to tie into Beast-mode port, raw data port, or JSON port to get RSSI).
# Would need to keep track of these objects and kill them when the aircraft timed-out
# or sent lat/long. Could switch back to the circle when lat/long times out but
# altitude is still coming in as well.
#
# TODO: Check everywhere that we set a variable to "". Make sure we're not setting
# it when a sentence including it comes in, then resetting it on all other sentences
# so that it never gets seen. "squawk_txt" and "squawk" were 2 of these.
# Check everywhere that $fields[] are checked/saved/used.
#
# TODO: Expire data values from hashes XX minutes after receiving them.
#
#
# Invoke it as:
#   ./ads-b.pl planes <passcode> [--circles] [--logging]
#
# If you add " --circles" to the end you'll also get a red circle around plane
# symbols at your current location which represent the area that a plane might
# be min, if it's only reporting altitude and not lat/long.
#
# If you add " --logging" to the end, this script will save the APRS portion of
# the output to a file called "~/.xastir/logs/planes.log". You can later suck
# this file back in to see the planes move around the map in hyperspeed. Useful
# for a quick demo.
#
# Injecting them from "planes" or "p1anes" assures that Xastir won't try to adopt
# the APRS Item packets as its own and re-transmit them.
#
#
# I got the "dump1090" program from here originally:
#       https://github.com/antirez/dump1090
# Newer fork:
#       https://github.com/MalcolmRobb/dump1090
# Newer-yet fork, seems to decode much better:
#       https://github.com/mutability/dump1090
#
# Invoke Mutability's "dump1090" program like so:
#   "./dump1090 --interactive --net --net-sbs-port 30003 --phase-enhance --oversample --fix --ppm -1 --gain -10 --device-index 0
#
#
# NOTE: There's also "dump978" which listens to 978 MHz ADS-B transmissions. You can
# invoke "dump1090" as above, then invoke "dump978" like this:
#
#       rtl_sdr -f 978000000 -s 2083334 -g 0 -d 1 - | ./dump978 | ./uat2esnt | nc -q1 localhost 30001
#
# which will convert the 978 MHz packets into ADS-B ES packets and inject them into "dump1090"
# for decoding. I haven't determined yet whether those packets will come out on "dump1090"'s
# port 30003 (which this Perl script uses). The above command also uses RTL device 1 instead of 0.
# If you're only interested in 978 MHz decoding, there's a way to start "dump1090" w/o a
# device attached, then start "dump978" and connect it to "dump1090".
#
# Then invoke this script in another xterm using "planes" as the callsign:
#   "./ads-b.pl planes <passcode>"
#
# NOTE: Do NOT use the same callsign as your Xastir instance, else it will
# "adopt" those APRS Item packets as its own and retransmit them. Code was
# added to the script to prevent such operation, but using "planes" as the
# callsign works great too!
#
#
# This script snags packets from port 30003 of "dump1090", parses them, then injects
# APRS packets into Xastir's UDP port (2023) if "Server Ports" are enabled in Xastir.
#
#
# Port 30001 is an input port (dump978 connects there and dumps data in).
#
# Port 30002 outputs in raw format, like:
#   *8D451E8B99019699C00B0A81F36E;
#   Every entry is separated by a simple newline (LF character, hex 0x0A).
#   The "callsign" (6 digits of hex) in chunk #4 = ICAO (airframe identifier).
#   Decoding the sentences:
#     https://www.sussex.ac.uk/webteam/gateway/file.php?name=coote-proj.pdf&site=20]
#     http://adsb-decode-guide.readthedocs.org/en/latest/
#
# Port 30003 outputs data is SBS1 (BaseStation) format, and is used by this script.
#   Decoding the sentences:
#   http://woodair.net/SBS/Article/Barebones42_Socket_Data.htm
#   NOTE: I changed the numbers by -1 to fit Perl's "split()" command field numbering.
#     Field 0:
#       Message type    (MSG, STA, ID, AIR, SEL or CLK)
#     Field 1:
#       Transmission Type   MSG sub types 1 to 8. Not used by other message types.
#     Field 2:
#       Session ID      Database Session record number
#     Field 3:
#       AircraftID      Database Aircraft record number
#     Field 4:
#       HexIdent    Aircraft Mode S hexadecimal code (What we use here... Unique identifier)
#     Field 5:
#       FlightID    Database Flight record number
#     Field 6:
#       Date message generated       As it says
#     Field 7:
#       Time message generated       As it says
#     Field 8:
#       Date message logged      As it says
#     Field 9:
#       Time message logged      As it says
#     Field 10:
#       Callsign    An eight digit flight ID - can be flight number or registration (or even nothing).
#     Field 11:
#       Altitude    Mode C altitude. Height relative to 1013.2mb (Flight Level). Not height AMSL..
#     Field 12:
#       GroundSpeed     Speed over ground (not indicated airspeed)
#     Field 13:
#       Track   Track of aircraft (not heading). Derived from the velocity E/W and velocity N/S
#     Field 14:
#       Latitude    North and East positive. South and West negative.
#     Field 15:
#       Longitude   North and East positive. South and West negative.
#     Field 16:
#       VerticalRate    64ft resolution
#     Field 17:
#       Squawk      Assigned Mode A squawk code.
#     Field 18:
#       Alert (Squawk change)   Flag to indicate squawk has changed.
#     Field 19:
#       Emergency   Flag to indicate emergency code has been set
#     Field 20:
#       SPI (Ident)     Flag to indicate transponder Ident has been activated.
#     Field 21:
#       IsOnGround      Flag to indicate ground squat switch is active
#
#
# Squawk Codes:
#   https://en.wikipedia.org/wiki/Transponder_%28aeronautics%29
#
#
# For reference, using 468/frequency (MHz) to get length of 1/2 wave dipole in feet:
#
#   1/2 wavelength on 1090 MHz: 5.15"
#   1/4 wavelength on 1090 MHz: 2.576" or 2  9/16"
#
#   1/2 wavelength on 978 MHz: 5.74"
#   1/4 wavelength on 978 MHz: 2.87" or 2  7/8"
#
#
# NOTE: In the tables below, lines marked with "Per Countries.dat file" are derived
# from the work of "Alexis" of the Group "https://mode-s.groups.io/g/mode-s"
# most likely arrived at via observation of Mode-S transponder activity. They are
# not guaranteed to represent reality in any way. Find the file in the Files section
# of the group.
#
# Most of the rest of the data in the tables was derived from:
#   http://www.kloth.net/radio/icao24alloc.php (Created 2003-01-12, Last modified 2011-06-23).
# Which in turn came from:
# "ICAO Annex 10 Volume III Chapter 9. Aircraft Addressing System"
#
#


eval '(exit $?0)' && eval 'exec perl -S $0 ${1+"$@"}'
& eval 'exec perl -S $0 $argv:q'
if 0;

use IO::Socket;


$my_alt = 600;     # In feet. Used by probability circles.


# Fetch my lat/long from Xastir config file
$my_lat = `grep STATION_LAT ~/.xastir/config/xastir.cnf`;
if (! ($my_lat =~ m/STATION_LAT:/) ) {
  die "Couldn't get STATION_LAT from Xastir config file\n";
}
$my_lon = `grep STATION_LONG ~/.xastir/config/xastir.cnf`;
if (! ($my_lon =~ m/STATION_LONG:/) ) {
  die "Couldn't get STATION_LONG from Xastir config file\n";
}
chomp $my_lat;
chomp $my_lon;
$my_lat =~ s/STATION_LAT://;
$my_lon =~ s/STATION_LONG://;
$my_lat =~ s/(\d+\.\d\d)\d(.)/$1$2/;
$my_lon =~ s/(\d+\.\d\d)\d(.)/$1$2/;
#print "$my_lat  $my_lon\n";


$udp_client = "xastir_udp_client";
$dump1090_host = "localhost"; # Server where dump1090 is running
$dump1090_port = 30003;     # 30003 is dump1090 default port

$xastir_host = "localhost"; # Server where Xastir is running
$xastir_port = 2023;        # 2023 is Xastir default UDP port

$plane_TTL = 1;            # Secs after which posits too old to create APRS packets from

$log_file = "~/.xastir/logs/planes.log";


$xastir_user = shift;
if (defined($xastir_user)) {
  chomp $xastir_user;
}
if ( (!defined($xastir_user)) || ($xastir_user eq "") ) {
  print "Please enter a callsign for Xastir injection, but not Xastir's callsign/SSID!\n";
  die;
}
$xastir_user =~ tr/a-z/A-Z/;

$xastir_pass = shift;
if (defined($xastir_pass)) {
  chomp $xastir_pass;
}
if ( (!defined($xastir_pass)) || ($xastir_pass eq "") ) {
  print "Please enter a passcode for Xastir injection\n";
  die;
}

$enable_circles = 0;
$enable_logging = 0;

$flag1 = shift;
if (defined($flag1)) {
  chomp $flag1;
  if ( ($flag1 ne "") && ($flag1 eq "--circles") ) {
    $enable_circles = 1;
  }
  if ( ($flag1 ne "") && ($flag1 eq "--logging") ) {
    $enable_logging = 1;
  }
}

$flag2 = shift;
if (defined($flag2)) {
  chomp $flag2;
  if ( ($flag2 ne "") && ($flag2 eq "--circles") ) {
    $enable_circles = 1;
  }
  if ( ($flag2 ne "") && ($flag2 eq "--logging") ) {
    $enable_logging = 1;
  }
}


# Connect to the server using a tcp socket
#
$socket = IO::Socket::INET->new(PeerAddr => $dump1090_host,
                                PeerPort => $dump1090_port,
                                Proto    => "tcp",
                                Type     => SOCK_STREAM)
  or die "Couldn't connect to $dump1090_host:$dump1090_port : $@\n";


# Flush output buffers often
select((select(STDOUT), $| = 1)[0]);


# Check Xastir's callsign/SSID to make sure we don't have a collision.  This
# will prevent Xastir adopting the Items as its own and retransmitting them.
#   xastir_udp_client localhost 2023 <callsign> <passcode> -identify
#   Received: WE7U-13
#
$injection_call = $xastir_user;
$injection_call =~ s/-\d+//;    # Get rid of dash and numbers

$injection_ssid = $xastir_user;
$injection_ssid =~ s/\w+//;     # Get rid of letters
$injection_ssid =~ s/-//;       # Get rid of dash
if ($injection_ssid eq "") { $injection_ssid = 0; }

# Find out Callsign/SSID of Xastir instance
$result = `$udp_client $xastir_host $xastir_port $xastir_user $xastir_pass -identify`;
if ($result =~ m/NACK/) {
  die "Received NACK from Xastir: Callsign/Passcode don't match?\n";
}
($remote_call, $remote_ssid) = split('-', $result);

chomp($remote_call);
$remote_call =~ s/Received:\s+//;

if ( !defined($remote_ssid) ) { $remote_ssid = ""; }
if ($remote_ssid ne "") { chomp($remote_ssid); }
if ($remote_ssid eq "") { $remote_ssid = 0; }

#print "$remote_call $remote_ssid $injection_call $injection_ssid\n";
#if ($remote_call eq $injection_call) { print "Call matches\n"; }
#if ($remote_ssid == $injection_ssid) { print "SSID matches\n"; }

if (     ($remote_call eq $injection_call)
     &&  ($remote_ssid == $injection_ssid) ) {
    $remote_ssid++;
    $remote_ssid%= 16;  # Increment by 1 mod 16
    $xastir_user = "$remote_call-$remote_ssid";
    print "Injection conflict. Corrected. New user = $xastir_user\n";
}


while (<$socket>)
{

  # For testing:
  #
  #$_ = "MSG,3,,,A0CF8D,,,,,,,28000,,,47.87670,-122.27269,,,0,0,0,0";
  #$_ = "MSG,5,,,AD815E,,,,,,,575,,,,,,,,,,";
  #$_ = "MSG,4,,,AAB812,,,,,,,,454,312,,,0,,0,0,0,0";
  #$_ = "MSG,3,,,ABB2D5,,,,,,,40975,,,47.68648,-122.67834,,,0,0,0,0";   # Lat/long/altitude (ft)
  #$_ = "MSG,1,,,A2CB32,,,,,,BOE181  ,,,,,,,,0,0,0,0";  # Tail number or flight number
  #$_ = "MSG,4,,,A0F4F6,,,,,,,,175,152,,,-1152,,0,0,0,0";   # Ground speed (knots)/Track


  chomp;
  if ( $_ eq "" ) { next; }


  # Sentences have either 10 or 22 fields, assuming they aren't cut off / collided with.
  @fields = split(",");


  # Check whether we have a sentence type, message type, and plane ID. If not we're done with this loop iteration
  if ( (!defined($fields[0])) || (!defined($fields[1])) || (!defined($fields[4])) || ($fields[4] eq "") ) { next; }

  $plane_id = $fields[4];
  $print1 = $plane_id;

  # Decode the country of registration via this webpage:
  #   http://www.kloth.net/radio/icao24alloc.php
  # Add it to the APRS comment field.  Remove the Tactical call
  # from the comment field since it is redundant.
  # Match on more specific first (longer string).
  #
  # NOTE: The above link has the countries arranged alphabetically.
  # The code below is arranged in this order (because of the order
  # in which they must be decoded):
  #
  #    1024 addresses (14 bits defined)
  #    4096 addresses (12 bits defined)
  #   32768 addresses (9 bits defined)
  #  262144 addresses (6 bits defined)
  # 1048576 addresses (4 bits defined)
  #
  # The code below is basically the 1024 column from the chart in
  # alphabetical order, then the 2nd column, and so on. The chart
  # should be reviewed against the code periodically, perhaps yearly.
  # You'll see longer bits decoded here and there prior to the normal
  # bit lengths in each section, for instance "Azerbaijan Military"
  # just prior to the "Azerbaijan" entry in the 14-bit address section.
  #
  $registry = "Registry?";

  # Convert $plane_id to binary string
  $binary_plane_id = unpack ('B*', pack ('H*',$plane_id) );

  # NOTE: In the code below, more specific addresses (more bits) should
  # appear prior to less specific. The code will snag the first match.



  #
  # 4-bit addresses (column "1048576" in the table):
  # ------------------------------------------------
  if      ($binary_plane_id =~ m/^0001/) { $registry = "Russia"; }  # Russian Federation

  elsif   ($binary_plane_id =~ m/^1010/) { $registry = "U.S.";        # United States
    if    ($binary_plane_id =~ m/^1010111/) { $registry = "U.S. Military"; }        # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^1010110111111/) { $registry = "U.S. Military"; }        # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^1010110111110111111/) { $registry = "U.S. Military"; }        # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^10101101111101111101/) { $registry = "U.S. Military"; }        # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^101011011111011111001/) { $registry = "U.S. Military"; }        # Per Countries.dat file
  }

 

  #
  # 6-bit addresses (column "262144" in the table):
  # -----------------------------------------------
  elsif   ($binary_plane_id =~ m/^111000/) { $registry = "Argentina";
    if    ($binary_plane_id =~ m/^111000010100110000110001/) { $registry = "Argentina Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111000010100110000110010/) { $registry = "Argentina Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111000010100110000110011/) { $registry = "Argentina Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111000010100110001110000/) { $registry = "Argentina Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^011111/) { $registry = "Australia";
    if    ($binary_plane_id =~ m/^0111111/) { $registry = "Australia Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01111101/) { $registry = "Australia Military"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0111110011/) { $registry = "Australia Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01111100101/) { $registry = "Australia Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^011111001001/) { $registry = "Australia Military"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0111110010001/) { $registry = "Australia Military"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01111100100001/) { $registry = "Australia Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0111110010000011/) { $registry = "Australia Military"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01111100100000101/) { $registry = "Australia Military"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^011111001000001001/) { $registry = "Australia Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01111100100000100011/) { $registry = "Australia Military"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01111100100000100010111/) { $registry = "Australia Military"; } # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^111001/) { $registry = "Brazil";
    if    ($binary_plane_id =~ m/^11100100000/) { $registry = "Brazil Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^111001001000100110111001/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001000111110111111110/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001000111111001000000/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000000111110110/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000000111110111/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000001110111010/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000001110111011/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000100101101010/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000001011000010/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000001011000011/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000010001000011/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000010001000100/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000010111100111/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000010111101000/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000010111101001/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000100100011111/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000100100100000/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000100100100001/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000001110101000/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000001110101010/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111001001000001110101011/) { $registry = "Brazil Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^110000/) { $registry = "Canada";
    if    ($binary_plane_id =~ m/^1100001/) { $registry = "Canada Military"; }   # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^011110/) { $registry = "China";
    if    ($binary_plane_id =~ m/^0111100000000001000/) { $registry = "China"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0111100000000001/) { $registry = "China Hong Kong"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^011110000000001000/) { $registry = "China Hong Kong"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^011110000000101000/) { $registry = "China Hong Kong"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0111100000001010010/) { $registry = "China Hong Kong"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^011110000000001100111/) { $registry = "China Macau"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^011110000000001101000/) { $registry = "China Macau"; }   # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^001110/) { $registry = "France";
    if    ($binary_plane_id =~ m/^00111011/) { $registry = "France Military"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^001110101/) { $registry = "France Military"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^001110000000001001011011/) { $registry = "France Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^001110000000110100011011/) { $registry = "France Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^001110000001111001111011/) { $registry = "France Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^001110000001110000111011/) { $registry = "France Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^001110000001111000111011/) { $registry = "France Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^001110000001101110111011/) { $registry = "France Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^001110000000110100111011/) { $registry = "France Military"; }   # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^001111/) { $registry = "Germany";
    if    ($binary_plane_id =~ m/^0011111010/) { $registry = "Germany Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0011111101/) { $registry = "Germany Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0011111110/) { $registry = "Germany Military"; } # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^100000/) { $registry = "India";
    if    ($binary_plane_id =~ m/^1000000000000010/) { $registry = "India Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^100000000000001100001101/) { $registry = "India Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100000000000000001111000/) { $registry = "India Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100000000000000001111001/) { $registry = "India Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100000000000000011010110/) { $registry = "India Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100000011110000011100011/) { $registry = "India Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^001100/) { $registry = "Italy";
    if    ($binary_plane_id =~ m/^0011001111111111/) { $registry = "Italy Military"; }  # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^100001/) { $registry = "Japan";
    if    ($binary_plane_id =~ m/^100001111100110000001010/) { $registry = "Japan Military"; }    # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100001111100000000000000/) { $registry = "Japan Military"; }    # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100001111100000000000001/) { $registry = "Japan Military"; }    # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100001111100110000000001/) { $registry = "Japan Military"; }    # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100001111100110000001011/) { $registry = "Japan Military"; }    # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100001111100110000001000/) { $registry = "Japan Military"; }    # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100001111100110000001001/) { $registry = "Japan Military"; }    # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^001101/) { $registry = "Spain";
    if    ($binary_plane_id =~ m/^0011011/) { $registry = "Spain Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^00110100/) { $registry = "Spain Military"; } # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^010000/) { $registry = "U.K.";  # United Kingdom
    if    ($binary_plane_id =~ m/^010000100100010110111010/) { $registry = "Montserrat"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010000100100000111110100/) { $registry = "Falkland Is."; }   # Per Countries.dat file specific plane)
    elsif ($binary_plane_id =~ m/^010000100100000111110101/) { $registry = "Falkland Is."; }   # Per Countries.dat file specific plane)
    elsif ($binary_plane_id =~ m/^010000100100000111110110/) { $registry = "Falkland Is."; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010000100100000111110111/) { $registry = "Falkland Is."; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010000111011111001011011/) { $registry = "Falkland Is."; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010000000000110111111101/) { $registry = "U.K. Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010000000000110111111110/) { $registry = "U.K. Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010000000000110111111111/) { $registry = "U.K. Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^01000011111100101100111/) { $registry = "U.K. Jersey"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01000011111001110001011/) { $registry = "Isle of Man"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001001000001001101/) { $registry = "Cayman Islands"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001001000001001100/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100000000000000100010/) { $registry = "Cayman Islands"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010000000000000011010/) { $registry = "Cayman Islands"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010000000000000010000/) { $registry = "Cayman Islands"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010000111110011100011/) { $registry = "Isle of Man"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010000100100000100111/) { $registry = "Cayman Islands"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010000100100100011011/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01000010010000010010/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01000010010000100011/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01000010010000010011/) { $registry = "Cayman Islands"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01000010010010100000/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01000000000000001100/) { $registry = "Cayman Islands"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001110111110100/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001111100111001/) { $registry = "Isle of Man"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001001000001100/) { $registry = "Cayman Islands"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001001000001101/) { $registry = "Cayman Islands"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001001000001110/) { $registry = "Cayman Islands"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001001000001000/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001001000010100/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001001000110000/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001001001000111/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010000111110011101/) { $registry = "Isle of Man"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010000100100000101/) { $registry = "Cayman Islands"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010000100100001001/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010000000000000110/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010000000000000001/) { $registry = "Cayman Islands"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010000000000000111/) { $registry = "Cayman Islands"; }    # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010000000000000000/) { $registry = "U.K. MoD"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01000011111001111/) { $registry = "Isle of Man"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01000000000000001/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01000000000000010/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001111101010/) { $registry = "Isle of Man"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001001000000/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001001000101/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001001001001/) { $registry = "Bermuda"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010000111110100/) { $registry = "Isle of Man"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001111101/) { $registry = "U.K. Guernsey"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100001111/) { $registry = "U.K. Military"; }   # Per Countries.dat file
  }



  #
  # 9-bit addresses (column "32768" in the table):
  # ----------------------------------------------
  elsif   ($binary_plane_id =~ m/^000010100/) { $registry = "Algeria";
    if    ($binary_plane_id =~ m/^000010100100/) { $registry = "Algeria Military"; }  # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^010001000/) { $registry = "Austria";
    if    ($binary_plane_id =~ m/^0100010001/) { $registry = "Austria Military"; }  # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^010001001/) { $registry = "Belgium";
    if    ($binary_plane_id =~ m/^010001001111/) { $registry = "Belgium Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010001001100000111100001/) { $registry = "Belgium Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010001001100000111100101/) { $registry = "Belgium Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010001001100000111100111/) { $registry = "Belgium Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010001001100000111101000/) { $registry = "Belgium Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010001001100000111100011/) { $registry = "Belgium Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010001001100000111100100/) { $registry = "Belgium Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010001001110110110000001/) { $registry = "Belgium Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010001001110110110000010/) { $registry = "Belgium Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010001001110110110000011/) { $registry = "Belgium Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^010001010/) { $registry = "Bulgaria";
    if    ($binary_plane_id =~ m/^010001010111/) { $registry = "Bulgaria Military"; }    # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^010010011/) { $registry = "Czech"; # Czech Republic
    if    ($binary_plane_id =~ m/^0100100110000100/) { $registry = "Czech Military"; } # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^011100100/) { $registry = "North Korea"; }  # Democratic People's Republic of Korea

  elsif   ($binary_plane_id =~ m/^010001011/) { $registry = "Denmark";
    if    ($binary_plane_id =~ m/^0100010111110100/) { $registry = "Denmark Military"; }  # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^000000010/) { $registry = "Egypt";
    if    ($binary_plane_id =~ m/^00000001000000000111/) { $registry = "Egypt Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^00000001000000001000/) { $registry = "Egypt Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^000000010000000100101100/) { $registry = "Egypt Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^010001100/) { $registry = "Finland";
    if    ($binary_plane_id =~ m/^0100011001111000/) { $registry = "Finland Military"; } # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^010001101/) { $registry = "Greece";
    if    ($binary_plane_id =~ m/^01000110100000/) { $registry = "Greece Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01000110111101011001001/) { $registry = "Greece Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010001101010000010010001/) { $registry = "Greece Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010001101010000010010011/) { $registry = "Greece Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010001101010000010010101/) { $registry = "Greece Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^010001110/) { $registry = "Hungary";
    if    ($binary_plane_id =~ m/^01000111001111/) { $registry = "Hungary Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01000111011111111111/) { $registry = "Hungary Military"; }  # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^100010100/) { $registry = "Indonesia";
    if    ($binary_plane_id =~ m/^100010100010100100000001/) { $registry = "Indonesia Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010100010100100000010/) { $registry = "Indonesia Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010100000000000100100/) { $registry = "Indonesia Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010100000000000101001/) { $registry = "Indonesia Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^011100110/) { $registry = "Iran";   # Iran, Islamic Republic of
    if    ($binary_plane_id =~ m/^011100110100110100011110/) { $registry = "Iran Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^011100101/) { $registry = "Iraq";
    if    ($binary_plane_id =~ m/^011100101000000111111/) { $registry = "Iraq Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0111001010000010000000/) { $registry = "Iraq Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01110010100000011111011/) { $registry = "Iraq Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^011100101000000111110101/) { $registry = "Iraq Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^011100111/) { $registry = "Israel";
    if    ($binary_plane_id =~ m/^0111001110001010/) { $registry = "Israel Military"; }  # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^011101000/) { $registry = "Jordan"; }

  elsif   ($binary_plane_id =~ m/^011101001/) { $registry = "Lebanon"; }

  elsif   ($binary_plane_id =~ m/^000000011/) { $registry = "Libya";   # Libyan Arab Jamahiriya
    if    ($binary_plane_id =~ m/^000000011000001111101011/) { $registry = "Libya Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^011101010/) { $registry = "Malaysia";
    if    ($binary_plane_id =~ m/^011101010000000101010110/) { $registry = "Malaysia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101010000000011010100/) { $registry = "Malaysia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101010000000000001100/) { $registry = "Malaysia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101010000000000001111/) { $registry = "Malaysia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101010000000000100100/) { $registry = "Malaysia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101010000000000100101/) { $registry = "Malaysia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101010000000000100110/) { $registry = "Malaysia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101010000000000100111/) { $registry = "Malaysia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101010000000010111101/) { $registry = "Malaysia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101010000000011000101/) { $registry = "Malaysia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101010000000011010111/) { $registry = "Malaysia Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^000011010/) { $registry = "Mexico";
    if    ($binary_plane_id =~ m/^000011010000011000010101/) { $registry = "Mexico Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000011010000010011000010/) { $registry = "Mexico Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000011010000000110111010/) { $registry = "Mexico Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000011010000010101000110/) { $registry = "Mexico Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000011010000010101000111/) { $registry = "Mexico Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000011010000000000011011/) { $registry = "Mexico Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000011010000000000111111/) { $registry = "Mexico Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000011010000001010111001/) { $registry = "Mexico Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000011010000000001000101/) { $registry = "Mexico Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000011010000000001011010/) { $registry = "Mexico Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000011010000011001001111/) { $registry = "Mexico Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000011010000011001001101/) { $registry = "Mexico Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^000000100/) { $registry = "Morocco";
    if    ($binary_plane_id =~ m/^00000010000000001011/) { $registry = "Morocco Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^000000100000000011000/) { $registry = "Morocco Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^000000100000000001011101/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000001011110/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000010101000/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000010101011/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000010100000/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000010100011/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000010100010/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000010100101/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000010101100/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000001001011/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000001000110/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000001001100/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000001001101/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000001001110/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000000110001/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000000110111/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000000111000/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000000111001/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000000111010/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000000111011/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000000111100/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000000111110/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000001000001/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000011001001/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000100000000011001100/) { $registry = "Morocco Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^010010000/) { $registry = "Netherlands";    # Netherlands, Kingdom of the
    if    ($binary_plane_id =~ m/^010010000000/) { $registry = "Netherlands Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010010000100000010010101/) { $registry = "Netherlands Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010000100000010010110/) { $registry = "Netherlands Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010000100000010001001/) { $registry = "Netherlands Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010000100000100001111/) { $registry = "Netherlands Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010000100000100010001/) { $registry = "Netherlands Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010000100000100010010/) { $registry = "Netherlands Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010000100000010001011/) { $registry = "Netherlands Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010000100000010000000/) { $registry = "Netherlands Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010000100000010000001/) { $registry = "Netherlands Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010000100000010000010/) { $registry = "Netherlands Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010000100000010100100/) { $registry = "Netherlands Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010000100000010100101/) { $registry = "Netherlands Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010000100/) { $registry = "Aruba"; } # Per Countries.dat file (In Netherlands block)
  }

  elsif   ($binary_plane_id =~ m/^110010000/) { $registry = "New Zealand";
    if    ($binary_plane_id =~ m/^1100100001111111/) { $registry = "New Zealand Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^110010000010010100011100/) { $registry = "New Zealand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^110010000010010100011101/) { $registry = "New Zealand Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^010001111/) { $registry = "Norway";
    if    ($binary_plane_id =~ m/^0100011110000001/) { $registry = "Norway Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0100011110000000111/) { $registry = "Norway Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01000111100000001101/) { $registry = "Norway Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010001111000000011001/) { $registry = "Norway Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^01000111100000001100011/) { $registry = "Norway Military"; }  # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^011101100/) { $registry = "Pakistan";
    if    ($binary_plane_id =~ m/^011101100000000011101001/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101100000000000011001/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101100001000000110000/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101100001000011010110/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101100001000011011000/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101100001000000111111/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101100001000001001011/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101100001000001010001/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101100001000001010010/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101100001000001010100/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101100001000001011101/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101100011100110000111/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101100010101011110011/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101100010101111110100/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101100000001011110101/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101100010000010011010/) { $registry = "Pakistan Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^011101011/) { $registry = "Philipines"; }

  elsif   ($binary_plane_id =~ m/^010010001/) { $registry = "Poland";
    if    ($binary_plane_id =~ m/^0100100011011000/) { $registry = "Poland Military"; }  # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^010010001000000110001110/) { $registry = "Poland Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^010010010/) { $registry = "Portugal";
    if    ($binary_plane_id =~ m/^0100100101111100/) { $registry = "Portugal Military"; } # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^011100011/) { $registry = "South Korea";   # Republic of Korea
    if    ($binary_plane_id =~ m/^011100011111101100000001/) { $registry = "South Korea Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100011111101100000010/) { $registry = "South Korea Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100011111100100001010/) { $registry = "South Korea Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100011111100100000110/) { $registry = "South Korea Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^010010100/) { $registry = "Romania";
    if    ($binary_plane_id =~ m/^010010100011010110101010/) { $registry = "Romania Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010100011010110101011/) { $registry = "Romania Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010100011010110101100/) { $registry = "Romania Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010100001011100101010/) { $registry = "Romania Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010100001100000010110/) { $registry = "Romania Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010100001100000101111/) { $registry = "Romania Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^011100010/) { $registry = "Saudi Arabia";
    if    ($binary_plane_id =~ m/^0111000100000010011/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0111000100000010100/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^0111000100000011100/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^011100010000001001011/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^011100010000000100001010/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100010000000100001011/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100010000001011100001/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100010000001011100010/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100010000001011010101/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100010000001011100011/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100010000001011100100/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100010000001011111001/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100010000001001011010/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100010000001001011011/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100010000001001011100/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100010000001001011110/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100010000001001011101/) { $registry = "Saudi Arabia Military"; } # Per Countries.dat file (specific plane)
  }

  # Serbia: See Yugoslavia slot

  elsif   ($binary_plane_id =~ m/^011101101/) { $registry = "Singapore";
    if    ($binary_plane_id =~ m/^011101101110001100000011/) { $registry = "Singapore Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101101110001100000010/) { $registry = "Singapore Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101101110001100000100/) { $registry = "Singapore Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101101110001100000001/) { $registry = "Singapore Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011101101000010011000011/) { $registry = "Singapore Military"; }   # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^000000001/) { $registry = "South Africa"; }

  elsif   ($binary_plane_id =~ m/^011101110/) { $registry = "Sri Lanka"; }

  elsif   ($binary_plane_id =~ m/^010010101/) { $registry = "Sweden";
    if    ($binary_plane_id =~ m/^010010101000000110000001/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000110000010/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000110000011/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000110000100/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000110000101/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000110000110/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000110000111/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000110001000/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000111100110/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000100010100/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000001000011111/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000111110010/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000001000000111/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000111110011/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000111110100/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000111110101/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000011010000/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000111111001/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000111111000/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000000110011001/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010010101000001000101010/) { $registry = "Sweden Military"; }   # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^010010110/) { $registry = "Switzerland";
    if    ($binary_plane_id =~ m/^010010110111/) { $registry = "Switzerland Military"; }  # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^011101111/) { $registry = "Syria"; }   # Syrian Arab Republic

  elsif   ($binary_plane_id =~ m/^100010000/) { $registry = "Thailand";
    if    ($binary_plane_id =~ m/^100010000101001100110011/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000010001001001000/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000010110100011/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000010110110000/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000010000000001/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000011101011000001/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000000000100111/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000000000101100/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000010110100111/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000010110101000/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000010110101001/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000010110101010/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000010110101011/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000010110101100/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000010110101101/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000010110101110/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000010110101111/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000000001001001/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000101001100110010/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000001110001100001/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000001110001100010/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000001110001100011/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000001110001100100/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010000000110110110110/) { $registry = "Thailand Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^000000101/) { $registry = "Tunisia"; }

  elsif   ($binary_plane_id =~ m/^010010111/) { $registry = "Turkey";
    if    ($binary_plane_id =~ m/^0100101110000010/) { $registry = "Turkey Military"; }  # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^010100001/) { $registry = "Ukraine"; }

  elsif   ($binary_plane_id =~ m/^000011011/) { $registry = "Venezuela";
    if    ($binary_plane_id =~ m/^000011011000000000110010/) { $registry = "Venezuela Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000011011000000001100000/) { $registry = "Venezuela Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000011011000000001101100/) { $registry = "Venezuela Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^100010001/) { $registry = "Viet Nam"; }

  elsif   ($binary_plane_id =~ m/^010011000/) { $registry = "Serbia";  # Was Yugoslavia
    if    ($binary_plane_id =~ m/^010011000000000101010101/) { $registry = "Serbia Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^111100000/) { $registry = "ICAO(1) Temp. Address"; }



  #
  # 12-bit addresses (column "4096" in the table):
  # ----------------------------------------------
  elsif   ($binary_plane_id =~ m/^011100000000/) { $registry = "Afghanistan"; }

  elsif   ($binary_plane_id =~ m/^000010010000/) { $registry = "Angola"; }

  elsif   ($binary_plane_id =~ m/^000010101000/) { $registry = "Bahamas";
    if    ($binary_plane_id =~ m/^000010101000000000100001/) { $registry = "Bahamas Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^100010010100/) { $registry = "Bahrain";
    if    ($binary_plane_id =~ m/^100010010100000000010001/) { $registry = "Bahrain Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010010100000000010110/) { $registry = "Bahrain Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^011100000010/) { $registry = "Bangladesh";
    if    ($binary_plane_id =~ m/^011100000010110000000010/) { $registry = "Bangladesh Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100000010110000000011/) { $registry = "Bangladesh Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100000010110000000100/) { $registry = "Bangladesh Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^111010010100/) { $registry = "Bolivia";
    if    ($binary_plane_id =~ m/^111010010100000011111010/) { $registry = "Bolivia Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111010010100000100000100/) { $registry = "Bolivia Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^000010011100/) { $registry = "Burkina Faso"; }

  elsif   ($binary_plane_id =~ m/^000000110010/) { $registry = "Burundi"; }

  elsif   ($binary_plane_id =~ m/^011100001110/) { $registry = "Cambodia"; }

  elsif   ($binary_plane_id =~ m/^000000110100/) { $registry = "Cameroon";
    if    ($binary_plane_id =~ m/^000000110100010001000011/) { $registry = "Cameroon Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000110100010001000101/) { $registry = "Cameroon Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^000001101100/) { $registry = "Central African Rep."; }    # Central African Republic

  elsif   ($binary_plane_id =~ m/^000010000100/) { $registry = "Chad"; }

  elsif   ($binary_plane_id =~ m/^111010000000/) { $registry = "Chile";
    if    ($binary_plane_id =~ m/^1110100000000110/) { $registry = "Chile Military"; }    # Per Countries.dat file
  }

  elsif   ($binary_plane_id =~ m/^000010101100/) { $registry = "Colombia";
    if    ($binary_plane_id =~ m/^000010101100000000000101/) { $registry = "Columbia Military"; }    # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000010101100000000111011/) { $registry = "Columbia Military"; }    # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000010101100000001100110/) { $registry = "Columbia Military"; }    # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000010101100000001100111/) { $registry = "Columbia Military"; }    # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000010101100000001110001/) { $registry = "Columbia Military"; }    # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000010101100000100001100/) { $registry = "Columbia Military"; }    # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000010101100000000110110/) { $registry = "Columbia Military"; }    # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^000010001100/) { $registry = "Congo DRC"; } # Democratic Republic of the Congo

  elsif   ($binary_plane_id =~ m/^000000110110/) { $registry = "Congo ROC"; }

  elsif   ($binary_plane_id =~ m/^000010101110/) { $registry = "Costa Rica"; }

  elsif   ($binary_plane_id =~ m/^000000111000/) { $registry = "Cote d Ivoire"; }

  elsif   ($binary_plane_id =~ m/^000010110000/) { $registry = "Cuba"; }

  elsif   ($binary_plane_id =~ m/^000011000100/) { $registry = "Dominican Republic"; }

  elsif   ($binary_plane_id =~ m/^111010000100/) { $registry = "Ecuador";
    if    ($binary_plane_id =~ m/^111010000100000000110101/) { $registry = "Ecuador Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^111010000100000000110000/) { $registry = "Ecuador Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^000010110010/) { $registry = "El Salvador"; }

  elsif   ($binary_plane_id =~ m/^000001000010/) { $registry = "Equatorial Guinea"; }

  elsif   ($binary_plane_id =~ m/^000001000000/) { $registry = "Ethiopia"; }

  elsif   ($binary_plane_id =~ m/^110010001000/) { $registry = "Fiji"; }

  elsif   ($binary_plane_id =~ m/^000000111110/) { $registry = "Gabon"; }

  elsif   ($binary_plane_id =~ m/^000010011010/) { $registry = "Gambia"; }

  elsif   ($binary_plane_id =~ m/^000001000100/) { $registry = "Ghana"; }

  elsif   ($binary_plane_id =~ m/^000010110100/) { $registry = "Guatemala"; }

  elsif   ($binary_plane_id =~ m/^000001000110/) { $registry = "Guinea"; }

  elsif   ($binary_plane_id =~ m/^000010110110/) { $registry = "Guyana"; }

  elsif   ($binary_plane_id =~ m/^000010111000/) { $registry = "Haiti"; }

  elsif   ($binary_plane_id =~ m/^000010111010/) { $registry = "Honduras"; }

  elsif   ($binary_plane_id =~ m/^010011001100/) { $registry = "Iceland"; }

  elsif   ($binary_plane_id =~ m/^010011001010/) { $registry = "Ireland";
    if    ($binary_plane_id =~ m/^010011001010000000100011/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010000100111110/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010000100111111/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010000101011000/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010001000000100/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010000111100111/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010000111101000/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010000111101001/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010000111101010/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010000111101011/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010000111101100/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010000111101101/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010000111101110/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010001010001100/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010001010001011/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010001100011010/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010001100011110/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010001100110000/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010001100110001/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010001100110010/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010001100110101/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010011001010001100110110/) { $registry = "Ireland Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^000010111110/) { $registry = "Jamaica"; }

  elsif   ($binary_plane_id =~ m/^000001001100/) { $registry = "Kenya"; }

  elsif   ($binary_plane_id =~ m/^011100000110/) { $registry = "Kuwait"; }

  elsif   ($binary_plane_id =~ m/^011100001000/) { $registry = "Laos"; }    # Lao People's Democratic Republic

  elsif   ($binary_plane_id =~ m/^000001010000/) { $registry = "Liberia"; }

  elsif   ($binary_plane_id =~ m/^000001010100/) { $registry = "Madagascar"; }

  elsif   ($binary_plane_id =~ m/^000001011000/) { $registry = "Malawi"; }

  elsif   ($binary_plane_id =~ m/^000001011100/) { $registry = "Mali"; }

  elsif   ($binary_plane_id =~ m/^000000000110/) { $registry = "Mozambique"; }

  elsif   ($binary_plane_id =~ m/^011100000100/) { $registry = "Myanmar"; }

  elsif   ($binary_plane_id =~ m/^011100001010/) { $registry = "Nepal"; }

  elsif   ($binary_plane_id =~ m/^000011000000/) { $registry = "Nicaragua"; }

  elsif   ($binary_plane_id =~ m/^000001100010/) { $registry = "Niger"; }

  elsif   ($binary_plane_id =~ m/^000001100100/) { $registry = "Nigeria";
    if    ($binary_plane_id =~ m/^000001100100000001010001/) { $registry = "Nigeria Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000001100100000011110000/) { $registry = "Nigeria Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^000011000010/) { $registry = "Panama";
    if    ($binary_plane_id =~ m/^000011000010000001001110/) { $registry = "Panama Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^100010011000/) { $registry = "Papua New Guinea"; }

  elsif   ($binary_plane_id =~ m/^111010001000/) { $registry = "Paraguay"; }

  elsif   ($binary_plane_id =~ m/^111010001100/) { $registry = "Peru";
    if    ($binary_plane_id =~ m/^111010001100000000000111/) { $registry = "Peru Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^000001101110/) { $registry = "Rwanda"; }

  elsif   ($binary_plane_id =~ m/^000001110000/) { $registry = "Senegal"; }

  elsif   ($binary_plane_id =~ m/^000001111000/) { $registry = "Somalia"; }

  elsif   ($binary_plane_id =~ m/^000001111100/) { $registry = "Sudan"; }

  elsif   ($binary_plane_id =~ m/^000011001000/) { $registry = "Suriname"; }

  elsif   ($binary_plane_id =~ m/^000010001000/) { $registry = "Togo"; }

  elsif   ($binary_plane_id =~ m/^000011000110/) { $registry = "Trinidad and Tobago"; }

  elsif   ($binary_plane_id =~ m/^000001101000/) { $registry = "Uganda"; }

  elsif   ($binary_plane_id =~ m/^100010010110/) { $registry = "United Arab Emirates";
    if    ($binary_plane_id =~ m/^100010010110110000/) { $registry = "United Arab Emirates Military"; } # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^100010010110000100100110/) { $registry = "United Arab Emirates Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010010110000000101001/) { $registry = "United Arab Emirates Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010010110000000101010/) { $registry = "United Arab Emirates Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010010110000000101011/) { $registry = "United Arab Emirates Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010010110000000101110/) { $registry = "United Arab Emirates Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^100010010110000000101100/) { $registry = "United Arab Emirates Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^000010000000/) { $registry = "Tanzania"; } # United Republic of Tanzania

  elsif   ($binary_plane_id =~ m/^111010010000/) { $registry = "Uruguay"; }

  elsif   ($binary_plane_id =~ m/^100010010000/) { $registry = "Yemen"; }

  elsif   ($binary_plane_id =~ m/^000010001010/) { $registry = "Zambia"; }



  # 14-bit addresses (column "1024" in the table):
  # ----------------------------------------------
  elsif   ($binary_plane_id =~ m/^01010000000100/) { $registry = "Albania"; }

  elsif   ($binary_plane_id =~ m/^00001100101000/) { $registry = "Antigua and Barbuda"; }

  elsif   ($binary_plane_id =~ m/^01100000000000/) { $registry = "Armenia"; }

  elsif   ($binary_plane_id =~ m/^01100000000010/) { $registry = "Azerbaijan";
    if    ($binary_plane_id =~ m/^011000000000100000000001/) { $registry = "Azerbaijan Military"; }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^00001010101000/) { $registry = "Barbados"; }

  elsif   ($binary_plane_id =~ m/^01010001000000/) { $registry = "Belarus"; }

  elsif   ($binary_plane_id =~ m/^00001010101100/) { $registry = "Belize"; }

  elsif   ($binary_plane_id =~ m/^00001001010000/) { $registry = "Benin"; }

  elsif   ($binary_plane_id =~ m/^01101000000000/) { $registry = "Bhutan"; }

  elsif   ($binary_plane_id =~ m/^01010001001100/) { $registry = "Bosnia and Herzegovina"; }

  elsif   ($binary_plane_id =~ m/^00000011000000/) { $registry = "Botswana";
    if    ($binary_plane_id =~ m/^000000110000000000010010/) { $registry = "Botswana Military" }  # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000000110000000000011010/) { $registry = "Botswana Military" }  # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^10001001010100/) { $registry = "Brunei Darussalam"; }

  elsif   ($binary_plane_id =~ m/^00001001011000/) { $registry = "Cape Verde"; }

  elsif   ($binary_plane_id =~ m/^00000011010100/) { $registry = "Comoros"; }

  elsif   ($binary_plane_id =~ m/^10010000000100/) { $registry = "Cook Islands"; }

  elsif   ($binary_plane_id =~ m/^01010000000111/) { $registry = "Croatia";
    if    ($binary_plane_id =~ m/^010100000001110100010011/) { $registry = "Croatia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010100000001111110000101/) { $registry = "Croatia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010100000001111110000110/) { $registry = "Croatia Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^01001100100000/) { $registry = "Cyprus"; }

  elsif   ($binary_plane_id =~ m/^00001001100000/) { $registry = "Djibouti"; }

  elsif   ($binary_plane_id =~ m/^00100000001000/) { $registry = "Eritrea"; }

  elsif   ($binary_plane_id =~ m/^01010001000100/) { $registry = "Estonia"; }

  elsif   ($binary_plane_id =~ m/^01010001010000/) { $registry = "Georgia"; }

  elsif   ($binary_plane_id =~ m/^00001100110000/) { $registry = "Grenada"; }

  elsif   ($binary_plane_id =~ m/^00000100100000/) { $registry = "Guinea-Bissau"; }

  elsif   ($binary_plane_id =~ m/^01101000001100/) { $registry = "Kazakhstan"; }

  elsif   ($binary_plane_id =~ m/^11001000111000/) { $registry = "Kiribati"; }

  elsif   ($binary_plane_id =~ m/^01100000000100/) { $registry = "Kyrgyzstan"; }

  elsif   ($binary_plane_id =~ m/^01010000001011/) { $registry = "Latvia"; }

  elsif   ($binary_plane_id =~ m/^00000100101000/) { $registry = "Lesotho"; }

  elsif   ($binary_plane_id =~ m/^01010000001111/) { $registry = "Lithuania";
    if    ($binary_plane_id =~ m/^010100000011111111010010/) { $registry = "Lithuania Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010100000011111111010011/) { $registry = "Lithuania Military"; }   # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^01001101000000/) { $registry = "Luxembourg";
    if    ($binary_plane_id =~ m/^0100110100000011110/) { $registry = "NATO"; }   # Per Countries.dat file (In Luxembourg block)
  }

  # Also see NATO in the Luxembourg block above
  elsif   ($binary_plane_id =~ m/^010001110111111111110001/) { $registry = "NATO Military"; } # Per Countries.dat file (specific plane)
  elsif   ($binary_plane_id =~ m/^010001110111111111110010/) { $registry = "NATO Military"; } # Per Countries.dat file (specific plane)
  elsif   ($binary_plane_id =~ m/^010001110111111111110011/) { $registry = "NATO Military"; } # Per Countries.dat file (specific plane)


  elsif   ($binary_plane_id =~ m/^00000101101000/) { $registry = "Maldives"; }

  elsif   ($binary_plane_id =~ m/^01001101001000/) { $registry = "Malta";
    if    ($binary_plane_id =~ m/^010011010010000001011000/) { $registry = "Malta Military"; }   # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^10010000000000/) { $registry = "Marshall Islands"; }

  elsif   ($binary_plane_id =~ m/^00000101111000/) { $registry = "Mauritania"; }

  elsif   ($binary_plane_id =~ m/^00000110000000/) { $registry = "Mauritius"; }

  elsif   ($binary_plane_id =~ m/^01101000000100/) { $registry = "Micronesia"; }   # Micronesia, Federated States of

  elsif   ($binary_plane_id =~ m/^01001101010000/) { $registry = "Monaco"; }

  elsif   ($binary_plane_id =~ m/^01101000001000/) { $registry = "Mongolia"; }

  elsif   ($binary_plane_id =~ m/^01010001011000/) { $registry = "Montenegro"; } # Per Countries.dat file

  elsif   ($binary_plane_id =~ m/^00100000000100/) { $registry = "Namibia"; }

  elsif   ($binary_plane_id =~ m/^11001000101000/) { $registry = "Nauru"; }

  elsif   ($binary_plane_id =~ m/^01110000110000/) { $registry = "Oman";
    if    ($binary_plane_id =~ m/^01110000110000000111/) { $registry = "Oman Military"; }   # Per Countries.dat file
    elsif ($binary_plane_id =~ m/^011100001100000010001100/) { $registry = "Oman Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^011100001100000010001011/) { $registry = "Oman Military"; }   # Per Countries.dat file (specific plane)
 
  }

  elsif   ($binary_plane_id =~ m/^01101000010000/) { $registry = "Palau"; }

  elsif   ($binary_plane_id =~ m/^00000110101000/) { $registry = "Qatar";
    if    ($binary_plane_id =~ m/^000001101010001001001010/) { $registry = "Qatar Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000001101010001001001011/) { $registry = "Qatar Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000001101010001001001100/) { $registry = "Qatar Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000001101010001001001101/) { $registry = "Qatar Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000001101010000011011001/) { $registry = "Qatar Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000001101010000011011010/) { $registry = "Qatar Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000001101010001001001000/) { $registry = "Qatar Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000001101010001001001001/) { $registry = "Qatar Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000001101010001001010101/) { $registry = "Qatar Military"; }   # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^000001101010001001010110/) { $registry = "Qatar Military"; }   # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^01010000010011/) { $registry = "Moldova"; }   # Republic of Moldova

  elsif   ($binary_plane_id =~ m/^11001000110000/) { $registry = "Saint Lucia"; }

  elsif   ($binary_plane_id =~ m/^00001011110000/) { $registry = "Saint Vincent and the Grenadines"; }

  elsif   ($binary_plane_id =~ m/^10010000001000/) { $registry = "Samoa"; }

  elsif   ($binary_plane_id =~ m/^01010000000000/) { $registry = "San Marino"; }

  elsif   ($binary_plane_id =~ m/^00001001111000/) { $registry = "Sao Tome and Principe"; }

  elsif   ($binary_plane_id =~ m/^00000111010000/) { $registry = "Seychelles"; }

  elsif   ($binary_plane_id =~ m/^00000111011000/) { $registry = "Sierra Leone"; }

  elsif   ($binary_plane_id =~ m/^01010000010111/) { $registry = "Slovakia";
    if    ($binary_plane_id =~ m/^010100000101111101101100/) { $registry = "Slovakia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010100000101111101100011/) { $registry = "Slovakia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010100000101111101100001/) { $registry = "Slovakia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010100000101111101100010/) { $registry = "Slovakia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010100000101111101101010/) { $registry = "Slovakia Military"; } # Per Countries.dat file (specific plane)
    elsif ($binary_plane_id =~ m/^010100000101111101101000/) { $registry = "Slovakia Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^01010000011011/) { $registry = "Slovenia";
    if    ($binary_plane_id =~ m/^0101000001101111/) { $registry = "Slovenia Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^10001001011100/) { $registry = "Solomon Islands"; }

  elsif   ($binary_plane_id =~ m/^00000111101000/) { $registry = "Swaziland"; }

  elsif   ($binary_plane_id =~ m/^01010001010100/) { $registry = "Tajikistan"; }

  elsif   ($binary_plane_id =~ m/^01010001001000/) { $registry = "Macedonia"; } # The former Yugoslav Republic of Macedonia

  elsif   ($binary_plane_id =~ m/^11001000110100/) { $registry = "Tonga"; }

  elsif   ($binary_plane_id =~ m/^01100000000110/) { $registry = "Turkmenistan";
    if    ($binary_plane_id =~ m/^011000000001100001100010/) { $registry = "Turkmenistan Military"; } # Per Countries.dat file (specific plane)
  }

  elsif   ($binary_plane_id =~ m/^01010000011111/) { $registry = "Uzbekistan"; }

  elsif   ($binary_plane_id =~ m/^11001001000000/) { $registry = "Vanuatu"; }

  elsif   ($binary_plane_id =~ m/^00000000010000/) { $registry = "Zimbabwe"; }

  elsif   ($binary_plane_id =~ m/^10001001100100/) { $registry = "Taiwan";   # Per Countries.dat file (In ICAO(2) Flight Safety block below)
    if    ($binary_plane_id =~ m/^100010011001000101100000/) { $registry = "Taiwan Military"; } # Per Countries.dat file (specific plane)
  }
  elsif   ($binary_plane_id =~ m/^10001001100100/) { $registry = "ICAO(2) Flight Safety"; }

  elsif   ($binary_plane_id =~ m/^11110000100100/) { $registry = "ICAO(2) Flight Safety"; }

# NOTE: ICAO blocks are different in Countries.dat file


  #
  # Blocks of addresses for anything that hasn't matched so far, from <http://www.kloth.net/radio/icao24alloc.php> :
  # ------------------------------------------------------------
  elsif   ($binary_plane_id =~ m/^00100/)  { $registry = "Africa Region"; }                   # AFI Region
  elsif   ($binary_plane_id =~ m/^00101/)  { $registry = "South America Region"; }            # SAM Region
  elsif   ($binary_plane_id =~ m/^0101/)   { $registry = "Europe/North Atlantic Regions"; }   # EUR and NAT Regions
  elsif   ($binary_plane_id =~ m/^01100/)  { $registry = "Middle East Region"; }              # MID Region
  elsif   ($binary_plane_id =~ m/^01101/)  { $registry = "Asia Region"; }                     # ASIA Region
  elsif   ($binary_plane_id =~ m/^1001/)   { $registry = "North America/Pacific Regions"; }   # NAM and PAC Regions
  elsif   ($binary_plane_id =~ m/^111011/) { $registry = "Carribean Region"; }                # CAR Region
  elsif   ($binary_plane_id =~ m/^1011/)   { $registry = "Country Code RESERVED"; }           # Reserved for future use
  elsif   ($binary_plane_id =~ m/^1101/)   { $registry = "Country Code RESERVED"; }           # Reserved for future use
  elsif   ($binary_plane_id =~ m/^1111/)   { $registry = "Country Code RESERVED"; }           # Reserved for future use
  elsif   ($binary_plane_id =~ m/^000000000000000000000000/) { $registry = "Country Code DISALLOWED"; }   # Shall not be assigned
  elsif   ($binary_plane_id =~ m/^111111111111111111111111/) { $registry = "Country Code DISALLOWED"; }   # Shall not be assigned


 
  # Parse altitude if MSG Type 2, 3, 5, 6, or 7, save in hash.
  $print2 = "       ";
  if (    $fields[1] == 2
       || $fields[1] == 3
       || $fields[1] == 5
       || $fields[1] == 6
       || $fields[1] == 7 ) {

    if ( defined($fields[11])
         && $fields[11] ne ""
         && $fields[11] ne 0 ) {

      $old = "";
      if (defined($altitude{$plane_id})) {
        $old = $altitude{$plane_id};
      }

      # Save new altitude
      $altitude{$plane_id} = sprintf("%06d", $fields[11]);

      if ($old ne $altitude{$plane_id}) {
        $print2 = sprintf("%5sft", $fields[11]);
        $newdata{$plane_id}++;  # Found a new altitude!
      }
    }
  }


  # Parse ground speed and track if MSG Type 2 or 4, save in hash.
  $print3 = "     ";
  $print4 = "    ";
  if ( $fields[1] ==  4 || $fields[1] == 2 ) {

    if ( defined($fields[12]) && $fields[12] ne "" ) {

      $old = "";
      if (defined($groundspeed{$plane_id})) {
        $old = $groundspeed{$plane_id};
      }

      # Save new ground speed
      $groundspeed{$plane_id} = $fields[12];

      if ($old ne $groundspeed{$plane_id}) {
        $print3 = sprintf("%3skn", $fields[12]);
        $newdata{$plane_id}++;  # Found a new ground speed!
      }
    }

    if ( defined($fields[13]) && $fields[13] ne "" ) {

      $old = "";
      if (defined($track{$plane_id})) {
        $old = $track{$plane_id};
      }

      # Save new track
      $track{$plane_id} = $fields[13];

      if ($old ne $track{$plane_id}) {
        $print4 = sprintf("%3s�", $fields[13]);
        $newdata{$plane_id}++;  # Found a new track!
      }
    }
  }


  # Parse lat/long if MSG Type 2 or 3, save in hash.
  $print5 = "                 ";
  if (  ( $fields[1] == 2 || $fields[1] == 3 )
       && defined($fields[14]) && $fields[14] ne ""
       && defined($fields[15]) && $fields[15] ne "" ) {

    $oldlat = "";
    if (defined($lat{$plane_id})) {
      $oldlat = $lat{$plane_id};
    }

    $lat = $fields[14] * 1.0;
    if ($lat >= 0.0) {
      $NS = 'N';
    } else {
      $NS = 'S';
      $lat = abs($lat);
    }
    $latdeg = int($lat);
    $latmins = $lat - $latdeg;
    $latmins2 = $latmins * 60.0;
    # Save new latitude
    $lat{$plane_id} = sprintf("%02d%05.2f%s", $latdeg, $latmins2, $NS);

    $oldlon = "";
    if (defined($lon{$plane_id})) {
      $oldlon = $lon{$plane_id};
    }

    $lon = $fields[15] * 1.0;
    if ($lon >= 0.0) {
      $EW = 'E';
    } else {
      $EW = 'W';
      $lon = abs($lon);
    }
    $londeg = int($lon);
    $lonmins = $lon - $londeg;
    $lonmins2 = $lonmins * 60.0;
    # Save new longitude
    $lon{$plane_id} = sprintf("%03d%05.2f%s", $londeg, $lonmins2, $EW);

    if ( ($oldlat ne $lat{$plane_id}) || ($oldlon ne $lon{$plane_id}) ) {
      $print5 = sprintf("%8s,%9s", $lat{$plane_id},$lon{$plane_id});

      # Save most recent posit time
      $last_posit_time{$plane_id} = time();

      $newdata{$plane_id}++;    # Found a new lat/lon!

      # Tactical callsign:
      # Have new lat/lon. Check whether we have a tactical call
      # already defined. If not, assign one that includes
      # the plane_id and the country of registration.
      if ( !defined($tactical{$plane_id}) ) {

        # Assign tactical call = $plane_id + registry
        # Max tactical call in Xastir is 57 chars (56 + terminator?)
        #
        $tactical{$plane_id} = $plane_id . " (" . $registry . ")";
        $tactical{$plane_id} =~ s/\s+/ /g; # Change multiple spaces to one
        $aprs = $xastir_user . '>' . "APRS::TACTICAL :" . $plane_id . "=" . $tactical{$plane_id};

        $print6 = sprintf("%-18s", $tactical{$plane_id});
        print("$print1  $print2  $print3  $print4  $print6  $aprs\n");

        # xastir_udp_client  <hostname> <port> <callsign> <passcode> {-identify | [-to_rf] <message>}
        $result = `$udp_client $xastir_host $xastir_port $xastir_user $xastir_pass \"$aprs\"`;
        if ($result =~ m/NACK/) {
          die "Received NACK from Xastir: Callsign/Passcode don't match?\n";
        }

        if ($enable_logging == 1) {
          `echo \"$aprs\" >> $log_file`;
        }

      }
    }
  }


  # Save tail or flight number in hash if MSG Type 1 or "ID" sentence.
  if (    ($fields[0] eq "ID" || $fields[1] ==  1)
       && defined($fields[10])
       && $fields[10] ne "????????"
       && $fields[10] ne ""
       && !($fields[10] =~ m/^\s+$/) ) {

    $old = "";
    if (defined($tail{$plane_id})) {
      $old = $tail{$plane_id}; 
    }

    # Save new tail number or flight number, assign tactical call
    $temp_tail = $fields[10];
    $temp_tail =~ s/[^a-zA-Z0-9,]//g; # Filter out all but alphanumeric chars
    $tail{$plane_id} = $temp_tail;
    $tail{$plane_id} =~ s/\s//g;    # Remove spaces

    if ($old ne $tail{$plane_id}) {
      $print6 = sprintf("%-18s", $temp_tail);
      $newdata{$plane_id}++;    # Found a new tail or flight number!
 
      # Assign tactical call = tail number or flight number + registry (if defined)
      # Max tactical call in Xastir is 57 chars (56 + terminator?)
      #
      $tactical{$plane_id} = $temp_tail;
      if ($registry ne "Registry?") {
        $tactical{$plane_id} = $temp_tail . " (" . $registry . ")";
        $tactical{$plane_id} =~ s/\s+/ /g; # Change multiple spaces to one
      }
      $aprs = $xastir_user . '>' . "APRS::TACTICAL :" . $plane_id . "=" . $tactical{$plane_id};

      print("$print1  $print2  $print3  $print4  $print6  $aprs\n");
 
      # xastir_udp_client  <hostname> <port> <callsign> <passcode> {-identify | [-to_rf] <message>}
      $result = `$udp_client $xastir_host $xastir_port $xastir_user $xastir_pass \"$aprs\"`;
      if ($result =~ m/NACK/) {
        die "Received NACK from Xastir: Callsign/Passcode don't match?\n";
      }

      if ($enable_logging == 1) {
        `echo \"$aprs\" >> $log_file`;
      }

    }
  }


  $squawk_txt = "";
  if ( defined($fields[17]) && ($fields[17] ne "") ) {

    $old = "";
    if (defined($squawk{$plane_id})) {
      $old = $squawk{$plane_id};
    }
    $squawk{$plane_id} = $fields[17];
 
    if ($old ne $squawk{$plane_id}) {
      $newdata{$plane_id}++;    # Found a new squawk!
    }
  }
  if (defined($squawk{$plane_id})) {
    $squawk_txt = sprintf(" SQUAWK=%04d", $squawk{$plane_id}); 
  }
 


  $emerg_txt = "";
  $emergency = "0";
  if ( defined($fields[19]) ) {
    $emergency = $fields[19];
  }
  if ( $emergency eq "-1" ) {       # Emergency of some type
    $emerg_txt = " EMERGENCY=";     # Keyword triggers Xastir's emergency mode!!!
 
    # Check squawk code
    if ( defined($squawk{$plane_id}) ) {
      if ($squawk{$plane_id} eq "7500") {        # Unlawful Interference (hijacking)
        $emerg_txt = $emerg_txt . "Hijacking";
      }
      if ($squawk{$plane_id} eq "7600") {        # Communications failure/problems
        $emerg_txt = $emerg_txt . "Comms_Failure";
      }
      if ($squawk{$plane_id} eq "7700") {        # General Emergency
        $emerg_txt = $emerg_txt . "General";
      }
    }
    $newdata{$plane_id}++;
  }


  $onGroundTxt = "";
  if ( defined($fields[21]) ) {
    $onGround = $fields[21];
    if ($onGround eq "-1") {
      $onGroundTxt = " On_Ground";
      $newdata{$plane_id}++;
    }
  }
 

  $newtrack = "360";
  if ( defined($track{$plane_id}) ) {
    if ($track{$plane_id} == 0) {
      $newtrack = "360";
    }
    else {
      $newtrack = sprintf("%03d", $track{$plane_id} );
    }
  }

  $newspeed = "000";
  if ( defined ($groundspeed{$plane_id}) ) {
    $newspeed = sprintf("%03d", $groundspeed{$plane_id} );
    if ( ($groundspeed{$plane_id} > 0) && ($groundspeed{$plane_id} < 57) ) {
      $symbol = "X";  # Switch to helicopter symbol
    }
    if ($groundspeed{$plane_id} > 126) {
      $symbol = "^";  # Switch to large aircraft symbol
    } 
  }

  $newtail = "";
  if ( defined($tail{$plane_id}) ) {
    $newtail = " $tail{$plane_id}";
  }

  # Auto-switch the symbol based on speed/altitude.
  # Symbols:
  #   Small airplane = /'
  #       Helicopter = /X 
  #   Large aircraft = /^
  #         Aircraft = \^ (Not used in this script)
  #
  #  Cessna 150:  57 knots minimum.
  # Twin Cessna: 215 knots maximum.
  #  UH-1N Huey: 110 knots maximum.
  # Landing speed Boeing 757: 126 knots.
  #
  # If <= 10000 feet and  1 -  56 knots: Helicopter
  # If <= 20000 feet and 57 - 125 knots: Small aircraft
  # If >  20000 feet                   : Large aircraft
  # if                      > 126 knots: Large aircraft
  #
  $symbol = "'"; # Start with small aircraft symbol
 
  $newalt = "";
  if ( defined($altitude{$plane_id}) ) {
    $newalt = " /A=$altitude{$plane_id}";

    if ($altitude{$plane_id} > 20000) {
      $symbol = "^";  # Switch to large aircraft symbol
    }
    elsif ($symbol eq "^") {
      # Do nothing, already switched to large aircraft due to speed
    }
    elsif ($symbol eq "X" && $altitude{$plane_id} > 10000) {
      $symbol = "'";  # Switch to small aircraft from helicopter
    }
  }



  # Above we parsed some message that changed some of our data, send out the
  # new APRS string if we have enough data defined.
  #
  if ( defined($newdata{$plane_id})
       && $newdata{$plane_id} ) {

    # Count percentage of planes with lat/lon out of total planes that have altitude listed.
    # This should show an approximate implementation percentage for ADS-B transponders.
    $alt_planes = 0;
    $lat_planes = 0;
    $print_adsb_percentage = "";
    foreach $key (keys %lat) {
      $lat_planes++;
    }
    foreach $key (keys %altitude) {
      $alt_planes++;
    }
    if ($alt_planes != 0) {
      $adsb_percentage = ( ($lat_planes * 1.0) / $alt_planes) * 100.0;
      $print_adsb_percentage = sprintf("ADS-B:%-1.1f%% ($lat_planes/$alt_planes)", $adsb_percentage);
    }


    # Do we have a lat/lon and is it recent enough?
    if (    defined($lat{$plane_id})
         && defined($lon{$plane_id}) ) {

      #
      # Yes we have a lat/lon
      #

      # Check the age of the lat/lon
      $age = time() - $last_posit_time{$plane_id};
      if ( $age > $plane_TTL ) {
        #
        # We have a lat/lon but it is too old
        #
        $print_age1 = sprintf("(%s%s)", $age, "s");
        $print_age2 = sprintf("%18s", $print_age1);
        $print_aprs = sprintf("%-96s", "$newtail$emerg_txt$squawk_txt$onGroundTxt ($registry)");
        print("$print1  $print2  $print3  $print4  $print_age2 $print_aprs  $print_adsb_percentage\n");
 
      }
      else {
        #
        # We have a recent lat/lon
        #
        $aprs="$xastir_user>APRS:)$plane_id!$lat{$plane_id}/$lon{$plane_id}$symbol$newtrack/$newspeed$newalt$newtail$emerg_txt$squawk_txt$onGroundTxt ($registry)";
        $print_aprs = sprintf("%-95s", $aprs);
        if (    $age > 0                    # Lat/lon is aging a bit
             || $print5 eq "                 " ) {     # Didn't parse lat/lon this time
          $print_age1 = sprintf("%s%s", $age, "s");
          $print_age2 = sprintf("%18s", $print_age1);
          print("$print1  $print2  $print3  $print4  $print_age2  $print_aprs  $print_adsb_percentage\n");
        }
        else {
          print("$print1  $print2  $print3  $print4  $print5  $print_aprs  $print_adsb_percentage\n");
        }

        # xastir_udp_client  <hostname> <port> <callsign> <passcode> {-identify | [-to_rf] <message>}
#        $result = `$udp_client $xastir_host $xastir_port $xastir_user $xastir_pass \"$aprs [Pmin0.0,]\"`;
        $result = `$udp_client $xastir_host $xastir_port $xastir_user $xastir_pass \"$aprs\"`;
        if ($result =~ m/NACK/) {
          die "Received NACK from Xastir: Callsign/Passcode don't match?\n";
        }

        if ($enable_logging == 1) {
          `echo \"$aprs\" >> $log_file`;
        }

      }
    }
    else {
      #
      # No, we have no lat/lon
      #
      $print_age = sprintf("%18s", "-");
      $print_aprs = sprintf("%-96s", "$newtail$emerg_txt$squawk_txt$onGroundTxt ($registry)");
      print("$print1  $print2  $print3  $print4   $print_age$print_aprs  $print_adsb_percentage\n");

      if ($enable_circles == 1) {
        $radius = 10.0; # Set a default of 10 miles
        if ( defined($altitude{$plane_id}) ) {
          $radius = ( ( ($altitude{$plane_id} - $my_alt) / 1000 ) * 2 );  # 40k = 80 miles, 20k = 40 miles, 10k = 20 miles, 1k = 2 miles
        }
        $print_radius = sprintf("%2.1f", $radius);
        $aprs="$xastir_user>APRS:)$plane_id!$my_lat/$my_lon$symbol$newtrack/$newspeed$newalt$newtail$emerg_txt$squawk_txt$onGroundTxt ($registry) [Pmin$print_radius,]";
  #     print "$aprs\n";

        # xastir_udp_client  <hostname> <port> <callsign> <passcode> {-identify | [-to_rf] <message>}
        $result = `$udp_client $xastir_host $xastir_port $xastir_user $xastir_pass \"$aprs\"`;
        if ($result =~ m/NACK/) {
          die "Received NACK from Xastir: Callsign/Passcode don't match?\n";
        }

        if ($enable_logging == 1) {
          `echo \"$aprs\" >> $log_file`;
        }

      }
    }

    # Reset the newdata flag
    $newdata{$plane_id} = 0;
  }


  # Convert altitude to altitude above MSL instead of altitude from a reference barometric reading?
  # Info:  http://forums.flyer.co.uk/viewtopic.php?t=16375
  # How many millibar in 1 feet of air? The answer is 0.038640888 @ 0C (25.879232 ft/mb).
  # How many millibar in 1 foot of air [15 �C]? The answer is 0.036622931 @ 15C (27.3053 ft/mb).
  # Flight Level uses a pressure of 29.92 "Hg (1,013.2 mb).
  # Yesterday the pressure here was about 1013, so the altitudes looked right on. Today the planes
  # are reporting ~500' higher via ADS-B when landing at Paine Field. Turns out the pressure today
  # is 21mb lower, which equates to an additional 573' of altitude reported using the 15C figure!
  # 
  # /A=aaaaaa feet
  # CSE/SPD, i.e. 180/999 (speed in knots, direction is WRT true North), if unknown:  .../...
  # )AIDV#2!4903.50N/07201.75WA
  # ;LEADERVVV*092345z4903.50N/07201.75W>088/036
  # )A19E61!4903.50N/07201.75W' 356/426 /A=29275  # Example Small Airplane Object 


# end of while loop
}

close($socket);



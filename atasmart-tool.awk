#!/usr/bin/gawk --exec

# vim: set noet ci pi sts=0 sw=4 ts=4 :


function warn(msg) {
	print "ERROR: " msg > "/dev/stderr"
}

function errexit(msg) {
	warn(msg)
	exit 1
}

function clear() {
	printf "\033c" # VT100 command to reset/clear terminal.
}

function escapebad(string) {
	# For shell...
	gsub(/[^\.a-zA-Z0-9\/_-]/,"\\\\&",string)
	return "\"" string "\""
}

function removebad(string) {
	gsub(/([^\.a-zA-Z0-9\/_-])+/,"_",string)
	if (substr(string,1,1) == "_") string = substr(string,2)
	if (substr(string,length(string)) == "_") string = substr(string,1,length(string)-1)
	return string
}

function issmart(disk) {
	#safedisk = escapebad(disk)
	if (system("test -r " escapebad(disk)) == 0) {
		if (system(skdump " --can-smart " escapebad(disk) " > /dev/null 2>&1") == 0) return 1
		else {
			warn("Device '" disk "' isn't smart capable.")
			return 0
		}
	} else {
		warn("Cannot read '" disk "'. Do you have permissions?")
                return 0
	}
}

function counttotsize() {
	for (device in devices) {
		while ((skdump " " device | getline) > 0) {
			if ($1 == "Size:") {
				mbytes = $2
				break
			}
		}
		close(skdump " " device)
		totmbytes += mbytes
		devices[device]["sdata"]["size"] = mbytes
	}
}

function getsmartdata(disk,dataset) {
	attrlist = 0

	if (system("test -b " escapebad(disk)) == 0) dumpcmd = skdump " " escapebad(disk)
	else dumpcmd = skdump " --load=" escapebad(disk) # Load raw smart data from file instead

	while ((dumpcmd | getline) > 0) {
		# This is certainly a hack to parse the output of skdump.
		# What's worse, the output of skdump might change.
		# However, we're trying our best to avoid little changes.
		if (attrlist) {
			if ($1 ~ /^(5|7|1[013]|18[12478]|19[6789]|250)$/) { # <-- smart attributes to watch on.
										# Not nice when hardcoded... TODO.
				name = $2
				for (i=1; i<=5; i++) $i = ""
				sub(/^\s+/,"")
				pretty = substr($0,0,match($0,/\s0x[0-9a-f]+/) - 1)

				# In case we happen to need old-age/pre-fail...
				# pre-fail should be taken seriously so maybe work on that at some point?
				#type = substr($0,RSTART + RLENGTH + 1,7)
			}
		}
		else if ($1 == "ID#") {
			attrlist = 1
			continue
		}
		else {
			name = tolower(substr($0,1,match($0,/:/) - 1))
			gsub(/\s+/,"_",name)
			switch (name) {
				case "size":
					pretty = $2
					break
				case "serial":
					pretty = $2
					gsub(/^\[|\]$/,"",pretty)
					break
				case "overall_status":
					name = "status"
					pretty = $3
					break
				case /^(model|powered_on)$/:
					pretty = substr($0,match($0,/:/) + 2)
					break
				case "bad_sectors":
					pretty = $3
					break
				case "percent_self-test_remaining":
					name = "test_remaining"
					pretty = substr($0,match($0,/:/) + 2)
					pretty = substr(pretty,1,length(pretty) - 1)
					break
			}
		}
		if (pretty != "") {
			devices[device][dataset][name] = pretty
			name = ""
			pretty = ""
		}
	}
	close(dumpcmd)
}

function file2arr(file,	a) {
	# a is local and should not be set.
	while ((getline < file) > 0) {
		key = $1
		sub($1 " ","")
		a[key] = $0
	}
	close(file)
	return a
}

function testprogress(disk) {
	pollcmd = skdump " " disk
	while ((pollcmd | getline) > 0) {
		if (/^Percent Self-Test Remaining: /) break
	}
	close(pollcmd)
	lf = strtonum($NF)
	sub(/%/,"",lf)

	# Since Progress varies from 90 to 0 (% left)
	# We'll convert the 90 step (9 really) into percents
	# what is what the rest of the script expects.
	return lf * ( 1 / 0.9 )
}

function printprogress() {
	printf "\033c" # VT100 command to reset/clear terminal.
	for (device in devices) print device ":\t" 100 - devices[device]["progress"] "%"
	print "\nTotal:\t\t" totprogress / totmbytes * 100 "%"
}

BEGIN {
	version = "0.0.2-alpha5"

	# Rather complex way to store script file name to 'this'.
	# Other methods I've found aren't realiable.
	# Better versions/methods are welcome. ;)
	# Also PROCINFO["argv"] was empty. Maybe some security feature?
	split(ENVIRON["_"],thispath,"/")
	this = thispath[length(thispath)]
	if (this ~ /[a-z]?awk$/ ) { # 'this' contains awk interpreter itself. Let's find the script name...
		OLDRS = RS
		RS = "\0"
		while ((getline this < "/proc/self/cmdline") > 0) {
			if (found) break
			else if (this ~ /(-f|--file|-x|--exec)$/) found = 1
		}
		close("/proc/self/cmdline")
		RS = OLDRS
	}

	if (found == "") this = "atasmart-tool"
	else {
		split(this,thispath,"/")
        	this = thispath[length(thispath)]
	}
	# 'this' set.

	if (ARGV[1] == "") errexit("You need --help.")

	# Let's set some sane defaults
	skdump = "skdump"
	sktest = "sktest"
	smartdatadir = "/var/lib/" this "/"
	sleep = 5
	gap = 5
	report = 1

	# Go trough cli switches...
	for (i = 1; i < ARGC; i++) {
		arg = ARGV[i]

		if ( substr(arg,1,1) != "-" ) break # ... but break the loop as soon as an argument does not start with a dash (-).
		else if (arg == "--") {
			i++
			break
		} else if (arg == "--help") {
			print "atasmart-tool v. " version " -- Ilja Sara"
			print "Small wrapper around skdump and sktest, S.M.A.R.T. -tools.\n\n"
			print this " [--test <quick|short|long|extended|monitor> [--gap <1-99>] [--sleep <n>] [--log] [--[no-]summary]] <device> [device2] .. [deviceN]"
			print "Without --test the action is 'monitor', unless no test is running then it's same as running 'skdump' without arguments on device(s)\n"
			print "--test <monitor|short|long|extended>\n\tRun a test or monitor a running test. 'long' and 'extended' are the same."
			print "--gap <n>\n\tdetermines the interval at which to print the progress percentage status. Default: " gap "%. Set to 0 to disable printing progress indicator."
			print "--sleep <n>\n\ttime to sleep in seconds between pollings."
			print "--log\n\tChanges output to log friendly format."
			print "--[no-]summary\n\tPrint (or omit) report at the end of test. Note: with '--test monitor' report printing is always disabled, since " this " can't know the smart values before the test(s) were started."
			print "--savedata\n\tSave smart data after the test to compare smart data in later runs."
			exit 0
		} else if (arg == "--test") {
			i++
			tt = ARGV[i]
			if (tt !~ /quick|short|long|monitor/) errexit("--test only accepts 'quick', 'short', 'long', 'extended' or 'monitor 'as an argument.")
		} else if (arg == "--gap") {
			i++
			gap = strtonum(ARGV[i])
			if (gap > 99 || gap < 0) errexit("Gap must be between 0 and 99.")
		} else if (arg == "--sleep") {
			i++
			sleep = strtonum(ARGV[i]) # Some sanity checks might be in place.
		}
		else if (arg == "--log") {
			logformat = 1
			bar = 0
		}
		else if (arg == "--summary") report = 1
		else if (arg == "--no-summary") report = 0
		else if (arg == "--savedata") savedata = 1
		else errexit("I don't know what to do with this '" arg "' -switch of yours. You may need --help. Aborting... :(")
	}

	if (ARGV[i] == "") errexit("No devices specified.")

	if (tt == "") { # Only dump smart data and exit since no test type was specified.
		for (i = 1; i < ARGC; i++) {
			print ""
			if (system(skdump " " ARGV[i]) > 0) e = 1
		}
		if (e) errexit("\nSome/all skdump processes exited with non-zero exit code")
		exit 0
	}

	# We're here if --test was passed correctly.

	# Create an array of devices and set starting value for progress.
	j = 1
	while (i < ARGC) { # Note: The value of i is what's left from parsing the cli switches.
		device = ARGV[i]
		if (issmart(device)) {
			devices[device]["progress"] = 100 + gap + 1
			j++
		} else warn("Skipping '" device "', since it does not seem to have smart cabability.")
		i++
	}

	if (j == 1) errexit("Not a single suitable device left. Exiting...")

	# Self explanatory.
	numdevices = j - 1

	if (tt ~ /^(quick|short|long|extended)$/) {
		if (tt == "long") tt = "extended"
		else if (tt == "quick") tt = "short"

		if (report) for (device in devices) {
			getsmartdata(device,"sdata")
			if (devices[device]["sdata"]["test_remaining"] > 0) errexit("Smart test is currently running. Won't start a new one. Aborting...")
			totmbytes += devices[device]["sdata"]["size"]
		} else counttotsize()

		# Run the tests:
		for (device in devices) system(sktest " " device " " tt)
	} else counttotsize() # We're just monitoring smart tests.

	if (logformat != 1) {
		clear()
		# TODO: Be more descriptive?
		print "Please wait..."
	}

	while (1) { # Main loop which displays the progress.
		totprogress = 0
		for (device in devices) {
			P = devices[device]["progress"]
			if (P > 0) {
				left = testprogress(device)
				if (gap == 0) P = left
				else if (left <= P - gap || left == 0 && left < P) {
					P = left
					devices[device]["progress"] = left
					if (logformat) printf device ": %2d%%\n",100 - P
					else refresh = 1
				}
			}
			totprogress += ( 100 - P ) * devices[device]["sdata"]["size"] / totmbytes
		}
		if (refresh) {
			clear()
			for (device in devices) printf device ":\t%2d%%\n",100 - devices[device]["progress"]
			printf "\nTotal:\t\t%3d%%\n\n",totprogress
			refresh = 0
		}
		if (totprogress >= 100) break # We break before sleep so avoid unneccessary delay. Otherwise we'd add check of 'totprogress' into the 'while' main loop header.
		system("sleep " sleep "s") # I guess awk can't do any better...
	} # Main loop END

	if (report && tt != "monitor") { # We should allow summary printing when monitoring... TODO
		for (device in devices) {
			getsmartdata(device,"newdata")
			smartdatafile = smartdatadir removebad(devices[device]["newdata"]["model"] "-" devices[device]["newdata"]["serial"]) ".smart"
			print "Device: " device "\t" devices[device]["newdata"]["model"] "\t\t" devices[device]["newdata"]["size"] / 1024 "GB\tStatus: " devices[device]["newdata"]["status"] "\tBad sectors: " devices[device]["newdata"]["bad_sectors"] "\tage: " devices[device]["newdata"]["powered_on"]

			if (system("test -r " escapebad(smartdatafile)) == 0) {
				olddata = "old"
				getsmartdata(smartdatafile,olddata)
			}
			else olddata = "sdata" # No previous smart data found from filesystem. Let's use the data from the beginning of the test.

			# Data comparison:
			for (attribute in devices[device][olddata]) {
				oldattr = devices[device][olddata][attribute]
				if (attribute ~ /device|type|size|powered_on/) continue
				newattr = devices[device]["newdata"][attribute]
				if (newattr != oldattr) print "!!!: " attribute " for " device " changed! " oldattr " -> " newattr > "/dev/stderr"
			}

			# Copy smart data into filesystem if requested.
			if (savedata) {
				if (system("test -r " escapebad(smartdatafile)) == 0) system("rm " smartdatafile)
				system(skdump " --save=" escapebad(smartdatafile) " " escapebad(device))
			}
		}
		print "\nTotal bytes on disks: " totmbytes / 1024 "GiB."
	}
	exit 0
}

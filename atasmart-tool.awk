#!/usr/bin/gawk --exec

function warn(msg) {
	print "ERROR: " msg > "/dev/stderr"
}

function errexit(msg) {
	warn(msg)
	exit 0
}

function mktempfile() {
	"mktemp --tmpdir \"" this ".XXXXXX.tmp\"" | getline
	close("mktemp --tmpdir \"" this ".XXXXXX.tmp\"")
	return $0
}

function issmart(disk) {
	disk = gensub(/[^\/A-Za-z0-9]/, "\\\\&", "g", disk)
	if (system("test -r \"" disk "\"") == 0) {
		skdump " --can-smart \"" disk "\" 2> /dev/null" | getline answer
		close(skdump " --can-smart " disk)
		if (answer == "YES") return 1
		else {
			warn("Device '" disk "' isn't smart capable.")
			return 0
		}
	} else {
		warn("Cannot read '" disk "'. Do you have permissions?")
		return 0
	}
}

function createsmartdata(disk) {
	datafile = mktempfile()
	if (system("test -f \"" datafile "\"") == 0) {
		actions = "overall status bad"
		split(actions,aa)
		for (an in aa) {
			action = aa[an]
			printf "%s",action ": " >> datafile
			cmd = skdump " --" action " \"" disk "\" >> \"" datafile "\""
			if (system(cmd) > 0) warn("Command: " cmd "\n ... exit status > 0.")
		}
		return datafile
	}
	else warn("Failed to create smart data dump file: '" datafile "'")
}

function testprogress(disk) {
	pollcmd = skdump " " disk
	while ((pollcmd | getline) > 0) { # No need for 'dump' variable here... TODO.
		if (/^Percent Self-Test Remaining: /) {
			close(pollcmd)
			break
		}
	}
	lf = $NF
	sub(/%/,"",lf)
	return strtonum(lf)
}

function printprogress() {
	printf "\033c" # VT100 command to reset/clear terminal.
	for (disk in progress) print disk ":\t" 100 - progress[disk] "%"
	print "\nTotal:\t\t" 100 - totremain / numdevices "%"
}

BEGIN {

	version = "0.0.1-alpha"

	# Rather complex way to store script file name to 'this'.
	# Other methods I've found aren't realiable.
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
	sleep = 5
	gap = 5
	report = 0

	for (i = 1; i < ARGC; i++) {
		#print "DEBUG first loop: i = " i
		#print "DEBUG first loop: ARGV[i] = " ARGV[i]
		#print "DEBUG first loop: substr = " substr(ARGV[i],1,1)

		arg = ARGV[i]

		if ( substr(arg,1,1) != "-" ) break
		else if (arg == "--") {
			i++
			break
		} else if (arg == "--help") {
			print "atasmart-tool v. " version " -- Ilja Sara"
			print "Small wrapper around skdump and sktest, S.M.A.R.T. -tools.\n\n"
			print this " [--test <short|long|extended|monitor> [--gap <{1..100}>] [--sleep <n>] [--log] [--summary]] <device> [device2] .. [deviceN]"
			print "Without --test the action is 'monitor', unless no test is running then it's same as running 'skdump' without arguments on device(s)\n"
			print "--test <monitor|short|long|extended>\n\tRun a test or monitor a running test. 'long' and 'extended' are the same." 
			print "--gap <n>\n\tdetermines the interval at which to print the progress percentage status. Default: " gap "%. Set to 0 to disable printing progress indicator."
			print "--sleep <n>\n\tTime to sleep in seconds between pollings."
			print "--log\n\tChanges output to log friendly format."
			print "--summary\n\tPrint report at the end of test. Note: with '--test monitor' report printing is always disabled, since " this " can't know the smart values before the test(s) were started."
			exit 1
		} else if (arg == "--test") {
			i++
			tt = ARGV[i]
			if (tt !~ /short|long|monitor/) errexit("--test only accepts 'short', 'long', 'extended' or 'monitor 'as an argument.")
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
		else errexit("I don't know what to do with this '" arg "' -switch of yours. You may need --help. Aborting... :(")
	}

	if (ARGV[i] == "") errexit("No devices specified.")

	#print createsmartdata(ARGV[i])
	#exit

	if (logformat) diffcmd = "diff --color=never --text --suppress-common-lines"
	else diffcmd = "diff --color=always --text --suppress-common-lines"

	# Create an array of devices and set starting value for progress.
	j = 1
	while (i < ARGC) {
		#print "DEBUG second loop: ARGV[i] " ARGV[i]
		device = ARGV[i]
		if (issmart(device)) {
			devlist[j] = device
			#print devlist[j]
			progress[devlist[j]] = 110
			j++
		} else warn("Skipping '" device "'...")
		i++
	}
	if (j == 1) errexit("No single suitable device left. Exiting...")
	numdevices = j - 1

	if (tt == "") {
		for (i = 1; i < ARGC; i++) {
			print ""
			if (system(skdump " " ARGV[i]) > 0) e = 1
		}
		if (e) errexit("Some/all skdump prcesses exited with non-zero exit code")
		exit 1
	} else if (tt ~ /short|long|extended/) {
		if (tt == "long") tt = "extended"

		if (report) for (d in devlist) smart_data[devlist[d]] = createsmartdata(devlist[d])

		# Run the tests:
		for (d in devlist) system(sktest " " devlist[d] " " tt)
	}

	while (1) {
		totremain = 0
		for (d in devlist) {
			device = devlist[d]
			P = progress[device]
			if (P > 0) {
				left = testprogress(device)
				if (gap == 0) P = left
				else if (left <= P - gap) { 
					P = left
					progress[device] = left
					if (logformat && P <= 100) print device ": " 100 - P "%"
					else refresh = 1
				}
			}	
			totremain += P
		}
		if (refresh) {
			printprogress()
			refresh = 0
		}
		if (totremain <= 0) break
		system("sleep " sleep "s") # I guess awk can't do any better...
	}

	if (report && tt ~ /short|long|extended/) {
		for (d in devlist) {
			device = devlist[d]
			new_smart_data[device] = createsmartdata(device)
			skdump " --power-on " device | getline pwronmsec
			close(skdump " --power-on " device)
			print "\n --== Device " device " - age: " pwronmsec / 1000 / 60 / 60 / 24 " days ==--"
			print "smartdiff (if any):"
			system(diffcmd " \"" smart_data[device] "\" \"" new_smart_data[device] "\"")
			while (getline < new_smart_data[device] > 0) {
				if ($1 == "bad" && $2 > 0) {
					print "WARNING: bad sector count - " $2
					break
				}
			}
			close(new_smart_data[device])
			system("rm \"" smart_data[device] "\" \"" new_smart_data[device] "\"")
		}
	}
	exit 1
}

#!/usr/bin/gawk --exec

function warn(msg) {
	print "ERROR: " msg > "/dev/stderr"
}

function errexit(msg) {
	warn(msg)
	exit 0
}

function escapebad(string) {
	# For shell...
	gsub(/[^\.a-zA-Z0-9\/_-]/,"\\\\&",string)
	return string
}

function mktempfile() {
	"mktemp --tmpdir=\"" tmpdir "\" \"" this ".XXXXXX.tmp\"" | getline
	close("mktemp --tmpdir=\"" tmpdir "\" \"" this ".XXXXXX.tmp\"")
	return $0
}

function issmart(disk) {
	safedisk = escapebad(disk)
	if (system("test -r \"" safedisk "\"") == 0) {
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

# This is a bad function. Needs to go.
function exec2file(cmd,file) {
	#safefile = escapebad(file)
	if (system("test -w \"" file "\"") == 0) {
		if (system(cmd " >> " file) == 0) return file
		else {
			return 0
		}
	} else return 0
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
		devices[device]["size"] = mbytes
	}
}

function createsmartdata(disk,format) {
	datafile = mktempfile()
	if (format == "full") {
		cmd = skdump " \"" disk "\""
		if (exec2file(cmd,datafile) == 0) warn("Command: " cmd "\n ... exit status > 0.")
        } else {
        	attrlist = 0
        	while (skdump " " disk | getline) {
        		# This is certainly a hack to parse the output of skdump.
        		# What's worse, the output of skdump might change.
			# However, we're trying our best to avoid little changes.
			if ($1 == "ID#") {attrlist = 1; continue}
			if (attrlist) {
				if ($1 ~ /^(1|5|7|1[013]|18[12478]|19[6789]|201|250)$/) {
					name = $2
					for (i=1; i<=5; i++) $i = ""
					sub(/^\s+/,"")
					pretty = substr($0,0,match($0,/\s0x[0-9a-f]+/) - 1)
					#type = substr($0,RSTART + RLENGTH + 1,7)
				}

			} else {
				name = tolower(substr($0,1,match($0,/:/) - 1))
				gsub(/\s+/,"_",name)
				switch (name) {
					case "size":
						pretty = $2
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
						
				}
				if (pretty != "") devices[disk][name] = pretty
			}
			if (pretty != "") print name,pretty >> datafile
			name = ""
			pretty = ""
        	}
        	close(skdump " " disk)
        }
	return datafile
}

function testprogress(disk) {
	pollcmd = skdump " " disk
	while ((pollcmd | getline) > 0) {
		if (/^Percent Self-Test Remaining: /) {
			close(pollcmd)
			break
		}
	}
    close(pollcmd)
	lf = $NF
	sub(/%/,"",lf)
	return strtonum(lf)
}

function printprogress() {
	printf "\033c" # VT100 command to reset/clear terminal.
	for (device in devices) print device ":\t" 100 - devices[device]["progress"] "%"
	print "\nTotal:\t\t" totprogress / totmbytes * 100 "%"
}

BEGIN {

	#print exec2file("echo 'foo bar versus the dea'",mktempfile())
	#exit

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
			print this " [--test <short|long|extended|monitor> [--gap <1-99>] [--sleep <n>] [--log] [--summary]] <device> [device2] .. [deviceN]"
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
		else errexit("I don't know what to do with this '" arg "' -switch of yours. You may need --help. Aborting... :(")
	}

	if (ARGV[i] == "") errexit("No devices specified.")

	#print createsmartdata(ARGV[i])
	#exit

	if (logformat) diffcmd = "diff --color=never --text --suppress-common-lines"
	else diffcmd = "diff --color=always --text --suppress-common-lines"

	"mktemp -d --tmpdir \"" this ".XXXXXX.tmp\"" | getline tmpdir
        close("mktemp -d --tmpdir \"" this ".XXXXXX.tmp\"" )

	# Create an array of devices and set starting value for progress.
	j = 1
	while (i < ARGC) {
		device = ARGV[i]
		if (issmart(device)) {
			devices[device]["progress"] = 110
			j++
		} else warn("Skipping '" device "' since it does not seem have smart capabilities...")
		i++
	}
	if (j == 1) errexit("No single suitable device left. Exiting...")
	numdevices = j - 1

	if (tt == "") {
		# Only dump smart data and exit.
		for (i = 1; i < ARGC; i++) {
			print ""
			if (system(skdump " " ARGV[i]) > 0) e = 1
		}
		if (e) errexit("Some/all skdump processes exited with non-zero exit code")
		exit 1
	} else if (tt ~ /^(quick|short|long|extended)$/) {
		if (tt == "long") tt = "extended"
		else if (tt == "quick") tt = "short"
		if (report) for (device in devices) {
			devices[device]["datafile"] = createsmartdata(device)
			totmbytes += devices[device]["size"]
		} else counttotsize()

		# Run the tests:
		for (device in devices) system(sktest " " device " " tt)
	} else { # We're just monitoring
		counttotsize()
		#print totmbytes " MB"
		#exit
	}

	while (1) {
		totprogress = 0
		for (device in devices) {
			P = devices[device]["progress"]
			if (P > 0) {
				left = testprogress(device)
				if (gap == 0) P = left
				else if (left <= P - gap || left == 0 && left < P) { 
					P = left
					devices[device]["progress"] = left
					if (logformat) print device ": " 100 - P "%"
					else refresh = 1
				}
			}	
			totprogress += ( 100 - P ) * devices[device]["size"] / totmbytes
			#print totprogress "%"
		}
		if (refresh) {
			printf "\033c" # VT100 command to reset/clear terminal.
			for (device in devices) print device ":\t" 100 - devices[device]["progress"] "%"
			print "\nTotal:\t\t" totprogress "%"
			refresh = 0
		}
		if (totprogress >= 100) break
		system("sleep " sleep "s") # I guess awk can't do any better...
	}

	if (report && tt != "monitor") {
		for (device in devices) {
			devices[device]["newdatafile"] = createsmartdata(device)
			print "\nDevice: " device " " devices[device]["model"] " " devices[device]["size"] / 1024 "GB - Status:" devices[device]["status"] " - age: " devices[device]["powered_on"] " - Bad sectors: " devices[device]["bad_sectors"]
			print "smartdiff (if any):"
			system(diffcmd " \"" devices[device]["datafile"] "\" \"" devices[device]["newdatafile"] "\"")
		}
	}
	system("rm -r " tmpdir)
	exit 1
}

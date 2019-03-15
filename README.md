## atasmart-tool

### Before you go further...
* Install libatasmart.
* Assume _**alpha**_ quality.

### Quickstart
	chmod +x atasmart-tool.awk
	./atasmart-tool.awk --help
#### Note
The total percentage of process is calculated in such way that **bigger capacity disks have more weight to the total %** of the process. So that's why the numbers may seem incorrect.

### About
* [Why?](https://pluspora.com/posts/f61ba1c025c70137cf9f005056264835)
* ... also some shell laguage would have been better fit for the task, but I had an urge to code awk. Sorry.
* I have some hopes someone will implement something like this, but in C, Python or (ba)sh.

### TODO -list  
* Gather more information at the start and end of test(s) and warn user if something alarming is found. - Almost done.

### License
GPL-3

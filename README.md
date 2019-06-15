## atasmart-tool
#### Aka. ”Suddenly I had changed simple parser to a **code mess** and even the language chosen _isn't_ fit for the task.”


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
* ... also some shell language would have been better fit for the task, but I had an urge to code awk. Sorry.
* I have some hopes someone will implement something like this, but in C, Python or (ba)sh.

### TODO -list  
* Gather more information at the start and end of test(s) and warn user if something alarming is found. - Almost done.
* Report changes in smart data via internal function instead of using `diff` in a form of "Value X has changed from Y to Z".

### License
GPL-3

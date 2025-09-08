//Modify this file to change what commands output to your statusbar, and recompile using the make command.
static const Block blocks[] = {
	/*Icon*/	/*Command*/		/*Update Interval*/	/*Update Signal*/
	{"", "~/.config/wm/scripts/netspeed",     1,         0},
	{"", "~/.config/wm/scripts/memory",      10,         0},
	{"", "date +'%Y-%m-%d %H:%M:%S'",         1,         0},
	{"", "~/.config/wm/scripts/battery",     10,         0},
	{"", "~/.config/wm/scripts/volume",  999999,        10},
};

//sets delimiter between status commands. NULL character ('\0') means no delimiter.
static char delim[] = " | ";
static unsigned int delimLen = 5;

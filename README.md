# bake: `make` in bash
**NOTE: work in progress**

`bake` is a simple bash setup that lets you write makefile-style automation in
bash. Like GNU make, it does dependency analysis and topsorting, and it
supports parallel job execution. Unlike GNU make, bake can be used as a library
from other scripts. The `bake` wrapper script just loads this library into bash
and runs the `bakefile` in the current directory.

## Simple example
Here's a fairly simple bakefile for a C project:

```sh
#!/usr/bin/env bake
# Rules for compiling C files
bake %name-debug.o : include/*.h :: gcc -DDEBUG $OPTS %name.c -o %name.o
bake %name.o       : include/*.h :: gcc $OPTS %name.c -o %name.o

# Rules to build executables
bake %modules.c = *.c           # destructuring bind
bake %bin-debug :: ld -lc %modules-debug.o -o %bin-debug
bake %bin       :: ld -lc %modules.o -o %bin

# High-level tasks
bake all : foo-debug foo        # virtual: no command
bake : all                      # specify that 'all' is the default
```

And here are some things you can do with it:

```
$ bake -l               # list rules
%name-debug.o : %name.c include/bar.h include/foo.h
%name.o : %name.c include/bar.h include/foo.h
%bin-debug : bar-debug.o bif-debug.o foo-debug.o
%bin : bar.o bif.o foo.o
all : foo-debug foo
$ bake foo              # outputs nothing, but makes foo
$ bake -v all           # this is how you get a trace
bake: bar-debug.o : bar.c include/bar.h include/foo.h
bake: bif-debug.o : bif.c include/bar.h include/foo.h
bake: foo-debug.o : foo.c include/bar.h include/foo.h
bake: foo-debug : bar-debug.o bif-debug.o foo-debug.o
$ bake --clean all
bake: would remove foo-debug foo bar-debug.o bif-debug.o foo-debug.o bar.o
bif.o foo.o
bake: (use bake --clean -f ... to actually do this)
$ bake --clean -f :all
```

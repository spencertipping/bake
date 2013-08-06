# bake: `make` in bash
**NOTE: work in progress**

`bake` is a simple bash setup that lets you write makefile-style automation in
bash. Like GNU make, it does dependency analysis and topsorting, and it
supports parallel job execution. Unlike GNU make, bake can be used as a library
from other scripts. The `bake` wrapper script just loads this library into bash
and runs the `bakefile` in the current directory.

## Features
- Correctness (uses sha-256 to track contents, though you can change this)
- Parallel job execution
- Remote job execution (requires passwordless SSH and sshfs)
- Seamless bash interoperability
- You can use bake as a library from an existing script
- Dependency graphs are first-class (so you can ask bake how it would build
  something, then use that output from your script)
- A build rule can have multiple declared outputs
- Multiple independent dependency graphs in one bash environment
- No dependencies apart from bash version 3 or later (and `sha256sum` if you
  want tracked file contents)
- Single-file installation: `cp /path/to/bake ~/bin/` (or somewhere else in
  your $PATH)
- Really simple syntax
- Mathematically consistent semantics

## Non-features
- No integration with autoconf, automake, etc
- Less portable than GNU make (but it should work everywhere you're likely to
  need it)
- Written in bash

## Example
Here's a bakefile you might use for a C project:

```sh
#!/usr/bin/env bake
# Rules for compiling C files
create_gcc_rule() {
  local suffix=$1
  shift                 # other args go to gcc below
  bake %name$suffix.o : %name.c include/*.h \
    :: gcc "$@" %name.c -o %name$suffix.o
}

create_gcc_rule
create_gcc_rule -debug -DDEBUG -g
create_gcc_rule -opt   -O3

# Rules to build executables
bake %modules.c = *.c           # destructuring bind
bake %bin-debug :: ld -lc %modules-debug.o -o %bin-debug
bake %bin       :: ld -lc %modules.o       -o %bin

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

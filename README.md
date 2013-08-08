# bake: `make` in bash
**NOTE: work in progress**

`bake` is a simple bash setup that lets you write makefile-style automation in
bash. Like GNU make, it does dependency analysis and topsorting, and it
supports parallel job execution. Unlike GNU make, bake can be used as a library
from other scripts. The `bake` wrapper script just loads this library into bash
and runs the `bakefile` in the current directory.

## Features
- Correctness (uses sha-256 to track contents, though you can change this)
- Generality (track any kind of contents, not just files)
- Parallel job execution
- Remote job execution (requires passwordless SSH)
- Seamless integration with bash
- You can type build rules at the command line
- Dependency graphs are first-class (so you can ask bake how it would build
  something, then use that output from your script)
- A build rule can have multiple declared outputs
- Multiple independent dependency graphs in one bash environment
- No dependencies apart from bash version 3 or later (and `sha256sum` if you
  want tracked file contents)
- Single-file installation: `cp /path/to/bake ~/bin/` (or somewhere else in
  your $PATH)
- Mathematically consistent semantics

## Non-features
- No integration with autoconf, automake, etc
- Less portable than GNU make (but it should work everywhere you're likely to
  need it)
- Written in bash

## bashrc usage
This is the simplest way to use bake. Source `bake.sh` from your bashrc, then
create a bake instance (a namespace for rules and globals):

```sh
# ... bashrc stuff ...

source ~/path/to/bake.sh
bake-instance bk
```

Then in your shell:

```sh
$ bk %x.o : %x.c :: gcc -c %in -o %out
$ bk foo.o              # compiles if necessary
$
```

## A simple bakefile
```sh
#!/bin/bash
bake %bin : %bin.c :: gcc -o %out %in
```

You could then run `bake foo` to compile `foo.c` into `foo`.

## A more complex bakefile
You can do everything bash normally lets you do within the context of a
bakefile:

```sh
#!/bin/bash
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
bake %@modules.c = *.c                  # destructuring bind

libs="-lc"
ld_command="ld $libs %in -o %out"       # %in = all inputs, %out = all outputs
bake %bin-opt   : %@modules-opt.o   :: $ld_command
bake %bin-debug : %@modules-debug.o :: $ld_command
bake %bin       : %@modules.o       :: $ld_command

# Default build target
bake : foo{,-debug,-opt}
```

And here are some things you can do with it:

```
$ bake -l               # list rules
%name-debug.o : %name.c include/bar.h include/foo.h
%name-opt.o : %name.c include/bar.h include/foo.h
%name.o : %name.c include/bar.h include/foo.h
%bin-debug : bar-debug.o bif-debug.o foo-debug.o
%bin-opt : bar-opt.o bif-opt.o foo-opt.o
%bin : bar.o bif.o foo.o
: foo-opt foo-debug foo
$ bake foo foo-opt      # outputs nothing, but makes foo and foo-opt
$ bake -v               # this is how you get a trace
bake: bar-debug.o : bar.c include/bar.h include/foo.h
bake: bif-debug.o : bif.c include/bar.h include/foo.h
bake: foo-debug.o : foo.c include/bar.h include/foo.h
bake: foo-debug : bar-debug.o bif-debug.o foo-debug.o
$ bake --clean
bake: would remove foo-opt foo-debug foo bar-debug.o bif-debug.o foo-debug.o
bar.o bif.o foo.o bar-opt.o bif-opt.o foo-opt.o
bake: (use bake --clean -f to actually do this)
$ bake --clean -f       # also outputs nothing
$
```

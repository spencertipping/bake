# Graph searching
Bake has two graph searching modes, grounded and ungrounded. Grounded rules
(`bake %x.o : %x.c`, for example) are executed only once bake can prove that
all required dependencies exist. In other words, their dependencies are a
precondition of the execution step.

Ungrounded rules are also called global variables, and they are executed
eagerly. For example, you could write this:

```sh
# grounded rule; this won't run unless %x.c exists
bake %x.o : %x.c :: gcc -c %< -o %@

# ungrounded rule; this could easily run if %x.c and %x.h don't exist
bake deps_for_%x.o = %x.c %x.h \
  :: echo "just calculated deps for %x.o"

bake --echo deps_for_foo.o              # -> just calculated deps for foo.o
                                        #    foo.c foo.h
```

The mnemonic is that `:` is read as "given" or "provided"; you're stating a
precondition. `=`, on the other hand, is read as "means" or "is equivalent to".
The validity of rewriting `=` is invariant with the availability of the terms
on the right-hand side. Note that both `:` and `=` support side-effects, but
side-effects behave differently between the two.

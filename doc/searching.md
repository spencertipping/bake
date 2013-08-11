# Graph searching
Bake has two graph searching modes, grounded and ungrounded. Grounded rules
(`bake %x.o : %x.c`, for example) are executed only once bake can prove that
all required dependencies exist. In other words, their dependencies are a
precondition of the execution step.

Ungrounded rules are also called global variables, and they are executed
eagerly. For example, you could write this:

```sh
# grounded rule; this won't run unless %x.c exists or can be generated
bake %x.o : %x.c :: gcc -c %in -o %out

# ungrounded rule; this will run even if %x.c and %x.h don't exist
bake deps_for_%x.o = %x.c %x.h \
  :: echo "just calculated deps for %x.o"

bake --echo deps_for_foo.o              # -> just calculated deps for foo.o
                                        #    foo.c foo.h
```

The mnemonic is that `:` is read as "given" or "provided"; you're stating a
precondition. `=`, on the other hand, is read as "means" or "is equivalent to".
The validity of rewriting a `=` form is invariant with the availability of the
terms on the right-hand side. Note that both `:` and `=` support side-effects,
but side-effects behave differently between the two.

## Prematch transitivity
Suppose we have a bakefile like this:

```sh
bake %x.a : %x.b :: make-a
bake %x.b : %x.c :: make-b
```

Bake can preground any .a goal through the corresponding .c goal by observing
the fact that the text "%x.b" matches the pattern %x.b. Therefore, %x.b is
likely to be an intermediate file.

Prematch transitivity tests can detect some cases, but they'll miss more
complicated things like multiple-output rules:

```sh
bake     %x.a : %x.b :: make-a
bake foo %x.b : %x.c :: make-b          # the 'foo' here defeats prematching
```

Prematching is important because it's the first thing bake does to identify
possible grounding paths. Even when it fails to detect some obvious cases, it
significantly optimizes the search space.

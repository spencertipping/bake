# Bake variables
Bake implements its own variable system using the `%name` syntax, operating
independently of bash variables you might have in a script. The goal here is to
separate variance-spaces; bash variables, in particular, are viewed as
constants, which lets you build the dependency graph procedurally:

```sh
for ext in $extensions; do
  bake %name.$ext :: generate $ext %name
done
```

## Plurality and destructuring
Bake variables are transparently plural and have semiring (without
multiplicative identity) properties. For example:

```sh
bake %@xs = foo bar bif
bake --echo %@xs.c                      # foo.c bar.c bif.c
bake %@ys.c %o@thers = foo.c bar.c bif.o
bake --echo %@ys %@others               # foo bar bif.o
bake %@js.js %@css.css = foo.css bar.js
bake --echo %@js %@css                  # bar foo
```

Specifically, variables are commutatively additive under word concatenation and
noncommutatively multiplicative under string concatenation. This lets you split
any list of words by factoring:

```sh
bake a%@a b%@b = a1 b1 a2 b2 a3 a4 a5
bake --echo %@a %@b                     # 1 2 3 4 1 2
bake --echo %@a-a %@b-b                 # 1-a 2-a 3-a 4-a 1-b 2-b
```

Words commute because dependencies do. That is, the following two shell
commands mean the same thing:

```sh
$ bake foo bar
$ bake bar foo
```

Note that while values themselves are commutative, destructuring bind patterns
are not:

```sh
bake %@xs.c %@others = foo.c bar bif.c
bake --echo %@xs . %@others             # foo bif . bar
bake %@xs %@others.c = foo.c bar bif.c
bake --echo %@xs . %@others             # foo.c bar bif.c .
```

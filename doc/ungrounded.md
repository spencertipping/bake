# Ungrounded rules
Bake has two kinds of rules, grounded and ungrounded. Grounded rules are paths
within a space of required resources: requesting the output of a grounded rule
involves resolving the dependency graph fully before running commands to
generate the output.

Ungrounded rules, on the other hand, are speculative and behave much more like
functions. Bake sees ungrounded rules as statements of equivalence. For
example:

```sh
bake foo = bar
bake bif : foo :: echo %in %out
bake foo : bok :: echo %in %out
```

The two grounded rules here will be interpreted as this:

```sh
bake bif : bar :: echo %in %out
bake bar : bok :: echo %in %out
```

So grounded rules define the build space, and ungrounded rules create
homomorphisms within that space.

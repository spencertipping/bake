# Evaluation
A few things that deserve some attention:

1. When globals are expanded with respect to other expressions
2. How dependencies are handled

## Globals
Globals are expanded immediately after parsing a rule. This means that you can
use a global to bind a variable indirectly:

```sh
$ bake %x = %y
$ bake %x = 5
$ bake --echo %y
5
$
```

However, globals aren't syntactic. You can't do this, for example:

```sh
$ bake %x = %y = 5
$ bake %x                       # does not set %y = 5
$ bake --echo %y
%y
$
```

## Dependencies
Bake tries to eliminate recursive cases as much as is practical. The reason is
that most sufficiently complicated rule sets will end up being infinite, and
odds are good that the user isn't trying to write a nonterminating build
script. This bias manifests itself as a few limitations:

1. Bake will use each grounded rule at most once (however, ungrounded rules may
   be iterated any number of times)
2. Globals are pre-expanded within both grounded and ungrounded rules.
3. (todo: document this more)

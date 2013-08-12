#!/bin/bash
# Bake function definition | Spencer Tipping
# Licensed under the terms of the MIT source code license

# Introduction.
# Bake provides a single entry point, the `bake-instance` function. The global
# `bake-instance` function is a way to create bake instances, each of which is a
# function that operates on a dependency graph. Instances are isolated from each
# other. Because of this design, bake ends up compiling a new function each time
# you create an instance. Bash doesn't officially support closures, but we can
# come close by using eval to compile references to global names.

# An instance called "bake" is available to bakefiles. See
# [bake-template](./bake-template) for details about how this works.

# Bash function recompilation.
# Bash has a horrible non-feature: any locals within a function are also local to
# functions you call, and they are mutable within those functions. This means
# local variables need to be script-unique in order to work properly (and even
# then they'll fail if you use recursion).

# Rather than manually prefix each local with a unique string, we can write a
# bash function to find all local definitions and fix them up. Then we just write
# functions normally and hand them off to a recompiler.

__bake_setup_globals() {
  __bake_var_pattern="%(@?[A-Za-z0-9_]+)"
  __bake_return=()
}

__bake_recompile() {
  # Takes a function name and recompiles it in place.
  local fn_name=$1
  local fn_source="$(declare -f $fn_name)"

  # Give every local variable a unique prefix.
  local local_source="$fn_source"
  local local_pattern="\blocal +(-[a-zA-Z]+ +)*([A-Za-z0-9_]+)"
  local -a locals=()
  while [[ "$local_source" =~ $local_pattern(.*) ]]; do
    locals+=( "${BASH_REMATCH[2]}" )
    local_source=${BASH_REMATCH[3]}
  done

  if (( ${#locals[@]} )); then
    local prefix=$(mktemp -u l_XXXX_)
    local oifs=$IFS; IFS='|'
    local find_pattern="${locals[*]}"
    IFS=$oifs

    eval "$(sed -r "s/\\b($find_pattern)\\b/$prefix\\1/g" <<<"$fn_source")"
  fi
}

# Variable handling logic.
# Code to bind and expand expressions with variables. This is optimized in some
# small ways by doing things like using bash wildcard matching as a preliminary
# check. This code can be global because it doesn't rely on any instance state.

# The first function we need is one that attempts to match a variable-laden
# template against some text. This function prints two space-separated values per
# matched variable: var-name and match-text. match-text may be empty, but if
# present it is safe to parse it into an array variable.

# Here are some match cases:

# | bake %@xs.c %@ys = foo.c bar.c bif    # %@xs = foo bar, %@ys = bif
#   bake %x.c %@xs.c = foo.c bar.c bif.c  # %x = foo, %@xs = bar bif

# Another set of cases involves cross-multiplication:

# | bake %@x.%@y = foo.c bar.h            # no match
#   bake %@x.%y = foo.c bar.c             # %@x = foo bar, %@y = c
#   bake %@x.%@y = foo.c bar.c            # %@x = foo bar, %@y = c
#   bake %x.%@y = foo.c foo.h             # %@x = foo, %@y = c h
#   bake %@x.%@y = foo.c foo.h            # %@x = foo, %@y = c h
#   bake %x.%@y %z = foo.c bar.h          # %x = foo, %@y = c, %z = bar.h

# Bake does not collapse cross-multiplied values with the distributive property.
# Specifically, when matching multiple variables it will assume that at most one
# is plural:

# | bake %@x.%@y = a.c a.d b.c b.d        # no match

# You can't reuse variables within a binding pattern, even if they are factored
# differently:

# | bake %x %x = a a                      # error: bad pattern
#   bake %x.%y %x = a.c a                 # error: bad pattern

# The first thing we need to do is be able to "factor" text. For example,
# factoring the string "foo bar.c bif.c" by the pattern "%.c" should give us two
# values, "bar.c bif.c" and "foo". `__bake_factor` does this, returning the two
# strings in __bake_return.

__bake_factor() {
  local factor=$1
  local -a text=( $2 )

  local factor_pattern=${factor//%/*}
  local -a matching=()
  local -a remainder=()
  local w
  for w in "${text[@]}"; do
    if [[ $w == $factor_pattern ]]; then
      matching+=( "$w" )
    else
      remainder+=( "$w" )
    fi
  done
  __bake_return=( "${matching[*]}" "${remainder[@]}" )
}

__bake_factor_profile() {
  local v=$1

  # Replace all named variables with anonymous % characters.
  while [[ $v =~ ^(.*)$__bake_var_pattern(.*)$ ]]; do
    v="${BASH_REMATCH[1]}%${BASH_REMATCH[3]}"
  done
  __bake_return=( "$v" )
}

__bake_check_pattern() {
  local v=$1
  local -a unique_variables=()

  while [[ $v =~ ^[^%]*$__bake_var_pattern(.*)$ ]]; do
    unique_variables+=( "${BASH_REMATCH[1]}" )
    v=${BASH_REMATCH[2]}
  done

  # Check for duplicate references to any variable.
  local i
  for i in ${!unique_variables[@]}; do
    local this_var=${unique_variables[i]}
    local j
    for (( j = i + 1;
           j < ${#unique_variables[@]}; ++j )); do
      [[ $this_var == ${unique_variables[j]} ]] && return 1
    done
  done
}

__bake_match() {
  local -a vars=( $1 )
  local -a text=( $2 )
  local -a result=()

  local -a profiles=()
  local v

  for v in "${vars[@]}"; do
    __bake_factor_profile "$v"
    profiles+=( "$__bake_return" )
  done

  __bake_check_pattern "${vars[*]}" || return 2

  local i
  for i in ${!vars[@]}; do
    local v=${vars[i]}
    local v_factor_profile=${profiles[i]}

    # Check for shadowing by a future term with the same profile. If we have
    # this, then this term will bind at most one term from the text.
    local profile_is_shadowed=
    local j
    for (( j = i + 1; j < ${#vars[@]}; ++j )); do
      if [[ ${profiles[j]} == ${v_factor_profile[i]} ]]; then
        profile_is_shadowed=1
        break
      fi
    done

    __bake_factor "$v_factor_profile" "${text[*]}"
    local -a matching=( ${__bake_return[0]} )
    local -a remainder=( ${__bake_return[1]} )

    # Construct a regexp match pattern based on the variable template. We then
    # bind up matching instances into the bindings[] array, which is
    # interleaved by the number of variables.
    local -a variable_names=()
    local -a bindings=()
    local plural_index=-1
    local match_pattern=${v%%%*}
    while [[ $v =~ $__bake_var_pattern([^%]*)(.*)$ ]]; do
      variable_names+=( "${BASH_REMATCH[1]}" )
      match_pattern="$match_pattern(.*)\"${BASH_REMATCH[2]}\""
      v=${BASH_REMATCH[3]}
    done

    # An empty match pattern means that the user typed something like 'bake % =
    # foo'.
    [[ -n $match_pattern ]] || return 3

    local namecount=${#variable_names[@]}

    local m
    for m in "${matching[@]}"; do
      # This should always match; but if it doesn't, we need to signal an error
      # indicating that something is way wrong.
      eval [[ \"$m\" =~ $match_pattern ]] || return 4

      for (( j = 0; j < namecount; ++j )); do
        local binding_value=${BASH_REMATCH[j + 1]}

        if (( plural_index != j && ${#bindings[@]} >= namecount )); then
          # Check to see whether we're introducing plurality. That is, binding
          # the variable to a value distinct from its earlier bindings. If we
          # are and we already have a plural index, then the match fails.
          #
          # We can optimize this a bit. We know that at most one variable can
          # be plural, so we can check just the first value. All others will be
          # identical to it.
          #
          # Note that we need to be dealing with a plural variable (i.e. one
          # that starts with @) in order to consider plurality a viable option.

          if [[ ${bindings[j]} != $binding_value ]]; then
            if [[ ${variable_names[j]:0:1} == @ && $plural_index == -1 ]]; then
              plural_index=$j
            else
              # We can't bind this term. At this point, we push it onto the
              # remainder and continue matching other terms. Before we can do
              # this, though, we need to undo any bindings we've made so far.
              local k
              for (( k = 0; k < j - 1; ++k )); do
                unset bindings[$(( ${#bindings[@]} - 1 ))]
              done
              remainder+=( "$m" )
              break
            fi
          fi
        fi

        bindings+=( "$binding_value" )
      done

      # profile_is_shadowed is a loop invariant, so this will happen on the
      # first iteration. This means no interference from the
      # matching[]-mangling code in the if-statement above.
      if [[ -n $profile_is_shadowed ]]; then
        remainder=( "${matching[@]:1}" "${remainder[@]}" )
        break
      fi
    done

    text=( "${remainder[@]}" )

    for (( j = 0; j < namecount; ++j )); do
      local binding_string="${variable_names[j]}"

      if (( j == plural_index )); then
        for (( k = j; k < ${#bindings[@]}; k += namecount )); do
          binding_string="$binding_string ${bindings[k]}"
        done
      else
        binding_string="$binding_string ${bindings[j]}"
      fi

      result+=( "$binding_string" )
    done
  done

  __bake_return=( "${result[@]}" )

  # We shouldn't have any text left. If we do, then return 1; the match didn't
  # consume all of the text.
  [[ -z $text ]]
}

# String expansion.
# The opposite of variable binding. This logic is much simpler, too; there aren't
# many special cases involved.

__bake_expand() {
  local oifs=$IFS; IFS=$'\n'
  local -a bindings=( $1 )
  IFS=$oifs

  local -a text=( $2 )

  local -a names=()
  local -a values=()

  local b
  for b in "${bindings[@]}"; do
    local -a var_and_values=( $b )
    names+=( "${var_and_values[0]}" )
    values+=( "${var_and_values[*]:1}" )
  done

  local -a result=()
  local word
  for word in "${text[@]}"; do
    local -a expansion=( "" )

    # Parse out until we hit a variable.
    while [[ -n $word && $word =~ ^([^%]*)($__bake_var_pattern)?(.*)$ ]]; do
      # Append any static text to each entry.
      local i
      for i in ${!expansion[@]}; do
        expansion[$i]="${expansion[i]}${BASH_REMATCH[1]}"
      done

      # If we have a variable, look up its value and multiply by the current
      # expansion. If we can't find the variable, append its name literally.
      if [[ -n ${BASH_REMATCH[2]} ]]; then
        local var_name=${BASH_REMATCH[2]:1}
        local found_var=
        for i in ${!names[@]}; do
          if [[ ${names[i]} == $var_name ]]; then
            # Expand and multiply.
            local -a value=( ${values[i]} )
            local -a new_expansion=()

            local v
            for v in "${value[@]}"; do
              local e
              for e in "${expansion[@]}"; do
                new_expansion+=( "$e$v" )
              done
            done

            expansion=( "${new_expansion[@]}" )
            found_var=1
            break
          fi
        done

        if [[ -z $found_var ]]; then
          local i
          for i in "${!expansion[@]}"; do
            expansion[$i]="${expansion[i]}%$var_name"
          done
        fi
      fi

      word=${BASH_REMATCH[4]}
    done

    result=( "${result[@]}" "${expansion[@]}" )
  done

  __bake_return=( "${result[@]}" )
}

# Instance bookkeeping function templates.
# These are later rewritten to create an instance (hence the __bakeinst
# placeholders).

__bakeinst_print_rules() {
  local i
  for i in ${!__bakeinst_g_out[@]}; do
    echo ${__bakeinst_g_out[i]} : \
         ${__bakeinst_g_in[i]} :: \
         ${__bakeinst_g_command[i]}
  done

  for i in ${!__bakeinst_u_out[@]}; do
    echo ${__bakeinst_u_out[i]} = \
         ${__bakeinst_u_in[i]} :: \
         ${__bakeinst_u_command[i]}
  done
}

__bakeinst_print_globals() {
  local g
  for g in "${__bakeinst_globals[@]}"; do
    local -a split=( $g )
    echo "%${split[0]} = ${split[@]:1}"
  done
}

# Definition code templates.
# Functions to define rules and globals. This requires some argument parsing to
# happen ahead of time; that is, these functions expect their arguments to be
# positional and properly quoted.

__bakeinst_defgrounded() {
  local outvars=$1
  local invars=$2
  local cmd=$3
  __bakeinst_g_out+=( "$outvars" )
  __bakeinst_g_in+=( "$invars" )
  __bakeinst_g_commands+=( "$cmd" )
}

__bakeinst_defungrounded() {
  local outvars=$1
  local invars=$2
  local cmd=$3
  __bakeinst_u_out+=( "$outvars" )
  __bakeinst_u_in+=( "$invars" )
  __bakeinst_u_commands+=( "$cmd" )
}

__bakeinst_defglobal() {
  local name=$1
  local value=$2

  # IFS needs to be its usual value when we call __bake_match
  __bake_match "$name" "$value"
  case $? in
    1) echo "bake: $name failed to match $value"
       return 1 ;;
    2) echo "bake: $name is not a valid pattern (repeated variable)"
       return 1 ;;
    3) echo "bake: $name is not a valid pattern (anonymous variable)"
       return 1 ;;
    4) echo "bake: $name = $value failed; this is a bug in bake"
       echo "bake: please file an issue: github.com/spencertipping/bake"
       return 1 ;;
  esac

  local oifs=$IFS; IFS=$'\n'
  local -a bindings=( "${__bake_return[@]}" )
  IFS=$oifs

  local b
  for b in "${bindings[@]}"; do
    local varname=${b%% *}
    local i
    local index=${#__bakeinst_globals[@]}
    for i in ${!__bakeinst_globals[@]}; do
      local gname=${__bakeinst_globals[i]}
      if [[ ${gname%% *} == $varname ]]; then
        index=$i
        break
      fi
    done
    __bakeinst_globals[$index]=$b
  done
}

# Dependency solver.
# This is not easy. The reason is that we could easily have matching rules that
# don't go anywhere useful. For example, consider a bakefile like this:

# | bake %bin : %bin.o :: ld -lc -o %out %in
#   bake %bin.o : %bin.c :: gcc -c -o %out %in

# Everything matches the first rule. Bake needs to realize that to build "foo",
# we need to use the first rule to expand "foo" into "foo.o", then use the second
# rule to expand "foo.o" into "foo.c".

# As it turns out, this is the only possible way to get from `foo` to `foo.c`.
# Bake won't apply a rule to its own inputs.

# There are some subtleties as usual. For example, build rules can produce
# multiple outputs. We deal with this by unifying the outvars of each build rule
# against the entire goal set, and adding a catch-all to get the rest. One
# consequence of this strategy is that the goals must be a superset of the files
# that are generated; bake won't use multi-output rules that generate more than
# you ask for.

__bakeinst_solve() {
  local -a terminal_rules=()
  local -a nonterminal_rules=()
  local -a everything_rules=()
  local -a rule_is_unary=()

  for i in ${!__bakeinst_u_out[@]}; do
    local outvars="${__bakeinst_u_out[i]}"
    __bake_factor_profile "$outvars"
    local profile="${__bake_return[*]}"

    # Figure out whether the rule produces a single output. If so, we can use a
    # much faster (linear speedup) matching algorithm.
    local unary=
    [[ ${outvars//%@/} == $outvars && ${profile/ /} == $profile ]] && unary=1
    rule_is_unary+=( "$unary" )

    # Look at the factor profile to detect everything-rules.
    if [[ -z ${profile//[ %]/} ]]; then
      everything_rules+=( "$i" )
    else
      # Terminal rules are easier: they have no inputs.
      if [[ -z ${__bakeinst_u_in[i]} ]]; then
        terminal_rules+=( "$i" )
      else
        nonterminal_rules+=( "$i" )
      fi
    fi
  done

  # Figure out what the user is asking for by running the stated goals through
  # the evaluator.
  __bakeinst_expand "$*"
  local -a goals=( "${__bakeinst_return[*]}" )
  local goal_size_limit=$(( 64 + ${#goals[@]} ** 3 ))

# Search algorithm.
# The backend isn't invoked during the graph search. Instead, bake uses the
# backend to identify opportunities to reuse steps scheduled in the solution.
# This means we can build out the solution without any backend interaction at
# all (and, in fact, we need to due to the way bake works).

# We're starting with the outputs and want to find a grounding path for each one.
# The very first thing to do, at every iteration, is to eliminate any goals
# matched by terminal rules. Doing this allows us to commit the intermediate
# solutions for those goals, which is ultimately how we end up solving the
# system. (And if a goal is terminal, then we want to prefer that solution to any
# re-expansion.)

# As we work down the tree, we build out a disjunctive list of requirements. This
# list stores the concrete dependencies for each given goal; if all of the
# dependencies are met, then the goal is grounded. For example, consider this
# bakefile:

# | bake %@modules = foo bar bif
#   bake %bin      = my-program-name
#   bake --terminal %x.sdoc
#   bake : %bin
#   bake %bin        : %@modules.o    :: ld -lc -o %out %in
#   bake %x.o        : %x.c           :: gcc -c %in -o %out
#   bake %x.o        : %x.lisp %x.li  :: compile-lisp %x.lisp -l %x.li -o %out
#   bake %x.%ext     : %x.%ext.sdoc   :: 'sdoc cat code.%ext::%in > %out'
#   bake {foo,bar}.c : foo-bar.c.sdoc :: sdoc --split %in

# And these files:

# | $ ls
#   bar.lisp.sdoc  bar.li.sdoc  foo-and-bar.c.sdoc
#   $

# Here's the solution bake needs to come up with:

# | bar.lisp.sdoc -> bar.lisp -> bar.o
#   bar.li.sdoc   -> bar.li --/        \
#                                       \
#                   /-> bif.c -> bif.o --+-- my-program-name
#  foo-bar.c.sdoc -+--> foo.c -> foo.o -/

# Notice that there are two kinds of merge points: those where one input splits
# to multiple outputs, and those where multiple inputs converge to a single
# output. It's also possible to have a many-to-many rule like this:

# | bake foo.o bar.o : foo.c bar.c :: ...

# However it's possible to reduce many-to-many rules to a simpler form:

# | bake foo.o bar.o : <gensym> :: ...
#   bake <gensym> : foo.c bar.c

# So many-to-many rules don't create any new conceptual challenges.

# Ok, so given all of this, here's how bake solves it. First, we make a list of
# goals, which in this case is the default of %bin (= my-program-name). This list
# grows, but we keep track of which ones were originally specified so we can fail
# if we can't ground all of them.

# We kick off the solution process by matching our goal list against the output
# variables of each rule. If we find a match, we expand the corresponding input
# variables, adding each as a new entry in the goals[] array. We then record the
# index of the rule and the indexes of each new goals[] entry. This becomes one
# way to build the goal, so we store it into the disjunctions array and add the
# new index to the goal-resolution array. By example:

# Initially we have nothing except for an unmet goal:

# | ungrounded=(1) expansion_indexes=(-1) goals=(my-program-name)
#   goal_resolution=() disjunctions=()

# Then we run my-program-name through the first rule to get object file
# dependencies:

# | ungrounded=(1 1 1 1)
#   expansion_indexes=(0 -1 -1 -1)
#   goals=(my-program-name foo.o bar.o bif.o)
#   disjunctions=("1 2 3")
#   goal_resolution=("0 0")
#   reverse_index=("" "0" "0" "0")

# Expand every goal again under its next possible expansion (using
# `expansion_indexes` to store the continuations of the breadth-first search):

# | ungrounded=(1 1 1 1 1 1 1)
#   expansion_indexes=(5 0 0 0 -1 -1 -1)
#   goals=(my-program-name foo.o bar.o bif.o foo.c bar.c bif.c)
#   disjunctions=("1 2 3" "4" "5" "6")
#   goal_resolution=("0 0" "1 1" "1 2" "1 3")
#   reverse_index=("" "0" "0" "0" "1" "2" "3")

# The next expansion is where we start to see interesting stuff happen. The
# continuations for the object files produce disjunctions:

# | ungrounded=(1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1)
#   expansion_indexes=(5 1 1 1 3 3 3 -1 -1 -1 -1 -1 -1 -1 -1 -1)
#   goals=(my-program-name foo.o bar.o bif.o foo.c bar.c bif.c    # 0..6
#          foo.lisp foo.li bar.lisp bar.li bif.lisp bif.li        # 7..12
#          foo.c.sdoc bar.c.sdoc bif.c.sdoc)                      # 13..15
#   disjunctions=("1 2 3" "4" "5" "6" "7 8" "9 10" "11 12"        # 0..6
#                 "13" "14" "15")                                 # 7..9
#   goal_resolution=("0 0" "1 1 4" "1 2 5" "1 3 6" "3 7" "3 8" "3 9")
#   reverse_index=("" "0" "0" "0" "1" "2" "3" "1" "1" "2" "2" "3" "3"
#                     "4" "5" "6")

# And so forth. Bake will be able to ground out rules when a goal is terminal and
# when the backend says it is valid to do so. (This, by the way, is why it's so
# important to have terminal rules; otherwise the search is infinite by
# definition.)

# A few things to note about this setup. First, bake has to re-scan the list of
# goals each time a new one is added. If we're adding a goal we're already in the
# process of solving, we just refer back to the existing one.

# Another optimization, though less crucial than goal unification, is that we
# keep a reverse index from dependencies to anyone who refers to them. This is
# analogous to maintaining parent-links in a breadth-first search tree. The idea
# is that we propagate grounding upwards rather than rescanning every goal at
# every iteration. This reduces the time spent solving very broad search spaces
# and reduces worst-case complexity by a linear factor (I think, anyway).

# Note that the user may ask for two things that depend on each other. For
# exmaple, they could type `bake foo.o my-program-name`, which is technically
# redundant. Even if they do this, it's still just fine for us to treat `foo.o`
# and `my-program-name` as independent goals; and in fact we have to because even
# if we found an alternative way to build `my-program-name`, failing to build
# `foo.o` would mean that the operation had failed.

  local required_goals=${#goals[@]}

  local -a ungrounded=( ${goals[@]/*/1} )
  local -a expansion_indexes=( ${goals[@]/*/-1} )
  local -a disjunctions=()
  local -a goal_resolution=()
  local -a reverse_index=( "${goals[@]/*/}" )

  local -a terminal_and_unary=()
  local -a terminal_and_not_unary=()

  local -a nonterminal_and_unary=()
  local -a nonterminal_and_not_unary=()

  local i
  for i in ${terminal_rules[@]}; do
    if [[ -n ${rule_is_unary[i]} ]]; then
      terminal_and_unary+=( "$i" )
    else
      terminal_and_not_unary+=( "$i" )
    fi
  done

  for i in ${nonterminal_rules[@]}; do
    if [[ -n ${rule_is_unary[i]} ]]; then
      nonterminal_and_unary+=( "$i" )
    else
      nonterminal_and_not_unary+=( "$i" )
    fi
  done

  while (( ${#ungrounded[@]:0:$required_goals} )); do
    # First identify terminal rules and mark them as being grounded. Follow
    # them upwards, marking any dependencies. Grounding is obviously
    # commutative, so optimize by using unary rules first.
    local -a newly_grounded=()
    local i
    for i in ${!goals[@]}; do
      if [[ -n ${ungrounded[i]} ]]; then
        local g=${goals[i]}
        local j
        for j in ${terminal_and_unary[@]}; do
          if __bake_match "${__bakeinst_g_out[j]}" "$g"; then
            newly_grounded+=( "$i" )
            break
          fi
        done
      fi
    done

    # Propagate grounding. This code duplication will make common cases way,
    # way faster.
    local cursor=0
    while (( cursor < ${#newly_grounded[@]} )); do
      local i=${newly_grounded[cursor]}
      (( ++cursor ))

      ungrounded[$i]=

      local j
      for j in ${reverse_index[i]}; do
        [[ -n ${ungrounded[j]} ]] && newly_grounded+=( "$j" )
      done
    done

    # Same thing here, but with non-unary rules.
    local -a newly_grounded=()
    local i
    for i in ${terminal_and_not_unary[@]}; do
      if __bake_match "${__bakeinst_g_out[j]} %@__rest" "${goals[*]}"; then
        # Ground out the matched goals.
        local oifs=$IFS; IFS=$'\n'
        local -a bindings=( ${__bake_return[@]} )
        IFS=$oifs

        __bake_expand "$bindings" "${__bakeinst_g_out[j]}"      # no %@__rest
        local -a expansion=( ${__bake_return[@]} )
        for word in ${expansion[@]}; do
          local index=-1
          local j
          for j in ${!goals[@]}; do
            if [[ ${goals[j]} == $word ]]; then
              index=$j
              break
            fi
          done

          if (( index == -1 )); then
            echo 'bake: internal error (reexpansion failed)'
            echo 'bake: please file an issue: github.com/spencertipping/bake'
            echo "bake: when filing, include this text:"
            echo "bake: $word :: ${goals[@]}"
            return 1
          fi

          [[ -n ${ungrounded[index]} ]] && newly_grounded+=( "$index" )
        done
      fi
    done

    # Propagate grounding again.
    local cursor=0
    while (( cursor < ${#newly_grounded[@]} )); do
      local i=${newly_grounded[cursor]}
      (( ++cursor ))

      ungrounded[$i]=

      local j
      for j in ${reverse_index[i]}; do
        [[ -n ${ungrounded[j]} ]] && newly_grounded+=( "$j" )
      done
    done

    # Ok, now we're done with the easy cases. If we still have any goals left,
    # start running them through nonterminal rules.
    local -a still_ungrounded=()
    local i
    for i in ${!goals[@]}; do
      [[ -n ${ungrounded[i]} ]] && still_ungrounded+=( "$i" )
    done

    if (( ${#still_ungrounded[@]} )); then
      # Try to match a unary rule against each still-ungrounded goal.
      local g
      for g in ${still_ungrounded[@]}; do
        local i
        for i in ${nonterminal_and_unary[@]}; do
          if __bake_match "${__bakeinst_g_out[i]}" "$g"; then
            # Add expansions unless already present.
            :
          fi
        done
      done
    fi
  done
}

# Interface layer.
# This is where we parse out stuff like `bake %foo.c = bar.c` into its underlying
# commands. Here are the rules we use:

# | 1. If any option indicates a special command, then we use that.
#   2. Otherwise, and if there is no `:`, `=`, or `::`, then the user is telling
#      us we need to build something.
#   3. Otherwise, the user is defining something.

# Definition cases:

# | 1. If we see `=`, no `::`, and the right-hand side can be expanded to a form
#      that contains no variables, then it's a global definition.
#   2. Otherwise, if we see `=`, then it's ungrounded.
#   3. Otherwise it's grounded.

# Here's the definition function, which takes all args from `bake`:

__bakeinst_define() {
  local -a outvars=()
  local -a invars=()
  local cmd=

  local parsing=outvars
  local grounded=

  while (( $# )); do
    local arg=$1
    shift

    if [[ $parsing == outvars ]]; then
      if [[ $arg == : ]]; then
        parsing=invars
        grounded=1
        continue
      elif [[ $arg == = ]]; then
        parsing=invars
        grounded=
        continue
      elif [[ $arg == :: ]]; then
        parsing=cmd
        grounded=1
        continue
      fi
    elif [[ $parsing == invars && $arg == :: ]]; then
      parsing=cmd
      continue
    fi

    case $parsing in
      outvars) outvars+=( "$arg" ) ;;
      invars)  invars+=( "$arg" ) ;;
      *)       cmd="$arg $*"; break ;;
    esac
  done

  # Is it the default rule?
  if [[ ${#outvars[@]} == 0 ]]; then
    if [[ -n $cmd ]]; then
      echo 'bake: cannot combine a command with the default build rule'
      return 1
    fi
    __bakeinst_default="${invars[*]}"
  else
    # Is it a global? Try expanding the RHS (invars) to see.
    local oifs=$IFS; IFS=$'\n'
    local globals="${__bakeinst_globals[*]}"
    IFS=$oifs

    __bake_expand "$globals" "${invars[*]}"
    local expanded_rhs="${__bake_return[*]}"

    if [[ ${expanded_rhs//%/} == $expanded_rhs \
       && "${outvars[*]/%/}" != "${outvars[*]//%/}" \
       && -z $grounded \
       && -z $cmd ]]; then
      # No expanded stuff, no command, and no vars on the left-hand side; looks
      # like a global definition.
      __bakeinst_defglobal "${outvars[*]}" "$expanded_rhs"
    elif [[ -n $grounded ]]; then
      __bakeinst_defgrounded "${outvars[*]}" "${invars[*]}" "$cmd"
    else
      __bakeinst_defungrounded "${outvars[*]}" "${invars[*]}" "$cmd"
    fi
  fi
}

__bakeinst_should_define() {
  for arg in "$@"; do
    if [[ $arg == = || $arg == : || $arg == :: ]]; then
      return 0  # success = should define something
    fi
  done
  return 1      # failure = no definition
}

__bakeinst_expand() {
  local oifs=$IFS; IFS=$'\n'
  local globals="${__bakeinst_globals[*]}"
  IFS=$oifs

  local val="$*"
  local expanded=1
  while [[ -n $expanded ]]; do
    expanded=

    # First expand out all globals.
    __bake_expand "$globals" "$val"
    local new_val="${__bake_return[*]}"
    [[ $new_val != $val ]] && expanded=1
    val=$new_val

    # Now try each ungrounded rule. If we find one that matches, do the
    # replacement and execute the associated command if there is one.
    local i
    for i in ${!__bakeinst_u_out[@]}; do
      if __bake_match "${__bakeinst_u_out[i]}" "$val"; then
        local oifs=$IFS; IFS=$'\n'
        local match="${__bake_return[*]}"
        IFS=$oifs

        # More bindings for the command. %in is the full incoming text, which
        # for us is just $val. %out is $new_val; that is, the replaced version.
        __bake_expand "$match" "${__bakeinst_u_in[i]}"
        local replacement="${__bake_return[*]}"

        __bake_expand "$match"$'\n'"in $val"$'\n'"out $replacement" \
                      "${__bakeinst_u_commands[i]}"
        local cmd_text="${__bake_return[*]}"

        if eval "${cmd_text:-:}"; then
          # Everything worked; commit the result.
          expanded=
          [[ $replacement != $val ]] && expanded=1
          val=$replacement
          break
        fi
      fi
    done
  done

  __bakeinst_return=( "$val" )
}

__bakeinst_main() {
  case $1 in
    --eval|--echo|-e)
      shift
      __bakeinst_expand "$*"
      echo "${__bakeinst_return[*]}"
      return 0 ;;

    --list|-l)
      __bakeinst_print_rules
      __bakeinst_print_globals
      return 0 ;;

    --terminal|-t)
      shift
      local arg
      for arg in "$@"; do
        __bakeinst_defgrounded "$arg" '' ''
      done
      return 0 ;;
  esac

  if __bakeinst_should_define "$@"; then
    __bakeinst_define "$@"
  else
    local solve_fn=__bakeinst_step_quietly
    while getopts 'j:v' OPTNAME; do
      case $OPTNAME in
        j) __bakeinst_jobs=$OPTARG ;;
        v) solve_fn=__bakeinst_step_verbosely ;;
        *) echo "bake: unknown option $OPTNAME"
           return 1 ;;
      esac
    done
    shift $OPTIND
    __bakeinst_solve $solve_fn "$@"
  fi
}

# Locals fixing.
# Before we call any bake functions, we need to recompile all of them to fix up
# their local variables (long story; see `__bake_recompile` for details).

declare __bake_current_fn
for __bake_current_fn in \
    $(declare -f | egrep '^__bake' | sed 's/[^A-Za-z0-9_].*//'); do
  __bake_recompile $__bake_current_fn
done

# In case someone uses bake without first creating an instance
__bake_setup_globals

# It takes a long time to fix up all of the locals, so we want to do this ahead
# of time and compile the result into a whole new script. All of the state is
# encapsulated into functions beginning with __bake. Assuming we're in a clean
# environment, all we need to do is grab the values of all of these definitions
# and echo them. This will become the new precompiled script.

__bake_recompiled() {
  local f
  for f in $(declare -f | egrep '^__bake' | sed 's/[^A-Za-z0-9_].*//'); do
    declare -f $f
  done
  declare -f bake-instance
}

# Bake-instance usage.
# Most of the configuration is done after you create an instance; this function
# just takes the name of the instance you want to create.

bake-instance() {
  local name=$1
  local prefix=__bake_$name

  if [[ $# != 1 ]]; then
    echo "usage: bake-instance <instance-name>"
    return 1
  fi

# State definitions.
# Every stateful definition in bake is represented as a rule, which has three
# parts, or a global, which has one. Here's a rule:

# | bake %x.o : %x.c :: gcc -c %in -o %out
#        |out|  |in|    |--- command ----|

# And here's a global:

# | bake %@modules.c %@others = *

# You can't combine globals with locals. For example, you can't write this:

# | bake %@modules.%ext = *.%ext          # invalid

# The reason is that this definition wouldn't give a value to `%@modules`; it
# would just make `%@modules` a part of another rewriting rule (and somewhat
# counterintuitively, a literal). The rule is that the right-hand side of any
# global assignment must be fully-specified at definition time (though it can
# contain references to other global variables, as long as they are defined).

# Like grounded rules, ungrounded rules can have commands:

# | bake inputs-for-%x.o = %x.c %x.h :: echo "hi"
#        |---- out ----|   |- in --|    |command|

# Note that bake assumes that any command attached to an ungrounded edge is cheap
# to execute. As such, these commands are not parallelized and ungrounded edges
# are executed speculatively and possibly multiple times.

  eval "
  # Grounded rules
  unset ${prefix}_g_out ${prefix}_g_in ${prefix}_g_commands
  declare -a ${prefix}_g_out=()
  declare -a ${prefix}_g_in=()
  declare -a ${prefix}_g_commands=()

  # Ungrounded rules
  unset ${prefix}_u_out ${prefix}_u_in ${prefix}_u_commands
  declare -a ${prefix}_u_out=()
  declare -a ${prefix}_u_in=()
  declare -a ${prefix}_u_commands=()

  # List of globals (name v1 v2 v3 ... vn)
  unset ${prefix}_globals
  declare -a ${prefix}_globals=()

  # Configuration
  declare ${prefix}_backend=bake-backend-sha
  declare ${prefix}_default=
  declare -a ${prefix}_init=()
  declare -a ${prefix}_finalize=()

  # Temporaries
  declare -a ${prefix}_return=()
  "

# Function template instantiation.
# Every function beginning with `__bakeinst` is actually a template that we'll
# re-eval with proper closure references. Bash makes this extremely easy.

  local fn
  for fn in $(declare -f | grep '^__bakeinst' | sed 's/[^A-Za-z0-9_].*//'); do
    local fn_source="$(declare -f $fn)"
    eval "${fn_source//__bakeinst/$prefix}"
  done

# Entry point.
# Each bake function redirects to `__bakeinst_main`.

  eval "
  __bake_setup_globals
  ${name}() {
    ${prefix}_main \"\$@\"
  }
  "
}

# Generated by SDoc

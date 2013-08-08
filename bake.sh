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

declare __bake_locals_prefix=0
declare __bake_locals_key=$(mktemp -u _XXXXXXXX)

__bake_fix_locals() {
  # Takes a function name and recompiles it in place.
  local fn_name=$1
  local fn_source="$(declare -f $fn_name)"

  # First step: build a list of local variables. Note that we don't handle
  # multiple local definitions here; that's a huge rabbit hole.
  local local_source="$fn_source"
  local local_pattern="\blocal +(-[a-zA-Z]+ +)*([A-Za-z0-9_]+)"
  local -a locals=()
  while [[ "$local_source" =~ $local_pattern(.*) ]]; do
    locals[${#locals[@]}]=${BASH_REMATCH[2]}
    local_source=${BASH_REMATCH[3]}
  done

  # Second step: replace each local within the source. The easiest way is to
  # shell out to sed or some such, but that has major performance implications.
  # Instead, use a destructuring loop like we did above.
  local prefix=l$__bake_locals_key$(( bake_locals_prefix++ ))_
  for l in "${locals[@]}"; do
    # Here's what's going on here. Bash doesn't give us lazy matching, which is
    # what we're really after; so we have to fake it. First, replace every
    # occurrence of the variable to add the prefix. Then go back and fix up any
    # replacement that happened not at a word boundary. (This is why our prefix
    # needs to be unique.)
    local replaced_source="${fn_source//$l/$prefix$l}"
    local patch_pattern="([A-Za-z0-9_])$prefix$l"
    fn_source=

    while [[ "$replaced_source" =~ $patch_pattern(.*)$ ]]; do
      local prematch_length=$((${#replaced_source} - ${#BASH_REMATCH[0]}))
      local prematch="${replaced_source:0:$prematch_length}"
      fn_source="$fn_source$prematch${BASH_REMATCH[1]}$l"
      replaced_source="${BASH_REMATCH[2]}"
    done

    fn_source="$fn_source$replaced_source"
  done

  eval "$fn_source"
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

declare __bake_var_pattern="%(@?[A-Za-z0-9_]+)"
declare -a __bake_return=()

__bake_factor() {
  local factor=$1
  local -a text=( $2 )

  local factor_pattern=${factor//%/*}
  local -a matching=()
  local -a remainder=()
  local w
  for w in "${text[@]}"; do
    if [[ $w == $factor_pattern ]]; then
      matching[${#matching[@]}]=$w
    else
      remainder[${#remainder[@]}]=$w
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
    unique_variables[${#unique_variables[@]}]=${BASH_REMATCH[1]}
    v=${BASH_REMATCH[2]}
  done

  # Check for duplicate references to any variable.
  for (( i = 0; i < ${#unique_variables[@]}; ++i )); do
    local this_var=${unique_variables[i]}
    local j
    for (( j = i + 1;
           j < ${#unique_variables[@]}; ++j )); do
      if [[ $this_var == ${unique_variables[j]} ]]; then
        return 1
      fi
    done
  done
}

__bake_match() {
  local -a vars=( $1 )
  local -a text=( $2 )

  local -a profiles=()
  local i

  for (( i = 0; i < ${#vars[@]}; ++i )); do
    __bake_factor_profile "${vars[i]}"
    profiles[i]=$__bake_return
  done

  __bake_check_pattern "${vars[*]}" || return 2

  for (( i = 0; i < ${#vars[@]}; ++i )); do
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
      variable_names[${#variable_names[@]}]=${BASH_REMATCH[1]}
      match_pattern="$match_pattern(.*)\"${BASH_REMATCH[2]}\""
      v=${BASH_REMATCH[3]}
    done

    local namecount=${#variable_names[@]}

    local m
    for m in "${matching[@]}"; do
      # This should always match; but if it doesn't, we need to signal an error
      # indicating that something is way wrong.
      eval [[ \"$m\" =~ $match_pattern ]] || return 3

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
              remainder[${#remainder[@]}]=$m
              break
            fi
          fi
        fi

        bindings[${#bindings[@]}]=$binding_value
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

    # Print the bindings in the return-value format. Display only the unique
    # values for each binding.
    for (( j = 0; j < namecount; ++j )); do
      echo -n "${variable_names[j]}"

      if (( j == plural_index )); then
        for (( k = j; k < ${#bindings[@]}; k += namecount )); do
          echo -n " ${bindings[k]}"
        done
      else
         echo -n " ${bindings[j]}"
      fi
      echo
    done
  done

  # We shouldn't have any text left. If we do, then return 1; the match didn't
  # consume all of the text.
  [[ -z $text ]]
}

# String expansion.
# The opposite of variable binding. This logic is much simpler, too; there aren't
# many special cases involved.

__bake_expand() {
  local oifs=$IFS
  IFS=$'\n'
  local -a bindings=( $1 )
  IFS=$oifs
  local -a text=( $2 )

  local -a names=()
  local -a values=()

  local b
  for b in "${bindings[@]}"; do
    local -a var_and_values=( $b )
    names[${#names[@]}]=${var_and_values[0]}
    values[${#values[@]}]=${var_and_values[*]:1}
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
                new_expansion[${#new_expansion[@]}]=$e$v
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
            expansion[$i]=${expansion[i]}%$var_name
          done
        fi
      fi

      word=${BASH_REMATCH[4]}
    done

    result=( "${result[@]}" "${expansion[@]}" )
  done

  echo "${result[*]}"
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
  __bakeinst_g_out[${#__bakeinst_g_out[@]}]=$outvars
  __bakeinst_g_in[${#__bakeinst_g_in[@]}]=$invars
  __bakeinst_g_commands[${#__bakeinst_g_commands[@]}]=$cmd
}

__bakeinst_defungrounded() {
  local outvars=$1
  local invars=$2
  local cmd=$3
  __bakeinst_u_out[${#__bakeinst_u_out[@]}]=$outvars
  __bakeinst_u_in[${#__bakeinst_u_in[@]}]=$invars
  __bakeinst_u_commands[${#__bakeinst_u_commands[@]}]=$cmd
}

__bakeinst_defglobal() {
  local name=$1
  local value=$2

  # IFS needs to be its usual value when we call __bake_match
  local match_result="$(__bake_match "$name" "$value" || echo $?)"

  local oifs=$IFS
  IFS=$'\n'
  local -a bindings=( $match_result )
  IFS=$oifs

  case "${bindings[*]}" in
    1) echo "bake: $name failed to match $value"
       return 1 ;;
    2) echo "bake: $name is not a valid pattern (repeated variable)"
       return 1 ;;
    3) echo "bake: $name = $value failed; this is a bug in bake"
       echo "bake: please file an issue: github.com/spencertipping/bake"
       return 1 ;;
  esac

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
# There are some important assumptions we make in order to solve dependencies.

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
      outvars) outvars[${#outvars[@]}]=$arg ;;
      invars)  invars[${#invars[@]}]=$arg ;;
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
    local oifs=$IFS
    IFS=$'\n'
    local globals="${__bakeinst_globals[@]}"
    IFS=$oifs

    local expanded_rhs="$(__bake_expand "$globals" "${invars[*]}")"

    if [[ ${expanded_rhs/%/} == $expanded_rhs && -z $grounded \
                                              && -z $cmd ]]; then
      # No expanded stuff and no cmd; probably a global.
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
  local oifs=$IFS
  IFS=$'\n'
  local globals="${__bakeinst_globals[*]}"
  IFS=$oifs

  local val="$*"
  local expanded=1
  while [[ -n $expanded ]]; do
    expanded=

    # First expand out all globals.
    local -a new_val=$(__bake_expand "$globals" "$val")
    [[ $new_val != $val ]] && expanded=1
    val=$new_val

    # Now try each ungrounded rule. If we find one that matches, do the
    # replacement and execute the associated command if there is one.
    local _i
    for _i in ${!__bakeinst_u_out[@]}; do
      
      local match="$(__bake_match "${__bakeinst_u_out[_i]}" "$val" || echo 1)"

      if [[ "${match[*]}" != 1 ]]; then
        # More bindings for the command. %in is the full incoming text, which
        # for us is just $val. %out is $new_val; that is, the replaced version.
        local replacement="$(__bake_expand "$match" "${__bakeinst_u_in[i]}")"
        local cmd_text="$(__bake_expand \
          "$match"$'\n'"in $val"$'\n'"out $replacement" \
          "${__bakeinst_u_commands[i]}")"

        if eval "${cmd_text:-:}"; then
          # Everything worked; commit the result.
          val=$replacement
          expanded=1
          break
        fi
      fi
    done
  done

  __bakeinst_return=$val
}

__bakeinst_main() {
  case $1 in
    --eval|--echo|-e)
      shift
      __bakeinst_expand "$*"
      return 0 ;;

    --list|-l)
      __bakeinst_print_rules
      __bakeinst_print_globals
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
# their local variables (long story; see `__bake_fix_locals` for details).

declare __bake_current_fn
for __bake_current_fn in \
    $(declare -f | egrep '^__bake' | sed 's/[^A-Za-z0-9_].*//'); do
  __bake_fix_locals $__bake_current_fn
done

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
  ${name}() {
    ${prefix}_main \"\$@\"
  }
  "
}

# Generated by SDoc

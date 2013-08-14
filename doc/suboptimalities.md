# Suboptimalities in the master branch
1. Separate designation is required for plural variables (probably inevitable
   unless we introduce some kind of semantic change)
2. Variable tables require linear scans to lookup values, making expansion
   O(kn) time complexity
3. Matching is unoptimized in several ways:
    - RHS factoring is not reused for subsequent matches, even when the
      variable profile is the same
    - RHS factoring is not even done well for the single-match case: the LHS is
      not analyzed enough up front to know whether we can reject matches
      quickly

Problem 1 is probably a rabbit hole. Problem 2 is solvable, but the solution
involves getting the matcher right. Problem 3 dictates the concrete changes
that need to be made.

As of this writing, the matcher on the master branch follows roughly this
algorithm:

1. Check the LHS for obvious problems like repeated unknowns (todo: allow
   these and expand inline)
2. For each LHS term, in order:
    1. Scan ahead within the LHS to determine whether the variable's profile is
       shadowed
    2. Refactor the RHS by the variable profile (linear-time operation)
    3. Bind values, factoring out up to one level of distributivity
    4. Recompile remaining RHS values into new text string (linear-time
       operation)
3. Return results, provided that all text has been consumed

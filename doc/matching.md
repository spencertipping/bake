# Matching
Bake uses a relatively complex algorithm to bind variables to values, and the
amount of destructuring that goes on ends up being a lot for bash to handle. As
a result, we do as much as we can to front-load the work, optimizing for
repeated match attempts.

A naïve matching algorithm would examine each variable in isolation,
refactoring the right-hand side separately each time, resulting in O(kn)
runtime. However, in many cases we can do significantly better than this. One
particular optimization is to pre-sort the right-hand side by profile, then do
a single linear-time match. This improves runtime to O(n log k).

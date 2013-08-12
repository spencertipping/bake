# Binding lists
The initial version of bake uses linear scans to resolve variable bindings.
This results in O(kn) expansion time, which is suboptimal.

There are two ways to mitigate this. One is to pre-expand globals, which
reduces the number of bindings that need to be considered. The other is to
become smarter about the way we store and access the data in binding tables.

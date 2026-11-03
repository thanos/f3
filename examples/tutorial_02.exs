# Runnable from the repository root:
#   mix run examples/tutorial_02.exs
#
# Prints the postscript of test/fixtures/small.f3. Set F3_FIXTURE to another
# committed fixture path to describe that file instead.

IO.puts("command: mix run examples/tutorial_02.exs")
Code.require_file(Path.expand("../scripts/fixtures/describe_tail.exs", __DIR__))

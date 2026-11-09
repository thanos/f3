# Runnable from the repository root:
#   mix run examples/tutorial_09.exs
#
# Prints the recorded benchmark. It does not time the fixtures again.

IO.puts("command: mix run examples/tutorial_09.exs")
IO.puts("recorded command: /usr/bin/time -l mix run scripts/bench.exs")
IO.puts("recorded native_stamp: 0")
IO.puts("recorded small.f3 read_us: 81")
IO.puts("recorded small.f3 read: error category=native_unavailable")
IO.puts("recorded maximum resident set size: 109854720")
IO.puts("recorded peak memory footprint: 97747616")
IO.puts("recorded ps_rss_kb: 107136")
IO.puts("parquet comparison: skipped")
IO.puts("batch_size: default")
IO.puts("hex: not published")

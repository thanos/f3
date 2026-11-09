Mox.defmock(F3.IO.Mock, for: F3.IO.Source)
Mox.defmock(F3.IO.FileSystemMock, for: F3.IO.FileSystem)
Mox.defmock(F3.Decoder.Mock, for: F3.Decoder)

Code.compile_file("native/f3_write/build.ex")

excluded = [:native]
excluded = if System.get_env("F3_MINIO") == "1", do: excluded, else: [:minio | excluded]
ExUnit.start(exclude: excluded)

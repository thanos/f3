Mox.defmock(F3.IO.Mock, for: F3.IO.Source)
Mox.defmock(F3.IO.FileSystemMock, for: F3.IO.FileSystem)
Mox.defmock(F3.Decoder.Mock, for: F3.Decoder)

ExUnit.start(exclude: [:native])

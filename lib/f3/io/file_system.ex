defmodule F3.IO.FileSystem do
  @moduledoc """
  Operating-system calls used by `F3.IO.Local`.

  Production code uses `F3.IO.FileSystem.OS`. Tests pass a Mox double as
  `:file_system` on `F3.IO.Local.open/2` so read and close failures can be
  returned without changing a real file.
  """

  @callback stat(Path.t()) :: {:ok, File.Stat.t()} | {:error, atom()}
  @callback open(Path.t(), [atom()]) :: {:ok, term()} | {:error, atom()}
  @callback pread(term(), non_neg_integer(), non_neg_integer()) ::
              {:ok, binary()} | :eof | {:error, atom()}
  @callback close(term()) :: :ok | {:error, atom()}
end

defmodule F3.IO.Source do
  @moduledoc """
  Positioned byte source.

  `pread/3` reads at most `length` bytes. That argument is the caller's cap.
  There is no process-wide size limit. A read that starts at or past the end
  returns `{:ok, ""}`. A read that extends past the end returns the bytes
  that remain. Implementations return a tagged error instead of raising.
  """

  @type state :: term()

  @callback size(state()) :: {:ok, non_neg_integer()} | {:error, F3.Error.t()}
  @callback pread(state(), non_neg_integer(), non_neg_integer()) ::
              {:ok, binary()} | {:error, F3.Error.t()}
  @callback close(state()) :: {:ok, state()} | {:error, F3.Error.t()}
end

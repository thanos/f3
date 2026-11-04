defmodule F3.Checksum do
  @moduledoc """
  XXH64 checksums for chunk bytes.

  The pinned writer uses `xxhash_rust` `Xxh64` with seed 0. Postscript
  checksums stay recorded and are not recomputed. A chunk checksum is
  checked only when the footer field is present.
  """

  import Bitwise

  @p1 0x9E3779B185EBCA87
  @p2 0xC2B2AE3D27D4EB4F
  @p3 0x165667B19E3779F9
  @p4 0x85EBCA77C2B2AE63
  @p5 0x27D4EB2F165667C5
  @mask 0xFFFFFFFFFFFFFFFF

  @doc """
  XXH64 of `bytes` with seed 0.
  """
  @spec xxh64(binary()) :: non_neg_integer()
  def xxh64(bytes) when is_binary(bytes), do: xxh64(bytes, 0)

  @doc """
  XXH64 of `bytes` with an integer seed.
  """
  @spec xxh64(binary(), integer()) :: non_neg_integer()
  def xxh64(bytes, seed) when is_binary(bytes) and is_integer(seed) do
    seed = mask(seed)
    hashed = hash_body(bytes, seed)
    finalize(mask(hashed + byte_size(bytes)), rest_after_rounds(bytes))
  end

  @doc """
  Checks a chunk checksum. `nil` means the footer did not store one.
  """
  @spec verify(binary(), non_neg_integer() | nil) :: :ok | {:error, F3.Error.t()}
  def verify(bytes, checksum) when is_binary(bytes) and is_nil(checksum), do: :ok

  def verify(bytes, checksum) when is_binary(bytes) and is_integer(checksum) and checksum >= 0 do
    if xxh64(bytes) == checksum do
      :ok
    else
      {:error, F3.Error.checksum(:read, "chunk checksum mismatch")}
    end
  end

  defp hash_body(bytes, seed) when byte_size(bytes) >= 32 do
    {v1, v2, v3, v4} = rounds(bytes, init_v(seed))
    merge_all(v1, v2, v3, v4)
  end

  defp hash_body(_bytes, seed), do: mask(seed + @p5)

  defp rest_after_rounds(bytes) when byte_size(bytes) >= 32 do
    skip = div(byte_size(bytes), 32) * 32
    binary_part(bytes, skip, byte_size(bytes) - skip)
  end

  defp rest_after_rounds(bytes), do: bytes

  defp init_v(seed) do
    {mask(seed + @p1 + @p2), mask(seed + @p2), seed, mask(seed - @p1)}
  end

  defp rounds(
         <<a::little-unsigned-64, b::little-unsigned-64, c::little-unsigned-64,
           d::little-unsigned-64, rest::binary>>,
         {v1, v2, v3, v4}
       ) do
    rounds(rest, {round(v1, a), round(v2, b), round(v3, c), round(v4, d)})
  end

  defp rounds(_rest, state), do: state

  defp merge_all(v1, v2, v3, v4) do
    acc = mask(rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18))
    acc = merge_round(acc, v1)
    acc = merge_round(acc, v2)
    acc = merge_round(acc, v3)
    merge_round(acc, v4)
  end

  defp merge_round(acc, val) do
    mask(xor64(acc, round(0, val)) * @p1 + @p4)
  end

  defp round(acc, input) do
    mask(rotl(mask(acc + mask(input * @p2)), 31) * @p1)
  end

  defp finalize(acc, <<word::little-unsigned-64, rest::binary>>) do
    acc = mask(rotl(xor64(acc, round(0, word)), 27) * @p1 + @p4)
    finalize(acc, rest)
  end

  defp finalize(acc, <<word::little-unsigned-32, rest::binary>>) do
    acc = mask(rotl(xor64(acc, mask(word * @p1)), 23) * @p2 + @p3)
    finalize(acc, rest)
  end

  defp finalize(acc, <<byte, rest::binary>>) do
    acc = mask(rotl(xor64(acc, mask(byte * @p5)), 11) * @p1)
    finalize(acc, rest)
  end

  defp finalize(acc, <<>>), do: avalanche(acc)

  defp avalanche(acc) do
    acc = xor64(acc, acc >>> 33)
    acc = mask(acc * @p2)
    acc = xor64(acc, acc >>> 29)
    acc = mask(acc * @p3)
    xor64(acc, acc >>> 32)
  end

  defp rotl(value, bits) do
    value = mask(value)
    mask(value <<< bits ||| value >>> (64 - bits))
  end

  defp xor64(left, right), do: Bitwise.bxor(mask(left), mask(right))
  defp mask(value), do: value &&& @mask
end

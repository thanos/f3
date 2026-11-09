defmodule F3.IO.HTTP.Sign do
  @moduledoc false

  @empty_hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  @doc """
  Returns headers for one path-style or virtual-hosted S3 request.

  `now` is `:clock` or `{date, stamp}` (`YYYYMMDD` and `YYYYMMDDTHHMMSSZ`).
  The secret is used only as HMAC key material and is not copied into the
  returned headers.
  """
  @spec headers(
          atom() | String.t(),
          String.t(),
          [{String.t(), String.t()}],
          map(),
          :clock | {String.t(), String.t()}
        ) ::
          {:ok, [{String.t(), String.t()}]}
  def headers(method, url, extra, creds, now) do
    uri = URI.parse(url)
    {date, stamp} = format_now(now)
    unsigned = unsigned_headers(host_header(uri), stamp, extra)
    authorization = authorization(method, uri, unsigned, creds, date, stamp)
    {:ok, [{"authorization", authorization} | unsigned]}
  end

  defp unsigned_headers(host, stamp, extra) do
    [
      {"host", host},
      {"x-amz-content-sha256", @empty_hash},
      {"x-amz-date", stamp}
      | drop_reserved(extra)
    ]
  end

  defp drop_reserved(headers) do
    Enum.reject(headers, fn {name, _value} ->
      String.downcase(name) in ["host", "authorization", "x-amz-date", "x-amz-content-sha256"]
    end)
  end

  defp authorization(method, uri, headers, creds, date, stamp) do
    scope = "#{date}/#{creds.region}/s3/aws4_request"
    signature = signature(method, uri, headers, creds.secret_key, stamp, scope)
    signed = signed_names(headers)

    "AWS4-HMAC-SHA256 Credential=#{creds.access_key}/#{scope}," <>
      "SignedHeaders=#{signed},Signature=#{signature}"
  end

  defp signature(method, uri, headers, secret, stamp, scope) do
    canonical = canonical_request(method, uri, headers)
    string = "AWS4-HMAC-SHA256\n#{stamp}\n#{scope}\n#{hex_sha256(canonical)}"
    date = String.slice(stamp, 0, 8)
    key = signing_key(secret, date, scope_region(scope))
    key |> hmac(string) |> Base.encode16(case: :lower)
  end

  defp scope_region(scope) do
    scope |> String.split("/") |> Enum.at(1)
  end

  defp canonical_request(method, uri, headers) do
    method = method |> to_string() |> String.upcase()

    Enum.join(
      [
        method,
        canonical_path(uri.path),
        canonical_query(uri.query),
        canonical_header_block(headers),
        signed_names(headers),
        @empty_hash
      ],
      "\n"
    )
  end

  defp canonical_path(nil), do: "/"
  defp canonical_path(""), do: "/"

  defp canonical_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &encode_segment/1)
  end

  defp canonical_query(nil), do: ""
  defp canonical_query(""), do: ""

  defp canonical_query(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.map(&split_query/1)
    |> Enum.sort()
    |> Enum.map_join("&", fn {key, value} ->
      encode_segment(key) <> "=" <> encode_segment(value)
    end)
  end

  defp split_query(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, value] -> {key, value}
      [key] -> {key, ""}
    end
  end

  defp canonical_header_block(headers) do
    headers
    |> normalized_headers()
    |> Enum.map_join(fn {name, value} -> "#{name}:#{value}\n" end)
  end

  defp signed_names(headers) do
    headers
    |> normalized_headers()
    |> Enum.map_join(";", fn {name, _value} -> name end)
  end

  defp normalized_headers(headers) do
    headers
    |> Enum.map(fn {name, value} ->
      {String.downcase(name), collapse_spaces(value)}
    end)
    |> Enum.sort()
  end

  defp collapse_spaces(value) do
    value
    |> String.trim()
    |> String.replace(~r/[[:space:]]+/, " ")
  end

  defp encode_segment(segment) do
    URI.encode(segment, &URI.char_unreserved?/1)
  end

  defp signing_key(secret, date, region) do
    ("AWS4" <> secret)
    |> hmac(date)
    |> hmac(region)
    |> hmac("s3")
    |> hmac("aws4_request")
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp hex_sha256(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    host = String.downcase(host)

    if port in [nil, default_port(scheme)] do
      host
    else
      "#{host}:#{port}"
    end
  end

  defp default_port("https"), do: 443
  defp default_port(_scheme), do: 80

  defp format_now({date, stamp}) when is_binary(date) and is_binary(stamp) do
    {date, stamp}
  end

  defp format_now(:clock) do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()
    date = pad(year, 4) <> pad(month, 2) <> pad(day, 2)
    stamp = date <> "T" <> pad(hour, 2) <> pad(minute, 2) <> pad(second, 2) <> "Z"
    {date, stamp}
  end

  defp pad(number, width) do
    number |> Integer.to_string() |> String.pad_leading(width, "0")
  end
end

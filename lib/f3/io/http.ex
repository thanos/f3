defmodule F3.IO.HTTP do
  @moduledoc """
  HTTP byte source.

  `open/2` sends one `HEAD` and stores `Content-Length`. `pread/3` sends one
  `GET` with `Range: bytes=offset-end` and returns at most the requested
  length. Redirects are refused. `lib_urls` in a footer are not requests.

  Unsigned options are `headers:` and `timeout_ms:`. `sign:` is a function
  `(method, url, headers) -> {:ok, headers} | {:error, F3.Error.t()}` that
  the caller uses to attach its own signature. When `endpoint:`, `bucket:`,
  `key:`, `region:`, `access_key:`, and `secret_key:` are all set, this
  module signs path-style `HEAD` and `GET` with SigV4. The object URL is
  `endpoint/bucket/key`. The secret is not stored on the error or printed
  by `Inspect`.
  """

  @behaviour F3.IO.Source

  alias F3.IO.HTTP.Sign

  @default_timeout_ms 10_000
  @credential_keys [:endpoint, :bucket, :key, :region, :access_key, :secret_key]
  @option_keys [:headers, :timeout_ms, :sign | @credential_keys]
  @redirects [301, 302, 303, 307, 308]

  @enforce_keys [:url, :display_url, :size, :headers, :timeout, :signer]
  defstruct [:url, :display_url, :size, :headers, :timeout, :signer, closed: false]

  @type t :: %__MODULE__{
          url: String.t(),
          display_url: String.t(),
          size: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          timeout: pos_integer(),
          signer:
            (atom(), String.t(), [{String.t(), String.t()}] ->
               {:ok, [{String.t(), String.t()}]} | {:error, F3.Error.t()})
            | nil,
          closed: boolean()
        }

  @doc """
  Opens `url` with one HEAD request.

  See the module docs for `opts`. When the six signing keys are set, `url`
  is not requested. The path-style object URL is.
  """
  @spec open(String.t(), keyword()) :: {:ok, t()} | {:error, F3.Error.t()}
  def open(url, opts \\ [])

  def open(url, opts) when is_binary(url) and is_list(opts) do
    with :ok <- ensure_httpc(),
         :ok <- known_options(opts),
         {:ok, timeout} <- timeout(opts),
         {:ok, headers} <- header_list(opts),
         {:ok, request_url, signer} <- prepare(url, opts),
         state <- new_state(request_url, headers, timeout, signer),
         {:ok, size} <- head_size(state) do
      {:ok, %{state | size: size}}
    end
  end

  def open(_url, _opts) do
    {:error, F3.Error.invalid_argument(:open, "http url must be a binary")}
  end

  @impl true
  def size(%__MODULE__{closed: true}), do: {:error, F3.Error.closed(:size)}
  def size(%__MODULE__{size: size}), do: {:ok, size}

  @impl true
  def pread(%__MODULE__{closed: true}, _offset, _length), do: {:error, F3.Error.closed(:pread)}

  def pread(%__MODULE__{}, offset, length)
      when not is_integer(offset) or not is_integer(length) or offset < 0 or length < 0 do
    {:error, F3.Error.invalid_argument(:pread, "offset and length must be non-negative integers")}
  end

  def pread(%__MODULE__{size: size}, offset, length) when length == 0 or offset >= size do
    {:ok, <<>>}
  end

  def pread(%__MODULE__{} = state, offset, length) do
    to_read = min(length, state.size - offset)
    last = offset + to_read - 1
    headers = [{"range", "bytes=#{offset}-#{last}"} | state.headers]

    with {:ok, headers} <- sign(state, :get, headers),
         {:ok, status, response_headers, body} <- http(:get, state, headers) do
      take_body(state, status, response_headers, body, to_read)
    end
  end

  @impl true
  def close(%__MODULE__{closed: true} = state), do: {:ok, state}
  def close(%__MODULE__{} = state), do: {:ok, %{state | closed: true, signer: nil, headers: []}}

  defp new_state(url, headers, timeout, signer) do
    %__MODULE__{
      url: url,
      display_url: display_url(url),
      size: 0,
      headers: headers,
      timeout: timeout,
      signer: signer
    }
  end

  defp prepare(url, opts) do
    case credential_mode(opts) do
      :unsigned ->
        with {:ok, request_url} <- plain_url(url) do
          {:ok, request_url, signer_fun(opts)}
        end

      {:signed, creds} ->
        with {:ok, request_url} <- object_url(creds) do
          {:ok, request_url, &Sign.headers(&1, &2, &3, creds, :clock)}
        end

      {:error, %F3.Error{}} = error ->
        error
    end
  end

  defp signer_fun(opts) do
    case Keyword.get(opts, :sign) do
      nil -> nil
      fun when is_function(fun, 3) -> fun
    end
  end

  defp credential_mode(opts) do
    present = Enum.filter(@credential_keys, &Keyword.has_key?(opts, &1))

    cond do
      present == [] ->
        :unsigned

      present == @credential_keys and Keyword.has_key?(opts, :sign) ->
        {:error, F3.Error.invalid_argument(:open, "sign cannot be combined with signing keys")}

      present == @credential_keys ->
        creds(opts)

      true ->
        {:error,
         F3.Error.invalid_argument(
           :open,
           "signed request needs endpoint, bucket, key, region, access_key, and secret_key"
         )}
    end
  end

  defp creds(opts) do
    values = Map.new(@credential_keys, fn key -> {key, Keyword.get(opts, key)} end)

    if Enum.all?(values, fn {_key, value} -> is_binary(value) and value != "" end) do
      {:signed,
       %{
         endpoint: values.endpoint,
         bucket: values.bucket,
         key: values.key,
         region: values.region,
         access_key: values.access_key,
         secret_key: values.secret_key
       }}
    else
      {:error, F3.Error.invalid_argument(:open, "signing keys must be non-empty binaries")}
    end
  end

  defp plain_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, URI.to_string(%{uri | userinfo: nil})}

      _other ->
        {:error, F3.Error.invalid_argument(:open, "http url must be http or https")}
    end
  end

  defp object_url(creds) do
    case plain_url(creds.endpoint) do
      {:ok, endpoint} ->
        uri = URI.parse(endpoint)
        path = "/" <> encode_segment(creds.bucket) <> "/" <> encode_key(creds.key)
        {:ok, URI.to_string(%{uri | path: path, query: nil, fragment: nil})}

      {:error, %F3.Error{}} ->
        {:error, F3.Error.invalid_argument(:open, "endpoint must be http or https")}
    end
  end

  defp encode_key(key) do
    key |> String.split("/") |> Enum.map_join("/", &encode_segment/1)
  end

  defp encode_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp display_url(url) do
    url
    |> URI.parse()
    |> Map.put(:userinfo, nil)
    |> URI.to_string()
  end

  defp known_options(opts) do
    unknown = opts |> Keyword.keys() |> Enum.reject(&(&1 in @option_keys))

    cond do
      unknown != [] ->
        {:error, F3.Error.invalid_argument(:open, "unknown options: #{Kernel.inspect(unknown)}")}

      bad_sign?(opts) ->
        {:error, F3.Error.invalid_argument(:open, "sign must be a function of arity 3")}

      true ->
        :ok
    end
  end

  defp bad_sign?(opts) do
    case Keyword.fetch(opts, :sign) do
      :error -> false
      {:ok, fun} -> not is_function(fun, 3)
    end
  end

  defp timeout(opts) do
    case Keyword.get(opts, :timeout_ms, @default_timeout_ms) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      _other ->
        {:error, F3.Error.invalid_argument(:open, "timeout_ms must be a positive integer")}
    end
  end

  defp header_list(opts) do
    case Keyword.get(opts, :headers, []) do
      headers when is_list(headers) ->
        normalize_headers(headers)

      _other ->
        {:error, F3.Error.invalid_argument(:open, "headers must be a list of name/value pairs")}
    end
  end

  defp normalize_headers(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn
      {name, value}, {:ok, acc} when is_binary(name) and is_binary(value) ->
        {:cont, {:ok, [{String.downcase(name), value} | acc]}}

      _other, _acc ->
        {:halt, {:error, F3.Error.invalid_argument(:open, "headers must be name/value binaries")}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, %F3.Error{}} = error -> error
    end
  end

  defp head_size(state) do
    with {:ok, headers} <- sign(state, :head, state.headers),
         {:ok, status, response_headers, body} <- http(:head, state, headers) do
      content_length(state, status, response_headers, body)
    end
  end

  defp content_length(state, status, headers, body) do
    cond do
      status in @redirects ->
        refused_redirect(:open)

      status == 404 ->
        {:error, F3.Error.not_found(state.display_url)}

      status != 200 ->
        {:error, F3.Error.io(:open, :status, %{status: status})}

      body not in [<<>>, ""] ->
        {:error, F3.Error.resource_limit(:open, "HEAD response included a body", %{})}

      true ->
        parse_length(headers)
    end
  end

  defp parse_length(headers) do
    case header_value(headers, "content-length") do
      nil ->
        {:error, F3.Error.io(:open, :content_length, %{})}

      value ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 -> {:ok, length}
          _other -> {:error, F3.Error.io(:open, :content_length, %{})}
        end
    end
  end

  defp take_body(state, status, headers, body, to_read) do
    claimed = claimed_length(headers)

    cond do
      status in @redirects ->
        refused_redirect(:pread)

      status == 404 ->
        {:error, F3.Error.not_found(state.display_url)}

      status not in [200, 206] ->
        {:error, F3.Error.io(:pread, :status, %{status: status})}

      claimed > to_read or byte_size(body) > to_read ->
        {:error,
         F3.Error.resource_limit(:pread, "response is larger than the requested range", %{})}

      byte_size(body) < to_read ->
        {:error,
         F3.Error.truncated(:pread, "response body is shorter than the requested range", %{})}

      true ->
        {:ok, body}
    end
  end

  defp claimed_length(headers) do
    case header_value(headers, "content-length") do
      nil ->
        0

      value ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 -> length
          _other -> 0
        end
    end
  end

  defp refused_redirect(operation) do
    {:error, F3.Error.io(operation, :redirect, %{})}
  end

  defp sign(%__MODULE__{signer: nil}, _method, headers), do: {:ok, headers}

  defp sign(%__MODULE__{signer: signer, url: url}, method, headers) do
    case signer.(method, url, headers) do
      {:ok, signed} when is_list(signed) ->
        {:ok, signed}

      {:error, %F3.Error{} = error} ->
        {:error, scrub(error)}

      _other ->
        {:error, F3.Error.invalid_argument(:pread, "sign must return {:ok, headers}")}
    end
  end

  defp scrub(%F3.Error{} = error) do
    operation = error.context[:operation] || :pread
    %{error | cause: nil, message: safe_message(error.message), context: %{operation: operation}}
  end

  defp safe_message(message) when is_binary(message) do
    if String.contains?(message, ["\n", "\r"]) do
      "request was rejected"
    else
      message
    end
  end

  defp safe_message(_message), do: "request was rejected"

  defp http(method, state, headers) do
    request = {String.to_charlist(state.url), charlist_headers(headers)}
    options = [timeout: state.timeout, connect_timeout: state.timeout, autoredirect: false]

    case :httpc.request(method, request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, body}} ->
        {:ok, status, response_headers, body_binary(body)}

      {:error, reason} ->
        {:error, http_failure(method, reason)}
    end
  end

  defp charlist_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp body_binary(body) when is_binary(body), do: body
  defp body_binary(body) when is_list(body), do: IO.iodata_to_binary(body)

  defp http_failure(method, reason) do
    operation = if method == :head, do: :open, else: :pread

    if timeout?(reason) do
      F3.Error.resource_limit(operation, "request timed out", %{})
    else
      F3.Error.io(operation, :ehttp, %{})
    end
  end

  defp timeout?(:timeout), do: true

  defp timeout?({:failed_connect, details}) when is_list(details) do
    Enum.any?(details, fn
      {_key, :timeout} -> true
      {:inet, _family, :timeout} -> true
      _other -> false
    end)
  end

  defp timeout?(_reason), do: false

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if to_string(key) |> String.downcase() == name, do: to_string(value)
    end)
  end

  defp ensure_httpc do
    Enum.each([:asn1, :crypto, :public_key, :ssl, :inets], &add_otp_ebin/1)

    with {:ok, _} <- Application.ensure_all_started(:public_key),
         {:ok, _} <- Application.ensure_all_started(:ssl),
         {:ok, _} <- Application.ensure_all_started(:inets) do
      :ok
    else
      {:error, _reason} ->
        {:error, F3.Error.io(:open, :ehttp, %{})}
    end
  end

  defp add_otp_ebin(app) do
    case :code.lib_dir(app) do
      path when is_list(path) ->
        :code.add_patha(path ++ ~c"/ebin")

      {:error, _reason} ->
        wildcard_ebin(app)
    end
  end

  defp wildcard_ebin(app) do
    root = to_string(:code.root_dir())

    case Path.wildcard(Path.join([root, "lib", "#{app}-*", "ebin"])) do
      [ebin | _] -> :code.add_patha(String.to_charlist(ebin))
      [] -> :ok
    end
  end

  defimpl Inspect do
    def inspect(%F3.IO.HTTP{display_url: url, size: size, closed: closed}, _opts) do
      "#F3.IO.HTTP<url: #{url}, size: #{size}, closed: #{closed}>"
    end
  end
end

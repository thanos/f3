defmodule F3.IO.HTTPTest do
  use ExUnit.Case, async: false

  @secret "super-secret-key"
  @access "AKIAIOSFODNN7EXAMPLE"
  @fixture "test/fixtures/small.f3"

  test "a full read of small.f3 matches the local read" do
    bytes = File.read!(@fixture)
    server = range_server(fn request -> file_response(request, "/small.f3", bytes) end)
    url = url(server, "/small.f3")

    {:ok, local} = F3.open(@fixture)
    {:ok, remote} = F3.open(@fixture, source: {:http, url})

    assert F3.schema(local) == F3.schema(remote)
    assert F3.metadata(local) == F3.metadata(remote)
    assert F3.read(local) == F3.read(remote)

    {:ok, size} = F3.IO.HTTP.size(remote.source_state)
    assert size == byte_size(bytes)
    assert read_all(remote.source_state, size) == bytes

    {:ok, _} = F3.close(local)
    {:ok, closed} = F3.close(remote)
    assert closed.source_state.closed
    stop_server(server)
  end

  test "a ranged pread is capped at the remaining bytes" do
    bytes = File.read!(@fixture)
    server = range_server(fn request -> file_response(request, "/small.f3", bytes) end)
    {:ok, state} = F3.IO.HTTP.open(url(server, "/small.f3"))
    {:ok, size} = F3.IO.HTTP.size(state)

    assert {:ok, "F3"} = F3.IO.HTTP.pread(state, size - 2, 10)
    assert {:ok, <<>>} = F3.IO.HTTP.pread(state, size, 4)
    assert {:ok, <<>>} = F3.IO.HTTP.pread(state, 0, 0)
    stop_server(server)
  end

  test "a missing object is not_found and a redirect is refused" do
    server =
      range_server(fn
        %{path: "/missing"} -> {404, [], ""}
        %{path: "/redirect"} -> {302, [{"location", "http://example.test/nope"}], ""}
        _request -> {500, [], ""}
      end)

    assert {:error, %F3.Error{category: :not_found}} =
             F3.open("missing", source: {:http, url(server, "/missing")})

    assert {:error, %F3.Error{category: :io, reason: :redirect}} =
             F3.open("redirect", source: {:http, url(server, "/redirect")})

    stop_server(server)
  end

  test "metadata reads do not contact an http server" do
    server = range_server(fn _request -> {500, [], "should-not-run"} end)

    {:ok, file} = F3.open(@fixture)
    assert {:ok, _schema} = F3.schema(file)
    {:ok, _} = F3.close(file)

    refute_receive {:http_request, _request}, 50
    stop_server(server)
  end

  test "inspect and errors omit signing secrets and request headers" do
    bytes = File.read!(@fixture)

    server =
      range_server(fn request ->
        send(self_or(request.parent), {:seen, request.headers})
        file_response(request, "/bucket/small.f3", bytes)
      end)

    opts = [
      endpoint: "http://127.0.0.1:#{server.port}",
      bucket: "bucket",
      key: "small.f3",
      region: "us-east-1",
      access_key: @access,
      secret_key: @secret,
      headers: [{"x-token", @secret}]
    ]

    assert {:ok, file} = F3.open("remote", source: {:http, "http://ignored.example/nope", opts})
    refute inspect(file) =~ @secret
    refute inspect(file.source_state) =~ @secret
    refute inspect(file) =~ "x-token"

    assert_receive {:seen, headers}
    authorization = header(headers, "authorization")
    assert authorization =~ "AWS4-HMAC-SHA256"
    refute authorization =~ @secret

    assert {:error, error} =
             F3.IO.HTTP.open("http://127.0.0.1:1/object",
               endpoint: "http://127.0.0.1:1",
               bucket: "bucket",
               key: "object",
               region: "us-east-1",
               access_key: @access,
               secret_key: @secret,
               timeout_ms: 200
             )

    refute inspect(error) =~ @secret
    stop_server(server)
  end

  test "a caller-supplied sign function replaces the library signer" do
    bytes = File.read!(@fixture)

    server =
      range_server(fn request ->
        send(request.parent, {:seen, request.headers})
        file_response(request, "/small.f3", bytes)
      end)

    sign = fn method, url, headers ->
      assert method in [:head, :get]
      assert url =~ "/small.f3"
      {:ok, [{"x-signed", "yes"} | headers]}
    end

    assert {:ok, state} = F3.IO.HTTP.open(url(server, "/small.f3"), sign: sign)
    assert_receive {:seen, headers}
    assert header(headers, "x-signed") == "yes"
    assert {:ok, _} = F3.IO.HTTP.close(state)
    stop_server(server)
  end

  test "short, oversized, and failed responses use the documented categories" do
    server =
      range_server(fn
        %{method: "HEAD", path: "/short"} ->
          {200, [{"content-length", "8"}], ""}

        %{path: "/short"} ->
          {206, [{"content-length", "1"}], "x"}

        %{method: "HEAD", path: "/fat"} ->
          {200, [{"content-length", "8"}], ""}

        %{path: "/fat"} ->
          {206, [{"content-length", "8"}], "01234567"}

        %{path: "/boom"} ->
          {500, [{"content-length", "4"}], "boom"}

        %{method: "HEAD", path: "/nolength"} ->
          {200, [], ""}

        _request ->
          {400, [], ""}
      end)

    assert {:ok, short} = F3.IO.HTTP.open(url(server, "/short"))

    assert {:error, %F3.Error{category: :truncated}} = F3.IO.HTTP.pread(short, 0, 4)

    assert {:ok, fat} = F3.IO.HTTP.open(url(server, "/fat"))

    assert {:error, %F3.Error{category: :resource_limit}} = F3.IO.HTTP.pread(fat, 0, 4)

    assert {:error, %F3.Error{category: :io}} = F3.IO.HTTP.open(url(server, "/boom"))
    assert {:error, %F3.Error{category: :io}} = F3.IO.HTTP.open(url(server, "/nolength"))
    stop_server(server)
  end

  test "a timeout is a resource limit" do
    server =
      range_server(fn _request ->
        Process.sleep(1_000)
        {200, [{"content-length", "1"}], "x"}
      end)

    assert {:error, %F3.Error{category: :resource_limit, message: "request timed out"}} =
             F3.IO.HTTP.open(url(server, "/hang"), timeout_ms: 100)

    stop_server(server)
  end

  test "invalid http arguments are invalid_argument" do
    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.IO.HTTP.open("ftp://example.test/a")

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.IO.HTTP.open("http://example.test/a", nope: true)

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.IO.HTTP.open("http://example.test/a", timeout_ms: 0)

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.IO.HTTP.open("http://example.test/a", headers: [{"x", 1}])

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.IO.HTTP.open("http://example.test/a", sign: :nope)

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.IO.HTTP.open("http://example.test/a", endpoint: "http://127.0.0.1:9")

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.open("http://example.test/a",
               source: {:http, "http://example.test/a", sign: fn _m, _u, headers -> headers end}
             )

    assert {:error, %F3.Error{category: :invalid_argument}} = F3.open("x", source: {:http, :nope})

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.open("x", source: {:http, "http://example.test", :bad})

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.open("tmp/not-written.f3", source: {:http, "http://example.test/a"})

    refute File.exists?("tmp/not-written.f3")
  end

  test "closed handles and bad pread arguments fail before a request" do
    bytes = File.read!(@fixture)
    server = range_server(fn request -> file_response(request, "/small.f3", bytes) end)
    {:ok, state} = F3.IO.HTTP.open(url(server, "/small.f3"))
    {:ok, closed} = F3.IO.HTTP.close(state)
    assert {:error, %F3.Error{category: :closed}} = F3.IO.HTTP.pread(closed, 0, 1)
    assert {:error, %F3.Error{category: :closed}} = F3.IO.HTTP.size(closed)
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.IO.HTTP.pread(state, -1, 1)
    stop_server(server)
  end

  test "sigv4 matches the published GET object example" do
    url = "https://examplebucket.s3.amazonaws.com/test.txt"

    headers = [
      {"host", "examplebucket.s3.amazonaws.com"},
      {"range", "bytes=0-9"},
      {"x-amz-content-sha256",
       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
      {"x-amz-date", "20130524T000000Z"}
    ]

    creds = %{
      region: "us-east-1",
      access_key: @access,
      secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    }

    assert {:ok, signed} =
             F3.IO.HTTP.Sign.headers(:get, url, headers, creds, {"20130524", "20130524T000000Z"})

    assert header(signed, "authorization") ==
             "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," <>
               "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date," <>
               "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"

    refute header(signed, "authorization") =~ creds.secret_key
  end

  test "a sign error is returned without the signer result's extra fields" do
    bytes = File.read!(@fixture)
    server = range_server(fn request -> file_response(request, "/small.f3", bytes) end)

    sign = fn _method, _url, _headers ->
      {:error,
       %F3.Error{
         reason: :open,
         category: :invalid_argument,
         message: "nope\n#{@secret}",
         cause: @secret,
         context: %{operation: :open, secret: @secret}
       }}
    end

    assert {:error, error} = F3.IO.HTTP.open(url(server, "/small.f3"), sign: sign)
    assert error.message == "request was rejected"
    assert error.cause == nil
    refute inspect(error) =~ @secret
    stop_server(server)
  end

  test "pread status failures and signing argument errors are categorized" do
    server =
      range_server(fn
        %{method: "HEAD", path: "/badlen"} ->
          {200, [{"content-length", "nope"}], ""}

        %{method: "HEAD"} ->
          {200, [{"content-length", "4"}], ""}

        %{path: "/redir"} ->
          {302, [{"location", "http://example.test/away"}], ""}

        %{path: "/gone"} ->
          {404, [], ""}

        %{path: "/nocl"} ->
          {206, [], "abcd"}

        %{path: "/badcl"} ->
          {206, [{"content-length", "zz"}], "abcd"}

        _request ->
          {400, [], ""}
      end)

    assert {:error, %F3.Error{category: :invalid_argument}} = F3.IO.HTTP.open(1)

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.IO.HTTP.open("http://example.test/a", headers: :bad)

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.IO.HTTP.open("http://example.test/a",
               endpoint: "ftp://files",
               bucket: "b",
               key: "k",
               region: "us-east-1",
               access_key: "a",
               secret_key: "s"
             )

    assert {:error, %F3.Error{category: :io}} = F3.IO.HTTP.open(url(server, "/badlen"))

    {:ok, redir} = F3.IO.HTTP.open(url(server, "/redir"))
    assert {:error, %F3.Error{category: :io, reason: :redirect}} = F3.IO.HTTP.pread(redir, 0, 4)
    {:ok, closed} = F3.IO.HTTP.close(redir)
    assert {:ok, ^closed} = F3.IO.HTTP.close(closed)

    {:ok, gone} = F3.IO.HTTP.open(url(server, "/gone"))
    assert {:error, %F3.Error{category: :not_found}} = F3.IO.HTTP.pread(gone, 0, 4)

    {:ok, nocl} = F3.IO.HTTP.open(url(server, "/nocl"))
    assert {:ok, "abcd"} = F3.IO.HTTP.pread(nocl, 0, 4)

    {:ok, badcl} = F3.IO.HTTP.open(url(server, "/badcl"))
    assert {:error, %F3.Error{category: :io}} = F3.IO.HTTP.pread(badcl, 0, 4)

    reject = fn
      :head, _url, headers -> {:ok, headers}
      :get, _url, _headers -> :nope
    end

    {:ok, signed} = F3.IO.HTTP.open(url(server, "/nocl"), sign: reject)
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.IO.HTTP.pread(signed, 0, 4)

    plain = fn _method, _url, _headers ->
      {:error,
       %F3.Error{reason: :open, category: :invalid_argument, message: "kept", context: %{}}}
    end

    assert {:error, %F3.Error{message: "kept"}} =
             F3.IO.HTTP.open(url(server, "/nocl"), sign: plain)

    weird = fn _method, _url, _headers ->
      {:error,
       %F3.Error{reason: :open, category: :invalid_argument, message: :nope, context: %{}}}
    end

    assert {:error, %F3.Error{message: "request was rejected"}} =
             F3.IO.HTTP.open(url(server, "/nocl"), sign: weird)

    stop_server(server)
  end

  test "sigv4 canonicalizes an empty path and a query" do
    creds = %{
      region: "us-east-1",
      access_key: @access,
      secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    }

    for url <- ["https://example.com", "https://example.com?", "https://example.com/a?b=1&c"] do
      assert {:ok, signed} =
               F3.IO.HTTP.Sign.headers(
                 :get,
                 url,
                 [{"range", "bytes=0-1"}],
                 creds,
                 {"20130524", "20130524T000000Z"}
               )

      assert header(signed, "authorization") =~ "AWS4-HMAC-SHA256"
      refute header(signed, "authorization") =~ creds.secret_key
    end
  end

  defp self_or(parent) when is_pid(parent), do: parent

  defp read_all(state, size) do
    Enum.reduce(0..(div(size, 64) + 1), {<<>>, 0}, fn _step, {acc, offset} ->
      {:ok, chunk} = F3.IO.HTTP.pread(state, offset, 64)
      {acc <> chunk, offset + byte_size(chunk)}
    end)
    |> elem(0)
  end

  defp file_response(%{method: "HEAD"}, path, bytes) do
    {200, [{"content-length", Integer.to_string(byte_size(bytes))}], "", path}
  end

  defp file_response(%{method: "GET", path: path, headers: headers}, path, bytes) do
    {start, last} = range(headers, byte_size(bytes))
    slice = binary_part(bytes, start, last - start + 1)
    length = Integer.to_string(byte_size(slice))

    {206,
     [
       {"content-length", length},
       {"content-range", "bytes #{start}-#{last}/#{byte_size(bytes)}"}
     ], slice, path}
  end

  defp file_response(_request, _path, _bytes), do: {404, [], ""}

  defp range(headers, size) do
    case header(headers, "range") do
      "bytes=" <> spec ->
        [first, last] = String.split(spec, "-")
        {String.to_integer(first), min(String.to_integer(last), size - 1)}

      _other ->
        {0, size - 1}
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp url(server, path), do: "http://127.0.0.1:#{server.port}#{path}"

  defp range_server(fun) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    parent = self()
    pid = spawn_link(fn -> accept_loop(listen, fun, parent) end)
    %{listen: listen, port: port, pid: pid}
  end

  defp stop_server(%{listen: listen, pid: pid}) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
    :gen_tcp.close(listen)
  end

  defp accept_loop(listen, fun, parent) do
    case :gen_tcp.accept(listen, 200) do
      {:ok, socket} ->
        serve(socket, fun, parent)
        accept_loop(listen, fun, parent)

      {:error, _reason} ->
        accept_loop(listen, fun, parent)
    end
  end

  defp serve(socket, fun, parent) do
    with {:ok, raw} <- read_request(socket, "") do
      request = parse_request(raw, parent)
      send(parent, {:http_request, request})
      {status, headers, body, _path} = normalize(fun.(request))
      :gen_tcp.send(socket, response(status, headers, body))
    end

    :gen_tcp.close(socket)
  end

  defp normalize({status, headers, body}), do: {status, headers, body, nil}
  defp normalize({status, headers, body, path}), do: {status, headers, body, path}

  defp read_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, data} -> read_request(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_request(raw, parent) do
    [head | _rest] = String.split(raw, "\r\n\r\n", parts: 2)
    [request_line | lines] = String.split(head, "\r\n")
    [method, path | _version] = String.split(request_line, " ")

    headers =
      Enum.map(lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {name, String.trim(value)}
      end)

    %{method: method, path: path, headers: headers, parent: parent}
  end

  defp response(status, headers, body) do
    lines =
      Enum.map(headers, fn {name, value} ->
        "#{name}: #{value}\r\n"
      end)

    [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason(status),
      "\r\n",
      lines,
      "connection: close\r\n\r\n",
      body
    ]
  end

  defp reason(200), do: "OK"
  defp reason(206), do: "Partial Content"
  defp reason(302), do: "Found"
  defp reason(404), do: "Not Found"
  defp reason(500), do: "Error"
  defp reason(_status), do: "Error"
end

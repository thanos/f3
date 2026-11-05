defmodule F3.Registry do
  @moduledoc """
  Bounded ETS table of `F3.Extension` modules.

  The caller starts the process and passes that pid as `extensions:` to
  `F3.read/2` or `F3.stream/2`. Two reads share registrations only when they
  are given the same pid. The key is the footer encoding and its
  `%{major, minor, patch}` version. `wasm_id` is part of the key only when
  the registration sets it.

  The table is public so a read can look up a module without taking the
  owner lock. `register/3` and `unregister/2` go through the owner. A full
  table returns `:resource_limit`. The default capacity is 64. The ceiling
  is 1024.
  """

  use GenServer

  alias F3.Error

  @default_capacity 64
  @max_capacity 1024

  @type key :: %{
          required(:encoding) => atom(),
          required(:version) => %{
            major: non_neg_integer(),
            minor: non_neg_integer(),
            patch: non_neg_integer()
          },
          optional(:wasm_id) => non_neg_integer() | nil
        }

  @doc """
  Starts an empty registry. `capacity:` defaults to #{@default_capacity}.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, Error.t()}
  def start_link(opts \\ []) when is_list(opts) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    if is_integer(capacity) and capacity >= 1 and capacity <= @max_capacity do
      GenServer.start_link(__MODULE__, capacity)
    else
      {:error, Error.invalid_argument(:registry, "capacity must be from 1 to #{@max_capacity}")}
    end
  end

  @doc """
  Registers `module` under the footer key. Replacing an existing key does
  not consume another slot.
  """
  @spec register(pid(), key(), module()) :: :ok | {:error, Error.t()}
  def register(pid, key, module) when is_pid(pid) and is_atom(module) do
    GenServer.call(pid, {:register, key, module})
  end

  def register(_pid, _key, _module) do
    {:error, Error.invalid_argument(:registry, "register expects a pid, a key, and a module")}
  end

  @doc """
  Removes one key. A missing key is `:ok`.
  """
  @spec unregister(pid(), key()) :: :ok | {:error, Error.t()}
  def unregister(pid, key) when is_pid(pid) do
    GenServer.call(pid, {:unregister, key})
  end

  @doc """
  Finds a module for one encoding unit. `:error` when the pid is dead, the
  table is gone, or nothing matches. A registration that set `wasm_id`
  matches only that id. A registration that omitted it matches any id,
  after the exact id is tried.
  """
  @spec lookup(pid() | nil, map()) :: {:ok, module()} | :error
  def lookup(nil, _metadata), do: :error

  def lookup(pid, metadata) when is_pid(pid) and is_map(metadata) do
    case index_lookup(pid) do
      nil ->
        :error

      table ->
        version = Map.get(metadata, :version)
        encoding = Map.get(metadata, :encoding)
        wasm_id = Map.get(metadata, :wasm_id)

        case :ets.lookup(table, entry_key(encoding, version, wasm_id)) do
          [{_key, module}] ->
            {:ok, module}

          [] ->
            wildcard(table, encoding, version)
        end
    end
  catch
    :error, :badarg -> :error
  end

  def lookup(_pid, _metadata), do: :error

  @impl true
  def init(capacity) do
    table = :ets.new(:f3_registry, [:set, :public, {:read_concurrency, true}])
    ensure_index()
    :ets.insert(:f3_registry_index, {self(), table})
    {:ok, %{table: table, capacity: capacity}}
  end

  @impl true
  def handle_call({:register, key, module}, _from, state) do
    case normalize(key) do
      {:ok, entry} ->
        size = :ets.info(state.table, :size)
        exists = :ets.member(state.table, entry)

        if not exists and size >= state.capacity do
          {:reply, {:error, Error.resource_limit(:registry, "extension registry is full")}, state}
        else
          :ets.insert(state.table, {entry, module})
          {:reply, :ok, state}
        end

      :error ->
        {:reply,
         {:error, Error.invalid_argument(:registry, "registration key is not a footer encoding")},
         state}
    end
  end

  def handle_call({:unregister, key}, _from, state) do
    case normalize(key) do
      {:ok, entry} ->
        :ets.delete(state.table, entry)
        {:reply, :ok, state}

      :error ->
        {:reply,
         {:error, Error.invalid_argument(:registry, "registration key is not a footer encoding")},
         state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    drop_ets(fn -> :ets.delete(:f3_registry_index, self()) end)
    drop_ets(fn -> :ets.delete(state.table) end)
    :ok
  end

  defp normalize(%{encoding: encoding, version: version} = key) when is_atom(encoding) do
    with {:ok, version} <- version_key(version),
         {:ok, wasm_id} <- wasm_key(Map.get(key, :wasm_id)) do
      {:ok, entry_key(encoding, version, wasm_id)}
    end
  end

  defp normalize(_key), do: :error

  defp version_key(%{major: major, minor: minor, patch: patch})
       when is_integer(major) and major >= 0 and is_integer(minor) and minor >= 0 and
              is_integer(patch) and patch >= 0 do
    {:ok, %{major: major, minor: minor, patch: patch}}
  end

  defp version_key(_version), do: :error

  defp wasm_key(nil), do: {:ok, nil}
  defp wasm_key(id) when is_integer(id) and id >= 0, do: {:ok, id}
  defp wasm_key(_id), do: :error

  defp wildcard(table, encoding, version) do
    case :ets.lookup(table, entry_key(encoding, version, nil)) do
      [{_key, module}] -> {:ok, module}
      [] -> :error
    end
  end

  defp entry_key(encoding, %{major: major, minor: minor, patch: patch}, wasm_id) do
    {encoding, major, minor, patch, wasm_id}
  end

  defp index_lookup(pid) do
    case :ets.whereis(:f3_registry_index) do
      :undefined ->
        nil

      _tid ->
        case :ets.lookup(:f3_registry_index, pid) do
          [{^pid, table}] -> table
          [] -> nil
        end
    end
  end

  defp ensure_index do
    case :ets.whereis(:f3_registry_index) do
      :undefined ->
        try do
          :ets.new(:f3_registry_index, [:named_table, :public, :set])
        catch
          :error, :badarg -> :f3_registry_index
        end

      tid ->
        tid
    end
  end

  defp drop_ets(fun) do
    fun.()
  catch
    :error, :badarg -> :ok
  end
end

defmodule JSONPatch.Path do
  @moduledoc false

  @doc """
  Splits a JSON Pointer (RFC 6901) path into its components.
  Path keys are converted to integers if possible, otherwise
  remaining strings.

  Example:

      iex> JSONPatch.Path.split_path("/a/b/22/c")
      ["a", "b", 22, "c"]

      iex> JSONPatch.Path.split_path("")
      []
  """
  @spec split_path(String.t()) :: [String.t() | non_neg_integer]
  def split_path(path)

  def split_path(nil), do: {:error, :path_error, "null is not valid value for 'path'"}

  def split_path(""), do: []

  def split_path(path) do
    case path do
      "/" <> _remainder ->
        path
        |> String.replace_leading("/", "")
        |> String.split("/")
        |> Enum.map(&convert_number/1)

      _otherwise ->
        {:error, :path_error, "JSON Pointer should start with a slash"}
    end
  end

  ## Converts string-formatted integers back to integers.
  ## Returns other inputs unchanged.
  defp convert_number("0"), do: 0

  defp convert_number(str) do
    # array indices with leading zeros are invalid, so don't convert them
    if String.match?(str, ~r"^[1-9]+[0-9]*$") do
      String.to_integer(str)
    else
      # ~ escape handling per RFC 6901
      str |> String.replace("~1", "/") |> String.replace("~0", "~")
    end
  end

  @doc """
  Traverses `data` according to the given `path`, returning `{:ok, value}`
  if a value was found at that path, or `{:error, reason}` otherwise.
  """
  @spec get_value_at_path(JSONPatch.json_document(), String.t()) :: JSONPatch.return_value()
  def get_value_at_path(data, path) when is_binary(path) do
    value_at_path(data, split_path(path))
  end

  @spec value_at_path(JSONPatch.json_document(), [String.t()]) :: JSONPatch.return_value()
  defp value_at_path(data, []), do: {:ok, data}

  defp value_at_path(data, [key | rest]) when is_number(key) and is_list(data) do
    case Enum.at(data, key, :missing) do
      :missing -> {:error, :path_error, "out-of-bounds index #{key}"}
      value -> value_at_path(value, rest)
    end
  end

  defp value_at_path(data, ["-" | rest]) when is_list(data) do
    case Enum.count(data) do
      0 -> {:error, :path_error, "can't use index '-' with empty array"}
      c -> value_at_path(data, [c - 1 | rest])
    end
  end

  defp value_at_path(data, [key | _rest]) when is_list(data) do
    {:error, :path_error, "can't index into array with string #{key}"}
  end

  defp value_at_path(%{} = data, [key | rest]) do
    case Map.get(data, to_string(key), :missing) do
      :missing -> {:error, :path_error, "missing key #{key}"}
      value -> value_at_path(value, rest)
    end
  end

  defp value_at_path(data, _) do
    {:error, :path_error, "can't index into value #{data}"}
  end

  @doc """
  Attempts to remove the value at the given path.  Returns the updated
  `{:ok, data}`, otherwise `{:error, reason}.

  Examples:

      iex> %{"a" => %{"b" => 1, "c" => 2}} |> JSONPatch.Path.remove_value_at_path("/a/b")
      {:ok, %{"a" => %{"c" => 2}}}

      iex> %{"a" => [1, 2, 3, 4]} |> JSONPatch.Path.remove_value_at_path("/a/2")
      {:ok, %{"a" => [1, 2, 4]}}

      iex> %{"a" => [1, 2, %{"c" => 3}, 4]} |> JSONPatch.Path.remove_value_at_path("/a/2/c")
      {:ok, %{"a" => [1, 2, %{}, 4]}}
  """
  @spec remove_value_at_path(JSONPatch.json_document(), String.t()) :: JSONPatch.return_value()
  def remove_value_at_path(data, path) do
    remove_at_path(data, split_path(path))
  end

  @spec remove_at_path(JSONPatch.json_document(), [String.t()]) ::
          JSONPatch.return_value() | {:ok, :removed}
  defp remove_at_path(_data, []), do: {:ok, :removed}

  defp remove_at_path(data, [key | rest]) when is_list(data) and is_number(key) do
    if key >= Enum.count(data) do
      {:error, :path_error, "out-of-bounds index #{key}"}
    else
      case remove_at_path(Enum.at(data, key), rest) do
        {:ok, :removed} -> {:ok, List.delete_at(data, key)}
        {:ok, value} -> {:ok, List.replace_at(data, key, value)}
        err -> err
      end
    end
  end

  defp remove_at_path(data, ["-" | rest]) when is_list(data) do
    case Enum.count(data) do
      0 -> {:error, :path_error, "can't use index '-' with empty array"}
      c -> remove_at_path(data, [c - 1 | rest])
    end
  end

  defp remove_at_path(data, [key | _rest]) when is_list(data) do
    {:error, :path_error, "can't index into array with string #{key}"}
  end

  defp remove_at_path(%{} = data, [key | rest]) do
    keystr = to_string(key)

    if Map.has_key?(data, keystr) do
      case remove_at_path(data[keystr], rest) do
        {:ok, :removed} -> {:ok, Map.delete(data, keystr)}
        {:ok, value} -> {:ok, Map.put(data, keystr, value)}
        err -> err
      end
    else
      {:error, :path_error, "missing key #{keystr}"}
    end
  end

  defp remove_at_path(data, _) do
    {:error, :path_error, "can't index into value #{data}"}
  end

  @doc """
  Attempts to add the value at the given path.  Returns the updated
  `{:ok, data}`, otherwise `{:error, reason}.

  Examples:

      iex> %{"a" => %{"c" => 2}} |> JSONPatch.Path.add_value_at_path("/a/b", 1)
      {:ok, %{"a" => %{"c" => 2, "b" => 1}}}

      iex> %{"a" => [1, 2, 3, 4]} |> JSONPatch.Path.add_value_at_path("/a/2", "woot")
      {:ok, %{"a" => [1, 2, "woot", 3, 4]}}
  """
  @spec add_value_at_path(JSONPatch.json_document(), String.t(), JSONPatch.json_encodable()) ::
          JSONPatch.return_value()
  def add_value_at_path(data, path, value) do
    add_at_path(data, split_path(path), value)
  end

  @spec add_at_path(JSONPatch.json_document(), [String.t()], JSONPatch.json_encodable()) ::
          JSONPatch.return_value()
  defp add_at_path(_data, [], value), do: {:ok, value}

  defp add_at_path(data, [key | rest], value) when is_list(data) and is_number(key) do
    cond do
      key > Enum.count(data) ->
        {:error, :path_error, "out-of-bounds index #{key}"}

      rest == [] ->
        {:ok, List.insert_at(data, key, value)}

      true ->
        case add_at_path(Enum.at(data, key), rest, value) do
          {:ok, v} ->
            {:ok, List.replace_at(data, key, v)}

          err ->
            err
        end
    end
  end

  defp add_at_path(data, ["-"], value) when is_list(data) do
    {:ok, data ++ [value]}
  end

  defp add_at_path(data, [key | _rest], _value) when is_list(data) do
    {:error, :path_error, "can't index into array with string #{key}"}
  end

  defp add_at_path(%{} = data, [key | rest], value) do
    keystr = to_string(key)

    if rest == [] do
      {:ok, Map.put(data, keystr, value)}
    else
      case add_at_path(data[keystr], rest, value) do
        {:ok, v} ->
          {:ok, Map.put(data, keystr, v)}

        err ->
          err
      end
    end
  end

  defp add_at_path(data, _, _) do
    {:error, :path_error, "can't index into value #{inspect(data)}"}
  end
end

defmodule JSONPatch do
  @moduledoc """
  JSONPatch is an Elixir implementation of the JSON Patch format,
  described in [RFC 6902](http://tools.ietf.org/html/rfc6902).

  ## Examples

      iex> JSONPatch.patch(%{"a" => 1}, [
      ...>   %{"op" => "add", "path" => "/b", "value" => %{"c" => true}},
      ...>   %{"op" => "test", "path" => "/a", "value" => 1},
      ...>   %{"op" => "move", "from" => "/b/c", "path" => "/c"}
      ...> ])
      {:ok, %{"a" => 1, "b" => %{}, "c" => true}}

      iex> JSONPatch.patch(%{"a" => 22}, [
      ...>   %{"op" => "add", "path" => "/b", "value" => %{"c" => true}},
      ...>   %{"op" => "test", "path" => "/a", "value" => 1},
      ...>   %{"op" => "move", "from" => "/b/c", "path" => "/c"}
      ...> ])
      {:error, :test_failed, ~s|test failed (patches[1], %{"op" => "test", "path" => "/a", "value" => 1})|}

  ## Installation

      # mix.exs
      def deps do
        [
          {:json_patch, "~> 0.8.0"}
        ]
      end

  """

  alias JSONPatch.Path

  @type json_document :: json_object | json_array

  @type json_object :: %{String.t() => json_encodable}

  @type json_array :: [json_encodable]

  @type json_encodable ::
          json_object
          | json_array
          | String.t()
          | number
          | true
          | false
          | nil

  @type patches :: [patch]

  @type patch :: map

  @type return_value :: {:ok, json_encodable} | {:error, error_type, String.t()}

  @type error_type :: :test_failed | :syntax_error | :path_error

  @type status_code :: non_neg_integer

  @doc """
  Applies JSON Patch (RFC 6902) patches to the given JSON document.
  Returns `{:ok, patched_map}` or `{:error, error_type, description}`.

  Examples:

      iex> %{"foo" => "bar"} |> JSONPatch.patch([%{"op" => "replace", "path" => "/foo", "value" => 2}])
      {:ok, %{"foo" => 2}}

      iex> %{"foo" => "bar"} |> JSONPatch.patch([%{"op" => "test", "path" => "/foo", "value" => 2}])
      {:error, :test_failed, ~s|test failed (patches[0], %{"op" => "test", "path" => "/foo", "value" => 2})|}

      iex> %{"foo" => "bar"} |> JSONPatch.patch([%{"op" => "remove", "path" => "/foo"}])
      {:ok, %{}}
  """
  @spec patch(json_document, patches, non_neg_integer) :: return_value
  def patch(doc, patches) do
    patch(doc, patches, 0)
  end

  defp patch(doc, [], _), do: {:ok, doc}

  defp patch(doc, [p | rest], i) do
    case apply_single_patch(doc, p) do
      {:ok, newdoc} ->
        patch(newdoc, rest, i + 1)

      {:error, type, desc} ->
        {:error, type, "#{desc} (patches[#{i}], #{inspect(p)})"}
    end
  end

  @doc """
  Converts a `t:return_value/0` or `t:error_type/0' to an HTTP status code.

  The HTTP status codes emitted are:
  * 200 OK (success)
  * 400 Bad Request (the syntax of the patch was invalid)
  * 409 Conflict (a `test` operation inside the patch did not succeed)
  * 422 Unprocessble Entity (the patch refers to an invalid or nonexistent path)

  Example:

      iex> JSONPatch.patch(%{"a" => 1}, [%{"op" => "test", "path" => "/a", "value" => 1}]) |> JSONPatch.status_code
      200

      iex> JSONPatch.patch(%{"a" => 1}, [%{"op" => "test", "path" => "/a", "value" => 22}]) |> JSONPatch.status_code
      409

      iex> JSONPatch.status_code(:path_error)
      422
  """
  @spec status_code(return_value | error_type) :: status_code
  def status_code(value) do
    case value do
      {:error, type, _} -> status_code(type)
      {:ok, _} -> 200
      :test_failed -> 409
      :path_error -> 422
      :syntax_error -> 400
      _ -> 400
    end
  end

  @spec apply_single_patch(json_document, patch) :: return_value
  defp apply_single_patch(doc, patch) do
    cond do
      !Map.has_key?(patch, "op") -> {:error, :syntax_error, "missing `op`"}
      !Map.has_key?(patch, "path") -> {:error, :syntax_error, "missing `path`"}
      true -> apply_op(patch["op"], doc, patch)
    end
  end

  @spec apply_op(String.t(), json_document, patch) :: return_value
  defp apply_op("test", doc, patch) do
    if Map.has_key?(patch, "value") do
      case Path.get_value_at_path(doc, patch["path"]) do
        {:ok, path_value} ->
          if path_value == patch["value"] do
            {:ok, doc}
          else
            {:error, :test_failed, "test failed"}
          end

        err ->
          err
      end
    else
      {:error, :syntax_error, "missing `value`"}
    end
  end

  defp apply_op("remove", doc, patch) do
    Path.remove_value_at_path(doc, patch["path"])
  end

  defp apply_op("add", doc, patch) do
    if Map.has_key?(patch, "value") do
      Path.add_value_at_path(doc, patch["path"], patch["value"])
    else
      {:error, :syntax_error, "missing `value`"}
    end
  end

  defp apply_op("replace", doc, patch) do
    if Map.has_key?(patch, "value") do
      case Path.remove_value_at_path(doc, patch["path"]) do
        {:ok, data} ->
          Path.add_value_at_path(data, patch["path"], patch["value"])

        err ->
          err
      end
    else
      {:error, :syntax_error, "missing `value`"}
    end
  end

  defp apply_op("move", doc, patch) do
    with true <- Map.has_key?(patch, "from"),
         {:ok, value} <- Path.get_value_at_path(doc, patch["from"]),
         {:ok, data} <- Path.remove_value_at_path(doc, patch["from"]) do
      Path.add_value_at_path(data, patch["path"], value)
    else
      false -> {:error, :syntax_error, "missing `from`"}
      err -> err
    end
  end

  defp apply_op("copy", doc, patch) do
    if Map.has_key?(patch, "from") do
      case Path.get_value_at_path(doc, patch["from"]) do
        {:ok, value} ->
          Path.add_value_at_path(doc, patch["path"], value)

        err ->
          err
      end
    else
      {:error, :syntax_error, "missing `from`"}
    end
  end

  # Operation outside the RFC that allows to change variable sized arrays.
  # The `path` parameter must point to the array that will be iterated.
  # Must have a `sub_operations` parameter with a list of operations that will be executed
  # once for each item in the array
  # To allow addresing the array, there is a pattern in the `path` and `from`
  # that will be replaced with the index in the array, by default it's `$?`
  defp apply_op("iterate", doc, %{"sub_operations" => sub_operations} = patch)
       when is_list(sub_operations) do
    with {:ok, path_list} <- Path.get_value_at_path(doc, patch["path"]),
         replacement_character <- Map.get(patch, "replacement_character", "$?") do
      Enum.reduce_while(0..(length(path_list) - 1), {:ok, doc}, fn index, {:ok, updated_doc} ->
        sub_operations
        |> replace_characters(replacement_character, index)
        |> then(fn updated_sub_operations ->
          patch(updated_doc, updated_sub_operations)
        end)
        |> case do
          {:ok, finished_doc} -> {:cont, {:ok, finished_doc}}
          {:error, _kind, _explanation} = error -> {:halt, error}
        end
      end)
    end
  end

  defp apply_op("iterate", _doc, _patch) do
    {:error, :syntax_error, "missing `sub_operations`"}
  end

  defp apply_op("join", doc, %{"from" => from, "path" => path} = patch) when is_list(from) do
    with {:ok, values} <- get_values(doc, from),
         joiner <- Map.get(patch, "joiner", ",") do
      Path.add_value_at_path(doc, path, Enum.join(values, joiner))
    end
  end

  defp apply_op("join", _doc, _patch) do
    {:error, :syntax_error, "missing `from`"}
  end

  defp apply_op(op, _doc, _patch) do
    {:error, :syntax_error, "not implemented: #{op}"}
  end

  defp replace_characters(operations, replacement_character, index) do
    Enum.map(operations, fn operation ->
      operation
      |> Map.update("path", nil, fn
        path when is_binary(path) ->
          String.replace(path, replacement_character, to_string(index))

        other ->
          other
      end)
      |> Map.update("from", nil, fn
        from when is_binary(from) ->
          String.replace(from, replacement_character, to_string(index))

        other ->
          other
      end)
      |> Map.update("sub_operations", nil, fn
        sub_operations when is_list(sub_operations) ->
          replace_characters(sub_operations, replacement_character, index)

        other ->
          other
      end)
    end)
  end

  defp get_values(doc, from) do
    from
    |> Enum.reduce_while([], fn from_item, accumulator ->
      doc
      |> Path.get_value_at_path(from_item)
      |> case do
        {:ok, value} -> {:cont, [value | accumulator]}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _kind, _message} = error -> error
      list when is_list(list) -> {:ok, Enum.reverse(list)}
    end
  end
end

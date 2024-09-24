defmodule JSONPatchTest do
  use ExUnit.Case, async: true

  if System.get_env("SKIP_TEST_SUITE") do
    IO.puts("Skipping test suite.")
  else
    doctest JSONPatch
    doctest JSONPatch.Path

    @test_suites [
      "local_test_suite.json",
      "json-patch-tests/tests.json",
      "json-patch-tests/spec_tests.json"
    ]
    for filename <- @test_suites do
      case File.read("./test/#{filename}") do
        {:ok, text} ->
          tests = Jason.decode!(text)

          for {t, i} <- Enum.with_index(tests) do
            test "#{filename}[#{i}] (#{t["comment"]})" do
              tt = unquote(Macro.escape(t))

              cond do
                tt["disabled"] ->
                  :skipped

                tt["error"] ->
                  assert({:error, type, desc} = JSONPatch.patch(tt["doc"], tt["patch"]))

                  if tt["error_type"] do
                    assert(String.to_existing_atom(tt["error_type"]) == type, desc)
                  end

                tt["expected"] ->
                  assert({:ok, tt["expected"]} == JSONPatch.patch(tt["doc"], tt["patch"]))

                true ->
                  assert(JSONPatch.patch(tt["doc"], tt["patch"]))
              end
            end
          end

        _ ->
          IO.puts(
            "Test suite #{filename} not present -- run `mix download-tests` to download test suite"
          )
      end
    end

    ## Outside of spec tests

    describe "iterate" do
      test "maps over an array" do
        document = %{
          "array" => [1, 2, 3],
          "second_array" => []
        }

        operations =
          [
            %{
              "op" => "iterate",
              "path" => "/array",
              "sub_operations" => [
                %{"op" => "add", "path" => "/second_array/$?", "value" => "banana"}
              ]
            }
          ]

        assert {:ok, %{"array" => [1, 2, 3], "second_array" => ["banana", "banana", "banana"]}} ==
                 JSONPatch.patch(document, operations)
      end

      test "allows removal of the iterated array" do
        document = %{
          "array" => [
            %{"first" => "ba", "second" => "na", "third" => "na"},
            %{"first" => "pa", "second" => "pa", "third" => "ya"},
            %{"first" => "po", "second" => "ta", "third" => "to"}
          ]
        }

        operations =
          [
            %{
              "op" => "iterate",
              "path" => "/array",
              "sub_operations" => [
                %{"op" => "remove", "path" => "/array/$?/first"}
              ]
            }
          ]

        assert {:ok,
                %{
                  "array" => [
                    %{"second" => "na", "third" => "na"},
                    %{"second" => "pa", "third" => "ya"},
                    %{"second" => "ta", "third" => "to"}
                  ]
                }} ==
                 JSONPatch.patch(document, operations)
      end

      test "allows for a custom replacement character" do
        document = %{
          "array" => [1, 2, 3],
          "second_array" => []
        }

        operations =
          [
            %{
              "op" => "iterate",
              "path" => "/array",
              "replacement_character" => "*",
              "sub_operations" => [
                %{"op" => "add", "path" => "/second_array/*", "value" => "banana"}
              ]
            }
          ]

        assert {:ok, %{"array" => [1, 2, 3], "second_array" => ["banana", "banana", "banana"]}} ==
                 JSONPatch.patch(document, operations)
      end

      test "allows nested iterations" do
        document = %{
          "array" => [[1, 2, 3], [4, 5, 6], [7, 8, 9]],
          "second_array" => [[], [], []]
        }

        operations =
          [
            %{
              "op" => "iterate",
              "path" => "/array",
              "replacement_character" => "$1",
              "sub_operations" => [
                %{
                  "op" => "iterate",
                  "path" => "/array/$1",
                  "replacement_character" => "$2",
                  "sub_operations" => [
                    %{"op" => "add", "path" => "/second_array/$1/$2", "value" => "banana"}
                  ]
                }
              ]
            }
          ]

        assert {:ok,
                %{
                  "array" => [[1, 2, 3], [4, 5, 6], [7, 8, 9]],
                  "second_array" => [
                    ["banana", "banana", "banana"],
                    ["banana", "banana", "banana"],
                    ["banana", "banana", "banana"]
                  ]
                }} ==
                 JSONPatch.patch(document, operations)
      end

      test "fails if no sub operations are defined" do
        document = %{
          "array" => [1, 2, 3],
          "second_array" => []
        }

        operations =
          [
            %{
              "op" => "iterate",
              "path" => "/array"
            }
          ]

        assert {:error, :syntax_error,
                "missing `sub_operations` (patches[0], %{\"op\" => \"iterate\", \"path\" => \"/array\"})"} ==
                 JSONPatch.patch(document, operations)
      end
    end

    describe "join" do
      test "joins multiples paths into one value" do
        document = %{
          "first" => "ba",
          "second" => "na",
          "third" => "na"
        }

        operations =
          [
            %{
              "op" => "join",
              "from" => ["/first", "/second", "/third"],
              "path" => "/joined"
            }
          ]

        assert {:ok,
                %{"first" => "ba", "joined" => "ba,na,na", "second" => "na", "third" => "na"}} ==
                 JSONPatch.patch(document, operations)
      end

      test "allows custom joiners" do
        document = %{
          "first" => "ba",
          "second" => "na",
          "third" => "na"
        }

        operations =
          [
            %{
              "op" => "join",
              "from" => ["/first", "/second", "/third"],
              "path" => "/joined",
              "joiner" => ""
            }
          ]

        assert {:ok, %{"first" => "ba", "joined" => "banana", "second" => "na", "third" => "na"}} ==
                 JSONPatch.patch(document, operations)
      end

      test "validates from parameter" do
        document = %{
          "first" => "ba",
          "second" => "na",
          "third" => "na"
        }

        operations =
          [
            %{
              "op" => "join",
              "path" => "/joined"
            }
          ]

        assert {:error, :syntax_error,
                "missing `from` (patches[0], %{\"op\" => \"join\", \"path\" => \"/joined\"})"} ==
                 JSONPatch.patch(document, operations)
      end
    end
  end
end

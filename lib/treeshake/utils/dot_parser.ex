defmodule Treeshake.Utils.DotParser do
  @moduledoc """
  Parses the DOT-format call graph produced by `dialyzer --callgraph <file>`.

  Dialyzer writes each edge as:

      "{module,function,arity}" -> "{other_module,other_fn,arity}";

  The node labels are Erlang term representations of MFA tuples, enclosed in
  double quotes. This module extracts those edge pairs and parses each label
  back into a proper `{module, function, arity}` tuple using Erlang's own
  scanner and parser, which correctly handles quoted atom names such as
  `'Elixir.MyModule'`.
  """

  @type mfa_tuple :: {atom(), atom(), non_neg_integer()}
  @type graph :: %{mfa_tuple() => [mfa_tuple()]}

  @doc """
  Parse a dialyzer DOT file and return an adjacency map.

  Returns `{:ok, graph}` where `graph` maps each caller MFA to the list of
  MFAs it directly calls. Edges whose labels cannot be parsed are silently
  dropped.
  """
  @spec parse_file(String.t()) :: {:ok, graph()} | {:error, term()}
  def parse_file(path) do
    with {:ok, content} <- File.read(path) do
      parse_content(content)
    end
  end

  @doc """
  Parse DOT content from a string and return an adjacency map.
  """
  @spec parse_content(String.t()) :: graph()
  def parse_content(content) do
    content
    |> extract_edge_strings()
    |> Enum.flat_map(fn {from_str, to_str} ->
      with {:ok, from} <- parse_mfa(from_str),
           {:ok, to} <- parse_mfa(to_str) do
        [{from, to}]
      else
        _ -> []
      end
    end)
    |> Enum.reduce(%{}, fn {from, to}, acc ->
      Map.update(acc, from, [to], &[to | &1])
    end)
  end

  @doc """
  Parse a single MFA label string such as `"{module,function,2}"` or
  `"{'Elixir.MyModule',some_fn,1}"` into a `{module, function, arity}` tuple.
  """
  @spec parse_mfa(String.t()) :: {:ok, mfa_tuple()} | :error
  def parse_mfa(str) do
    # Erlang's erl_scan/erl_parse require the input to end with a full stop.
    charlist = String.to_charlist(str <> ".")

    with {:ok, tokens, _} <- :erl_scan.string(charlist),
         {:ok, term} <- :erl_parse.parse_term(tokens),
         true <- valid_mfa?(term) do
      {:ok, term}
    else
      _ -> :error
    end
  end

  # ---- private ----

  # Extract all "..." -> "..." pairs from the DOT source.
  # Handles both plain `"A" -> "B";` and attributed `"A" -> "B" [...];` edges.
  @spec extract_edge_strings(String.t()) :: [{String.t(), String.t()}]
  defp extract_edge_strings(content) do
    ~r/"([^"]+)"\s*->\s*"([^"]+)"/
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.map(fn [from, to] -> {from, to} end)
  end

  defp valid_mfa?({m, f, a}) when is_atom(m) and is_atom(f) and is_integer(a) and a >= 0,
    do: true

  defp valid_mfa?(_), do: false
end

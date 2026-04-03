defmodule Treeshake.Utils.BeamAnalyzer do
  @moduledoc """
  Analyzes the output of `Treeshake.Utils.BeamReader.read/2`, resolving the
  call-graph through private functions so callers can reason about public-function
  boundaries without tracking private implementation details themselves.
  """

  alias Treeshake.Utils.BeamReader
  alias Treeshake.Utils.BeamReader.FunctionInfo

  defmodule PublicFunctionInfo do
    @moduledoc false
    defstruct [:calls, :potential_modules, :matching_terms]
  end

  @type name_arity :: {atom(), non_neg_integer()}

  @type analysis :: %{
          required(:module) => atom(),
          required(:public_functions) => %{name_arity() => PublicFunctionInfo.t()},
          required(:private_functions) => %{name_arity() => [name_arity()]},
          optional(:callbacks) => [name_arity()]
        }

  @doc """
  Analyzes the module info returned by `Treeshake.Utils.BeamReader.read/2`.

  Returns a map with:
    * `:public_functions` — map from `{name, arity}` to a `PublicFunctionInfo`
      whose `:calls`, `:potential_modules`, and `:matching_terms` are expanded
      to include data from every private function transitively called
    * `:private_functions` — map from `{name, arity}` to the list of public
      `{name, arity}` pairs that transitively call that private function

  The `:callbacks` key is preserved if present in the input.
  """
  @spec analyze(BeamReader.module_info()) :: analysis()
  def analyze(%{module: module, functions: functions} = module_info) do
    {pub_fns, priv_fns} = Enum.split_with(functions, & &1.public)

    priv_index =
      Map.new(priv_fns, fn %FunctionInfo{name: name, arity: arity} = fn_info ->
        {{name, arity}, fn_info}
      end)

    # Expand each public function, yielding {pub_key, pub_info, reachable_private_keys}.
    expansions =
      Enum.map(pub_fns, fn pub_fn ->
        reachable = reachable_privates(pub_fn, priv_index)
        all_fns = [pub_fn | Enum.map(reachable, &Map.fetch!(priv_index, &1))]

        pub_info = %PublicFunctionInfo{
          calls:
            all_fns
            |> Enum.flat_map(& &1.calls)
            |> Enum.map(&resolve_local(&1, module))
            |> Enum.reject(fn {m, name, arity} -> m == module and Map.has_key?(priv_index, {name, arity}) end)
            |> Enum.uniq(),
          potential_modules: all_fns |> Enum.flat_map(& &1.potential_modules) |> Enum.uniq(),
          matching_terms: all_fns |> Enum.flat_map(& &1.matching_terms) |> Enum.uniq()
        }

        {{pub_fn.name, pub_fn.arity}, pub_info, reachable}
      end)

    expanded_pub = Map.new(expansions, fn {pub_key, pub_info, _} -> {pub_key, pub_info} end)

    # Build reverse index: private_key -> [public caller keys], preserving pub_fns order.
    priv_caller_map =
      expansions
      |> Enum.flat_map(fn {pub_key, _, reachable} -> Enum.map(reachable, &{&1, pub_key}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    expanded_priv =
      Map.new(priv_fns, fn %FunctionInfo{name: name, arity: arity} ->
        {{name, arity}, Map.get(priv_caller_map, {name, arity}, [])}
      end)

    result = %{module: module, public_functions: expanded_pub, private_functions: expanded_priv}

    if Map.has_key?(module_info, :callbacks) do
      Map.put(result, :callbacks, module_info.callbacks)
    else
      result
    end
  end

  defp resolve_local({nil, name, arity}, module), do: {module, name, arity}
  defp resolve_local(call, _module), do: call

  # Returns the MapSet of private function keys transitively reachable from fn_info.
  defp reachable_privates(fn_info, priv_index) do
    fn_info |> priv_keys_of(priv_index) |> MapSet.to_list() |> reachable_privates(priv_index, MapSet.new())
  end

  defp reachable_privates([], _priv_index, visited), do: visited

  defp reachable_privates([key | rest], priv_index, visited) do
    if MapSet.member?(visited, key) do
      reachable_privates(rest, priv_index, visited)
    else
      new_keys = key |> then(&Map.fetch!(priv_index, &1)) |> priv_keys_of(priv_index) |> MapSet.to_list()
      reachable_privates(rest ++ new_keys, priv_index, MapSet.put(visited, key))
    end
  end

  defp priv_keys_of(%FunctionInfo{calls: calls}, priv_index) do
    for {nil, name, arity} <- calls,
        key = {name, arity},
        Map.has_key?(priv_index, key),
        into: MapSet.new(),
        do: key
  end
end

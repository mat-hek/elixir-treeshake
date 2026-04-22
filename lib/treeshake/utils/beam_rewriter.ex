defmodule Treeshake.Utils.BeamRewriter do
  @moduledoc """
  Low-level utility for rewriting compiled BEAM files by keeping only specific functions.

  Reads the abstract code chunk, strips all functions not in the keep list (along
  with their export entries and typespecs), recompiles, and returns the resulting binary.

  Raises if the BEAM cannot be read, has no `debug_info`, or fails to recompile.
  """

  @doc """
  Keep only `functions` in the BEAM file at `beam_path` and return the new binary.

  `functions` is a list of `{name, arity}` tuples identifying the functions to
  retain. All other functions, their export entries, typespecs, and inline hints
  are removed.

  Raises on any failure (missing file, no debug_info, compile error, etc.).
  """
  @spec keep_funs(Path.t(), [{atom(), non_neg_integer()}]) ::
          {binary(), [{atom(), non_neg_integer()}]}
  def keep_funs(beam_path, functions) do
    to_keep = MapSet.new(functions)

    {module, forms} = read_abstract_code!(beam_path)

    # Pre-compute which local functions will be removed so we can strip
    # references to them from record field defaults and similar attributes.
    to_remove =
      forms
      |> Enum.flat_map(fn
        {:function, _, name, arity, _} -> [{name, arity}]
        _ -> []
      end)
      |> MapSet.new()
      |> MapSet.difference(to_keep)

    {new_forms, removed} =
      Enum.flat_map_reduce(forms, [], fn
        {:function, _line, name, arity, _clauses} = form, removed ->
          if MapSet.member?(to_keep, {name, arity}),
            do: {[form], removed},
            else: {[], [{name, arity} | removed]}

        {:attribute, line, :export, exports}, removed ->
          filtered = Enum.filter(exports, fn {f, a} -> MapSet.member?(to_keep, {f, a}) end)
          {[{:attribute, line, :export, filtered}], removed}

        {:attribute, _line, :spec, {{name, arity}, _}} = form, removed ->
          if MapSet.member?(to_keep, {name, arity}), do: {[form], removed}, else: {[], removed}

        {:attribute, line, :compile, value}, removed ->
          {[{:attribute, line, :compile, filter_inline(value, to_keep)}], removed}

        {:attribute, line, :dialyzer, value}, removed ->
          case filter_dialyzer(value, to_keep) do
            nil -> {[], removed}
            filtered -> {[{:attribute, line, :dialyzer, filtered}], removed}
          end

        {:attribute, line, :deprecated, entries}, removed when is_list(entries) ->
          filtered =
            Enum.filter(entries, fn
              {f, a, _reason} -> MapSet.member?(to_keep, {f, a})
              {f, a} -> MapSet.member?(to_keep, {f, a})
              _ -> true
            end)

          {[{:attribute, line, :deprecated, filtered}], removed}

        {:attribute, line, :record, {record_name, fields}}, removed ->
          cleaned = Enum.map(fields, &strip_removed_default(&1, to_remove))
          {[{:attribute, line, :record, {record_name, cleaned}}], removed}

        form, removed ->
          {[form], removed}
      end)

    {compile!(module, new_forms, beam_path), removed}
  end

  defp read_abstract_code!(beam_path) do
    case beam_path |> String.to_charlist() |> :beam_lib.chunks([:abstract_code]) do
      {:ok, {module, [abstract_code: {:raw_abstract_v1, forms}]}} ->
        {module, forms}

      {:ok, {_module, [abstract_code: :no_abstract_code]}} ->
        raise "no abstract code (debug_info) in #{beam_path}"

      {:error, :beam_lib, reason} ->
        raise "failed to read BEAM #{beam_path}: #{inspect(reason)}"

      error ->
        raise "unexpected error reading #{beam_path}: #{inspect(error)}"
    end
  end

  defp compile!(module, forms, beam_path) do
    case :compile.forms(forms, [:return_errors, :return_warnings, :debug_info]) do
      {:ok, ^module, binary, _warnings} ->
        binary

      {:ok, other_module, _binary, _warnings} ->
        raise "module name mismatch after recompile: expected #{inspect(module)}, got #{inspect(other_module)} (#{beam_path})"

      {:error, errors, _warnings} ->
        raise "recompile failed for #{beam_path}:\n#{format_errors(errors)}"
    end
  end

  # Strip the default value from a record field if its default expression is a
  # local call to a function that was removed. Erlang lint rejects such
  # references even when no code path actually exercises the default.
  defp strip_removed_default({:typed_record_field, rf, type}, to_remove) do
    {:typed_record_field, strip_removed_default(rf, to_remove), type}
  end

  defp strip_removed_default(
         {:record_field, line, name, {:call, _, {:atom, _, f}, args}},
         to_remove
       )
       when is_atom(f) do
    if MapSet.member?(to_remove, {f, length(args)}),
      do: {:record_field, line, name},
      else: {:record_field, line, name, {:call, line, {:atom, line, f}, args}}
  end

  defp strip_removed_default(field, _to_remove), do: field

  # Returns nil to signal "drop the attribute entirely".
  defp filter_dialyzer(atom, _to_keep) when is_atom(atom), do: atom

  defp filter_dialyzer({type, {f, a}}, to_keep) do
    if MapSet.member?(to_keep, {f, a}), do: {type, {f, a}}, else: nil
  end

  defp filter_dialyzer({type, funs}, to_keep) when is_list(funs) do
    case Enum.filter(funs, fn
           {f, a} -> MapSet.member?(to_keep, {f, a})
           _ -> true
         end) do
      [] -> nil
      filtered -> {type, filtered}
    end
  end

  defp filter_dialyzer(entries, to_keep) when is_list(entries) do
    case Enum.flat_map(entries, fn entry ->
           case filter_dialyzer(entry, to_keep) do
             nil -> []
             v -> [v]
           end
         end) do
      [] -> nil
      filtered -> filtered
    end
  end

  defp filter_dialyzer(other, _to_keep), do: other

  defp filter_inline({:inline, inlines}, to_keep) when is_list(inlines) do
    {:inline, Enum.filter(inlines, fn {f, a} -> MapSet.member?(to_keep, {f, a}) end)}
  end

  defp filter_inline({:inline, {f, a}}, to_keep) do
    if MapSet.member?(to_keep, {f, a}), do: {:inline, {f, a}}, else: {:inline, []}
  end

  defp filter_inline(opts, to_keep) when is_list(opts) do
    Enum.map(opts, fn
      {:inline, inlines} when is_list(inlines) ->
        {:inline, Enum.filter(inlines, fn {f, a} -> MapSet.member?(to_keep, {f, a}) end)}

      {:inline, {f, a}} ->
        if MapSet.member?(to_keep, {f, a}), do: {:inline, {f, a}}, else: {:inline, []}

      other ->
        other
    end)
  end

  defp filter_inline(other, _to_keep), do: other

  defp format_errors(errors) do
    inspect(errors)
    # Enum.map_join(errors, "\n", fn {file, file_errors} ->
    #   Enum.map_join(file_errors, "\n", fn {line, mod, desc} ->
    #     "#{file}:#{line}: #{mod.format_error(desc)}"
    #   end)
    # end)
  end
end

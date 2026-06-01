defmodule Engine.Search.Store.State do
  import Forge.EngineApi.Messages

  alias Engine.Dispatch
  alias Engine.Search.Fuzzy
  alias Forge.Project
  alias Forge.Search.Indexer.Entry

  require Logger

  defstruct [
    :project,
    :backend,
    :create_index,
    :update_index,
    :loaded?,
    :fuzzy,
    :async_load_ref,
    :update_buffer,
    :backend_prepared?,
    :backend_index_state,
    :trace_writes_before_load?
  ]

  def new(%Project{} = project, create_index, update_index, backend) do
    %__MODULE__{
      backend: backend,
      create_index: create_index,
      project: project,
      loaded?: false,
      update_index: update_index,
      update_buffer: %{},
      fuzzy: Fuzzy.from_entries([]),
      backend_prepared?: false,
      backend_index_state: nil,
      trace_writes_before_load?: false
    }
    |> prepare_backend()
  end

  defp prepare_backend(%__MODULE__{backend_prepared?: true} = state), do: state

  defp prepare_backend(%__MODULE__{} = state) do
    case state.backend.new(state.project) do
      {:ok, backend_result} ->
        case state.backend.prepare(backend_result) do
          {:ok, index_state} when index_state in [:empty, :stale] ->
            %__MODULE__{state | backend_prepared?: true, backend_index_state: index_state}

          {:error, :not_leader} ->
            %__MODULE__{state | backend_prepared?: false, backend_index_state: :not_leader}

          error ->
            Logger.error("Could not prepare search backend due to #{inspect(error)}")
            state
        end

      error ->
        Logger.error("Could not create search backend due to #{inspect(error)}")
        state
    end
  end

  def drop(%__MODULE__{} = state) do
    state.backend.drop()
  end

  def destroy(%__MODULE__{} = state) do
    state.backend.destroy(state)
  end

  @doc """
  Asynchronously loads the search state.

  This function returns prior to creating or refreshing the index, which
  occurs in a separate process. The caller should listen for a message
  of the shape `{ref, result}`, where `ref` matches the state's
  `:async_load_ref`. Once received, that result should be passed to
  `async_load_complete/2`.
  """
  def async_load(%__MODULE__{loaded?: false, async_load_ref: nil} = state) do
    state
    |> prepare_backend()
    |> prepare_backend_async()
  end

  def async_load(%__MODULE__{} = state) do
    {:ok, state}
  end

  def async_load_complete(%__MODULE__{} = state, result) do
    new_state = %__MODULE__{state | loaded?: true, async_load_ref: nil}

    response =
      case result do
        {:create_index, result} ->
          create_index_complete(new_state, result)

        {:update_index, result} ->
          update_index_complete(new_state, result)

        :initialize_fuzzy ->
          initialize_fuzzy(new_state)
      end

    Dispatch.broadcast(project_index_ready(project: state.project))
    response
  end

  def replace(%__MODULE__{} = state, entries) do
    with :ok <- state.backend.replace_all(entries),
         :ok <- maybe_sync(state) do
      {:ok, %__MODULE__{state | fuzzy: Fuzzy.from_backend(state.backend)}}
    end
  end

  def refresh_index(%__MODULE__{} = state) do
    run_index_operation(state, state.update_index, &initialize_fuzzy/1)
  end

  def rebuild_index(%__MODULE__{} = state) do
    run_index_operation(state, state.create_index, fn state ->
      state
      |> initialize_fuzzy()
      |> drop_buffered_updates()
    end)
  end

  def exact(%__MODULE__{loaded?: false}, _subject, _constraints) do
    {:error, :loading}
  end

  def exact(%__MODULE__{} = state, subject, constraints) do
    {type, subtype} = type_and_subtype(constraints)

    backend = state.backend

    list_result(backend.find_by_subject(subject, type, subtype))
  end

  def prefix(%__MODULE__{loaded?: false}, _prefix, _constraints) do
    {:error, :loading}
  end

  def prefix(%__MODULE__{} = state, prefix, constraints) do
    {type, subtype} = type_and_subtype(constraints)

    backend = state.backend

    list_result(backend.find_by_prefix(prefix, type, subtype))
  end

  def fuzzy(%__MODULE__{loaded?: false}, _subject, _constraints) do
    {:error, :loading}
  end

  def fuzzy(%__MODULE__{} = state, subject, constraints) do
    case Fuzzy.match(state.fuzzy, subject) do
      [] ->
        {:ok, []}

      ids ->
        {type, subtype} = type_and_subtype(constraints)

        backend = state.backend

        list_result(backend.find_by_ids(ids, type, subtype))
    end
  end

  def all(%__MODULE__{loaded?: false}, _) do
    {:error, :loading}
  end

  def all(%__MODULE__{} = state, constraints) do
    {type, subtype} = type_and_subtype(constraints)

    entries =
      state.backend.reduce([], fn
        %Entry{} = entry, acc ->
          if matches_constraints?(entry, type, subtype) do
            [entry | acc]
          else
            acc
          end

        _, acc ->
          acc
      end)

    {:ok, entries}
  end

  def resolve_mfa(%__MODULE__{} = state, module, function, arity) do
    mfa = Forge.Formats.mfa(module, function, arity)

    case exact(state, mfa, subtype: :definition) do
      {:ok, [entry | _]} -> resolve_mfa_entry(entry, module, function, arity)
      _ -> {module, function, arity, false, false}
    end
  end

  defp resolve_mfa_entry(
         %Entry{type: {:function, :delegate}, metadata: %{original_mfa: original_mfa}},
         module,
         function,
         arity
       ) do
    case Forge.Code.parse_mfa(original_mfa) do
      {target_module, target_fun, target_arity} ->
        {target_module, target_fun, target_arity, true, true}

      nil ->
        {module, function, arity, true, false}
    end
  end

  defp resolve_mfa_entry(%Entry{type: {:function, _}}, module, function, arity) do
    {module, function, arity, true, false}
  end

  defp resolve_mfa_entry(%Entry{}, module, function, arity) do
    {module, function, arity, false, false}
  end

  defp list_result(result) when is_list(result), do: {:ok, result}
  defp list_result(error), do: error

  defp run_index_operation(%__MODULE__{} = state, operation, on_success)
       when is_function(operation, 2) and is_function(on_success, 1) do
    case operation.(state.project, state.backend) do
      :ok -> {:ok, on_success.(state)}
      {:error, _} = error -> error
    end
  end

  defp type_and_subtype(constraints) do
    {Keyword.get(constraints, :type, :_), Keyword.get(constraints, :subtype, :_)}
  end

  defp matches_constraints?(%Entry{type: t, subtype: st}, type, subtype) do
    (type == :_ or t == type) and (subtype == :_ or st == subtype)
  end

  def siblings(%__MODULE__{loaded?: false}, _entry) do
    {:error, :loading}
  end

  def siblings(%__MODULE__{} = state, entry) do
    backend = state.backend

    list_result(backend.siblings(entry))
  end

  def parent(%__MODULE__{loaded?: false}, _entry) do
    {:error, :loading}
  end

  def parent(%__MODULE__{} = state, entry) do
    case state.backend.parent(entry) do
      %Entry{} = entry -> {:ok, entry}
      error -> error
    end
  end

  def buffer_updates(%__MODULE__{} = state, path, entries) do
    %__MODULE__{state | update_buffer: Map.put(state.update_buffer, path, entries)}
  end

  def drop_buffered_updates(%__MODULE__{} = state) do
    %__MODULE__{state | update_buffer: %{}}
  end

  def flush_buffered_updates(%__MODULE__{update_buffer: updates} = state)
      when map_size(updates) == 0 do
    maybe_sync(state)
    {:ok, state}
  end

  def flush_buffered_updates(%__MODULE__{} = state) do
    with %__MODULE__{} = state <- flush_path_updates(state),
         :ok <- maybe_sync(state) do
      {:ok, drop_buffered_updates(state)}
    end
  end

  def update_nosync(%__MODULE__{} = state, path, entries) do
    replace_path_entries_nosync(state, path, entries)
  end

  def commit_trace(%__MODULE__{} = state, path, modules, entries)
      when is_binary(path) and is_list(modules) and is_list(entries) do
    commit_traces(state, [{path, modules, entries}])
  end

  def commit_traces(%__MODULE__{} = state, trace_updates) when is_list(trace_updates) do
    state = prepare_backend(state)
    trace_updates = normalize_trace_updates(trace_updates)

    if state.loaded? do
      replace_loaded_trace_entries_nosync(state, trace_updates)
    else
      replace_unloaded_trace_entries_nosync(state, trace_updates)
    end
  end

  defp replace_loaded_trace_entries_nosync(%__MODULE__{} = state, trace_updates) do
    with {:ok, state} <- delete_exact_module_definitions_from_other_paths(state, trace_updates) do
      Enum.reduce_while(trace_updates, {:ok, mark_trace_write(state)}, fn {path, _modules,
                                                                           entries},
                                                                          {:ok, state} ->
        case replace_path_entries_nosync(state, path, ensure_block_structure(path, entries)) do
          {:ok, state} -> {:cont, {:ok, state}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp normalize_trace_updates(trace_updates) do
    Enum.map(trace_updates, fn {path, modules, entries} ->
      {path, Enum.uniq(modules), Enum.map(entries, &put_entry_path(&1, path))}
    end)
  end

  defp trace_paths(trace_updates) do
    MapSet.new(trace_updates, fn {path, _modules, _entries} -> path end)
  end

  defp flush_path_updates(%__MODULE__{} = state) do
    Enum.reduce_while(state.update_buffer, state, fn {path, entries}, state ->
      case update_nosync(state, path, entries) do
        {:ok, new_state} ->
          {:cont, new_state}

        error ->
          {:halt, error}
      end
    end)
  end

  defp delete_exact_module_definitions_from_other_paths(%__MODULE__{} = state, trace_updates) do
    traced_paths = trace_paths(trace_updates)
    traced_modules = trace_modules(trace_updates)

    modules_by_path = exact_module_definition_paths(state, traced_modules, traced_paths)

    Enum.reduce_while(modules_by_path, {:ok, state}, fn {path, modules}, {:ok, state} ->
      case remove_exact_module_definitions_at_path(state, path, modules) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  defp remove_exact_module_definitions_at_path(%__MODULE__{} = state, path, modules)
       when is_list(modules) do
    module_atoms = MapSet.new(modules)
    module_by_name = module_by_name(modules)

    kept_entries =
      state
      |> entries_for_path(path)
      |> Enum.reject(&definition_for_exact_modules?(&1, module_atoms, module_by_name))

    replace_path_entries_nosync(
      state,
      path,
      ensure_block_structure(path, kept_entries)
    )
  end

  defp replace_path_entries_nosync(%__MODULE__{} = state, path, entries) do
    old_ids =
      state
      |> entries_for_path(path)
      |> Enum.flat_map(fn
        %Entry{id: id} when is_integer(id) -> [id]
        %Entry{} -> []
      end)

    with {:ok, _deleted_ids} <- state.backend.delete_by_path(path),
         :ok <- state.backend.insert(entries) do
      fuzzy =
        state.fuzzy
        |> Fuzzy.drop_values(old_ids)
        |> Fuzzy.add(entries)

      {:ok, %__MODULE__{state | fuzzy: fuzzy}}
    end
  catch
    :exit, {:timeout, _} ->
      Logger.warning("Timeout updating index for path: #{path}")
      {:ok, state}
  end

  defp replace_unloaded_trace_entries_nosync(%__MODULE__{} = state, trace_updates) do
    traced_paths = trace_paths(trace_updates)
    traced_modules = trace_modules(trace_updates)
    module_atoms = MapSet.new(traced_modules)
    module_by_name = module_by_name(traced_modules)
    match_modules? = MapSet.size(module_atoms) > 0
    new_entries = trace_entries_with_structure(trace_updates)

    kept_entries =
      state.backend.reduce([], fn
        %Entry{path: path} = entry, acc when is_binary(path) ->
          replace? =
            MapSet.member?(traced_paths, path) or
              (match_modules? and
                 definition_for_exact_modules?(entry, module_atoms, module_by_name))

          if replace? do
            acc
          else
            [entry | acc]
          end

        %Entry{} = entry, acc ->
          [entry | acc]

        _entry, acc ->
          acc
      end)

    with :ok <- state.backend.replace_all(Enum.reverse(kept_entries, new_entries)) do
      {:ok, mark_trace_write(%__MODULE__{state | fuzzy: Fuzzy.from_entries(new_entries)})}
    end
  end

  defp entries_for_path(%__MODULE__{} = state, path) do
    state.backend.reduce([], fn
      %Entry{path: ^path} = entry, acc -> [entry | acc]
      _entry, acc -> acc
    end)
  end

  defp put_entry_path(%Entry{} = entry, path), do: %Entry{entry | path: path}

  defp trace_modules(trace_updates) do
    trace_updates
    |> Enum.flat_map(fn {_path, modules, _entries} -> modules end)
    |> Enum.uniq()
  end

  defp trace_entries_with_structure(trace_updates) do
    Enum.flat_map(trace_updates, fn {path, _modules, entries} ->
      ensure_block_structure(path, entries)
    end)
  end

  defp exact_module_definition_paths(%__MODULE__{}, [], _traced_paths), do: %{}

  defp exact_module_definition_paths(%__MODULE__{} = state, modules, traced_paths) do
    module_atoms = MapSet.new(modules)
    module_by_name = module_by_name(modules)

    %{}
    |> state.backend.reduce(fn
      %Entry{path: path} = entry, acc when is_binary(path) ->
        if MapSet.member?(traced_paths, path) do
          acc
        else
          case exact_definition_module(entry, module_atoms, module_by_name) do
            {:ok, module} -> Map.update(acc, path, [module], &[module | &1])
            :error -> acc
          end
        end

      _entry, acc ->
        acc
    end)
    |> Map.new(fn {path, modules} -> {path, Enum.uniq(modules)} end)
  end

  defp definition_for_exact_modules?(%Entry{} = entry, module_atoms, module_by_name) do
    match?({:ok, _module}, exact_definition_module(entry, module_atoms, module_by_name))
  end

  defp exact_definition_module(
         %Entry{subtype: :definition, subject: subject},
         module_atoms,
         module_by_name
       ) do
    cond do
      is_atom(subject) and MapSet.member?(module_atoms, subject) ->
        {:ok, subject}

      is_binary(subject) ->
        exact_function_definition_module(subject, module_by_name)

      true ->
        :error
    end
  end

  defp exact_definition_module(%Entry{}, _module_atoms, _module_by_name), do: :error

  defp exact_function_definition_module(subject, module_by_name) do
    with {:ok, module_name} <- mfa_subject_module_name(subject) do
      Map.fetch(module_by_name, module_name)
    end
  end

  defp module_by_name(modules) do
    Map.new(modules, &{Forge.Formats.module(&1), &1})
  end

  defp mfa_subject_module_name(subject) when is_binary(subject) do
    case Regex.run(~r/^(.+)\.[^.\/]+\/\d+$/, subject) do
      [_, module_name] -> {:ok, module_name}
      _ -> :error
    end
  end

  defp ensure_block_structure(path, entries) do
    if Enum.any?(entries, &structure?/1) do
      entries
    else
      [Entry.block_structure(path, %{root: %{}}) | entries]
    end
  end

  defp structure?(%Entry{type: :metadata, subtype: :block_structure}), do: true
  defp structure?(%Entry{}), do: false

  defp mark_trace_write(%__MODULE__{} = state) do
    %__MODULE__{state | trace_writes_before_load?: true}
  end

  defp prepare_backend_async(
         %__MODULE__{async_load_ref: nil, backend_index_state: :not_leader} = state
       ) do
    task = Task.async(fn -> :initialize_fuzzy end)

    %__MODULE__{state | async_load_ref: task.ref}
  end

  defp prepare_backend_async(
         %__MODULE__{async_load_ref: nil, backend_index_state: index_state} = state
       )
       when index_state in [:empty, :stale] do
    task =
      Task.async(fn ->
        case index_load_action(state) do
          :create_index ->
            Logger.info("backend reports empty")
            {:create_index, state.create_index.(state.project, state.backend)}

          :update_index ->
            Logger.info("backend reports #{index_state}")
            {:update_index, state.update_index.(state.project, state.backend)}
        end
      end)

    %__MODULE__{state | async_load_ref: task.ref}
  end

  defp prepare_backend_async(%__MODULE__{async_load_ref: nil} = state) do
    Logger.error("Could not initialize index because the search backend is not ready")
    state
  end

  defp index_load_action(%__MODULE__{trace_writes_before_load?: true}), do: :update_index
  defp index_load_action(%__MODULE__{backend_index_state: :stale}), do: :update_index
  defp index_load_action(%__MODULE__{backend_index_state: :empty}), do: :create_index

  defp create_index_complete(%__MODULE__{} = state, result) do
    index_operation_complete(state, result, "create")
  end

  defp update_index_complete(%__MODULE__{} = state, result) do
    index_operation_complete(state, result, "update")
  end

  defp index_operation_complete(%__MODULE__{} = state, :ok, _operation) do
    initialize_fuzzy(state)
  end

  defp index_operation_complete(%__MODULE__{} = state, {:error, _} = error, operation) do
    Logger.warning("Could not #{operation} index, got: #{inspect(error)}")
    state
  end

  defp maybe_sync(%__MODULE__{} = state) do
    if function_exported?(state.backend, :sync, 1) do
      state.backend.sync(state.project)
    else
      :ok
    end
  end

  defp initialize_fuzzy(%__MODULE__{} = state) do
    fuzzy = Fuzzy.from_backend(state.backend)

    %__MODULE__{state | fuzzy: fuzzy}
  end
end

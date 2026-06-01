defmodule Engine.Search.Store.StateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Forge.Test.Fixtures

  alias Engine.Search.Store.State
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Project
  alias Forge.Search.Indexer.Entry
  alias Forge.Search.Indexer.Source.Block

  defmodule TimeoutBackend do
    @behaviour Engine.Search.Store.Backend

    def delete_by_path(_path) do
      exit({:timeout, {GenServer, :call, [:some_ref]}})
    end

    def new(_project), do: {:ok, :new}
    def prepare(_), do: {:ok, :empty}
    def insert(_entries), do: :ok
    def replace_all(_entries), do: :ok
    def find_by_subject(_subject, _type, _subtype), do: []
    def find_by_prefix(_prefix, _type, _subtype), do: []
    def find_by_ids(_ids, _type, _subtype), do: []
    def reduce(acc, _fun), do: acc
    def siblings(_entry), do: []
    def parent(_entry), do: nil
    def structure_for_path(_path), do: {:ok, %{}}
    def drop, do: :ok
    def destroy(_state), do: :ok
  end

  defmodule DeleteErrorBackend do
    @behaviour Engine.Search.Store.Backend

    def delete_by_path(_path), do: {:error, :delete_failed}

    def new(_project), do: {:ok, :new}
    def prepare(_), do: {:ok, :empty}
    def insert(_entries), do: :ok
    def replace_all(_entries), do: :ok
    def find_by_subject(_subject, _type, _subtype), do: []
    def find_by_prefix(_prefix, _type, _subtype), do: []
    def find_by_ids(_ids, _type, _subtype), do: []
    def reduce(acc, _fun), do: acc
    def siblings(_entry), do: []
    def parent(_entry), do: nil
    def structure_for_path(_path), do: {:ok, %{}}
    def drop, do: :ok
    def destroy(_state), do: :ok
  end

  defmodule TraceBackend do
    @behaviour Engine.Search.Store.Backend

    def reset do
      set_entries([])
      set_reduce_calls(0)
      set_replace_all_calls(0)
    end

    def set_entries(entries), do: :persistent_term.put({__MODULE__, :entries}, entries)
    def entries, do: :persistent_term.get({__MODULE__, :entries}, [])
    def reduce_calls, do: :persistent_term.get({__MODULE__, :reduce_calls}, 0)
    def replace_all_calls, do: :persistent_term.get({__MODULE__, :replace_all_calls}, 0)

    defp set_reduce_calls(count) do
      :persistent_term.put({__MODULE__, :reduce_calls}, count)
    end

    defp set_replace_all_calls(count) do
      :persistent_term.put({__MODULE__, :replace_all_calls}, count)
    end

    def new(_project), do: {:ok, :new}
    def prepare(_), do: {:ok, :empty}

    def replace_all(entries) do
      set_replace_all_calls(replace_all_calls() + 1)
      set_entries(entries)
    end

    def delete_by_path(path) do
      {deleted, kept} = Enum.split_with(entries(), &(&1.path == path))
      set_entries(kept)
      {:ok, Enum.flat_map(deleted, &List.wrap(&1.id))}
    end

    def insert(entries) do
      set_entries(entries() ++ entries)
      :ok
    end

    def reduce(acc, fun) do
      set_reduce_calls(reduce_calls() + 1)
      Enum.reduce(entries(), acc, fun)
    end

    def find_by_subject(_subject, _type, _subtype), do: []
    def find_by_prefix(_prefix, _type, _subtype), do: []
    def find_by_ids(_ids, _type, _subtype), do: []
    def siblings(_entry), do: []
    def parent(_entry), do: nil
    def structure_for_path(_path), do: {:ok, %{}}
    def drop, do: set_entries([])
    def destroy(_state), do: :ok
  end

  describe "update_nosync/3" do
    test "catches timeout from backend and logs the warning" do
      Logger.put_module_level(State, :warning)
      on_exit(fn -> Logger.put_module_level(State, Logger.level()) end)

      project = project()

      state = new_state(project, TimeoutBackend)

      {result, log} =
        with_log(fn ->
          State.update_nosync(state, "/some/path.ex", [])
        end)

      assert {:ok, %State{}} = result
      assert log =~ "Timeout updating index for path: /some/path.ex"
    end
  end

  describe "refresh_index/1" do
    @tag :tmp_dir
    test "returns index update errors instead of crashing", %{tmp_dir: tmp_dir} do
      project = tmp_dir |> Forge.Document.Path.to_uri() |> Project.bare()

      state =
        new_state(project, DeleteErrorBackend,
          update_index: fn _project, _backend -> {:error, :update_failed} end
        )

      assert {:error, :update_failed} = State.refresh_index(state)
    end
  end

  describe "trace writes" do
    setup do
      TraceBackend.reset()

      state = new_state(project(), TraceBackend)

      {:ok, state: state}
    end

    test "commit_trace replaces all entries at the committed path", %{state: state} do
      path = "/trace_commit.ex"
      old_definition = definition(path, TraceCommit)
      old_reference = reference(path, "Old.reference/0")
      new_definition = definition(path, TraceCommit)
      new_reference = reference(path, "Enum.map/2")
      TraceBackend.set_entries([old_definition, old_reference])

      assert {:ok, %State{}} =
               State.commit_trace(state, path, [TraceCommit], [new_definition, new_reference])

      assert [^new_definition, ^new_reference] =
               TraceBackend.entries()
               |> Enum.reject(&structure?/1)
               |> Enum.sort_by(& &1.id)
    end

    test "commit_trace removes previous exact module definitions from other paths", %{
      state: state
    } do
      old_path = "/old_multi_module.ex"
      new_path = "/new_multi_module.ex"
      old_a = definition(old_path, Multi.A)
      old_a_fun = function_definition(old_path, "Multi.A.old/0")
      old_b = definition(old_path, Multi.B)
      new_a = definition(new_path, Multi.A)
      new_a_fun = function_definition(new_path, "Multi.A.new/0")
      TraceBackend.set_entries([old_a, old_a_fun, old_b])

      assert {:ok, %State{}} =
               State.commit_trace(state, new_path, [Multi.A], [new_a, new_a_fun])

      entries = Enum.reject(TraceBackend.entries(), &structure?/1)
      assert old_b in entries
      assert new_a in entries
      assert new_a_fun in entries
      refute old_a in entries
      refute old_a_fun in entries
    end

    test "commit_traces removes previous exact module definitions with one backend scan", %{
      state: state
    } do
      old_path = "/old_batch_module.ex"
      new_path = "/new_batch_module.ex"
      sibling_path = "/batch_sibling_module.ex"
      old_definition = definition(old_path, BatchMoved)
      old_function = function_definition(old_path, "BatchMoved.old/0")
      old_reference = reference(old_path, "Enum.map/2")
      sibling_definition = definition(sibling_path, BatchSibling)
      new_definition = definition(new_path, BatchMoved)
      new_function = function_definition(new_path, "BatchMoved.new/0")

      TraceBackend.set_entries([
        old_definition,
        old_function,
        old_reference,
        sibling_definition
      ])

      assert {:ok, %State{}} =
               State.commit_traces(state, [
                 {new_path, [BatchMoved], [new_definition, new_function]}
               ])

      entries = Enum.reject(TraceBackend.entries(), &structure?/1)
      assert old_reference in entries
      assert sibling_definition in entries
      assert new_definition in entries
      assert new_function in entries
      refute old_definition in entries
      refute old_function in entries
    end

    test "commit_traces does not scan the backend for every traced path replacement", %{
      state: state
    } do
      trace_updates =
        for module <- [BatchTraceScan.A, BatchTraceScan.B, BatchTraceScan.C] do
          path = "/#{module}.ex"
          {path, [module], [definition(path, module)]}
        end

      assert {:ok, %State{}} = State.commit_traces(state, trace_updates)

      assert TraceBackend.reduce_calls() == 1
      assert TraceBackend.replace_all_calls() == 1
    end

    test "exact module matching does not treat dotted module prefixes as hierarchy", %{
      state: state
    } do
      old_path = "/old_nested_module.ex"
      new_path = "/new_nested_module.ex"
      old_parent = definition(old_path, NestedParent)
      child = definition(old_path, NestedParent.Child)
      child_function = function_definition(old_path, "NestedParent.Child.child/0")
      new_parent = definition(new_path, NestedParent)

      TraceBackend.set_entries([old_parent, child, child_function])

      assert {:ok, %State{}} =
               State.commit_trace(state, new_path, [NestedParent], [new_parent])

      entries = Enum.reject(TraceBackend.entries(), &structure?/1)
      assert new_parent in entries
      assert child in entries
      assert child_function in entries
      refute old_parent in entries
    end
  end

  defp new_state(project, backend, opts \\ []) do
    State.new(
      project,
      Keyword.get(opts, :create_index, fn _project, _backend -> :ok end),
      Keyword.get(opts, :update_index, fn _project, _backend -> :ok end),
      backend
    )
  end

  defp definition(path, subject) do
    Entry.definition(path, Block.root(), subject, :module, test_range(), nil)
  end

  defp reference(path, subject) do
    Entry.reference(path, Block.root(), subject, {:function, :usage}, test_range(), nil)
  end

  defp function_definition(path, subject) do
    Entry.definition(path, Block.root(), subject, {:function, :public}, test_range(), nil)
  end

  defp test_range do
    Range.new(
      %Position{line: 1, character: 1, starting_index: 1},
      %Position{line: 1, character: 2, starting_index: 1}
    )
  end

  defp structure?(%Entry{type: :metadata, subtype: :block_structure}), do: true
  defp structure?(%Entry{}), do: false
end

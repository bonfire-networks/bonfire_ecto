defmodule Bonfire.Ecto.Acts.Work do
  @moduledoc """
  An act that performs queued up work in a transaction.

  Work is queued up with calls to `add/2` in earlier acts and when run, this act will apply the
  appropriate actions.

  Only runs if there are no epic or changesets errors.
  """
  require Logger
  import Bonfire.Common.Utils
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  alias Ecto.Changeset
  import Bonfire.Epics
  use Arrows
  import Untangle

  @doc """
  Records that a particular key contains a changeset for processing.

  Use in earlier acts, to schedule work for in-transaction.

  If you wish to delete, you must ensure you set the changeset's `:action` key to `:delete`.
  """
  def add(epic, key), do: Epic.update(epic, __MODULE__, [], &[key | &1])

  @doc false
  def run(epic, act) do
    debug(act)
    # retrieve the list of keys to check
    keys = Map.get(epic.assigns, __MODULE__, [])
    # flatten them all into a keyword list
    changesets = Enum.flat_map(keys, &get_key(epic, act, &1))
    epic = promote_changeset_errors(epic, act, changesets)

    cond do
      epic.errors != [] ->
        maybe_debug(
          epic,
          act,
          length(epic.errors),
          "Skipping due to epic errors"
        )

        epic

      changesets == [] ->
        maybe_debug(epic, act, "Skipping, nothing to do")
        epic

      true ->
        maybe_debug(epic, act, "Entering transaction")
        repo = Bonfire.Common.Config.repo()

        case repo.transact_with(fn -> run(epic, act, changesets, repo) end) do
          {:ok, epic} -> epic
          {:error, epic} -> epic
        end
    end
  end

  # all the checks passed and we are in a transaction, actually do the stuff.
  defp run(epic, act, changesets, repo)
  defp run(epic, _, [], _), do: {:ok, epic}

  defp run(epic, act, [{key, changeset} | changesets], repo) do
    case e(changeset, :action, nil) do
      :insert ->
        maybe_debug(epic, act, key, "Inserting changeset on #{repo} at")
        repo.insert(changeset)

      :update ->
        maybe_debug(epic, act, key, "Applying update on #{repo} to changeset at")
        repo.update(changeset)

      :upsert ->
        maybe_debug(epic, act, key, "Applying upsert on #{repo} to changeset at")
        # note: because upsert is not an ecto action
        Map.put(changeset, :action, nil)
        |> repo.upsert()

      :delete ->
        maybe_debug(epic, act, key, "Deleting changeset on #{repo} at")
        repo.delete(changeset)

      other when is_struct(changeset) or is_list(changeset) ->
        # FIXME: should only trigger this in delete epics!
        maybe_debug(
          epic,
          act,
          other,
          "Did not detect a changeset with a valid action, attempt as object"
        )

        with {:ok, num} <-
               Bonfire.Ecto.Acts.Delete.maybe_delete(changeset, repo) |> debug("deleted") do
          # TODO: assign the number to epic in case needed?
          :ok
        end
    end
    |> case do
      :ok ->
        maybe_debug(epic, act, key, "Successfully applied changeset, continue...")

        epic
        |> run(act, changesets, repo)

      {:ok, value} ->
        maybe_debug(
          epic,
          act,
          key,
          "Successfully applied changeset, assign the returned value and continue..."
        )

        Epic.assign(epic, key, value)
        |> run(act, changesets, repo)

      {:error, value} ->
        maybe_debug(epic, act, value, "Error running changeset")
        {:error, Epic.add_error(epic, act, value)}
    end
  end

  defp promote_changeset_errors(epic, act, changesets) do
    Enum.reduce(changesets, epic, fn {_, changeset}, epic ->
      if is_map(changeset) and Map.has_key?(changeset, :valid) and
           !changeset.valid? do
        maybe_debug(epic, act, changeset, "Adding changeset to epic errors")
        Epic.add_error(epic, act, changeset)
      else
        epic
      end
    end)
  end

  # looks a key up, makes sure it's sane, otherwise discards it, possibly logging an error.
  defp get_key(epic, act, key) do
    case epic.assigns[key] do
      %Changeset{action: action} = changeset
      when action in [:insert, :update, :upsert, :delete] ->
        [{key, changeset}]

      %Changeset{action: action} ->
        maybe_debug(
          epic,
          act,
          "Skipping changeset at key :#{key} with unknown action :#{action}"
        )

        []

      # FIXME: this should only kick in for deletion epics
      object when is_struct(object) or is_list(object) ->
        [{key, object}]

      nil ->
        maybe_debug(epic, act, "Skipping missing key :#{key}")
        []

      other ->
        error(other, "Skipping, not a changeset :#{key}")
        []
    end
  end
end

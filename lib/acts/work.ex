defmodule Bonfire.Ecto.Acts.Work do
  @moduledoc """
  An act that performs queued up work in a transaction.

  Work is queued up with calls to `add/2` in earlier acts and when run, this act will apply the
  appropriate actions.

  Only runs if there are no epic or changesets errors.
  """
  require Logger
  import Bonfire.Common.Utils
  use Bonfire.Common.E
  alias Bonfire.Common.Enums
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  alias Ecto.Changeset
  import Bonfire.Epics
  use Arrows
  import Untangle

  @doc """
  Records that a particular key contains an `Ecto.Changeset` that needs to be processed (inserted, updated, upserted, or deleted).

  Call this in earlier acts to queue work for in-transaction processing.

  If you wish to delete, you must ensure you set the changeset's `:action` key to `:delete`.

  ## Parameters

    - `epic` - The epic struct that contains the list of acts to be executed.
    - `key` - The key representing the changeset to be processed.

  ## Examples

      iex> epic = %Epic{}
      iex> Bonfire.Ecto.Acts.Work.add(epic, :some_changeset)
      %Epic{assigns: %{Bonfire.Ecto.Acts.Work => [:some_changeset]}}

  """
  def add(epic, key), do: Epic.update(epic, __MODULE__, [], &[key | &1])

  @doc """
  Runs the queued work within a transaction if no errors are detected in the epic.

  This function retrieves the list of keys scheduled for processing, validates them,
  and performs the appropriate actions (`:insert`, `:update`, `:upsert`, `:delete`) in a transaction.

  ## Parameters

    - `epic` - The epic struct that contains the list of acts to be executed.
    - `act` - The current act being processed.

  ## Examples

      iex> epic = %Epic{assigns: %{Bonfire.Ecto.Acts.Work => [:some_changeset]}, errors: []}
      iex> act = %{}
      iex> Bonfire.Ecto.Acts.Work.run(epic, act)
      %Epic{assigns: %{Bonfire.Ecto.Acts.Work => [:some_changeset]}, errors: []}

      iex> epic = %Epic{assigns: %{Bonfire.Ecto.Acts.Work => [:some_changeset]}, errors: ["error"]}
      iex> act = %{}
      iex> Bonfire.Ecto.Acts.Work.run(epic, act)
      %Epic{assigns: %{Bonfire.Ecto.Acts.Work => [:some_changeset]}, errors: ["error"]}

  """
  def run(epic, act) do
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
        repo = Bonfire.Common.Config.repo()

        #  Note that usually a transaction was already opened in Begin, so as per https://hexdocs.pm/ecto/Ecto.Repo.html#c:transaction/2-nested-transactions this won't start a new one
        if not repo.in_transaction?(),
          do: maybe_debug(epic, act, "Work: Entering transaction"),
          else: debug(act)

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
    action = e(changeset, :action, nil)

    case action do
      :insert ->
        maybe_debug(epic, act, key, "Inserting changeset on #{repo} at")
        debug(changeset, "Inserting changeset")

        repo.insert(changeset)
        |> Untangle.debug("Inserted changeset?")

      :update ->
        maybe_debug(epic, act, key, "Applying update on #{repo} to changeset at")
        repo.update(changeset)

      :upsert ->
        maybe_debug(epic, act, key, "Applying upsert on #{repo} to changeset at")
        # note: because upsert is not an ecto action
        Map.put(changeset, :action, nil)
        |> repo.upsert()

      :delete when is_list(changeset) ->
        maybe_debug(epic, act, key, "Deleting multiple changesets on #{repo} at")

        Enum.map(changeset, &repo.delete/1)
        |> Enums.all_oks_or_error()

      :delete ->
        maybe_debug(epic, act, key, "Deleting changeset on #{repo} at")

        # Doesn't error if delete is stale. Defaults to false. This may happen if the struct has been deleted from the database before this deletion BUT ALSO if there is a rule or a trigger on the database that rejects the delete operation (FIXME: the latter seems undesirable in this case)
        repo.delete(changeset, allow_stale: true)

      _other when is_struct(changeset) or is_list(changeset) ->
        # FIXME: should only trigger this in delete epics!
        maybe_debug(
          epic,
          act,
          action,
          "Did not detect a changeset with a valid action, assume object deletion"
        )

        with {:ok, num} <-
               Bonfire.Ecto.Acts.Delete.maybe_delete(changeset, repo) |> debug("deleted") do
          # TODO: assign the number to epic in case needed?
          :ok
        end
    end
    |> debug("Result of operation #{action} changeset")
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

        Untangle.debug(key, "Assign result to epic at")

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

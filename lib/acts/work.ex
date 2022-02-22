defmodule Bonfire.Ecto.Acts.Work do
  @moduledoc """
  An act that performs queued up work in a transaction.

  Work is queued up with calls to `add/2` in earlier acts and when run, this act will apply the
  appropriate actions.

  Only runs if there are no epic or changesets errors.
  """
  require Logger 
  import Bonfire.Common.Utils
  alias Bonfire.Epics.{Act, Epic}
  alias Ecto.Changeset
  require Act
  use Arrows
  import Where

  @doc """
  Records that a particular key contains a changeset for processing.

  Use in earlier acts, to schedule work for in-transaction.

  If you wish to delete, you must ensure you set the changeset's `:action` key to `:delete`.
  """
  def add(epic, key), do: Epic.update(epic, __MODULE__, [], &[key | &1])

  @doc false
  def run(epic, act) do
    # retrieve the list of keys to check
    keys = Map.get(epic.assigns, __MODULE__, [])
    # flatten them all into a keyword list
    changesets = Enum.flat_map(keys, &get_key(epic, act, &1))
    epic = promote_changeset_errors(epic, act, changesets)
    cond do
      epic.errors != [] ->
        Act.debug(epic, act, length(epic.errors), "Skipping due to epic errors")
        epic
      changesets == [] ->
        Act.debug(epic, act, "Skipping, nothing to do")
        epic
      true ->
        Act.debug(epic, act, "Entering transaction")
        repo = Application.get_env(:bonfire, :repo_module)
        case repo.transact_with(fn -> run(epic, act, changesets, repo) end) do
          {:ok, epic} -> epic
          {:error, epic} -> epic
        end
    end
  end

  # all the checks passed and we are in a transaction, actually do the stuff.
  defp run(epic, act, changesets, repo)
  defp run(epic, _, [], _), do: {:ok, epic}
  defp run(epic, act, [{key, changeset}|changesets], repo) do
    case changeset.action do
      :insert ->
        Act.debug(epic, act, "Inserting changeset at :#{key}")
        repo.insert(changeset)
      :update ->
        Act.debug(epic, act, "Applying update to changeset at :#{key}")
        repo.update(changeset)
      :delete ->
        Act.debug(epic, act, "Deleting changeset at :#{key}")
        repo.delete(changeset)
    end
    |> case do
         {:ok, value} ->
           Act.debug(epic, act, "Successfully applied :#{key}")
           Epic.assign(epic, key, value)
           |> run(act, changesets, repo)
         {:error, value} ->
           Act.debug(epic, act, value, "Error")
           {:error, Epic.add_error(epic, act, value)}
       end
  end

  defp promote_changeset_errors(epic, act, changesets) do
    Enum.reduce(changesets, epic, fn {_, changeset}, epic ->
      if !changeset.valid? do
        Act.debug(epic, act, changeset, "Adding changeset to epic errors")
        Epic.add_error(epic, act, changeset)
      else
        epic
      end
    end)
  end

  # looks a key up, makes sure it's sane, otherwise discards it, possibly logging an error.
  defp get_key(epic, act, key) do
    case epic.assigns[key] do
      %Changeset{action: action}=changeset when action in [:insert, :update, :delete] -> [{key, changeset}]
      %Changeset{action: action} ->
        Act.debug(epic, act, "Skipping changeset at key :#{key} with unknown action :#{action}")
        []
      nil ->
        Act.debug(epic, act, "Skipping missing key :#{key}")
        []
      other ->
        error(other, "Skipping, not a changeset :#{key}")
        []
    end
  end

end

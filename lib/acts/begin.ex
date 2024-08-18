defmodule Bonfire.Ecto.Acts.Begin do
  @moduledoc """
  An Act that enters a transaction unless it senses that it would be futile.
  """
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic

  alias Bonfire.Ecto.Acts.Commit
  # alias Bonfire.Ecto.Acts.Work

  import Bonfire.Epics
  import Bonfire.Common.Config, only: [repo: 0]

  # import Untangle

  @doc """
  Runs the given act(s) within a transaction if no errors are detected in the epic.

  This function takes the modules before the `Commit` module in the `epic.next` list, runs them,
  and then processes the remaining modules. If there are any errors in the epic, it avoids
  entering a transaction.

  ## Parameters

    - `epic` - The epic struct that contains the list of acts to be executed.
    - `act` - The current act being processed.

  ## Examples

      iex> epic = %Epic{next: [%{module: OtherModule}, %{module: Commit}], errors: []}
      iex> act = %{}
      iex> Bonfire.Ecto.Acts.Begin.run(epic, act)
      %Epic{next: [], errors: []}

      iex> epic = %Epic{next: [%{module: OtherModule}, %{module: Commit}], errors: ["error"]}
      iex> act = %{}
      iex> Bonfire.Ecto.Acts.Begin.run(epic, act)
      %Epic{next: [], errors: ["error"]}

  """
  def run(epic, act) do
    # take all the modules before commit and run them, then return the remainder.
    {next, rest} = Enum.split_while(epic.next, &(&1.module != Commit))
    # drop commit if there are any items left
    rest = Enum.drop(rest, 1)
    nested = %{epic | next: next}

    # if for some reason something is unlikely to work, we won't bother with the transaction.
    cond do
      epic.errors != [] ->
        smart(
          epic,
          act,
          epic.errors,
          "not entering transaction because of errors"
        )

        epic = Epic.run(nested)
        %{epic | next: rest}

      true ->
        if not repo().in_transaction?(),
          do: maybe_debug(epic, act, "Begin: entering transaction"),
          else:
            IO.warn(
              "We're already in a transaction, better avoid this and let Epics handle the transaction..."
            )

        repo().transact_with(fn ->
          epic = Epic.run(nested)
          if epic.errors == [], do: {:ok, epic}, else: {:error, epic}
        end)
        |> case do
          {:ok, epic} ->
            maybe_debug(epic, act, "committed successfully.")
            %{epic | next: rest}

          {:error, %Epic{} = epic} ->
            maybe_debug(epic, act, "rollback because of errors")
            %{epic | next: rest}

          {:error, e} ->
            maybe_debug(epic, act, "rollback because of errors: #{inspect(e)}")
            %{epic | next: rest}
        end
    end
  end
end

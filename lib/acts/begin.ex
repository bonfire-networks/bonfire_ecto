defmodule Bonfire.Ecto.Acts.Begin do
  @moduledoc """
  An Act that enters a transaction unless it senses that it would be futile.
  """
  alias Bonfire.Epics.{Act, Epic}
  alias Bonfire.Ecto.Acts.{Commit, Work}
  require Act
  # import Where

  def run(epic, act) do
    # take all the modules before commit and run them, then return the remainder.
    {next, rest} = Enum.split_while(epic.next, &(&1.module != Commit))
    rest = Enum.drop(rest, 1) # drop commit if there are any items left
    nested = %{ epic | next: next }
    # if for some reason something is unlikely to work, we won't bother with the transaction.
    cond do
      epic.errors != [] ->
        Act.smart(epic, act, epic.errors, "not entering transaction because of errors")
        epic = Epic.run(nested)
        %{ epic | next: rest }
      true ->
        Act.debug(epic, act, "entering transaction")
        Bonfire.Repo.transact_with(fn ->
          epic = Epic.run(nested)
          if epic.errors == [], do: {:ok, epic}, else: {:error, epic}
        end)
        |> case do
          {:ok, epic} ->
            Act.debug(epic, act, "committed successfully.")
            %{ epic | next: rest }
          {:error, epic} ->
            Act.debug(epic, act, "rollback because of errors")
            %{ epic | next: rest }
        end
    end
  end
end

# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Resource.Relationships.NoAttributesPaginationTest do
  use ExUnit.Case, async: false

  defmodule Item do
    use Ash.Resource, domain: Ash.Test.Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :rank, :integer, public?: true
      attribute :recorded_at, :utc_datetime_usec, public?: true
    end

    actions do
      defaults create: :*

      read :required_pagination do
        pagination keyset?: true, required?: true
      end

      read :read do
        primary? true
        pagination keyset?: true, offset?: true, required?: false, countable: true
      end
    end
  end

  defmodule Parent do
    use Ash.Resource, domain: Ash.Test.Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, create: :*]
    end

    relationships do
      has_many :items, Item do
        no_attributes? true
        sort rank: :asc, id: :asc
      end
    end
  end

  test "keyset pagination applies before returning each parent's results" do
    parents = for _ <- 1..2, do: Ash.create!(Parent)
    items = for rank <- 1..4, do: Ash.create!(Item, %{rank: rank})
    ids = Enum.map(items, & &1.id)
    query = Ash.Query.page(Item, limit: 2, count: true)

    [first, second] = Ash.load!(parents, items: query)
    assert Enum.map(first.items.results, & &1.id) == Enum.take(ids, 2)
    assert Enum.map(second.items.results, & &1.id) == Enum.take(ids, 2)
    assert first.items.count == 4
    assert first.items.more?

    cursor = List.last(first.items.results).__metadata__.keyset
    query = Ash.Query.page(Item, limit: 2, after: cursor, count: true)
    [first, second] = Ash.load!(parents, items: query)
    assert Enum.map(first.items.results, & &1.id) == Enum.drop(ids, 2)
    assert Enum.map(second.items.results, & &1.id) == Enum.drop(ids, 2)
    refute first.items.more?
    assert first.items.count == 4

    cursor = hd(first.items.results).__metadata__.keyset
    query = Ash.Query.page(Item, limit: 2, before: cursor)
    [first, _] = Ash.load!(parents, items: query)
    assert Enum.map(first.items.results, & &1.id) == Enum.take(ids, 2)
  end

  test "expression-sort cursors preserve microseconds for equal timestamps" do
    require Ash.Sort
    timestamp = ~U[2026-09-14 10:00:00.123456Z]
    for _ <- 1..2, do: Ash.create!(Item, %{recorded_at: timestamp})

    query =
      Ash.Query.sort(Item, [
        {Ash.Sort.expr_sort(recorded_at, :utc_datetime_usec), :desc},
        {:id, :asc}
      ])

    first = Ash.read!(query, page: [limit: 1])
    cursor = hd(first.results).__metadata__.keyset
    second = Ash.read!(query, page: [limit: 1, after: cursor])

    assert [%Item{recorded_at: ^timestamp} = next] = second.results
    assert next.id != hd(first.results).id
    refute second.more?
  end

  test "unpaginated relationship loads do not require a page limit" do
    parent = Ash.create!(Parent)
    for rank <- 1..4, do: Ash.create!(Item, %{rank: rank})
    query = Ash.Query.for_read(Item, :required_pagination)

    assert Enum.map(Ash.load!(parent, items: query).items, & &1.rank) == [1, 2, 3, 4]
  end

  test "offset pagination skips rows and unpaginated loads remain complete" do
    parent = Ash.create!(Parent)
    for rank <- 1..4, do: Ash.create!(Item, %{rank: rank})

    query = Ash.Query.page(Item, limit: 2, offset: 1, count: true)
    page = Ash.load!(parent, items: query).items
    assert %Ash.Page.Offset{count: 4, more?: true} = page
    assert Enum.map(page.results, & &1.rank) == [2, 3]
    assert Enum.map(Ash.load!(parent, :items).items, & &1.rank) == [1, 2, 3, 4]
  end
end

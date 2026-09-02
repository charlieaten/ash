# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Resource.Relationships.ManualPaginationTest do
  use ExUnit.Case, async: false

  require Ash.Query

  defmodule Item do
    use Ash.Resource, domain: Ash.Test.Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    actions do
      defaults [:read, create: :*]
    end

    attributes do
      uuid_primary_key :id, writable?: true, public?: true
      attribute :rank, :integer, public?: true
      attribute :parent_id, :uuid, public?: true
    end
  end

  defmodule Loader do
    use Ash.Resource.ManualRelationship

    def load(records, _opts, _context) do
      parent_ids = Enum.map(records, & &1.id)

      items =
        Item
        |> Ash.Query.filter(parent_id in ^parent_ids)
        |> Ash.Query.sort(id: :desc)
        |> Ash.read!()

      {:ok, Enum.group_by(items, & &1.parent_id)}
    end
  end

  defmodule Parent do
    use Ash.Resource, domain: Ash.Test.Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    actions do
      defaults [:read, create: :*]
    end

    attributes do
      uuid_primary_key :id
    end

    relationships do
      has_many :items, Item do
        manual Loader
        no_attributes? true
        sort rank: :desc_nils_last
      end
    end
  end

  setup do
    parent = Ash.create!(Parent)

    items =
      for {id, rank} <- [{1, 1}, {2, 1}, {3, nil}, {4, nil}] do
        Ash.create!(Item, %{
          id: "00000000-0000-0000-0000-00000000000#{id}",
          rank: rank,
          parent_id: parent.id
        })
      end

    %{parent: parent, items: items}
  end

  test "keyset pages use the relationship sort, a stable tie-breaker, and full counts", context do
    %{parent: parent, items: [first, second, third, fourth]} = context
    page = load_page(parent, limit: 1, count: true)

    assert %Ash.Page.Keyset{results: [%{id: id}], count: 4, more?: true} = page
    assert id == first.id
    cursor = hd(page.results).__metadata__.keyset

    page = load_page(parent, limit: 2, after: cursor, count: true)
    assert Enum.map(page.results, & &1.id) == [second.id, third.id]
    assert page.count == 4
    assert page.more?

    cursor = List.last(page.results).__metadata__.keyset
    page = load_page(parent, limit: 2, after: cursor, count: true)
    assert Enum.map(page.results, & &1.id) == [fourth.id]
    refute page.more?

    cursor = hd(page.results).__metadata__.keyset
    page = load_page(parent, limit: 2, before: cursor, count: true)
    assert Enum.map(page.results, & &1.id) == [second.id, third.id]
    assert page.more?
    assert page.count == 4
  end

  test "offset pages remain available", %{parent: parent, items: items} do
    assert %Ash.Page.Offset{results: results, count: 4, more?: true} =
             load_page(parent, limit: 2, offset: 1, count: true)

    assert Enum.map(results, & &1.id) == Enum.map(Enum.slice(items, 1, 2), & &1.id)
  end

  test "each parent receives its own page, including empty relationships", context do
    %{parent: parent} = context
    other_parent = Ash.create!(Parent)
    query = Ash.Query.page(Item, limit: 1, count: true)

    [loaded, empty] =
      Ash.load!([parent, other_parent], items: query)

    assert %Ash.Page.Keyset{results: [_], count: 4, more?: true} = loaded.items
    assert %Ash.Page.Keyset{results: [], count: 0, more?: false} = empty.items
  end

  test "unpaginated loads still return the loader's list", %{parent: parent, items: items} do
    assert Enum.map(load_page(parent, nil), & &1.id) == Enum.map(Enum.reverse(items), & &1.id)
    assert Enum.map(load_page(parent, false), & &1.id) == Enum.map(Enum.reverse(items), & &1.id)
  end

  test "invalid cursors return an Ash error", %{parent: parent} do
    query = Ash.Query.page(Item, limit: 1, after: "invalid")

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.load(parent, items: query)
  end

  defp load_page(parent, page) do
    query = Item |> Ash.Query.select(:id) |> Ash.Query.page(page)

    parent
    |> Ash.load!(items: query)
    |> Map.fetch!(:items)
  end
end

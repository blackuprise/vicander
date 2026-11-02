defmodule DDD.ListingTest do
  use DDD.DataCase

  alias DDD.{Page, Slice}

  defmodule Job do
    use DDD.Aggregate

    aggregate do
      identity :id, :uuid
      field :title, :string, required: true
      field :status, {:enum, [:open, :done]}, default: :open
      field :priority, :integer, default: 0
      field :due, :date
    end
  end

  defmodule JobPort do
    use DDD.Repository

    repo Job do
    end
  end

  defmodule Jobs do
    use DDD.Repository.Ecto, port: JobPort, repo: DDD.TestRepo, table: "listing_jobs"
  end

  defmodule Overdue do
    use DDD.Specification

    @impl DDD.Specification
    def check(%{status: :open, due: %Date{} = due}, _opts) do
      if Date.compare(due, Date.utc_today()) == :lt,
        do: :ok,
        else: {:error, :not_overdue, "not overdue"}
    end

    def check(_job, _opts), do: {:error, :not_overdue, "not overdue"}

    @impl DDD.Specification
    def to_filter(_opts), do: [status: :open, due: {:lt, Date.utc_today()}]
  end

  defmodule UrgentFrom do
    use DDD.Specification

    @impl DDD.Specification
    def check(%{priority: priority}, opts) do
      if priority >= Keyword.fetch!(opts, :min),
        do: :ok,
        else: {:error, :not_urgent, "not urgent"}
    end

    @impl DDD.Specification
    def to_filter(opts), do: {:priority, {:gte, Keyword.fetch!(opts, :min)}}
  end

  defmodule InMemoryOnly do
    use DDD.Specification
    @impl DDD.Specification
    def check(_job, _opts), do: :ok
  end

  # title, status, priority, due
  @seed [
    {"alpha", :open, 1, ~D[2020-01-01]},
    {"bravo", :open, 3, nil},
    {"charlie", :done, 3, ~D[2020-06-01]},
    {"delta", :open, 2, ~D[2030-01-01]},
    {"echo", :done, 1, nil},
    {"foxtrot", :open, 2, ~D[2030-06-01]},
    {"golf", :open, 5, ~D[2020-03-01]}
  ]

  setup do
    DDD.TestRepo.query!("""
    CREATE TEMP TABLE listing_jobs (
      id uuid PRIMARY KEY, title varchar, status varchar, priority bigint, due date,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL,
      version bigint NOT NULL DEFAULT 0
    )
    """)

    jobs =
      for {title, status, priority, due} <- @seed do
        {:ok, job} = Job.new(title: title, status: status, priority: priority, due: due)
        {:ok, saved} = Jobs.save(job)
        saved
      end

    %{jobs: jobs}
  end

  defp titles({:ok, jobs}) when is_list(jobs), do: Enum.map(jobs, & &1.title)
  defp titles({:ok, %{entries: jobs}}), do: Enum.map(jobs, & &1.title)

  defp list_titles(opts), do: opts |> Jobs.list() |> titles() |> Enum.sort()

  # The title order a listing must produce: priority descending, then title, then id.
  defp expected(jobs, order_fun), do: jobs |> Enum.sort_by(order_fun) |> Enum.map(& &1.title)

  describe "list/1 and count/1" do
    test "lists everything by identity when asked for nothing", %{jobs: jobs} do
      assert titles(Jobs.list()) == expected(jobs, & &1.id)
      assert {:ok, 7} = Jobs.count()
      assert {:ok, [%Job{} | _]} = Jobs.list()
    end

    test "limits" do
      assert {:ok, [_, _]} = Jobs.list(limit: 2)
    end

    test "a keyword filter is every condition at once" do
      assert list_titles(filter: [status: :open, priority: 2]) == ["delta", "foxtrot"]
      assert {:ok, 2} = Jobs.count(filter: [status: :open, priority: 2])
    end

    test "a map is a filter too, and so is a list of filters" do
      assert list_titles(filter: %{status: :done}) == ["charlie", "echo"]
      assert list_titles(filter: [[status: :done], [priority: 1]]) == ["echo"]
      assert list_titles(filter: []) |> length() == 7
    end

    test "comparison operators" do
      assert list_titles(filter: [priority: {:gt, 3}]) == ["golf"]
      assert list_titles(filter: [priority: {:gte, 3}]) == ["bravo", "charlie", "golf"]
      assert list_titles(filter: [priority: {:lt, 2}]) == ["alpha", "echo"]
      assert list_titles(filter: [priority: {:lte, 1}]) == ["alpha", "echo"]
      assert list_titles(filter: [status: {:neq, :open}]) == ["charlie", "echo"]
      assert list_titles(filter: [priority: {:eq, 5}]) == ["golf"]
      assert list_titles(filter: {:priority, :gt, 3}) == ["golf"]
    end

    test "in, not in and pattern matching" do
      assert list_titles(filter: [priority: {:in, [1, 5]}]) == ["alpha", "echo", "golf"]
      assert list_titles(filter: [priority: {:not_in, [1, 2, 3]}]) == ["golf"]
      assert list_titles(filter: [title: {:like, "%o%"}]) == ["bravo", "echo", "foxtrot", "golf"]
      assert list_titles(filter: [title: {:like, "FOX%"}]) == []
      assert list_titles(filter: [title: {:ilike, "FOX%"}]) == ["foxtrot"]
    end

    test "nil means NULL" do
      assert list_titles(filter: [due: nil]) == ["bravo", "echo"]
      assert list_titles(filter: [due: {:neq, nil}]) |> length() == 5
    end

    test "dates are compared as dates" do
      assert list_titles(filter: [due: {:lt, ~D[2020-04-01]}]) == ["alpha", "golf"]
    end

    test "or, and, not" do
      assert list_titles(filter: {:or, [[priority: 5], [title: "echo"]]}) == ["echo", "golf"]
      assert list_titles(filter: {:or, []}) == []

      assert list_titles(filter: {:and, [[status: :open], [priority: {:gte, 3}]]}) ==
               ["bravo", "golf"]

      assert list_titles(filter: {:not, [status: :open]}) == ["charlie", "echo"]
    end

    test "values are parameters, not SQL" do
      assert list_titles(filter: [title: "'; DROP TABLE listing_jobs; --"]) == []
      assert {:ok, 7} = Jobs.count()
    end
  end

  describe "searching with a specification" do
    test "the database finds what the spec would accept", %{jobs: jobs} do
      in_memory = for job <- jobs, Overdue.satisfied_by?(job), do: job.title

      assert Enum.sort(in_memory) == ["alpha", "golf"]
      assert list_titles(spec: Overdue) == Enum.sort(in_memory)
    end

    test "specs compose, with options" do
      assert list_titles(spec: DDD.Specification.all_of([Overdue, {UrgentFrom, min: 3}])) ==
               ["golf"]

      assert list_titles(spec: DDD.Specification.any_of([Overdue, {UrgentFrom, min: 5}])) ==
               ["alpha", "golf"]

      assert list_titles(spec: DDD.Specification.not_spec({UrgentFrom, min: 2})) ==
               ["alpha", "echo"]
    end

    test "a spec and a filter are both applied" do
      assert list_titles(spec: Overdue, filter: [priority: 1]) == ["alpha"]
      assert {:ok, 1} = Jobs.count(spec: Overdue, filter: [priority: 1])
    end

    test "a spec that can only be checked in memory cannot be searched with" do
      assert_raise ArgumentError, ~r/InMemoryOnly cannot be searched with/, fn ->
        Jobs.list(spec: InMemoryOnly)
      end
    end

    test "to_filter/2 translates the composites" do
      assert DDD.Specification.to_filter({:all_of, [{UrgentFrom, min: 1}, {:not, Overdue}]}) ==
               {:and,
                [
                  {:priority, {:gte, 1}},
                  {:not, [status: :open, due: {:lt, Date.utc_today()}]}
                ]}
    end
  end

  describe "bad filters are business errors" do
    test "an unknown field" do
      assert {:error, %DDD.Error{kind: :business, code: :invalid_filter} = error} =
               Jobs.list(filter: [nope: 1])

      assert error.details.fields == [
               :created_at,
               :due,
               :id,
               :priority,
               :status,
               :title,
               :updated_at,
               :version
             ]

      assert {:error, %DDD.Error{code: :invalid_filter}} = Jobs.count(filter: {:nope, :gt, 1})
    end

    test "an unknown operator, a malformed filter and operands of the wrong shape" do
      assert {:error, %DDD.Error{code: :invalid_filter, message: "unknown operator :near" <> _}} =
               Jobs.list(filter: {:priority, :near, 1})

      assert {:error, %DDD.Error{code: :invalid_filter, message: "not a filter: " <> _}} =
               Jobs.list(filter: "priority > 1")

      assert {:error, %DDD.Error{code: :invalid_filter}} = Jobs.list(filter: [priority: {:in, 1}])
      assert {:error, %DDD.Error{code: :invalid_filter}} = Jobs.list(filter: [title: {:like, 1}])
    end

    test "a value that does not fit its column" do
      assert {:error, %DDD.Error{code: :invalid_filter}} = Jobs.list(filter: [id: "not-a-uuid"])
    end
  end

  describe "ordering" do
    test "ascending, descending and by several fields", %{jobs: jobs} do
      assert titles(Jobs.list(order: :title)) == Enum.sort(Enum.map(jobs, & &1.title))
      assert titles(Jobs.list(order: {:desc, :priority})) |> hd() == "golf"

      assert titles(Jobs.list(order: [desc: :priority, asc: :title])) ==
               expected(jobs, &{-&1.priority, &1.title})
    end

    test "the identity breaks ties, so equal rows come back in a stable order", %{jobs: jobs} do
      ids = fn {:ok, list} -> Enum.map(list, & &1.id) end

      # "done" sorts before "open"; inside each status the identity decides.
      by_id = fn status ->
        jobs |> Enum.filter(&(&1.status == status)) |> Enum.sort_by(& &1.id) |> Enum.map(& &1.id)
      end

      assert ids.(Jobs.list(order: :status)) == by_id.(:done) ++ by_id.(:open)
      assert ids.(Jobs.list(order: [desc: :status])) == by_id.(:open) ++ by_id.(:done)
    end

    test "an unknown field or a nonsense order is an error" do
      assert {:error, %DDD.Error{kind: :business, code: :invalid_order}} = Jobs.list(order: :nope)

      assert {:error, %DDD.Error{code: :invalid_order, message: "not a sort order: " <> _}} =
               Jobs.list(order: [{:sideways, :title}])

      assert {:error, %DDD.Error{code: :invalid_order}} = Jobs.page(order: [1])
      assert {:error, %DDD.Error{code: :invalid_order}} = Jobs.slice(order: :nope)
    end
  end

  describe "page/1" do
    test "numbered pages with totals", %{jobs: jobs} do
      by_id = Enum.map(Enum.sort_by(jobs, & &1.id), & &1.title)

      assert {:ok, %Page{page: 1, page_size: 3, total_entries: 7, total_pages: 3} = first} =
               Jobs.page(page_size: 3)

      assert titles({:ok, first}) == Enum.take(by_id, 3)
      assert Page.has_next?(first)
      refute Page.has_previous?(first)

      assert {:ok, last} = Jobs.page(page: 3, page_size: 3)
      assert titles({:ok, last}) == Enum.drop(by_id, 6)
      refute Page.has_next?(last)
      assert Page.has_previous?(last)
    end

    test "a page beyond the end is empty, and the defaults apply" do
      assert {:ok, %Page{entries: [], page: 9, total_entries: 7, total_pages: 1}} =
               Jobs.page(page: 9)

      assert {:ok, %Page{page: 1, page_size: 20, entries: entries}} = Jobs.page()
      assert length(entries) == 7
    end

    test "filters apply to the totals as well" do
      assert {:ok, %Page{total_entries: 2, total_pages: 1}} =
               Jobs.page(filter: [status: :done], page_size: 5)

      assert {:ok, %Page{total_entries: 0, total_pages: 0, entries: []}} =
               Jobs.page(filter: [priority: 99])
    end

    test "page sizes are capped, and bad numbers are errors" do
      assert {:ok, %Page{page_size: 1000}} = Jobs.page(page_size: 5000)
      assert {:error, %DDD.Error{kind: :business, code: :invalid_page}} = Jobs.page(page: 0)
      assert {:error, %DDD.Error{code: :invalid_page}} = Jobs.page(page: "2")
      assert {:error, %DDD.Error{code: :invalid_page}} = Jobs.page(page_size: -1)
    end
  end

  describe "slice/1" do
    defp walk(order, limit, extra \\ []) do
      Stream.unfold(:start, fn
        :done ->
          nil

        cursor ->
          opts = [order: order, limit: limit] ++ extra
          opts = if cursor == :start, do: opts, else: [{:after, cursor} | opts]
          {:ok, slice} = Jobs.slice(opts)
          {slice, if(slice.next_cursor, do: slice.next_cursor, else: :done)}
      end)
      |> Enum.to_list()
    end

    test "walks the whole listing without gaps or repeats", %{jobs: jobs} do
      slices = walk(:title, 3)
      assert Enum.map(slices, &length(&1.entries)) == [3, 3, 1]

      assert Enum.flat_map(slices, & &1.entries) |> Enum.map(& &1.title) ==
               expected(jobs, & &1.title)

      assert [true, true, false] = Enum.map(slices, &Slice.has_next?/1)
    end

    test "descending, and by several fields with mixed directions", %{jobs: jobs} do
      order = [desc: :priority, asc: :title]

      assert walk(order, 2) |> Enum.flat_map(& &1.entries) |> Enum.map(& &1.title) ==
               expected(jobs, &{-&1.priority, &1.title})

      assert walk([desc: :title], 4) |> Enum.flat_map(& &1.entries) |> Enum.map(& &1.title) ==
               expected(jobs, & &1.title) |> Enum.reverse()
    end

    test "ties on the sort field are broken by the identity, so nothing is skipped", %{jobs: jobs} do
      # Three rows have priority 3 or 2: one per slice boundary forces a tie on the cursor.
      walked = walk([asc: :priority], 1) |> Enum.flat_map(& &1.entries)
      assert length(walked) == 7
      assert Enum.sort(Enum.map(walked, & &1.id)) == Enum.sort(Enum.map(jobs, & &1.id))
      assert Enum.map(walked, & &1.priority) == Enum.sort(Enum.map(jobs, & &1.priority))
    end

    test "filters apply", %{jobs: jobs} do
      open = for job <- jobs, job.status == :open, do: job.title

      assert walk(:title, 2, filter: [status: :open])
             |> Enum.flat_map(& &1.entries)
             |> Enum.map(& &1.title) ==
               Enum.sort(open)
    end

    test "the last slice and a listing that fits in one slice have no cursor" do
      assert {:ok, %Slice{next_cursor: nil, limit: 20, entries: entries}} = Jobs.slice()
      assert length(entries) == 7
      assert {:ok, %Slice{entries: [], next_cursor: nil}} = Jobs.slice(filter: [priority: 99])
    end

    test "a limit that is not a positive integer is an error, a huge one is capped" do
      assert {:error, %DDD.Error{code: :invalid_page}} = Jobs.slice(limit: 0)
      assert {:ok, %Slice{limit: 1000}} = Jobs.slice(limit: 10_000)
    end

    test "a cursor only works with the order it came from" do
      {:ok, %Slice{next_cursor: cursor}} = Jobs.slice(order: :title, limit: 2)

      assert {:error, %DDD.Error{kind: :business, code: :invalid_cursor}} =
               Jobs.slice(order: {:desc, :title}, limit: 2, after: cursor)

      assert {:ok, %Slice{}} = Jobs.slice(order: :title, limit: 2, after: cursor)
    end

    test "garbage is not a cursor" do
      for bad <- ["", "%%%", "AAAA", Base.url_encode64("not a term"), 42, :atom] do
        assert {:error, %DDD.Error{code: :invalid_cursor}} = Jobs.slice(after: bad)
      end

      forged = {[asc: :id], []} |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
      assert {:error, %DDD.Error{code: :invalid_cursor}} = Jobs.slice(after: forged)

      wrong_type =
        {[asc: :id], ["not-a-uuid"]}
        |> :erlang.term_to_binary()
        |> Base.url_encode64(padding: false)

      assert {:error, %DDD.Error{}} = Jobs.slice(after: wrong_type)
    end
  end
end

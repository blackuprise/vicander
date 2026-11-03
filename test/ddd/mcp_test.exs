defmodule DDD.MCPTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DDD.MCP.{Args, Json, Registry, Schema}

  # ── Fixtures: a small domain, its port, commands, queries and a server ───────

  defmodule Note do
    @moduledoc false
    use DDD.Aggregate

    aggregate do
      description "A note someone wrote"

      identity :id, :uuid
      field :text, :string, required: true, description: "What the note says"
      field :status, {:enum, [:open, :done]}, default: :open
      field :due, :date
      field :tags, {:array, :string}, default: []
      field :price, :money
    end
  end

  defmodule NoteRepository do
    @moduledoc false
    use DDD.Repository

    repo Note do
      find_by :status
      find_by [:status, :text]
      find_by :due
    end

    def impl, do: DDD.MCPTest.NoteMemory
  end

  defmodule NoteMemory do
    @moduledoc false
    use DDD.InMemoryRepository, port: DDD.MCPTest.NoteRepository

    def find_by_status(status), do: Enum.filter(all(), &(&1.status == status))

    def find_by_status_and_text(status, text),
      do: Enum.filter(all(), &(&1.status == status and &1.text == text))

    def find_by_due(due), do: Enum.filter(all(), &(&1.due == due))
  end

  defmodule BrokenNoteRepository do
    @moduledoc false
    use DDD.Repository

    repo Note do
      find_by :status
    end

    def impl, do: DDD.MCPTest.BrokenMemory
  end

  defmodule BrokenMemory do
    @moduledoc false
    def find_by_id(_), do: {:error, :database_down}
    def find_by_status(_), do: raise("boom")
  end

  defmodule AddNote do
    @moduledoc false
    use DDD.Command, transaction: false

    command do
      description "Write a note"

      field :text, :string, required: true, description: "What the note says"
      field :due, :date, description: "When it is due"
      field :tags, {:array, :string}, default: []
      field :price, :money
      field :status, {:enum, [:open, :done]}
    end

    @impl DDD.Command
    def execute(command) do
      attrs = command |> Map.from_struct() |> Enum.reject(fn {_, v} -> is_nil(v) end)

      with {:ok, note} <- Note.new(attrs), do: DDD.MCPTest.NoteMemory.save(note)
    end
  end

  defmodule Reject do
    @moduledoc false
    use DDD.Command, transaction: false

    command do
      description "Always refuses"
    end

    @impl DDD.Command
    def execute(_), do: {:error, {:nope, "not today"}}
  end

  defmodule Down do
    @moduledoc false
    use DDD.Command, transaction: false

    command do
      description "The database is down"
    end

    @impl DDD.Command
    def execute(_),
      do: {:error, DDD.Error.infrastructure(code: :db_down, message: "secret connection string")}
  end

  defmodule Crash do
    @moduledoc false
    use DDD.Command, transaction: false

    command do
      description "Raises"
    end

    @impl DDD.Command
    def execute(_), do: raise("kaboom with secrets")
  end

  defmodule Notes do
    @moduledoc false
    use DDD.Query, transaction: false

    query do
      description "The texts of the notes with a status"
      field :status, {:enum, [:open, :done]}, required: true, description: "Which notes"
    end

    @impl DDD.Query
    def execute(%__MODULE__{status: status}) do
      {:ok,
       for(
         n <- DDD.MCPTest.NoteMemory.find_by_status(status),
         do: %{text: n.text, at: ~D[2030-01-01]}
       )}
    end
  end

  defmodule Policy do
    @moduledoc false
    def authorize("add_note", %{"text" => "forbidden"}), do: {:error, "that text is not allowed"}
    def authorize("resource:note", %{"uri" => "note://by/status/done"}), do: {:error, "no"}
    def authorize(_, _), do: :ok
  end

  # Every way a policy can say no.
  defmodule StrictPolicy do
    @moduledoc false
    def authorize("reject", _),
      do: {:error, DDD.Error.business(code: :custom, message: "custom no")}

    def authorize("down", _), do: {:error, :nope}
    def authorize("crash", _), do: :maybe
    def authorize(_, _), do: :ok
  end

  defmodule StrictServer do
    @moduledoc false
    use DDD.MCP.Server,
      commands: [{Reject, name: "reject"}, {Down, name: "down"}, {Crash, name: "crash"}],
      authorize: &DDD.MCPTest.StrictPolicy.authorize/2
  end

  defmodule Server do
    @moduledoc false
    use DDD.MCP.Server,
      name: "notes",
      version: "9.9.9",
      instructions: "Write and read notes.",
      commands: [AddNote, {Reject, name: "reject"}, {Down, name: "down"}, {Crash, name: "crash"}],
      queries: [Notes],
      repos: [NoteRepository],
      authorize: &DDD.MCPTest.Policy.authorize/2
  end

  defmodule ReadOnlyServer do
    @moduledoc false
    use DDD.MCP.Server,
      commands: [AddNote],
      queries: [Notes],
      repos: [{Note, repository: NoteRepository}],
      read_only: true
  end

  defmodule BrokenServer do
    @moduledoc false
    use DDD.MCP.Server, repos: [BrokenNoteRepository]
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  setup do
    start_supervised!(NoteMemory)
    :ok
  end

  defp rpc(server, method, params \\ nil, id \\ 1) do
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    message = if params, do: Map.put(message, "params", params), else: message
    {:reply, response} = server.handle(message)
    response
  end

  defp result(server, method, params \\ nil), do: rpc(server, method, params)["result"]

  defp call(server, name, arguments \\ %{}),
    do: result(server, "tools/call", %{"name" => name, "arguments" => arguments})

  defp text(%{"content" => [%{"text" => text}]}), do: text
  defp json(call_result), do: call_result |> text() |> Jason.decode!()

  defp note!(attrs \\ []) do
    {:ok, note} = Note.new(Keyword.merge([text: "buy milk"], attrs))
    {:ok, _} = NoteMemory.save(note)
    note
  end

  # ── Protocol ──────────────────────────────────────────────────────────────

  describe "initialize" do
    test "reports the server, its capabilities and instructions" do
      result =
        result(Server, "initialize", %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "t", "version" => "1"}
        })

      assert result["protocolVersion"] == "2025-03-26"
      assert result["serverInfo"] == %{"name" => "notes", "version" => "9.9.9"}
      assert result["instructions"] == "Write and read notes."
      assert result["capabilities"]["tools"] == %{"listChanged" => false}

      assert result["capabilities"]["resources"] == %{
               "subscribe" => false,
               "listChanged" => false
             }
    end

    test "an unknown protocol version is answered with the latest one we speak" do
      assert result(Server, "initialize", %{"protocolVersion" => "1999-01-01"})["protocolVersion"] ==
               "2025-06-18"

      assert result(Server, "initialize", %{})["protocolVersion"] == "2025-06-18"
    end

    test "a server with nothing to offer claims no capability" do
      defmodule Empty do
        use DDD.MCP.Server, []
      end

      assert result(Empty, "initialize", %{})["capabilities"] == %{}
      refute Map.has_key?(result(Empty, "initialize", %{}), "instructions")
    end

    test "a read-only server with only commands offers no tools" do
      defmodule OnlyCommands do
        use DDD.MCP.Server, commands: [AddNote], read_only: true
      end

      assert result(OnlyCommands, "initialize", %{})["capabilities"] == %{}
    end

    test "name and version default to the application's" do
      info = result(DDD.Test.MCPServer, "initialize", %{})["serverInfo"]
      assert info["name"] == "vicander"
      assert info["version"] == "0.1.0"

      # A server outside any application has no name or version of its own.
      assert result(ReadOnlyServer, "initialize", %{})["serverInfo"] ==
               %{"name" => "ddd", "version" => "0.0.0"}
    end
  end

  describe "messages" do
    test "a notification gets no reply" do
      assert :noreply =
               Server.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    end

    test "ping" do
      assert result(Server, "ping") == %{}
    end

    test "an unknown method" do
      assert %{"error" => %{"code" => -32_601, "message" => "Method not found: nope"}} =
               rpc(Server, "nope")
    end

    test "something that is not a request" do
      assert {:reply, %{"error" => %{"code" => -32_600}, "id" => nil}} = Server.handle("hello")
      assert {:reply, %{"error" => %{"code" => -32_600}, "id" => 7}} = Server.handle(%{"id" => 7})
      assert {:reply, %{"error" => %{"code" => -32_600}}} = Server.handle([%{}])
      assert %{"error" => %{"code" => -32_700}} = DDD.MCP.parse_error()
    end

    test "a string id is echoed back" do
      assert %{"id" => "abc"} = rpc(Server, "ping", nil, "abc")
    end
  end

  # ── Tools ─────────────────────────────────────────────────────────────────

  describe "tools/list" do
    test "lists commands and queries by name, sorted, with their descriptions" do
      tools = result(Server, "tools/list")["tools"]
      assert Enum.map(tools, & &1["name"]) == ~w(add_note crash down notes reject)
      assert Enum.find(tools, &(&1["name"] == "add_note"))["description"] == "Write a note"
    end

    test "queries are read-only, commands are not" do
      tools = Map.new(result(Server, "tools/list")["tools"], &{&1["name"], &1})
      assert tools["notes"]["annotations"] == %{"readOnlyHint" => true}
      assert tools["add_note"]["annotations"] == %{"readOnlyHint" => false}
    end

    test "the input schema comes from the command's fields" do
      tool = Enum.find(result(Server, "tools/list")["tools"], &(&1["name"] == "add_note"))
      schema = tool["inputSchema"]
      props = schema["properties"]

      assert schema["type"] == "object"
      assert schema["additionalProperties"] == false
      assert schema["required"] == ["text"]
      assert props["text"] == %{"type" => "string", "description" => "What the note says"}

      assert props["due"] == %{
               "type" => "string",
               "format" => "date",
               "description" => "When it is due"
             }

      assert props["tags"] == %{
               "type" => "array",
               "items" => %{"type" => "string"},
               "default" => []
             }

      assert props["status"] == %{"type" => "string", "enum" => ["open", "done"]}
      assert props["price"]["type"] == "object"
      assert props["price"]["properties"]["currency"] == %{"type" => "string"}
      assert props["price"]["properties"]["amount"]["type"] == ["string", "number"]
    end

    test "a command without fields has no required list" do
      tool = Enum.find(result(Server, "tools/list")["tools"], &(&1["name"] == "reject"))

      assert tool["inputSchema"] == %{
               "type" => "object",
               "properties" => %{},
               "additionalProperties" => false
             }
    end

    test "a read-only server hides command tools" do
      assert Enum.map(result(ReadOnlyServer, "tools/list")["tools"], & &1["name"]) == ["notes"]
    end
  end

  describe "tools/call" do
    test "a command runs with arguments cast from JSON" do
      result =
        call(Server, "add_note", %{
          "text" => "buy milk",
          "due" => "2030-05-06",
          "tags" => ["home", "food"],
          "status" => "done",
          "price" => %{"amount" => "2.50", "currency" => "EUR"}
        })

      assert result["isError"] == false
      body = json(result)
      assert body["text"] == "buy milk"
      assert body["due"] == "2030-05-06"
      assert body["tags"] == ["home", "food"]
      assert body["status"] == "done"
      assert body["price"]["currency"] == "EUR"
      assert {:ok, saved} = NoteMemory.find_by_id(body["id"])
      assert saved.due == ~D[2030-05-06]
      assert saved.price.amount == Decimal.new("2.50")
    end

    test "a query returns its data" do
      note!(text: "a")
      result = call(Server, "notes", %{"status" => "open"})
      assert result["isError"] == false
      assert json(result) == [%{"text" => "a", "at" => "2030-01-01"}]
    end

    test "a null argument counts as absent" do
      assert %{"isError" => false} = call(Server, "add_note", %{"text" => "x", "due" => nil})
    end

    test "a missing required argument is a business error with the violation" do
      result = call(Server, "add_note", %{})
      assert result["isError"] == true
      body = json(result)["error"]
      assert body["code"] == "validation_failed"
      assert [%{"field" => "text", "code" => "required"}] = body["violations"]
    end

    test "an argument that can't be converted is reported under its name" do
      result = call(Server, "add_note", %{"text" => "x", "due" => "tomorrow", "status" => "gone"})
      violations = json(result)["error"]["violations"]
      assert Enum.sort(Enum.map(violations, & &1["field"])) == ["due", "status"]
      assert Enum.all?(violations, &(&1["code"] == "invalid_type"))
    end

    test "a nested value that breaks its own rules is explained" do
      result =
        call(Server, "add_note", %{
          "text" => "x",
          "price" => %{"amount" => "1", "currency" => "euro"}
        })

      [violation] = json(result)["error"]["violations"]
      assert violation["field"] == "price"
      assert violation["code"] == "invalid"
      assert violation["details"]["errors"]["currency"] == ["must be a 3-letter code"]
    end

    test "a nested value is built through new/1, never loaded as already valid" do
      result = call(Server, "add_note", %{"text" => "x", "price" => %{"currency" => "EUR"}})
      assert [%{"field" => "price"}] = json(result)["error"]["violations"]
    end

    test "unknown tools and arguments are protocol errors" do
      assert %{"error" => %{"code" => -32_602, "message" => "Unknown tool: nope"}} =
               rpc(Server, "tools/call", %{"name" => "nope"})

      assert %{"error" => %{"message" => message}} =
               rpc(Server, "tools/call", %{
                 "name" => "add_note",
                 "arguments" => %{"text" => "x", "zzz" => 1, "aaa" => 2}
               })

      assert message == "Unknown argument(s) for add_note: aaa, zzz"

      assert %{"error" => %{"code" => -32_602}} =
               rpc(Server, "tools/call", %{"name" => "notes", "arguments" => [1]})

      assert %{"error" => %{"code" => -32_602}} = rpc(Server, "tools/call", %{})
      assert %{"error" => %{"code" => -32_602}} = rpc(Server, "tools/call", %{"name" => 5})
    end

    test "arguments may be left out" do
      assert %{"isError" => true} = rpc(Server, "tools/call", %{"name" => "reject"})["result"]
    end

    test "a business error from the handler is shown" do
      result = call(Server, "reject")
      assert result["isError"] == true
      assert %{"error" => %{"code" => "nope", "message" => "not today"}} = json(result)
    end

    test "an infrastructure error is generic and its details stay in the log" do
      log = capture_log(fn -> send(self(), {:result, call(Server, "down")}) end)
      assert_received {:result, result}
      assert result["isError"] == true
      assert text(result) == "The operation failed. Try again later."
      refute text(result) =~ "secret"
      assert log =~ "secret connection string"
    end

    test "a crash is generic too" do
      log = capture_log(fn -> send(self(), {:result, call(Server, "crash")}) end)
      assert_received {:result, result}
      assert text(result) == "The operation failed. Try again later."
      refute text(result) =~ "secrets"
      assert log =~ "kaboom"
    end

    test "tool calls are logged" do
      log = capture_log(fn -> call(Server, "add_note", %{"text" => "x"}) end)
      assert log =~ "[mcp] tool add_note ok"
      log = capture_log(fn -> call(Server, "reject") end)
      assert log =~ "[mcp] tool reject failed"
    end
  end

  describe "read-only and authorization" do
    test "a read-only server refuses a command even if it is asked for by name" do
      result = call(ReadOnlyServer, "add_note", %{"text" => "x"})
      assert result["isError"] == true
      assert json(result)["error"]["code"] == "read_only"
      assert NoteMemory.count() == 0
      assert %{"isError" => false} = call(ReadOnlyServer, "notes", %{"status" => "open"})
    end

    test "the read-only option of serve/1 overrides the server" do
      {:ok, input} =
        StringIO.open(~s({"jsonrpc":"2.0","id":1,"method":"tools/list"}\n))

      {:ok, output} = StringIO.open("")
      :ok = Server.serve(read_only: true, input: input, output: output)
      {_, written} = StringIO.contents(output)
      names = written |> Jason.decode!() |> get_in(["result", "tools"]) |> Enum.map(& &1["name"])
      assert names == ["notes"]
    end

    test "authorize can refuse with a message, with an error, or by returning garbage" do
      result = call(Server, "add_note", %{"text" => "forbidden"})
      assert result["isError"] == true

      assert json(result)["error"] == %{
               "code" => "not_authorized",
               "message" => "that text is not allowed"
             }

      assert NoteMemory.count() == 0

      assert json(call(StrictServer, "reject"))["error"]["code"] == "custom"
      assert json(call(StrictServer, "down"))["error"]["message"] == "Not allowed."
      assert json(call(StrictServer, "crash"))["error"]["message"] == "Not allowed."
    end

    test "authorize is called with the tool name and the raw arguments" do
      assert %{"isError" => false} = call(Server, "add_note", %{"text" => "fine"})
    end
  end

  # ── Resources ─────────────────────────────────────────────────────────────

  describe "resources" do
    test "resources/list is empty on purpose" do
      note!()
      assert result(Server, "resources/list") == %{"resources" => []}
    end

    test "templates: one by identity, one per declared lookup" do
      templates = result(Server, "resources/templates/list")["resourceTemplates"]

      assert Enum.map(templates, & &1["uriTemplate"]) == [
               "note://{id}",
               "note://by/status/{status}",
               "note://by/status/{status}/text/{text}",
               "note://by/due/{due}"
             ]

      assert Enum.map(templates, & &1["name"]) ==
               ["note", "note_by_status", "note_by_status_and_text", "note_by_due"]

      assert hd(templates)["description"] == "A note someone wrote"
      assert Enum.all?(templates, &(&1["mimeType"] == "application/json"))
      assert Enum.at(templates, 1)["description"] =~ "lookup by status, at most 100 results"
    end

    test "reads one aggregate by its identity, with every field" do
      note = note!(due: ~D[2030-01-01])
      uri = "note://#{note.id}"
      [content] = result(Server, "resources/read", %{"uri" => uri})["contents"]
      assert content["uri"] == uri
      assert content["mimeType"] == "application/json"
      body = Jason.decode!(content["text"])
      assert body["id"] == note.id
      assert body["text"] == "buy milk"
      assert body["due"] == "2030-01-01"
      assert body["status"] == "open"
      assert Map.has_key?(body, "created_at")
    end

    test "a lookup by one field, a typed value and several fields" do
      note!(text: "a")
      note!(text: "b", due: ~D[2030-01-01], status: :done)

      read = fn uri ->
        Jason.decode!(hd(result(Server, "resources/read", %{"uri" => uri})["contents"])["text"])
      end

      assert %{"count" => 1, "truncated" => false, "limit" => 100, "items" => [%{"text" => "a"}]} =
               read.("note://by/status/open")

      assert %{"items" => [%{"text" => "b"}]} = read.("note://by/due/2030-01-01")
      assert %{"items" => [%{"text" => "b"}]} = read.("note://by/status/done/text/b")
      assert %{"items" => []} = read.("note://by/status/done/text/zzz")
    end

    test "a lookup is capped at 100 and says so" do
      for n <- 1..101, do: note!(text: "n#{n}")
      uri = "note://by/status/open"

      body =
        Jason.decode!(hd(result(Server, "resources/read", %{"uri" => uri})["contents"])["text"])

      assert body["count"] == 100
      assert body["truncated"] == true
      assert length(body["items"]) == 100
    end

    test "what is not there is 'not found'" do
      for uri <- [
            "note://#{UUID.uuid4()}",
            "other://x",
            "no-scheme",
            "note://by/colour/red",
            "note://by/status",
            "note://by/due/not-a-date",
            "note://by/status/open/extra"
          ] do
        response = rpc(Server, "resources/read", %{"uri" => uri})
        assert %{"error" => %{"code" => -32_002}} = response, uri
      end
    end

    test "resources/read needs a uri" do
      assert %{"error" => %{"code" => -32_602}} = rpc(Server, "resources/read", %{})
    end

    test "a failure reading is generic" do
      log =
        capture_log(fn ->
          for uri <- ["note://anything", "note://by/status/open"] do
            assert %{
                     "error" => %{
                       "code" => -32_603,
                       "message" => "The resource could not be read."
                     }
                   } =
                     rpc(BrokenServer, "resources/read", %{"uri" => uri})
          end
        end)

      assert log =~ "database_down"
    end

    test "authorize can refuse a read" do
      assert %{"error" => %{"code" => -32_001, "message" => "no"}} =
               rpc(Server, "resources/read", %{"uri" => "note://by/status/done"})
    end

    test "a read-only server still reads" do
      note = note!()

      assert %{"contents" => [_]} =
               result(ReadOnlyServer, "resources/read", %{"uri" => "note://#{note.id}"})
    end
  end

  # ── The registry ──────────────────────────────────────────────────────────

  describe "building a server" do
    defp build(opts), do: Registry.build!(DDD.MCPTest.Server, opts)

    defmodule Mute do
      use DDD.Command, transaction: false

      command do
      end

      def execute(_), do: {:ok, 1}
    end

    defmodule MuteNote do
      use DDD.Aggregate

      aggregate do
        identity :id, :uuid
      end
    end

    test "an exposed module without a description fails at startup" do
      assert_raise ArgumentError, ~r/Mute is exposed over MCP but has no description/, fn ->
        build(commands: [Mute])
      end

      assert_raise ArgumentError, ~r/MuteNote is exposed over MCP but has no description/, fn ->
        build(repos: [{MuteNote, repository: NoteRepository}])
      end
    end

    test "two tools with one name fail, naming both" do
      assert_raise ArgumentError, ~r/two tools are named "reject": .*Reject and .*Reject/, fn ->
        build(commands: [Reject, Reject])
      end

      assert %Registry{tools: %{"nope" => _, "reject" => _}} =
               build(commands: [Reject, {Reject, name: "nope"}])
    end

    test "a command and a query may not share a name either" do
      defmodule Query.Reject do
        use DDD.Query, transaction: false

        query do
          description "x"
        end

        def execute(_), do: {:ok, 1}
      end

      assert_raise ArgumentError, ~r/two tools are named "reject"/, fn ->
        build(commands: [Reject], queries: [Query.Reject])
      end
    end

    test "only commands are listed as commands and queries as queries" do
      assert_raise ArgumentError, ~r/Notes is not a command/, fn -> build(commands: [Notes]) end
      assert_raise ArgumentError, ~r/Reject is not a query/, fn -> build(queries: [Reject]) end
    end

    test "an entity needs a repository with impl/0" do
      assert_raise ArgumentError, ~r/needs a repository to be exposed/, fn ->
        build(repos: [Note])
      end

      assert_raise ArgumentError, ~r/neither an aggregate nor a repository port/, fn ->
        build(repos: [Reject])
      end

      defmodule NoImpl do
        use DDD.Repository

        repo Note do
        end
      end

      assert_raise ArgumentError, ~r/must define impl\/0/, fn -> build(repos: [NoImpl]) end
    end

    test "names can be overridden for entities too" do
      registry = build(repos: [{NoteRepository, name: "memo"}])
      assert Map.keys(registry.repos) == ["memo"]
    end

    test "the built registry is cached" do
      assert Server.registry() == Server.registry()
    end
  end

  # ── Stdio ─────────────────────────────────────────────────────────────────

  describe "stdio" do
    defp session(lines) do
      {:ok, input} = StringIO.open(Enum.join(lines, "\n") <> "\n")
      {:ok, output} = StringIO.open("")
      :ok = Server.serve(input: input, output: output)
      {_, written} = StringIO.contents(output)
      written |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    end

    test "one reply per request, none for notifications, blank lines and bad JSON handled" do
      replies =
        session([
          ~s({"jsonrpc":"2.0","id":1,"method":"ping"}),
          "",
          ~s({"jsonrpc":"2.0","method":"notifications/initialized"}),
          "this is not json",
          ~s({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"notes","arguments":{"status":"open"}}})
        ])

      assert [
               %{"id" => 1, "result" => %{}},
               %{"id" => nil, "error" => %{"code" => -32_700}},
               %{"id" => 2} = last
             ] =
               replies

      assert last["result"]["isError"] == false
    end

    test "the loop ends when the input ends" do
      assert session([]) == []
    end

    test "a read error ends the loop" do
      # A closed device: reading from it fails instead of returning a line.
      {:ok, input} = StringIO.open("")
      StringIO.close(input)
      {:ok, output} = StringIO.open("")

      capture_log(fn -> assert :ok = Server.serve(input: input, output: output) end)
    end
  end

  # ── Pieces ────────────────────────────────────────────────────────────────

  describe "DDD.MCP.Json" do
    defmodule Plain do
      defstruct [:a, :b]
    end

    defmodule Sealed do
      defstruct [:__sealed__, :x]
    end

    test "converts what domain results contain" do
      {:ok, price} = DDD.Money.of("1.50", "EUR")

      value = %{
        "string key" => 1,
        42 => :int_key,
        atom: :done,
        nil: nil,
        bool: true,
        dec: Decimal.new("1.5"),
        date: ~D[2030-01-02],
        time: ~T[10:00:00],
        naive: ~N[2030-01-02 10:00:00],
        dt: ~U[2030-01-02 10:00:00Z],
        money: price,
        plain: %Plain{a: 1, b: :x},
        tuple: {1, :a},
        list: [1, :b],
        pid: self()
      }

      out = Json.prepare(value)
      assert out["atom"] == "done"
      assert out["nil"] == nil
      assert out["dec"] == "1.5"
      assert out["date"] == "2030-01-02"
      assert out["time"] == "10:00:00"
      assert out["naive"] == "2030-01-02T10:00:00"
      assert out["dt"] == "2030-01-02T10:00:00Z"
      assert out["money"] == %{"amount" => "1.50", "currency" => "EUR"}
      assert out["plain"] == %{"a" => 1, "b" => "x"}
      assert out["tuple"] == [1, "a"]
      assert out["list"] == [1, "b"]
      assert out["pid"] =~ "#PID"
      assert out["string key"] == 1
      assert out["42"] == "int_key"
      assert is_binary(Json.encode(value))
    end

    test "a sealed struct that is not a DDD schema is converted structurally" do
      assert Json.prepare(struct(Sealed, __sealed__: 1, x: 2)) == %{"x" => 2}
    end
  end

  describe "DDD.MCP.Schema" do
    test "every scalar and composite type" do
      assert Schema.type(:text) == %{"type" => "string"}
      assert Schema.type(:atom) == %{"type" => "string"}
      assert Schema.type(:integer) == %{"type" => "integer"}
      assert Schema.type(:float) == %{"type" => "number"}
      assert Schema.type(:boolean) == %{"type" => "boolean"}
      assert Schema.type(:uuid) == %{"type" => "string", "format" => "uuid"}
      assert Schema.type(:time) == %{"type" => "string", "format" => "time"}
      assert Schema.type(:datetime) == %{"type" => "string", "format" => "date-time"}
      assert Schema.type(:naive_datetime) == %{"type" => "string", "format" => "date-time"}
      assert Schema.type(:binary) == %{"type" => "string", "contentEncoding" => "base64"}
      assert Schema.type(:map) == %{"type" => "object"}
      assert Schema.type(:json) == %{}
      assert Schema.type(:list) == %{"type" => "array"}

      assert Schema.type({:map, :integer}) == %{
               "type" => "object",
               "additionalProperties" => %{"type" => "integer"}
             }

      assert Schema.type({:ref, Note}) == %{"type" => "string", "format" => "uuid"}

      assert %{"type" => "array", "items" => %{"type" => "object"}} =
               Schema.type({:list, DDD.Money})
    end

    test "nesting stops at a depth" do
      assert Schema.type({:one, DDD.Money}, 0) == %{"type" => "object"}
      assert %{"properties" => _} = Schema.type({:one, DDD.Money}, 1)
    end

    test "defaults are advertised in their JSON form" do
      defmodule Defaults do
        use DDD.Command, transaction: false

        command do
          description "d"
          field :day, :date, default: ~D[2030-01-01]
          field :kind, {:enum, [:a, :b]}, default: :b
        end

        def execute(_), do: {:ok, 1}
      end

      props = Schema.input(Defaults)["properties"]
      assert props["day"]["default"] == "2030-01-01"
      assert props["kind"]["default"] == "b"
    end
  end

  describe "DDD.MCP.Args" do
    test "from_string/2 reads URI values" do
      assert Args.from_string(:integer, "42") == {:ok, 42}
      assert Args.from_string(:integer, "4x") == :error
      assert Args.from_string(:float, "1.5") == {:ok, 1.5}
      assert Args.from_string(:float, "x") == :error
      assert Args.from_string(:boolean, "true") == {:ok, true}
      assert Args.from_string(:boolean, "false") == {:ok, false}
      assert Args.from_string(:boolean, "yes") == :error
      assert Args.from_string(:date, "2030-01-02") == {:ok, ~D[2030-01-02]}
      assert Args.from_string(:date, "x") == :error
      assert Args.from_string({:enum, [:a]}, "a") == {:ok, :a}
      assert Args.from_string({:enum, [:a]}, "b") == :error
      assert Args.from_string(:string, "x") == {:ok, "x"}
      assert Args.from_string({:ref, Note}, "x") == :error
      assert {:ok, _} = Args.from_string({:ref, Note}, UUID.uuid4())
    end

    test "atoms are never created from input" do
      assert Args.from_string(:atom, "definitely_not_an_existing_atom_#{System.unique_integer()}") ==
               :error
    end

    test "composite values" do
      defmodule Composite do
        use DDD.Command, transaction: false

        command do
          description "c"
          field :amounts, {:array, :decimal}
          field :by_day, {:map, :date}
          field :prices, {:list, DDD.Money}
          field :owner, {:ref, DDD.MCPTest.Note}
        end

        def execute(_), do: {:ok, 1}
      end

      id = UUID.uuid4()

      assert {:ok, attrs} =
               Args.cast(Composite, %{
                 "amounts" => ["1.5", 2],
                 "by_day" => %{"a" => "2030-01-01"},
                 "prices" => [%{"amount" => "1", "currency" => "EUR"}],
                 "owner" => id
               })

      assert attrs.amounts == [Decimal.new("1.5"), Decimal.new(2)]
      assert attrs.by_day == %{"a" => ~D[2030-01-01]}
      assert [%DDD.Money{currency: "EUR"}] = attrs.prices
      assert attrs.owner == id

      for bad <- [
            %{"amounts" => "1"},
            %{"amounts" => ["x"]},
            %{"by_day" => %{"a" => "nope"}},
            %{"by_day" => [1]},
            %{"prices" => [%{"amount" => "1", "currency" => "no"}]},
            %{"prices" => ["EUR"]},
            %{"owner" => "x"}
          ] do
        assert {:error, %DDD.Error{}} = Args.cast(Composite, bad), inspect(bad)
      end
    end
  end
end

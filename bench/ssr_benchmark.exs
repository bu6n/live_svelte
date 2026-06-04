# SSR Benchmark: Node.js vs Deno
#
# Measures end-to-end SSR render latency for both runtimes, including IPC
# overhead, JSON serialisation, and JS execution time.
#
# Prerequisites:
#   mix deps.get
#   mix deps.compile
#
# Run:
#   mix run bench/ssr_benchmark.exs
#
# To benchmark against a real Svelte SSR bundle instead of the built-in
# fixture, set the LIVE_SVELTE_SERVER_JS environment variable:
#   LIVE_SVELTE_SERVER_JS=/path/to/priv/svelte mix run bench/ssr_benchmark.exs

# ---------------------------------------------------------------------------
# Fixture server.js
# A minimal ES module that mimics what the real Svelte SSR bundle does:
# it accepts (name, props, slots) and returns a JSON-encoded render result.
# It does enough string work to produce representative IPC + JS timings
# without requiring a compiled Svelte project.
# ---------------------------------------------------------------------------
fixture_js = """
function render(name, props, slots) {
  const propsEntries = Object.entries(props ?? {});
  const attrs = propsEntries
    .map(([k, v]) => `${k}="${String(v).replace(/"/g, '&quot;')}"`)
    .join(" ");
  const slotHtml = Object.values(slots ?? {}).join("");
  const html = `<div data-component="${name}" ${attrs}>${slotHtml}</div>`;
  const css = { code: "", map: null };
  return JSON.stringify({ html, head: "", css });
}

// Deno: expose on globalThis so DenoRider.eval can call it
if (typeof globalThis !== "undefined") globalThis.render = render;

// Node.js: named export consumed by NodeJS.call!/2
export { render };
"""

server_dir =
  case System.get_env("LIVE_SVELTE_SERVER_JS") do
    nil ->
      dir = Path.join(System.tmp_dir!(), "live_svelte_bench_#{System.os_time(:second)}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.js"), fixture_js)
      IO.puts("[bench] Using fixture server.js at #{dir}")
      dir

    path ->
      IO.puts("[bench] Using custom server.js at #{path}")
      path
  end

# ---------------------------------------------------------------------------
# Start supervisors
# ---------------------------------------------------------------------------
{:ok, _} = Application.ensure_all_started(:nodejs)

nodejs_started =
  case NodeJS.Supervisor.start_link(path: server_dir, pool_size: 4) do
    {:ok, _pid} ->
      IO.puts("[bench] NodeJS supervisor started (pool_size: 4)")
      true

    {:error, reason} ->
      IO.puts("[bench] WARNING: could not start NodeJS supervisor: #{inspect(reason)}")
      false
  end

deno_available = Code.ensure_loaded?(DenoRider)

deno_started =
  if deno_available do
    server_js = Path.join(server_dir, "server.js")

    case DenoRider.start_link(main_module_path: server_js) do
      {:ok, _pid} ->
        IO.puts("[bench] DenoRider started")
        true

      {:error, reason} ->
        IO.puts("[bench] WARNING: could not start DenoRider: #{inspect(reason)}")
        false
    end
  else
    IO.puts("[bench] Skipping Deno: deno_rider not in deps (add `{:deno_rider, \"~> 0.2\"}` to mix.exs)")
    false
  end

unless nodejs_started or deno_started do
  IO.puts("\nNo SSR runtime could be started. Exiting.")
  System.halt(1)
end

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------
scenarios_input = %{
  simple: {
    "Counter",
    %{"count" => 42, "label" => "clicks"},
    %{}
  },
  nested: {
    "UserCard",
    %{
      "user" => %{
        "id" => 1,
        "name" => "Alice",
        "email" => "alice@example.com",
        "role" => "admin",
        "meta" => %{"created_at" => "2024-01-01", "verified" => true}
      },
      "theme" => "dark"
    },
    %{}
  },
  large_list: {
    "DataTable",
    %{
      "rows" =>
        Enum.map(1..50, fn i ->
          %{"id" => i, "name" => "Item #{i}", "value" => i * 1.5, "active" => rem(i, 2) == 0}
        end),
      "page" => 1,
      "total" => 50
    },
    %{}
  },
  with_slots: {
    "Modal",
    %{"title" => "Confirm action", "variant" => "warning"},
    %{"default" => "<p>Are you sure you want to delete this item?</p>", "footer" => "<button>Cancel</button><button>OK</button>"}
  }
}

# ---------------------------------------------------------------------------
# Collect telemetry durations alongside Benchee for cross-validation
# ---------------------------------------------------------------------------
telemetry_samples = :ets.new(:bench_telemetry, [:public, :bag])

handler_id = :bench_telemetry_handler

:telemetry.attach(
  handler_id,
  [:live_svelte, :ssr, :stop],
  fn _event, %{duration: d}, %{component: c}, _ ->
    :ets.insert(telemetry_samples, {c, d})
  end,
  nil
)

# ---------------------------------------------------------------------------
# Build Benchee job map
# ---------------------------------------------------------------------------
make_job = fn mod, {name, props, slots} ->
  fn -> mod.render(name, props, slots) end
end

jobs =
  Enum.flat_map(scenarios_input, fn {scenario, args} ->
    node_jobs =
      if nodejs_started do
        [{"NodeJS / #{scenario}", make_job.(LiveSvelte.SSR.NodeJS, args)}]
      else
        []
      end

    deno_jobs =
      if deno_started do
        [{"Deno   / #{scenario}", make_job.(LiveSvelte.SSR.Deno, args)}]
      else
        []
      end

    node_jobs ++ deno_jobs
  end)
  |> Map.new()

# ---------------------------------------------------------------------------
# Run benchmark
# ---------------------------------------------------------------------------
IO.puts("\n=== LiveSvelte SSR Benchmark: Node.js vs Deno ===\n")

Benchee.run(
  jobs,
  time: 10,
  warmup: 2,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console
  ],
  print: [
    benchmarking: true,
    configuration: true,
    fast_warning: true
  ]
)

# ---------------------------------------------------------------------------
# Telemetry summary
# ---------------------------------------------------------------------------
:telemetry.detach(handler_id)

IO.puts("\n=== Telemetry duration summary (native → µs) ===\n")

telemetry_samples
|> :ets.tab2list()
|> Enum.group_by(&elem(&1, 0), &:erlang.convert_time_unit(elem(&1, 1), :native, :microsecond))
|> Enum.sort_by(&elem(&1, 0))
|> Enum.each(fn {component, durations} ->
  sorted = Enum.sort(durations)
  count = length(sorted)
  mean = Enum.sum(sorted) / count
  p50 = Enum.at(sorted, div(count, 2))
  p95 = Enum.at(sorted, floor(count * 0.95))
  p99 = Enum.at(sorted, floor(count * 0.99))

  IO.puts("  #{component}")
  IO.puts("    n=#{count}  mean=#{Float.round(mean, 1)}µs  p50=#{p50}µs  p95=#{p95}µs  p99=#{p99}µs")
end)

IO.puts("")

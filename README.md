<div align="center">
  <img src="./assets/Designer-9.png" height="120" alt="SnerdMQ Ruby Logo" />
  <h1>💎 SnerdMQ Ruby SDK v0.3.3</h1>
  <p>A zero-config, C-speed background job queue for Ruby. Ditch Redis and Sidekiq for lightweight, persistent background jobs.</p>

  [![Gem Version](https://badge.fury.io/rb/snerdmq.svg)](https://badge.fury.io/rb/snerdmq)
  [![Docs](https://img.shields.io/badge/docs-speed--nerd.github.io-blue)](https://speed-nerd.github.io/docs/)
</div>

This is the official Ruby SDK wrapper for **SnerdMQ**. It handles all JSON-RPC communication and `IO.popen` orchestration so you can write lightning-fast background jobs without managing any external databases like Redis or Postgres.

## ✨ v0.3.3 AI Features
- **Smart API Rate-Limiting**: Natively tracks `rate_limit_group` execution velocity to prevent 429 "Too Many Requests" API errors.
- **Payload-Hashing Deduplication**: Automatically computes cryptographic hashes to drop duplicate tasks instantly.
- **Dynamic Float Prioritization**: A native Binary Max-Heap bypasses standard FIFO rules for high urgency tasks.
- **Progress Streaming & Live Dashboard**: Handlers can stream progress updates to a built-in React UI dashboard served by the SDK.
- **Ditch Sidekiq & Redis**: Gives your Ruby apps persistent state, automatic retries, and dead-letter queues right out of the box with zero external infrastructure.
- **Zero Rust Required**: Our gem installation script automatically downloads the pre-compiled C-speed Rust binary for your OS.
- **Thread Safe**: Uses native Ruby `Thread`s and `Mutex` locks to orchestrate I/O without blocking your main event loop.

### ⚙️ Advanced Task Configuration (v0.3.3)
To power complex AI workflows, tasks can now be configured with advanced orchestration parameters:

* **`auto_dedupe` (`true/false`)**: If set to `true`, the daemon computes a cryptographic hash of the `task_type` and `data`. If an identical payload is currently sitting in the queue pending execution, this new task is silently dropped. Excellent for preventing duplicate generative AI requests from trigger-happy users!
* **`urgency_score` (`Float`)**: A value (e.g. `0.99`) used to bypass the standard FIFO queue. SnerdMQ uses a true Binary Max-Heap to continually float tasks with the highest urgency score to the very front of the execution line. Standard tasks default to `0.0`.
* **`rate_limit_group` (`String`)**: A custom string (e.g. `"openai_api"` or `"db_writes"`) that groups tasks together for backpressure control.
* **`max_per_minute` (`Integer`)**: Used in conjunction with `rate_limit_group`. If the queue processes more tasks in this group than the allowed limit within a 60-second rolling window, further tasks in this group are temporarily paused. This natively prevents 429 "Too Many Requests" errors when bursting third-party APIs.
* **`execute_at` (`String` | `Time`)**: A timestamp of when the job should be executed in the future.
* **`retry_after_hours` (`Float`)**: Backoff in **hours** before a failed job is retried (default `0.0`). See *Cron Jobs vs. Retryable Jobs* below.
* **`cron` (`String`)**: A cron expression (e.g. `"0 * * * *"`) for recurring jobs. Shorthands like `"2h"` or `"10m"` are also supported.
* **`webhook_url` (`String`)**: By providing a webhook URL, SnerdMQ will completely bypass your local Ruby blocks and dispatch the task payload via an HTTP POST request directly to the specified URL.
* **`max_execution_seconds` (`Integer`)**: Optional hard timeout in seconds. If execution takes longer, it's marked as failed.

### Note on Hard Timeouts (`max_execution_seconds`)
When `max_execution_seconds` is provided, the Ruby SDK wraps the execution of your handler in a `Timeout.timeout` block. If the task takes longer than the timeout, a `Timeout::Error` is raised and the execution will be marked as failed. The background Rust daemon also enforces this timeout at the IPC level.

### 🌐 HTTP Webhooks (Serverless Execution)
You can configure a task to execute externally via an HTTP POST request. By setting a `webhook_url`, the internal background processor will skip any registered handlers (`queue.register_handler`) and directly invoke the HTTP endpoint.

If the HTTP endpoint returns a non-200 status code, it triggers a retry. If it permanently fails (reaches `max_retries`), the Dead Letter Queue event is automatically fired via a final HTTP POST to the same `webhook_url` but with the header `X-SnerdMQ-Event: MaxRetriesReached`.

### 🕒 Cron Jobs vs. Retryable Jobs
When using the new scheduling features, it is important to understand the difference between Cron and Retry behaviors:
> - **A Cron Job** is a *Repeatable Job* that executes again **only after a success**, on a fixed schedule.
> - **A Retryable Job** is a *Recovery Job* that executes again **only after a failure**, attempting to recover using the `retry_after_hours` backoff.
> - **Combined:** If a Cron Job fails, it temporarily uses `retry_after_hours` to retry until it recovers. Once it succeeds, it goes back to ticking on its standard cron schedule!

## 📦 Installation

Installing the SDK is a simple two-step process:

**1. Install the gem:**
```bash
gem install snerdmq
# Or add `gem 'snerdmq'` to your Gemfile
```

**2. Download the Rust Engine:**
Run this script from your terminal immediately after installing the gem. It will fetch the correct highly-optimized SnerdMQ binary for your operating system (macOS/Linux/Windows) and place it securely inside the gem installation directory:
```bash
snerdmq-install
```

---

## ⚡ Quickstart

Using the SDK is incredibly simple. Initialize the queue, register your handler blocks, and start listening!

```ruby
require 'snerdmq'

# 1. Initialize the daemon in the background
queue = Snerdmq::SnerdQueue.new

# 2. Register your background job logic using a standard block
queue.register_handler("send_email") do |data|
  to = data["to"]
  subject = data["subject"]
  puts "Sending email to #{to} with subject: #{subject}..."
  
  # Raise an exception here to automatically trigger SnerdMQ's retry logic!
end

# 3. Start the non-blocking Thread listeners
queue.start_listening
puts "SnerdMQ Ruby SDK is listening for jobs..."

# 4. Enqueue a job from anywhere in your codebase
queue.enqueue(
  task_id: "email-123",
  task_type: "send_email",
  data: { "to" => "john@wick.com", "subject" => "Continental Update" },
  max_retries: 3,
  retry_after_hours: 0.5,      # Wait 30 minutes before retrying a failed job
  rate_limit_group: "email_api",
  max_per_minute: 100
)

# 5. Need scheduling, deduplication, or serverless execution? All
# orchestration options are opt-in — combine only what you need:
queue.enqueue(
  task_id: "email-digest-1",
  task_type: "send_email",
  data: { "to" => "john@wick.com", "subject" => "Daily Digest" },
  cron: "0 8 * * *",           # Run every day at 08:00
  auto_dedupe: true,           # Drop identical pending payloads
  urgency_score: 0.99,         # Float to the front of the queue
  webhook_url: "https://api.example.com/webhook", # Execute via HTTP instead of local blocks
  max_execution_seconds: 300   # Hard timeout
)

# Keep main thread alive
sleep
```

### ☠️ Dead Letter Queue (Handling Permanent Failures)

When a task fails repeatedly and exhausts its `max_retries`, the SnerdMQ daemon permanently moves it to the Dead Letter Queue. You can hook into this event to alert your team, update your database, or send a Slack message by registering a Max Retry Handler.

```ruby
# 5. Catch tasks that have permanently failed (Dead Letter Queue)
queue.register_max_retry_handler('send_email') do |data|
  puts "Email task failed after all retries! Data: #{data.inspect}"
end
```

---

## 📊 Live Dashboard

SnerdMQ ships with a built-in **React UI dashboard** served directly by the SDK — no extra services or ports to manage in your infrastructure. It gives you a real-time window into your queue:

- **Live stats**: total enqueued, processed, and failed jobs
- **Recent Jobs table**: per-task status (`queued`, `active`, `completed`, `failed`, `dead_letter`), retry counts, and badges showing which features a task uses (cron / webhook / timeout)
- **Real-time Progress Stream**: live output from `yield_progress` calls in your handlers

```ruby
queue = Snerdmq::SnerdQueue.new

# Start the built-in dashboard on http://localhost:9090
queue.start_dashboard(port: 9090)

# ... register handlers, start listening, enqueue jobs ...
```

Then open **http://localhost:9090** in your browser. The dashboard UI automatically uses HTTP polling to stay up to date (progress events included), and the SDK also exposes a small JSON API (`/api/stats`, `/api/tasks`, `/api/progress`) if you want to build your own tooling on top. The dashboard assets ship inside the gem — nothing extra to deploy.

> **Note:** `start_dashboard` only serves the UI — your jobs keep running whether or not the dashboard is open.

---

## 📡 Progress Reporting

Long-running handlers can stream live updates to the Dashboard's Progress Stream (ideal for streaming LLM tokens or multi-step ETL work):

```ruby
queue.register_handler("generate_report") do |data|
  (1..10).each do |step|
    do_work(step)
    queue.yield_progress("Step #{step}/10 complete")
  end
end
```

> `yield_progress` must be called **inside a task handler** — the SDK tracks which task is currently executing so each update lands on the right job in the dashboard.

---

## 🧩 Queue Topology: One Queue or Many?

### ✅ Recommended: one queue, all job types (singleton)

Each `Snerdmq::SnerdQueue` client spawns its own Rust daemon and **exclusively owns** its storage directory (`.snerdata` by default). The recommended pattern is **one client per application process**: register every job type on it and serve a single shared dashboard:

```ruby
require 'snerdmq'

# ONE queue client for the whole app
queue = Snerdmq::SnerdQueue.new

# Job type #1: image processing
queue.register_handler("process_image") do |data|
  puts "Processing image: #{data['image_id']}"
end

# Job type #2: OTP emails — same queue, same daemon
queue.register_handler("send_otp_email") do |data|
  puts "Sending OTP to: #{data['to']}"
end

queue.start_listening

# Both job types flow through the exact same queue
queue.enqueue(task_id: "img-1", task_type: "process_image", data: { "image_id" => "abc123" }, max_retries: 3, retry_after_hours: 0.5)
queue.enqueue(task_id: "otp-1", task_type: "send_otp_email", data: { "to" => "john@wick.com" }, max_retries: 3, retry_after_hours: 0.5)

# ONE dashboard shows every job type
queue.start_dashboard(port: 8080)
```

All job types share everything: the same persistent job log, retry/DLQ pipeline, rate-limit state, stats — and one dashboard at `http://localhost:8080` showing all of them.

### 🚫 Same storage twice = fails fast

The daemon takes an **exclusive OS-level lock** on its storage directory at startup. A second client on the same storage fails instead of silently double-executing your jobs:

```ruby
first = Snerdmq::SnerdQueue.new   # ✅ owns .snerdata
second = Snerdmq::SnerdQueue.new  # ❌ daemon refuses to start:
# "Another daemon is already running on storage '.snerdata'"
```

This applies across processes too — with **Puma/Unicorn clustered workers, every worker is a separate process** that spawns its own daemon, so each worker needs its own `storage_path` (or run a single dedicated worker process for jobs).

### 🔀 Need multiple queues? Give each one its own storage

```ruby
images = Snerdmq::SnerdQueue.new(storage_path: ".snerdata-images")
emails = Snerdmq::SnerdQueue.new(storage_path: ".snerdata-emails")

images.start_dashboard(port: 8080) # separate dashboards, so separate ports
emails.start_dashboard(port: 8081)
```

Now you have two fully independent engines: separate job logs, separate rate-limit state, separate dashboards. Only split when you actually need isolation (different teams, different retention, independent monitoring) — otherwise the singleton is simpler and recommended.

---

## 🌍 Advanced: Distributed Scaling

Because the daemon exclusively locks its storage directory, scaling horizontally means **one queue per server**, each with its own storage. Your load balancer routes requests across servers, and every server processes the jobs it enqueued:

```ruby
require 'snerdmq'

# Each server runs its own daemon on its own storage dir (local disk works fine)
queue = Snerdmq::SnerdQueue.new(storage_path: "/var/data/snerd") # per-server storage
```

A shared network drive (AWS EFS or NFS) is still a good home for that storage when a single instance needs durable state — e.g. a container that restarts but must keep its queue. Native OS file locking (`flock`) keeps writes safe — no Redis required.

*Built with ❤️ for John Wick tier engineering.*


## Architecture Best Practices

When building production applications with SnerdMQ, it is recommended to initialize the queue as a Singleton, isolate your domain workers into separate files/functions, use Dead Letter Queues (DLQ) for failed tasks via `RegisterMaxRetryHandler`, and ensure manual graceful shutdown. The embedded Dashboard UI can also be easily served from the same instance.

```ruby
require 'snerdmq'

queue = SnerdQueue.new(storage_path: "./.snerdata")

def init_email_workers(queue)
  queue.register_handler('send_email') do |data|
    puts "Sending email to #{data['email']}..."
  end

  queue.register_max_retry_handler('send_email') do |data|
    puts "Email to #{data['email']} failed permanently. Dead letter processing..."
  end
end

def init_image_workers(queue)
  queue.register_handler('process_image') do |data|
    puts "Processing image #{data['imageId']}..."
  end
end

init_email_workers(queue)
init_image_workers(queue)

queue.start_dashboard(8080)

# Trap signals for graceful shutdown
trap('INT') { queue.shutdown; exit }
trap('TERM') { queue.shutdown; exit }

queue.start_listening
```

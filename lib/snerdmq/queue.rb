require 'json'
require 'thread'
require 'timeout'
require 'time'

module Snerdmq
  class SnerdQueue
    def initialize(binary_path: nil, storage_path: nil)
      @binary_path = binary_path
      @storage_path = storage_path
      
      if @binary_path.nil?
        ext = RbConfig::CONFIG['host_os'].match?(/mswin|msys|mingw|cygwin|bccwin|wince|emc/) ? '.exe' : ''
        # Assume the binary was downloaded into the gem's bin/ directory via snerdmq-install
        @binary_path = File.expand_path("../../bin/snerdmq#{ext}", __dir__)
      end

      unless File.exist?(@binary_path)
        raise "[Snerd] Binary not found at #{@binary_path}. Ensure it is compiled or run 'snerdmq-install'."
      end

      @handlers = {}
      @max_retry_handlers = {}
      @handlers_mutex = Mutex.new
      
      @stdin_mutex = Mutex.new
      @shutting_down = false
      @io = nil
      @listener_thread = nil
      @pending_enqueues = {}
      @pending_mutex = Mutex.new
      @ws_clients = []
      @ws_mutex = Mutex.new
    end

    def register_handler(task_type, &block)
      @handlers_mutex.synchronize do
        @handlers[task_type] = block
      end

      if @io && !@shutting_down
        send_message({
          action: "register",
          task_type: task_type
        })
      end
    end

    def register_max_retry_handler(task_type, &block)
      @handlers_mutex.synchronize do
        @max_retry_handlers[task_type] = block
      end
    end

    def start_listening
      args = []
      args << @storage_path if @storage_path

      # Open a bidirectional pipe to the Rust daemon
      @io = IO.popen([@binary_path] + args, "r+")

      # Re-register all existing handlers
      @handlers_mutex.synchronize do
        @handlers.keys.each do |task_type|
          send_message({
            action: "register",
            task_type: task_type
          })
        end
      end

      @listener_thread = Thread.new do
        listen_to_stdout
      end
    end

    def enqueue(task_id:, task_type:, data:, max_retries: 3, retry_after_hours: 0.0, rate_limit_group: nil, max_per_minute: nil, auto_dedupe: false, urgency_score: nil, execute_at: nil, cron: nil, webhook_url: nil, max_execution_seconds: nil, trigger_after_ids: nil)
      raise "[Snerd] Cannot enqueue task: Queue is not running. Call start_listening first." if @io.nil? || @shutting_down
      
      payload = {
        action: "enqueue",
        task_id: task_id,
        task_type: task_type,
        task_data: data.to_json,
        max_retries: max_retries,
        retry_after_hours: retry_after_hours
      }

      payload[:rate_limit_group] = rate_limit_group if rate_limit_group
      payload[:max_per_minute] = max_per_minute if max_per_minute
      payload[:auto_dedupe] = auto_dedupe if auto_dedupe
      payload[:urgency_score] = urgency_score if urgency_score
      
      if execute_at
        payload[:execute_at] = execute_at.respond_to?(:iso8601) ? execute_at.iso8601 : execute_at.to_s
      end
      payload[:cron] = cron if cron
      payload[:webhook_url] = webhook_url if webhook_url
      payload[:max_execution_seconds] = max_execution_seconds if max_execution_seconds
      payload[:trigger_after_ids] = trigger_after_ids if trigger_after_ids

      cond = ConditionVariable.new
      result = nil
      
      @pending_mutex.synchronize do
        @pending_enqueues[task_id] = { cond: cond, result: nil }
      end

      send_message(payload)

      @pending_mutex.synchronize do
        # Wait up to 5 seconds for Ack
        cond.wait(@pending_mutex, 5.0) if @pending_enqueues[task_id][:result].nil?
        pending = @pending_enqueues.delete(task_id)
        result = pending[:result] if pending
      end

      if result.nil?
        raise "[Snerd] Timeout waiting for daemon Ack on task #{task_id}"
      elsif result.is_a?(StandardError)
        raise result
      end
      
      true
    end

    def shutdown
      @shutting_down = true
      begin
        Process.kill("TERM", @io.pid) if @io && @io.pid
      rescue Errno::ESRCH, Errno::ECHILD
        # Process already dead
      end
      
      @listener_thread.join(2) if @listener_thread
      @io.close if @io && !@io.closed?
    end

    def listen_to_stdout
      @io.each_line do |line|
        next if line.strip.empty?

        begin
          msg = JSON.parse(line)
           
          
          if msg["action"] == "execute"
            # Execute in a short-lived thread so we don't block the stdout listener loop
            Thread.new { handle_execute(msg) }
          elsif msg["action"] == "ack"
            if msg["task_id"]
              @pending_mutex.synchronize do
                if pending = @pending_enqueues[msg["task_id"]]
                  pending[:result] = true
                  pending[:cond].signal
                end
              end
            end
          elsif msg["action"] == "error"
            if msg["task_id"]
              @pending_mutex.synchronize do
                if pending = @pending_enqueues[msg["task_id"]]
                  pending[:result] = StandardError.new(msg["message"])
                  pending[:cond].signal
                end
              end
            else
              warn "[Snerd] Error from engine: #{msg['message']}"
            end
          elsif msg["action"] == "progress"
            # Persist progress events so the dashboard (which falls back to
            # HTTP polling in Ruby) can display them in the Progress Stream.
            append_progress_event(msg)
            @ws_mutex.synchronize do
              @ws_clients.each do |ws|
                ws.send(msg.to_json)
              end
            end
          elsif msg["action"] == "max_retries_reached"
            task_type = msg["task_type"]
            handler = nil
            @handlers_mutex.synchronize do
              handler = @max_retry_handlers[task_type]
            end

            if handler
              Thread.new do
                begin
                  raw_data = msg["task_data"]
                  task_data = raw_data.is_a?(String) ? JSON.parse(raw_data) : raw_data
                  Thread.current[:snerd_task_id] = msg["task_id"]
                  handler.call(task_data)
                rescue => e
                  warn "[Snerd] Error in max retry handler for task #{msg['task_id']}: #{e.message}"
                end
              end
            else
              warn "[Snerd] Dead Letter Queue: Task #{msg['task_id']} (#{msg['task_type']}) permanently failed."
            end
          end
        rescue JSON::ParserError
          # Ignore malformed stdout lines
        end
      end
    rescue IOError, Errno::EPIPE
      # Normal when shutting down
    end

    def handle_execute(msg)
      task_id = msg["task_id"]
      task_type = msg["task_type"]
      max_execution_seconds = msg["max_execution_seconds"]
      
      raw_data = msg["task_data"]
      task_data = raw_data.is_a?(String) ? JSON.parse(raw_data) : raw_data

      handler = nil
      @handlers_mutex.synchronize do
        handler = @handlers[task_type]
      end

      unless handler
        send_message({
          action: "result",
          task_id: task_id,
          status: "error",
          error_msg: "No handler registered."
        })
        return
      end

      begin
        Thread.current[:snerd_task_id] = task_id
        if max_execution_seconds
          Timeout.timeout(max_execution_seconds) do
            handler.call(task_data)
          end
        else
          handler.call(task_data)
        end
        send_message({
          action: "result",
          task_id: task_id,
          status: "success"
        })
      rescue Timeout::Error
        send_message({
          action: "result",
          task_id: task_id,
          status: "error",
          error_msg: "Task execution timed out after #{max_execution_seconds} seconds"
        })
      rescue => e
        send_message({
          action: "result",
          task_id: task_id,
          status: "error",
          error_msg: e.message
        })
      end
    end

    def yield_progress(data)
      task_id = Thread.current[:snerd_task_id]
      raise "[Snerd] yield_progress must be called within a task handler context." unless task_id
      send_message({ action: "progress", task_id: task_id, data: data })
    end

    def start_dashboard(port: 8080)
      require 'rack'
      require 'puma'
      require 'faye/websocket'
      require 'json'
      
      app = lambda do |env|
        if Faye::WebSocket.websocket?(env)
          ws = Faye::WebSocket.new(env)
          @ws_mutex.synchronize { @ws_clients << ws }
          ws.on(:close) do |event|
            @ws_mutex.synchronize { @ws_clients.delete(ws) }
          end
          return ws.rack_response
        end

        req = Rack::Request.new(env)
        cors_headers = {
          'Access-Control-Allow-Origin' => '*',
          'Access-Control-Allow-Methods' => 'GET, POST, OPTIONS'
        }

        if req.options?
          return [204, cors_headers, []]
        end

        if req.get? && req.path == '/'
          html_path = File.expand_path("../../static/index.html", __dir__)
          if File.exist?(html_path)
            return [200, { 'Content-Type' => 'text/html' }, [File.read(html_path)]]
          else
            return [404, {}, ['Dashboard UI not found']]
          end
        elsif req.get? && req.path == '/api/progress'
          events = []
          progress_path = File.join(@storage_path || './.snerdata', 'progress_events.log')
          if File.exist?(progress_path)
            File.readlines(progress_path).last(100).each do |line|
              begin
                ev = JSON.parse(line)
                events << ev if ev.is_a?(Hash) && ev['ts']
              rescue
              end
            end
          end
          return [200, { 'Content-Type' => 'application/json' }.merge(cors_headers), [events.to_json]]
        elsif req.get? && req.path == '/api/stats'
          stats = { enqueued: 0, processed: 0, failed: 0 }
          tasks_map = {}
          tasks_path = File.join(@storage_path || './.snerdata', 'tasks', 'tasks.log')
          if File.exist?(tasks_path)
            File.readlines(tasks_path).each do |line|
              next if line.strip.empty?
              begin
                t = JSON.parse(line)
                tasks_map[t['taskId']] = t if t['taskId']
              rescue
              end
            end
          end
          tasks_map.values.each do |t|
            stats[:enqueued] += 1
            if t['deletedAt']
              if t['LastJobError']
                stats[:failed] += 1
              else
                stats[:processed] += 1
              end
            end
          end
          return [200, { 'Content-Type' => 'application/json' }.merge(cors_headers), [stats.to_json]]
        elsif req.get? && req.path == '/api/tasks'
          tasks_map = {}
          tasks_path = File.join(@storage_path || './.snerdata', 'tasks', 'tasks.log')
          if File.exist?(tasks_path)
            File.readlines(tasks_path).each do |line|
              next if line.strip.empty?
              begin
                t = JSON.parse(line)
                tasks_map[t['taskId']] = t
              rescue
              end
            end
          end
          
          formatted = []
          tasks_map.values.each do |t|
            if t['deletedAt']
              if t['LastJobError'] && (t['retryCount'] || 0) >= (t['maxRetries'] || 3)
                status = 'dead_letter'
              elsif t['LastJobError']
                status = 'failed'
              else
                status = 'completed'
              end
            elsif t['LastJobError']
              status = 'failed'
            else
              status = 'queued'
              if t['executeAt']
                begin
                  status = 'active' if Time.parse(t['executeAt']) <= Time.now
                rescue
                end
              end
            end
            formatted << {
              id: t['taskId'],
              type: t['taskType'],
              status: status,
              progress: 0,
              retryCount: t['retryCount'] || 0,
              maxRetries: t['maxRetries'] || 3,
              retryAfterTime: t['retryAfterTime'],
              cronExpression: t['cronExpression'],
              webhookUrl: t['webhookUrl'],
              maxExecutionSeconds: t['maxExecutionSeconds']
            }
          end
          return [200, { 'Content-Type' => 'application/json' }.merge(cors_headers), [formatted.first(50).to_json]]
        end

        [404, {}, []]
      end

      Thread.new do
        puts "[Snerd] Dashboard running on http://localhost:#{port}"
        server = Puma::Server.new(app)
        server.add_tcp_listener('0.0.0.0', port)
        server.run
      end
    end

    private

    def append_progress_event(msg)
      dir = @storage_path || './.snerdata'
      return unless File.directory?(dir)
      path = File.join(dir, 'progress_events.log')

      event = { ts: Time.now.to_f, task_id: msg['task_id'], data: msg['data'] }.to_json
      File.open(path, 'a') { |f| f.puts(event) }

      # Keep the file bounded: retain only the most recent events
      if File.size(path) > 512 * 1024
        lines = File.readlines(path).map(&:strip).reject(&:empty?)
        File.write(path, lines.last(200).join("\n") + "\n")
      end
    rescue
      # Never break the listener loop over progress persistence
    end

    def send_message(msg)
      @stdin_mutex.synchronize do
        return if @shutting_down || @io.nil? || @io.closed?
        @io.puts(msg.to_json)
        @io.flush
      end
    rescue Errno::EPIPE, Errno::EIO, IOError
      # Broken pipe / IO error if the daemon died unexpectedly
    end
  end
end
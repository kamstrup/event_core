require 'fcntl'
require 'monitor'
require 'thread'
require 'fiber'

# TODO:
# - Maybe a super simple event bus
# - unit tests for error reporting in add_read/write



module EventCore

  # Low level event source representation.
  # Only needed when the convenience APIs on EventLoop are not enough.
  class Source

    def initialize
      @closed = false
      @ready = false
      @timeout_secs = nil
      @trigger = nil
    end

    # Check if a source is ready. Called on each main loop iteration.
    # May have side effects, but should not leave ready state until
    # consume_event_data!() has been called.
    def ready?
      @ready
    end

    # Mark source as ready
    def ready!(event_data=nil)
      @ready = true
      @event_data = event_data
    end

    # Timeout in seconds, or nil
    def timeout
      @timeout_secs
    end

    # An optional IO object to select on
    def select_io
      nil
    end

    # Returns :read, :write, or nil. If select_io is non-nil,
    # then the select_type must not be nil.
    def select_type
      nil
    end

    # Consume pending event data and set readiness to false
    def consume_event_data!
      raise "Source not ready: #{self}" unless ready?
      data = @event_data
      @event_data = nil
      @ready = false
      data
    end

    # Raw event data is passed to this function before passed to the trigger
    def event_factory(event_data)
      event_data
    end

    # Check to see if close!() has been called.
    def closed?
      @closed
    end

    # Close this source, marking it for removal from the main loop.
    def close!
      @closed = true
      @trigger = nil # Help the GC, if the closure holds onto some data
    end

    # Set the trigger function to call on events to the given block
    def trigger(&block)
      @trigger = block
    end

    # Consume pending event data and fire the trigger,
    # closing if the trigger returns (explicitly) false.
    def notify_trigger
      event_data = consume_event_data!
      event = event_factory(event_data)
      if @trigger
        # Not just !@trigger.call(event), we want explicitly "false"
        close! if @trigger.call(event) == false
      end
    end
  end

  # Idle sources are triggered on each iteration of the event loop.
  class IdleSource < Source

    def initialize(event_data=nil)
      super()
      @ready = true
      @event_data = event_data
    end

    def ready?
      true
    end

    def timeout
      0
    end

    def consume_event_data!
      @event_data
    end

  end

  # A source that triggers when data is ready to be read from an internal pipe.
  # Send data to the pipe with the (blocking) write() method.
  class PipeSource < Source

    attr_reader :rio, :wio

    def initialize
      super()
      @rio, @wio = IO.pipe
      @rio.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC | Fcntl::O_NONBLOCK)
      #@wio.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC | Fcntl::O_NONBLOCK)
      @buffer_size = 4096
    end

    def select_io
      @rio
    end

    def select_type
      :read
    end

    def consume_event_data!
      begin
        @rio.read_nonblock(@buffer_size)
      rescue EOFError
        nil
      end
    end

    def closed?
      @rio.closed?
    end

    def close!
      super
      @rio.close unless @rio.closed?
      @wio.close unless @wio.closed?
    end

    def write(buf)
      @wio.write(buf)
    end

  end

  class IOSource < Source

    attr_accessor :auto_close

    def initialize(io, type)
      super()
      raise "Nil IO provided" if io.nil?
      @io = io
      @type = type
      @auto_close = true
      raise "Invalid select type: #{type}" unless [:read, :write].include?(type)
    end

    def select_io
      @io
    end

    def select_type
      @type
    end

    def consume_event_data!
      nil
    end

    def close!
      super
      @io.close if @auto_close and not @io.closed?
    end

  end

  class FiberSource < Source

    def initialize(loop, proc)
      super()
      raise "First arg must be a MainLoop: #{loop}" unless loop.is_a? MainLoop
      raise "Second arg must be a Proc: #{proc.class}" unless proc.is_a? Proc

      @loop = loop
      @fiber = Fiber.new do
        proc.call
      end

      @ready = true

      trigger { |async_task_data|
        task = @fiber.resume(async_task_data)

        # If yielding, maybe spawn an async sub-task?
        if @fiber.alive?
          if task.is_a? Proc
            @ready = false
            loop.add_once {
              fiber_task = FiberTask.new(self)
              task.call(fiber_task)
            }
          elsif task.nil?
            # all good, just yielding until next loop iteration
          else
            raise "Fibers that yield must return nil or a Proc: #{task.class}"
          end
        end

        next @fiber.alive?
      }
    end

    def ready!(event_data=nil)
      super(event_data)
      @loop.send_wakeup
    end

    def consume_event_data!
      event_data = super
      @ready = true
      event_data
    end

    def close!
      super
      @fiber = nil
    end
  end

  class FiberTask
    def initialize(fiber_source)
      @fiber_source = fiber_source
    end

    def done(result)
      @fiber_source.ready!(result)
    end
  end

  # A source that marshals Unix signals to be handled in the main loop.
  # This detaches you from the dreaded "trap context", and allows
  # you to reason about the state of the rest of your app
  # in the signal handler.
  #
  # The trigger is called with an array of signals as argument.
  # There can be more than one signal if more than one signal fired
  # since the source was last checked.
  #
  # Closing the signal handler will set the trap handler to DEFAULT.
  class UnixSignalSource < PipeSource

    # Give it a list of signals, names or integers, to listen for.
    def initialize(*signals)
      super()
      @signals = signals
      @signals.each do |sig|
        Signal.trap(sig) do
          write("#{sig}+")
        end
      end
    end

    def event_factory(event_data)
      # We may have received more than one signal since last check
      event_data.split('+')
    end

    def close!
      super
      # Restore default signal handlers
      @signals.each { |sig| Signal.trap(sig, "DEFAULT")}
    end

  end

  # A source that fires the trigger depending on a timeout.
  class TimeoutSource < Source
    def initialize(secs)
      super()
      @timeout_secs = secs
      @next_timestamp = Time.now.to_f + secs
    end

    def ready?
      return true if @ready

      now = Time.now.to_f
      if now >= @next_timestamp
        ready!
        @next_timestamp = now + @timeout_secs
        return true
      end
      false
    end

    def timeout
      delta = @next_timestamp - Time.now.to_f
      delta > 0 ? delta : 0
    end
  end

  # Core data structure for handling and polling Sources.
  class MainLoop

    def initialize
      # We use a monitor, not a mutex, becuase Ruby mutexes are not reentrant,
      # and we need reentrancy to be able to add sources from within trigger callbacks
      @monitor = Monitor.new

      @monitor.synchronize {
        @sources = []
        @quit_handlers = []

        # Only ever set @do_quit through the quit() method!
        # Otherwise the state of the loop will be undefiend
        @do_quit = false
        @control_source = PipeSource.new
        @control_source.trigger { |event|
          # We can get multiple control messages in one event,
          # so generally it is a "string of control chars", hence the include? and not ==
          # If event is nil, it means the pipe has been closed
          @do_quit = true if event.nil? || event.include?('q')
        }
        @sources << @control_source

        @sigchld_source = nil
        @children = []

        @thread = nil
      }
    end

    # Add an event source to check in the loop. You can do this from any thread,
    # or from trigger callbacks, or whenever you please.
    # Returns the source, so you can close!() it when no longer needed.
    def add_source(source)
      @monitor.synchronize {
        wakeup_needed = !@thread.nil? && @thread != Thread.current
        raise "Unable to add source - loop terminated" if @sources.nil?
        @sources << source
        send_wakeup if wakeup_needed
      }
      source
    end

    # Add an idle callback to the loop. Will be removed like any other
    # if it returns with 'next false'.
    # For one-off dispatches into the main loop, fx. for callbacks from
    # another thread add_once() is even more convenient.
    # Returns the source, so you can close!() it when no longer needed.
    def add_idle(&block)
      source = IdleSource.new
      source.trigger { next false if block.call == false }
      add_source(source)
    end

    # Add an idle callback that is removed after its first invocation,
    # no matter how it returns.
    # Returns the source, for API consistency, but it is not really useful,
    # as it will be auto-closed on next mainloop iteration.
    def add_once(delay_secs=nil, &block)
      source = delay_secs.nil? ? IdleSource.new : TimeoutSource.new(delay_secs)
      source.trigger { block.call; next false  }
      add_source(source)
    end

    # Add a timeout function to be called periodically, or until it returns with 'next false'.
    # The timeout is in seconds and the first call is fired after it has elapsed.
    # Returns the source, so you can close!() it when no longer needed.
    def add_timeout(secs, &block)
      source = TimeoutSource.new(secs)
      source.trigger { next false if block.call == false }
      add_source(source)
    end

    # Add a unix signal handler that is dispatched in the main loop.
    # The handler will receive an array of signal numbers that was triggered
    # since last step in the loop. You can provide one or more signals
    # to listen for, given as integers or names.
    # Returns the source, so you can close!() it when no longer needed.
    def add_unix_signal(*signals, &block)
      source = UnixSignalSource.new(*signals)
      source.trigger { |signals|  next false if block.call(signals) == false }
      add_source(source)
    end

    # Asynchronously write buf to io. Invokes block when complete,
    # giving any encountered exception as argument, nil on success.
    # Returns the source so you can close! it to cancel.
    def add_write(io, buf, &block)
      source = IOSource.new(io, :write)
      source.trigger {
        begin
          # Note: because of string encoding snafu, Ruby can report more bytes read than buf.length!
          len = io.write_nonblock(buf)
          if len == buf.bytesize
            block.call(nil) unless block.nil?
            next false
          end
          buf = buf.byteslice(len..-1)
          next true
        rescue IO::WaitWritable
          # All good, wait until we're writable again
          next true
        rescue => e
          block.call(e) unless block.nil?
          next false
        end
      }
      add_source(source)
    end

    # Asynchronously read an IO calling the block each time data is ready.
    # The block receives to arguments: the read buffer, and an exception.
    # The read buffer will be nil when EOF has been reached in which case
    # the IO will be closed and the source removed from the loop.
    # Returns the source so you can cancel the read with source.close!
    def add_read(io, &block)
      source = IOSource.new(io, :read)
      source.trigger {
        begin
          loop do
            buf = io.read_nonblock(4096*4) # 4 pages
            block.call(buf, nil)
          end
        rescue IO::WaitReadable
          # All good, wait until we're writable again
          next true
        rescue EOFError
          block.call(nil, nil)
          next false
        rescue => e
          block.call(nil, e)
          next false
        end
      }
      add_source(source)
    end

    def add_fiber(&block)
      source = FiberSource.new(self, block)
      add_source(source)
    end

    # Add a callback to invoke when the loop is quitting, before it becomes invalid.
    # Sources added during the callback will not be invoked, but will be cleaned up.
    def add_quit(&block)
      @monitor.synchronize {
        @quit_handlers << block
      }
    end

    # Like Process.spawn(), invoking the given block in the main loop when
    # the process child process exits. The block is called with the Process::Status
    # object of the child.
    #
    # WARNING: The main loop install a SIGCHLD handler to automatically wait() on processes
    # started this way. So this function will not work correctly if you tamper with
    # SIGCHLD yourself.
    #
    # When you quit the loop any non-waited for children will be detached with Process.detach()
    # to prevent zombies.
    #
    # Returns the PID of the child (that you should /not/ wait() on).
    def spawn(*args, &block)
      if @sigchld_source.nil?
        @sigchld_source = add_unix_signal("CHLD") {
          reap_children
        }
      end

      pid = Process.spawn(*args)
      @children << {:pid => pid, :block => block}
      pid
    end

    # The Thread instance currently iterating the run() method.
    # nil if the loop is not running
    def thread
      @thread
    end

    # Returns true iff a thread is currently iterating the loop with the run() method.
    def running?
      !@thread.nil?
    end

    # Safe and clean shutdown of the loop.
    # Note that the loop will only shut down on next iteration, not immediately.
    def quit
      # Does not require locking. If any data comes through in what ever form,
      # we quit the loop
      send_control('q')
    end

    # Start the loop, and do not return before some calls quit().
    # When the loop returns (via quit) it will call close! on all sources.
    def run
      @thread = Thread.current

      loop do
        step
        break if @do_quit
      end

      @monitor.synchronize {
        @quit_handlers.each { |block| block.call }

        @children.each { |child| Process.detach(child[:pid]) }
        @children = nil

        @sources.each { |source| source.close! }
        @sources = nil

        @control_source.close!

        @thread = nil
      }
    end

    # Expert: Run a single iteration of the main loop.
    def step
      # Collect sources
      ready_sources = []
      select_sources_by_ios = {}
      read_ios = []
      write_ios = []
      timeout = 0

      @monitor.synchronize {
        @sources.delete_if do |source|
          if source.closed?
            true
          else
            ready_sources << source if source.ready?

            io = source.select_io
            unless io.nil? || io.closed?
              case source.select_type
                when :read
                  read_ios << io
                when :write
                  write_ios << io
                else
                  raise "Invalid source select_type: #{source.select_type}"
              end

              select_sources_by_ios[io] = source
            end

            dt = source.timeout
            timeout = dt.nil? ? 0 : (dt < timeout ? dt : timeout)

            false
          end
        end
      }

      # Release lock while we're selecting so users can add sources. add_source() will see
      # that we are stuck in a select() and do send_wakeup().
      # Note: Only select() without locking, everything else must be locked!
      read_ios, write_ios, exception_ios = IO.select(read_ios, write_ios, [], timeout)

      @monitor.synchronize {
        # On timeout read_ios will be nil
        unless read_ios.nil?
          read_ios.each { |io|
            ready_sources << select_sources_by_ios[io]
          }
        end

        unless write_ios.nil?
          write_ios.each { |io|
            ready_sources << select_sources_by_ios[io]
          }
        end
      }

      # Dispatch all sources marked ready
      ready_sources.each { |source|
        source.notify_trigger
      }

      @do_quit = true if @control_source.closed?
    end

    # Expert: wake up the main loop, forcing it to check all sources.
    # Useful if you're twiddling readyness of sources "out of band".
    def send_wakeup
      send_control('.')
    end

    private
    def send_control(char)
      raise "Illegal control character '#{char}'" unless ['.', 'q'].include?(char)
      @control_source.write(char)
    end

    private
    def reap_children
      # Waiting on pid -1, to reap any child would be tempting, but that could conflict
      # with other parts of code, not using EventCore, trying to wait() on those pids.
      # In stead we have to check each child explicitly spawned via loop.spawn(). This
      # is O(N) in the number of children, naturally, but I haven't found a better way
      # that is robust.
      @children.delete_if {|child|
        if Process.wait(child[:pid], Process::WNOHANG)
          status = $?
          child[:block].call(status) unless child[:block].nil?
          true
        else
          false
        end
      }
    end
  end

end

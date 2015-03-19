require 'fcntl'
require 'monitor'
require 'thread'

# TODO:
# - IOSource
# - Child process reaper

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
    def select_io()
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
      @event_data
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

    alias :super_close! :close!

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

    def consume_event_data!
      @rio.read_nonblock(@buffer_size)
    end

    def closed?
      @rio.closed?
    end

    def close!
      super_close!
      @rio.close unless @rio.closed?
      @wio.close unless @wio.closed?
    end

    def write(buf)
      @wio.write(buf)
    end

  end

  # A source that mashals Unix signals to be handled in the main loop.
  # This detaches you from the dreaded Ruby "trap context", and allows
  # you to do what you like in the signal handler.
  #
  # The trigger is called with an array of signal numbers as argument.
  # There can be more than one signal number if more than one signal fired
  # since the source was last checked. Signal names can be recovered with
  # Signal.signame().
  class UnixSignalSource < PipeSource

    # We need to allocate the signal messages we send over the pipe up front,
    # to avoid allocating memory (building strings) inside the signal trap context.
    # A signal message is just its integer value as a string trailed by a newline.
    SIGNAL_MESSAGES_BY_SIGNO = Hash[Signal.list.map {|k,v| [v, "#{v}\n"]}]

    # Give it a list of signals, names or integers, to listen for.
    def initialize(*signals)
      super()
      @signals = signals.map { |sig| sig.is_a?(Integer) ? Signal.signame(sig) : sig.to_s}
      @signals.each do |sig_name|
        Signal.trap(sig_name) do |signo|
          write(SIGNAL_MESSAGES_BY_SIGNO[signo])
        end
      end
    end

    def event_factory(event_data)
      # We may have received more than one signal since last check
      event_data.split('\n').map { |datum| datum.to_i }
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
  end

  # Core data structure for handling and polling Sources.
  class EventLoop

    def initialize
      @sources = []

      # Only ever set @do_quit through the quit() method!
      # Otherwise the state of the loop will be undefiend
      @do_quit = false
      @control_source = PipeSource.new
      @control_source.trigger { |event|
        # We can get multiple control messages in one event,
        # so generally it is a "string of control chars", hence the include? and not ==
        @do_quit = true if event.include?('q')
      }
      @sources << @control_source

      # We use a monitor, not a mutex, becuase Ruby mutexes are not reentrant,
      # and we need reentrancy to be able to add sources from within trigger callbacks
      @monitor = Monitor.new

      @selecting = false
    end

    # Add an event source to check in the loop. You can do this from any thread,
    # or from trigger callbacks, or whenever you please.
    # Returns the source, so you can close!() it when no longer needed.
    def add_source(source)
      @monitor.synchronize {
        @sources << source
        send_wakeup if @selecting
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
    def add_once(&block)
      source = IdleSource.new
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

    # Safe and clean shutdown of the loop.
    # Note that the loop will only shut down on next iteration, not immediately.
    def quit
      # Does not require locking. If any data comes through in what ever form,
      # we quit the loop
      send_control('q')
    end

    # Start the loop, and do not return before some calls quit().
    def run
      loop do
        step
        break if @do_quit
      end

      @sources = nil
      @control_source.close!
    end

    # Expert: Run a single iteration of the main loop.
    def step
      # Collect sources
      ready_sources = []
      select_sources_by_ios = {}
      timeouts = []

      @monitor.synchronize {
        @sources.delete_if do |source|
          if source.closed?
            puts "DEL #{source}"
            true
          else
            ready_sources << source if source.ready?

            unless source.select_io.nil?
              select_sources_by_ios[source.select_io] = source
            end

            timeouts << source.timeout unless source.timeout.nil?

            false
          end
        end

        # Dispatch all sources marked ready
        ready_sources.each { |source|
          source.notify_trigger
        }

        # Note1: select_sources_by_ios is never empty - we always have the quit source in there.
        #        We need that assumption to ensure timeouts work
        # Note2: timeouts.min is nil if there are no timeouts, causing infinite blocking - as intended
        @selecting = true
      }

      # Release lock while we're selecting so users can add sources. add_source() will see
      # that we are stuck in a select() and do send_wakeup().
      # Note: Only select() without locking, everything else must be locked!
      read_ios, write_ios, exception_ios = IO.select(select_sources_by_ios.keys, [], [], timeouts.min)

      @monitor.synchronize {
        @selecting = false

        # On timeout read_ios will be nil
        unless read_ios.nil?
          read_ios.each { |io|
            select_sources_by_ios[io].notify_trigger
          }
        end
      }
    end

    private
    def send_control(char)
      raise "Illegal control character '#{char}'" unless ['.', 'q'].include?(char)
      @control_source.write(char)
    end

    private
    def send_wakeup
      send_control('.')
    end
  end

end

if __FILE__ == $0
  loop = EventCore::EventLoop.new

  loop.add_unix_signal(1) { |signo|
    puts "SIG1: #{signo}"
  }

  loop.add_unix_signal(2) { |signo|
    puts "SIG2: #{signo}"
    puts "Quitting loop"
    loop.quit
  }

  loop.add_timeout(3) { puts "Time: #{Time.now.sec}" }

  i = 0
  loop.add_timeout(1) {
    i += 1
    puts "-- #{Time.now.sec}s i=#{i}"
    if i == 5
      loop.add_once { puts "SEND QUIT"; loop.quit }
      next false
    end
  }

  loop.add_once { puts "ONCE" }

  thr = Thread.new {
    sleep 4
    puts "Thread here"
    loop.add_idle { puts "WEEEE, idle callback in main loop, send from thread" }
    puts "Thread done"
  }

  loop.run
  puts "Loop exited gracefully"

  thr.join
end

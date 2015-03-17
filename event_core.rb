require 'fcntl'
require 'monitor'
require 'thread'

# TODO:
# - ThreadSource (source updated safely from another thread - fx. blocking resque poll)
# - API for removal of sources
# - map signo to static strings (with newlines) so we don't build strings in UnixSignalHandler

module EventCore

  class Event

  end

  class Source

    def initialize
      @closed = false
      @ready = false
      @timeout_secs = nil
      @trigger = nil
    end

    def ready?
      @ready
    end

    def ready!(event_data=nil)
      @ready = true
      @event_data = event_data
    end

    def timeout
      @timeout_secs
    end

    def select_io()
      nil
    end

    def consume_event_data!
      raise "Source not ready: #{self}" unless ready?
      data = @event_data
      @event_data = nil
      @ready = false
      data
    end

    def event_factory(event_data)
      event_data
    end

    def closed?
      @closed
    end

    def close!
      @closed = true
      @trigger = nil
    end

    def trigger(&block)
      @trigger = block
    end

    # Consume pending event data and fire all triggers.
    # Returns true if one or more triggers where removed
    # due to returning true
    def notify_trigger
      event_data = consume_event_data!
      event = event_factory(event_data)
      if @trigger && @trigger.call(event)
        close!
      end
    end
  end

  # Idle sources are triggered on each iteration of the event loop.
  # If any one of the triggers returns true the whole source will close
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

  class UnixSignalSource < PipeSource

    def initialize(*signals)
      super()
      @signals = signals.map { |sig| sig.is_a?(Integer) ? Signal.signame(sig) : sig.to_s}
      @signals.each do |sig_name|
        Signal.trap(sig_name) do |signo|
          puts "TRAP SIG #{signo}"
          write("#{signo}\n")
        end
      end
    end

    def event_factory(event_data)
      event_data.split('\n').map { |datum| datum.to_i }
    end

  end

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
    def add_source(source)
      @monitor.synchronize {
        @sources << source
        send_wakeup if @selecting
      }
    end

    # Add an idle callback to the loop. Will be removed like any other
    # if it returns with 'next true'.
    # For one-off dispatches into the main loop, fx. for callbacks from
    # another thread add_once() is even more convenient.
    def add_idle(&block)
      source = IdleSource.new
      source.trigger { next true if block.call  }
      add_source(source)
    end

    # Add an idle callback that is removed after its first invocation,
    # no matter how it returns.
    def add_once(&block)
      source = IdleSource.new
      source.trigger { block.call; next true  }
      add_source(source)
    end

    def add_timeout(secs, &block)
      source = TimeoutSource.new(secs)
      source.trigger { next true if block.call }
      add_source(source)
    end

    def quit
      # Does not require locking. If any data comes through in what ever form,
      # we quit the loop
      send_control('q')
    end

    def run
      loop do
        step
        break if @do_quit
      end

      @control_source.close!
    end

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

loop = EventCore::EventLoop.new
signals = EventCore::UnixSignalSource.new(1, 2)
signals.trigger { |event|
  puts "EVENT: #{event}"
  loop.quit if event.first == 2
}
loop.add_source(signals)

loop.add_timeout(3) { |event| puts "Time: #{Time.now.sec}"}

i = 0
loop.add_timeout(1) {|event|
  i += 1
  puts "-- #{Time.now.sec}s i=#{i}"
  if i == 10
    loop.add_once { puts "SEND QUIT"; loop.quit }
    next true
  end
}

loop.add_once { puts "ONCE" }

thr = Thread.new {
  sleep 4
  puts "Thread here"
  loop.add_once { puts "WEEEE"; loop.quit }
  puts "Thread done"
}

loop.run
puts "Loop exited gracefully"

thr.join

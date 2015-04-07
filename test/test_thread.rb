require 'thread'
require 'test/unit'
require 'event_core'

class TestThread < Test::Unit::TestCase

  def setup
    @loop = EventCore::MainLoop.new
    @mutex = Mutex.new
  end

  def teardown
    @loop = nil
    @mutex = nil
  end

  def test_threads10
    n = 0

    threads = (1..10).map {
      Thread.new {
        # Ensure we're adding sources while the main loop is running
        sleep 0.1
        @loop.add_idle { @mutex.synchronize { n += 1; next false } }
        @loop.add_once { @mutex.synchronize { n += 1 } }

        sleep 0.05

        @loop.add_once(0.05) { @mutex.synchronize { n += 1 } }
        @loop.add_once(0.05) {
          @loop.add_once { @mutex.synchronize { n += 1 } }
        }

        # Many threads issuing quit, while loop is blocked in select
        @loop.add_once(0.2) { @loop.add_once(1) { @loop.quit } }
      }
    }


    @loop.run
    threads.each { |t| t.join }

    assert_equal 40, n
  end
end
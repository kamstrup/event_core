require 'test/unit'
require 'event_core'

class TestTimeout < Test::Unit::TestCase

  def setup
    @loop = EventCore::MainLoop.new
  end

  def teardown
    @loop = nil
  end

  def test_1timeout
    got_timeout = false
    @loop.add_timeout(0.1) { got_timeout = true }
    sleep 0.2
    @loop.step
    assert_equal true, got_timeout
  end

  def test_1timeout_repeat
    ntimeouts = 0
    @loop.add_timeout(0.05) { ntimeouts += 1 }
    @loop.add_timeout(0.21) { @loop.quit }
    @loop.run
    assert 4 <= ntimeouts
  end

  def test_1timeout_once
    ntimeouts = 0
    @loop.add_timeout(0.05) { ntimeouts += 1; next false }
    @loop.add_timeout(0.21) { @loop.quit }
    @loop.run
    assert_equal 1, ntimeouts
  end

  def test_no_busy_spin
    # ample time to busy-check many times - in case we have a bug
    t = TimeoutCheckSource.new(0.5)
    t.trigger { @loop.quit; next false }
    @loop.add_source(t)
    @loop.run

    assert 1 <= t.nchecks and t.nchecks < 6
  end

  # Asserts that an idle source added from inside a slow timeout trigger is called
  # immediately - waking up the main loop.
  # We do this by adding a spinning idle trigger on the first tick of a 1s timeout,
  # and asserting that it does 10 busy spins before the second step of the 1s timeout
  def test_wakeup_from_timeout
    outer_counter = 0
    inner_counter = 0
    @loop.add_timeout(1) {
      if outer_counter >= 1
        fail("Inner loop not dispatched in time (inner: #{inner_counter}, outer: #{outer_counter})")
      end

      # This trigger should fire immediately and reach 10, before the next 1s timeout fires
      @loop.add_idle {
        inner_counter += 1
        if inner_counter == 10
          @loop.quit
          next false
        end
      }
      outer_counter += 1
    }
    @loop.run

    assert_equal 10, inner_counter
    assert_equal 1, outer_counter
  end

  class TimeoutCheckSource < EventCore::TimeoutSource

    attr_reader :nchecks

    def initialize(secs)
      super(secs)
      @nchecks = 0
    end

    def timeout
      t = super
      @nchecks += 1
      t
    end
  end

end
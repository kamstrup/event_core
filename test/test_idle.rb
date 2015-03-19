require 'test/unit'
require 'event_core'

class TestIdle < Test::Unit::TestCase

  def setup
    @loop = EventCore::EventLoop.new
  end

  def teardown
    @loop = nil
  end

  def test_1idle
    did_run = false
    idle = @loop.add_idle { did_run = true }
    @loop.step
    assert_equal true, did_run
    assert_equal false, idle.closed?
  end

  def test_1idle_nsteps
    nsteps = 0
    idle = @loop.add_idle { nsteps += 1 }

    (1..10).each { |n|
      @loop.step
      assert_equal n, nsteps
      assert_equal false, idle.closed?
    }
  end
end
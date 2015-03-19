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

  def test_2idle
    did_run1 = false
    did_run2 = false

    idle1 = @loop.add_idle { did_run1 = true }
    idle2 = @loop.add_idle { did_run2 = true }

    @loop.step

    assert_equal true, did_run1
    assert_equal true, did_run2
    assert_equal false, idle1.closed?
    assert_equal false, idle2.closed?
  end

  def test_nidle_nsteps
    nsteps = []
    idles = []
    (1..10).each {|i|
      nsteps << 0
      idles << @loop.add_idle { nsteps[i-1] += 1 }
    }

    (1..7).each {  @loop.step }

    (1..10).each {|i|
      assert_equal 7, nsteps[i-1]
      assert_equal false, idles[i-1].closed?
    }
  end
end
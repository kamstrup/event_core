require 'test/unit'
require 'event_core'

class TestUnixSignal < Test::Unit::TestCase

  def setup
    @loop = EventCore::EventLoop.new
    @sources = []
  end

  def teardown
    @loop = nil
    @sources.each {|source| source.close! } # To detach signal handlers
  end

  def test_1sig
    got_signal = false
    @sources << @loop.add_unix_signal("USR2") { got_signal = true }
    Process.kill("USR2", Process.pid)
    sleep 0.2 # Allow signal to reach back to us
    @loop.step
    assert_equal true, got_signal
  end

  def test_1sig_multi
    nsignals = 0
    @sources << @loop.add_unix_signal("USR2") { |signals| nsignals += signals.length}

    (1..10).each {
      Process.kill("USR2", Process.pid)
      sleep 0.2 # Allow signal to reach back to us
    }
    @loop.step
    assert_equal 10, nsignals
  end

  def test_2sig
    got_signal1 = false
    got_signal2 = false
    @sources << @loop.add_unix_signal("USR1") { got_signal1 = true }
    @sources << @loop.add_unix_signal("USR2") { got_signal2 = true }
    Process.kill("USR1", Process.pid)
    Process.kill("USR2", Process.pid)
    sleep 0.5 # Allow signals reach back to us
    @loop.step
    assert_equal true, got_signal1
    assert_equal true, got_signal2
  end

end
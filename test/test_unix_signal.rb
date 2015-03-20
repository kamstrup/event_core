require 'test/unit'
require 'event_core'

class TestUnixSignal < Test::Unit::TestCase

  def setup
    @loop = EventCore::MainLoop.new
    @loop.add_once(30) { raise 'Test timed out!' }
    @sources = []
  end

  def teardown
    @loop = nil
    @sources.each {|source| source.close! } # To detach signal handlers
  end

  def test_1sig
    nsignals = 0
    @sources << @loop.add_unix_signal("USR2") { nsignals += 1 }
    @loop.add_once(0.2) { Process.kill("USR2", Process.pid) }
    @loop.add_once(0.4) { @loop.quit }
    @loop.run
    assert_equal 1, nsignals
  end

  def test_1sig_multi
    nsignals = 0
    @sources << @loop.add_unix_signal("USR2") { |signals| nsignals += signals.length}

    (1..10).each { |i|
      @loop.add_once(0.2*i) { Process.kill("USR2", Process.pid) }
    }
    @loop.add_once(11*0.2) { @loop.quit }

    @loop.run
    assert_equal 10, nsignals
  end

  def test_2sig
    got_signal1 = false
    got_signal2 = false
    @sources << @loop.add_unix_signal("HUP") { got_signal1 = true }
    @sources << @loop.add_unix_signal("USR2") { got_signal2 = true }
    @loop.add_once(0.2) { Process.kill("HUP", Process.pid) }
    @loop.add_once(0.3) { Process.kill("USR2", Process.pid) }
    @loop.add_once(0.4) { @loop.quit }
    @loop.run
    assert_equal true, got_signal1
    assert_equal true, got_signal2
  end

end
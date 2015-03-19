require 'test/unit'
require 'event_core'

class TestSpawn < Test::Unit::TestCase

  def setup
    @loop = EventCore::EventLoop.new
  end

  def teardown
    @loop = nil
  end

  def test_ls
    status = nil
    @loop.spawn("ls", :out => '/dev/null') { |_status| status = _status; @loop.quit }
    @loop.add_timeout(0.5) { @loop.quit }
    @loop.run

    assert_not_nil status
    assert status.success?
    assert status.exited?
    assert !status.signaled?
    assert !status.stopped?
    assert !status.coredump?
  end

  def test_kill_sleep
    status = nil
    pid = @loop.spawn("sleep 10", :err => :out, :out => '/dev/null') { |_status| status = _status; @loop.quit }
    @loop.add_once(0.5) { Process.kill(9, pid) }
    @loop.run

    assert_not_nil status
    assert !status.success?
    assert !status.exited?
    assert status.signaled?
    assert_equal 9, status.termsig
    assert !status.stopped?
    assert !status.coredump?
  end

  def test_no_block
    @loop.spawn("ls", :out => '/dev/null')
    @loop.add_once(0.2) { @loop.quit }
    @loop.run

    # Implicit check: should not crash because we don't provide a block
  end

end
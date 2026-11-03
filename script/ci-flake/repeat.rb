# Run with a versioned Ruby through Bundler, from the repository root.
# REPEAT=100 TEST_NAMES=test_eof_error_length,test_eof_error_rest ...
$stdout.sync = true
root = ENV.fetch('HTTPCLIENT_PROJECT_ROOT', Dir.pwd)
require File.join(root, ENV.fetch('TEST_FILE', 'test/test_httpclient'))
require File.join(__dir__, 'variants')
require 'test/unit/ui/console/testrunner'
Test::Unit::AutoRunner.need_auto_run = false

module TimeoutTiming
  def timeout(seconds, *arguments, &block)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    wall_started = Time.now
    super
  rescue HTTPClient::TimeoutError => error
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    warn "TIMEOUT test=#{Thread.current.thread_variable_get(:flake_test).inspect} class=#{error.class} configured=#{seconds} elapsed=#{elapsed.round(6)} wall_elapsed=#{(Time.now - wall_started).round(6)}"
    warn "threads=#{Thread.list.map { |t| [t.object_id, t.status, t.backtrace && t.backtrace.first(4)] }.inspect}"
    raise
  end
end
Timeout.singleton_class.prepend(TimeoutTiming) unless ENV['NO_TIMING'] == '1'

# Optional instrumentation changes scheduling; compare with uninstrumented runs.
if ENV['TRACE_TIMEOUT_RAISES'] == '1'
  module TraceTimerCreation
    def start(*arguments, &block)
      created = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      origin = caller.first(3)
      super(*arguments) do |*yielded|
        Thread.current.thread_variable_set(:timer_created, created)
        Thread.current.thread_variable_set(:timer_origin, origin)
        block.call(*yielded)
      end
    end
  end
  module TraceTimerRaise
    def raise(*arguments)
      if arguments.first.is_a?(Class) && arguments.first <= HTTPClient::TimeoutError
        created = Thread.current.thread_variable_get(:timer_created)
        age = created && Process.clock_gettime(Process::CLOCK_MONOTONIC) - created
        warn "TIMER_RAISE class=#{arguments.first} age=#{age} origin=#{Thread.current.thread_variable_get(:timer_origin).inspect} caller=#{caller.first(3).inspect}"
      end
      super
    end
  end
  Thread.singleton_class.prepend(TraceTimerCreation)
  Thread.prepend(TraceTimerRaise)
end

suite = Test::Unit::TestSuite.new('Repeated CI failures')
test_class = Object.const_get(ENV.fetch('TEST_CLASS', 'TestHTTPClient'))
if ENV['NO_TIMING'] != '1'
  module CurrentFlakeTest
    def run(*arguments, &block)
      Thread.current.thread_variable_set(:flake_test, [name, instance_variable_get(:@flake_iteration)])
      super
    ensure
      Thread.current.thread_variable_set(:flake_test, nil)
    end
  end
  test_class.prepend(CurrentFlakeTest)
end
names = ENV.fetch('TEST_NAMES', 'test_eof_error_length,test_eof_error_rest,test_get_content').split(',')
abort "unknown tests: #{(names - test_class.public_instance_methods.map(&:to_s)).inspect}" unless
  (names - test_class.public_instance_methods.map(&:to_s)).empty?
repetitions = Integer(ENV.fetch('REPEAT', '100'))
abort 'REPEAT must be positive' unless repetitions > 0
repetitions.times do |iteration|
  names.each do |name|
    test = test_class.new(name)
    test.instance_variable_set(:@flake_iteration, iteration + 1)
    suite << test
  end
end
puts RUBY_DESCRIPTION
puts "tests=#{names.inspect} repetitions=#{repetitions} timing=#{ENV['NO_TIMING'] != '1'}"
timeout_method = Timeout.method(:timeout)
timeout_method = timeout_method.super_method unless ENV['NO_TIMING'] == '1'
puts "timeout=#{timeout_method.source_location.inspect}"
puts "gems=#{Gem.loaded_specs.values.map { |s| [s.name, s.version.to_s] }.sort.inspect}"
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = Test::Unit::UI::Console::TestRunner.run(suite, :output_level => 2)
puts "elapsed=#{Process.clock_gettime(Process::CLOCK_MONOTONIC) - started}"
puts result.to_s
exit(result.passed? ? 0 : 1)
